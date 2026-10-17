defmodule PhoenixKitEcommerce.API.CartStore do
  @moduledoc """
  Cart rows of the public cart API: finding the cart behind a cart token,
  creating it lazily on the first write, and the revision snapshots that
  `changes_since` needs.

  The cart behind a token is the row whose `session_id` is
  `CartToken.session_id(hash)`. Once a checkout claim has moved or merged
  that cart, the token is answered from `phoenix_kit_shop_cart_claims`
  (`resolve/1`), which is how `cart_locked` stays reachable.

  `for_write/3` and `lock_active!/2` must run inside a transaction (they raise
  otherwise: the locks they take would protect nothing).

  Every `hash` argument trusts its caller: it must be the digest that
  `CartToken.verify/1` returned. Never pass `ctx.actor.cart_token_hash` -
  core's executor fills that from the raw token string without checking its
  signature, so any string would then create `api:` rows and read counters.
  """

  import Ecto.Query, warn: false

  # Core's API modules exist only in the core release that carries the shop API;
  # until the package's core floor follows it, the package must still compile
  # against the core it is built with.
  @compile {:no_warn_undefined, PhoenixKit.API.RateLimit}

  alias PhoenixKit.API.RateLimit
  alias PhoenixKit.RepoHelper
  alias PhoenixKitBilling.Currency
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.API.CartToken
  alias PhoenixKitEcommerce.Cart
  alias PhoenixKitEcommerce.CartClaim

  @preloads [:items, :shipping_method]
  @snapshot_limit 10

  @type resolved :: {:ok, Cart.t()} | :empty | {:locked, CartClaim.t()} | :not_found

  @doc """
  What the token's hash stands for right now: an active cart, an empty open
  cart (a signed token that has not written yet), a claimed cart (`:locked`)
  or a swept one (`:not_found`).
  """
  @spec resolve(String.t()) :: resolved()
  def resolve(hash) when is_binary(hash), do: resolve(hash, @preloads)

  defp resolve(hash, preloads) do
    case latest_cart(CartToken.session_id(hash), preloads) do
      %Cart{status: "active"} = cart -> {:ok, cart}
      %Cart{} -> locked_or(hash, :not_found)
      nil -> locked_or(hash, :empty)
    end
  end

  @doc """
  True when no cart row stands for the token yet and it is not claimed. Cheaper
  than `resolve/1`: it reads neither the lines nor the shipping method.
  """
  @spec empty?(String.t()) :: boolean()
  def empty?(hash) when is_binary(hash), do: resolve(hash, []) == :empty

  @doc """
  The cart a write goes to, creating it on the first write.

  Takes the session lock, re-resolves under it (a concurrent first write may
  have created the row), then either locks the existing active cart
  (`:existing`) or charges the row limits and creates it (`:created`).

  Options: `count_row: false` skips the limit charge (a dry run).
  """
  @spec for_write(String.t(), map(), keyword()) ::
          {:ok, Cart.t(), :existing | :created}
          | {:locked, CartClaim.t()}
          | :not_found
          | {:error, :rate_limited, pos_integer()}
          | {:error, term()}
  def for_write(hash, ctx, opts \\ []) when is_binary(hash) do
    session_id = CartToken.session_id(hash)
    Shop.lock_cart_identity!(nil, session_id)

    case resolve(hash, []) do
      {:ok, cart} -> lock_existing(cart, hash)
      :empty -> create(session_id, ctx, Keyword.get(opts, :count_row, true))
      {:locked, claim} -> {:locked, claim}
      :not_found -> :not_found
    end
  end

  @doc """
  Locks a cart row (`FOR UPDATE`) and returns it fresh, with lines and the
  shipping method, **if it is still the active cart of the token `hash`**.
  A cart that was swept, merged or moved to a browser session while the
  caller waited for the lock rolls the surrounding transaction back with
  `gone/1`'s answer: `{:locked, claim}` or `:not_found`.
  """
  @spec lock_active!(String.t(), String.t()) :: Cart.t()
  def lock_active!(cart_uuid, hash) when is_binary(cart_uuid) and is_binary(hash) do
    if not repo().in_transaction?() do
      raise ArgumentError, "lock_active!/2 must be called inside a transaction"
    end

    case lock_row(cart_uuid, hash) do
      {:ok, cart} -> cart
      {:gone, outcome} -> repo().rollback(outcome)
    end
  end

  @doc """
  What a token stands for once its cart cannot be written to: `{:locked,
  claim}` when a used claim exists (the cart was handed to a buyer), else
  `:not_found` (swept, abandoned, never there).
  """
  @spec gone(String.t()) :: {:locked, CartClaim.t()} | :not_found
  def gone(hash) when is_binary(hash) do
    case resolve(hash) do
      {:locked, claim} -> {:locked, claim}
      _swept_or_none -> :not_found
    end
  end

  @doc """
  The currency code a cart created by this call would get: the call's currency
  (`ctx.currency`, an explicit override or the request context), else the
  shop's display currency. Used to answer an empty cart without creating one.
  """
  @spec display_currency(map()) :: String.t() | nil
  def display_currency(ctx) do
    with_request_currency(ctx[:currency], &Shop.get_display_currency_code/0)
  end

  @doc """
  Stores a revision snapshot in `metadata["api_revisions"]`: newest first, at
  most 10, one per revision. Merged into the metadata with `||`, so the other
  keys (`first_item_notified`, ...) survive. Pass the cart as just read under
  its lock.
  """
  @spec put_snapshot!(Cart.t(), map()) :: :ok
  def put_snapshot!(%Cart{uuid: uuid, metadata: metadata}, %{"revision" => revision} = snapshot) do
    existing = (metadata || %{})["api_revisions"] || []

    list =
      [snapshot | Enum.reject(existing, &(&1["revision"] == revision))]
      |> Enum.take(@snapshot_limit)

    patch = %{"api_revisions" => list}

    {1, _} =
      from(c in Cart,
        where: c.uuid == ^uuid,
        update: [
          set: [
            metadata: fragment("COALESCE(?, '{}'::jsonb) || ?", c.metadata, type(^patch, :map))
          ]
        ]
      )
      |> repo().update_all([])

    :ok
  end

  # --- internals ------------------------------------------------------------

  defp latest_cart(session_id, preloads) do
    from(c in Cart,
      where: c.session_id == ^session_id,
      order_by: [desc: c.inserted_at, desc: c.uuid],
      limit: 1,
      preload: ^preloads
    )
    |> repo().one()
  end

  defp locked_or(hash, otherwise) do
    from(k in CartClaim,
      where: k.cart_token_hash == ^hash and not is_nil(k.used_at),
      order_by: [desc: k.used_at],
      limit: 1
    )
    |> repo().one()
    |> case do
      %CartClaim{} = claim -> {:locked, claim}
      nil -> otherwise
    end
  end

  defp lock_existing(%Cart{uuid: uuid}, hash) do
    case lock_row(uuid, hash) do
      {:ok, cart} -> {:ok, cart, :existing}
      {:gone, outcome} -> outcome
    end
  end

  # The one place a token's cart row is locked. After the lock (a wait for
  # another transaction, such as a checkout claim, ends with the committed
  # row) the row must still be active AND still carry the token's session id:
  # a claim moves the cart to the buyer's session without changing its
  # status, and a write that went on would change the buyer's cart after the
  # hand-off. `gone/1` runs after the lock, so it sees that claim.
  defp lock_row(cart_uuid, hash) do
    expected = CartToken.session_id(hash)

    case repo().one(from(c in Cart, where: c.uuid == ^cart_uuid, lock: "FOR UPDATE")) do
      %Cart{status: "active", session_id: ^expected} = cart ->
        {:ok, repo().preload(cart, @preloads)}

      _swept_merged_or_moved ->
        {:gone, gone(hash)}
    end
  end

  # The row limits are charged before the insert, so an insert that then fails
  # still spends its slot: the limits count attempts, and a rate-limiter counter
  # cannot be given back.
  defp create(session_id, ctx, count_row?) do
    with :ok <- charge_row(ctx, count_row?),
         {:ok, cart} <-
           with_request_currency(ctx[:currency], fn ->
             Shop.create_cart(session_id: session_id)
           end) do
      {:ok, cart, :created}
    end
  end

  defp charge_row(_ctx, false), do: :ok

  defp charge_row(ctx, true) do
    ip = (ctx[:actor] && ctx[:actor].ip) || "unknown"

    case RateLimit.check_cart_rows(ip) do
      :ok -> :ok
      {:error, retry_after} -> {:error, :rate_limited, retry_after}
    end
  end

  # `create_cart/1` freezes the request's display currency into the cart. The
  # request currency is process-scoped, so it is set for this call only and the
  # previous value is restored. This covers callers outside the API handlers
  # (which run inside `API.Context.with_request_currency/2`) and the call's own
  # currency override.
  defp with_request_currency(code, fun) do
    previous = Currency.get_request_currency()
    Currency.put_request_currency(code)

    try do
      fun.()
    after
      Currency.put_request_currency(previous)
    end
  end

  defp repo, do: RepoHelper.repo()
end
