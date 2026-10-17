defmodule PhoenixKitEcommerce.API.CartHandlers do
  @moduledoc """
  Handlers of the seven public cart tools. They run behind core's executor,
  which has already checked the switch, the rate limits and the input schema,
  so they deal only with the cart.

  Every handler takes `(input, ctx)` and returns `{:ok, map}`,
  `{:preview, preview, fingerprint}` (when `ctx.dry_run?`; no side effect) or
  `{:error, code, message, context}`.

  `language` and `currency` (control fields every public tool accepts, declared
  from `API.Public.Schemas.control_fields/0`) are resolved first by `in_context/3`,
  after the signature of the cart token has been checked (`in_cart_context/3`).

  A cart token that is not one this server signed is `cart_not_found`; a
  signed token with no row yet reads as an empty open cart; a token whose cart
  was claimed answers `cart_locked` to anything that would change or hand
  over the cart and `status: "checking_out"` to a read.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.CountryData
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.API.CartMoney
  alias PhoenixKitEcommerce.API.CartSettings
  alias PhoenixKitEcommerce.API.CartStore
  alias PhoenixKitEcommerce.API.CartToken
  alias PhoenixKitEcommerce.API.CartView
  alias PhoenixKitEcommerce.API.CartWriter
  alias PhoenixKitEcommerce.API.Claims
  alias PhoenixKitEcommerce.API.Context
  alias PhoenixKitEcommerce.API.Loader
  alias PhoenixKitEcommerce.API.Meta
  alias PhoenixKitEcommerce.Cart
  alias PhoenixKitEcommerce.ShippingMethod

  @type result ::
          {:ok, map()} | {:preview, map(), String.t()} | {:error, atom(), String.t(), map()}

  # --- shop.create_cart --------------------------------------------------------------

  @doc "Mints a cart token. Creates no row."
  @spec create_cart(map(), map()) :: result()
  def create_cart(input, ctx), do: in_context(input, ctx, &do_create_cart/2)

  defp do_create_cart(_input, ctx) do
    seconds = CartSettings.idle_days() * 86_400

    if ctx[:dry_run?] == true,
      do: {:preview, %{expires_in_seconds: seconds}, "create_cart"},
      else: mint_token(seconds)
  end

  defp mint_token(seconds) do
    case CartToken.mint() do
      {:ok, token} ->
        {:ok, %{cart_token: token, expires_in_seconds: seconds}}

      {:error, :no_secret} ->
        {:error, :internal_error, "The cart service is not configured.", %{}}
    end
  end

  # --- shop.get_cart -------------------------------------------------------------------

  @doc "The cart behind a token."
  @spec get_cart(map(), map()) :: result()
  def get_cart(input, ctx), do: in_cart_context(input, ctx, &do_get_cart/3)

  defp do_get_cart(hash, _input, ctx) do
    case CartStore.resolve(hash) do
      {:ok, cart} -> ok(CartView.build(cart))
      :empty -> ok(CartView.empty(CartStore.display_currency(ctx)))
      {:locked, claim} -> ok(CartView.locked(claimed_currency(claim, ctx)))
      :not_found -> cart_not_found()
    end
  end

  # --- shop.set_cart_items ----------------------------------------------------------

  @doc "Sets the named lines to their final quantities."
  @spec set_cart_items(map(), map()) :: result()
  def set_cart_items(input, ctx), do: in_cart_context(input, ctx, &do_set_cart_items/3)

  defp do_set_cart_items(hash, input, ctx) do
    case CartWriter.set_items(hash, input, ctx) do
      {:ok, result} -> ok(result)
      {:preview, result, fingerprint} -> preview(result, fingerprint)
      {:error, _code, _message, _context} = error -> error
    end
  end

  @max_cost 10

  @doc """
  The rate-limit price of a `set_cart_items` call: one unit per ten lines, at
  most ten. Declared on the tool as `cost: {#{inspect(__MODULE__)}, :set_cart_items_cost}`.
  The executor calls it with the RAW input, before validation, so it must answer
  a positive integer for any term and never raise.
  """
  @spec set_cart_items_cost(term()) :: pos_integer()
  def set_cart_items_cost(%{"items" => items}) when is_list(items),
    do: items |> length() |> div(10) |> Kernel.+(1) |> min(@max_cost)

  def set_cart_items_cost(_input), do: 1

  # --- shop.clear_cart --------------------------------------------------------------

  @doc """
  Whether a `clear_cart` call has something to confirm: the cart behind the token
  has lines. Declared on the tool as `danger: {#{inspect(__MODULE__)}, :clear_needs_confirmation?}`.
  A token that never wrote, an empty cart, a swept or a claimed one has nothing to
  destroy, so such a call gets its plain answer at once instead of a confirmation
  code (an anonymous caller could otherwise mint a stored code per call).
  """
  @spec clear_needs_confirmation?(map(), map()) :: boolean()
  def clear_needs_confirmation?(input, _ctx) do
    with {:ok, hash} <- CartToken.verify(Map.get(input, "cart_token")),
         {:ok, %Cart{items: [_ | _]}} <- CartStore.resolve(hash) do
      true
    else
      _nothing_to_clear -> false
    end
  end

  @doc """
  Removes every line. When the cart has lines, core runs this with `dry_run?: true`
  first (`clear_needs_confirmation?/2`) and only runs it for real with a valid
  confirmation bound to the cart token; the preview lists what would go and the
  fingerprint is the cart's revision.
  """
  @spec clear_cart(map(), map()) :: result()
  def clear_cart(input, ctx), do: in_cart_context(input, ctx, &do_clear_cart/3)

  defp do_clear_cart(hash, _input, ctx) do
    with {:ok, cart} <- writable_cart(hash) do
      case cart do
        :empty -> clear_nothing(ctx)
        %Cart{} -> clear(cart, hash, ctx)
      end
    end
  end

  # A token without a cart has nothing to clear. An explicit dry run still has to
  # answer with a preview (core answers 500 to a dry run that does not), so it
  # previews an empty cart, with the fingerprint of the empty revision.
  defp clear_nothing(%{dry_run?: true} = ctx) do
    empty = CartView.empty(CartStore.display_currency(ctx))

    preview(%{lines_removed: 0, cart: empty, would_be: empty}, CartView.revision(nil))
  end

  defp clear_nothing(ctx) do
    ok(%{lines_removed: 0, cart: CartView.empty(CartStore.display_currency(ctx))})
  end

  defp clear(cart, _hash, %{dry_run?: true}) do
    view = CartView.build(cart)

    preview(
      %{lines_removed: length(view.lines), cart: view, would_be: CartView.empty(cart.currency)},
      view.revision
    )
  end

  defp clear(cart, hash, _ctx) do
    result =
      repo().transaction(fn ->
        locked = CartStore.lock_active!(cart.uuid, hash)
        count = length(locked.items)

        case Shop.clear_cart(locked) do
          {:ok, _cleared} ->
            fresh = CartStore.lock_active!(locked.uuid, hash)
            CartStore.put_snapshot!(fresh, CartView.stamp(CartView.snapshot(fresh)))
            {count, fresh}

          {:error, reason} ->
            repo().rollback(reason)
        end
      end)

    case result do
      {:ok, {count, fresh}} -> ok(%{lines_removed: count, cart: CartView.build(fresh)})
      {:error, reason} -> write_failed(reason)
    end
  end

  # --- shop.get_shipping_options ----------------------------------------------------

  @doc "Every active shipping method for the cart and a country, with availability and the reason."
  @spec get_shipping_options(map(), map()) :: result()
  def get_shipping_options(input, ctx),
    do: in_cart_context(input, ctx, &do_get_shipping_options/3)

  defp do_get_shipping_options(hash, input, ctx) do
    with {:ok, country} <- country(input),
         {:ok, cart} <- shipping_cart(hash, ctx) do
      ok(%{country: country, methods: shipping_options(cart, country)})
    end
  end

  # A token with no row is priced as an empty cart; nothing is created.
  defp shipping_cart(hash, ctx) do
    case CartStore.resolve(hash) do
      {:ok, cart} ->
        {:ok, cart}

      :empty ->
        currency = CartStore.display_currency(ctx)

        {:ok,
         %Cart{
           items: [],
           subtotal: Decimal.new(0),
           total: Decimal.new(0),
           currency: currency,
           base_currency: currency,
           total_weight_grams: 0,
           shipping_method: nil
         }}

      {:locked, _claim} ->
        locked()

      :not_found ->
        cart_not_found()
    end
  end

  defp shipping_options(cart, country) do
    candidate = %{cart | shipping_country: country}
    available = candidate |> Shop.get_available_shipping_methods() |> MapSet.new(& &1.uuid)
    base_subtotal = Shop.cart_amount_to_base(candidate, candidate.subtotal || Decimal.new(0))

    [active: true]
    |> Shop.list_shipping_methods()
    |> Enum.map(fn method ->
      shown = Shop.present_shipping_method(candidate, method)
      available? = MapSet.member?(available, method.uuid)
      calculated? = ShippingMethod.calculated?(method)

      %{
        id: method.uuid,
        name: method.name,
        price: if(calculated?, do: nil, else: CartMoney.new(shown.price, candidate.currency)),
        free: shown.free?,
        pay_on_delivery: shown.pay_on_delivery?,
        calculated: calculated?,
        estimated_days: estimated_days(method),
        available: available?,
        reason: if(available?, do: nil, else: reason(method, candidate, country, base_subtotal))
      }
    end)
  end

  defp estimated_days(%ShippingMethod{estimated_days_min: nil, estimated_days_max: nil}), do: nil

  defp estimated_days(%ShippingMethod{estimated_days_min: min, estimated_days_max: max}),
    do: %{min: min, max: max}

  defp reason(method, cart, country, base_subtotal) do
    weight = cart.total_weight_grams || 0

    [
      {not ShippingMethod.serves_country?(method, country), "country_not_served"},
      {below?(base_subtotal, method.min_order_amount), "order_below_minimum"},
      {above?(base_subtotal, method.max_order_amount), "order_above_maximum"},
      {is_integer(method.min_weight_grams) and weight < method.min_weight_grams,
       "weight_below_minimum"},
      {is_integer(method.max_weight_grams) and weight > method.max_weight_grams,
       "weight_above_maximum"}
    ]
    |> Enum.find_value("not_available", fn {failed?, code} -> failed? && code end)
  end

  defp below?(_amount, nil), do: false
  defp below?(amount, limit), do: Decimal.compare(amount, limit) == :lt

  defp above?(_amount, nil), do: false
  defp above?(amount, limit), do: Decimal.compare(amount, limit) == :gt

  # --- shop.set_shipping -------------------------------------------------------------

  @doc "Chooses a shipping method and country for a cart with lines."
  @spec set_shipping(map(), map()) :: result()
  def set_shipping(input, ctx), do: in_cart_context(input, ctx, &do_set_shipping/3)

  defp do_set_shipping(hash, input, ctx) do
    with {:ok, country} <- country(input),
         {:ok, cart} <- existing_cart(hash),
         {:ok, method} <- find_method(input["method_id"]) do
      choose_shipping(hash, cart, method, country, ctx)
    end
  end

  defp existing_cart(hash) do
    case CartStore.resolve(hash) do
      {:ok, %Cart{items: [_ | _]} = cart} -> {:ok, cart}
      {:ok, %Cart{}} -> cart_empty("Add items to the cart before choosing shipping.")
      :empty -> cart_empty("Add items to the cart before choosing shipping.")
      {:locked, _claim} -> locked()
      :not_found -> cart_not_found()
    end
  end

  defp find_method(id) when is_binary(id) do
    with uuid when is_binary(uuid) <- Loader.canonical_uuid(id),
         %ShippingMethod{active: true} = method <- Shop.get_shipping_method(uuid) do
      {:ok, method}
    else
      _ -> invalid("method_id", "Unknown shipping method.", nil)
    end
  end

  defp find_method(_other), do: invalid("method_id", "Unknown shipping method.", nil)

  defp choose_shipping(hash, cart, method, country, ctx) do
    available = available_methods(cart, country)

    cond do
      not available?(available, method) ->
        method_unavailable(available)

      ctx[:dry_run?] == true ->
        preview(
          %{method: method.uuid, country: country, cart: CartView.build(cart)},
          CartView.revision(cart)
        )

      true ->
        write_shipping(hash, cart, method, country)
    end
  end

  defp available_methods(cart, country),
    do: Shop.get_available_shipping_methods(%{cart | shipping_country: country})

  defp available?(available, method), do: Enum.any?(available, &(&1.uuid == method.uuid))

  defp method_unavailable(available) do
    {:error, :validation_failed,
     "That shipping method is not available for this cart and country.",
     %{
       reason: "method_unavailable",
       errors: [
         %{
           path: "method_id",
           message: "Not available for this cart and country.",
           limit: nil,
           allowed: Enum.map(available, & &1.uuid)
         }
       ]
     }}
  end

  # The choice was checked on the cart as it was read; another write may have
  # changed the lines (the subtotal, the weight) before the row lock, so the
  # method is checked again on the locked cart.
  defp write_shipping(hash, cart, method, country) do
    result =
      repo().transaction(fn ->
        locked = CartStore.lock_active!(cart.uuid, hash)
        available = available_methods(locked, country)

        if not available?(available, method),
          do: repo().rollback({:method_unavailable, available})

        case Shop.set_cart_shipping(locked, method, country) do
          {:ok, _updated} ->
            fresh = CartStore.lock_active!(locked.uuid, hash)
            CartStore.put_snapshot!(fresh, CartView.stamp(CartView.snapshot(fresh)))
            fresh

          {:error, reason} ->
            repo().rollback(reason)
        end
      end)

    case result do
      {:ok, fresh} -> ok(CartView.build(fresh))
      {:error, reason} -> write_failed(reason)
    end
  end

  # --- shop.get_checkout_link --------------------------------------------------------

  @doc """
  Issues a one-time claim URL for the cart. The URL is `ctx.base_url` plus the
  claim path, which has no locale prefix; the claim remembers the call's
  language for the page. The response carries a credential, so core's
  idempotency layer never stores it for replay, and the URL must point at a
  host this install serves: `ctx.hosts` plus the host of the `site_url`
  setting when one is set. When the host of `ctx.base_url` is not served the
  first of `ctx.hosts` is used instead (the `site_url` origin when there are
  none), and a call with no host to use at all is refused before a claim
  exists. A dry run refuses in exactly the same cases. Core fills `ctx.hosts`
  with the request host unless the host app's `:api_request_context` hook
  names the domains, so that default accepts whatever Host header the request
  came with; a multi-domain install should name its domains there.
  """
  @spec get_checkout_link(map(), map()) :: result()
  def get_checkout_link(input, ctx), do: in_cart_context(input, ctx, &do_get_checkout_link/3)

  # The base URL is resolved before the dry-run branch: a preview must refuse
  # exactly where the real call does.
  defp do_get_checkout_link(hash, _input, ctx) do
    with {:ok, cart} <- linkable_cart(hash),
         {:ok, base_url} <- claim_base_url(ctx) do
      if ctx[:dry_run?] == true do
        {:preview, %{would_issue_link: true, lines: length(cart.items)}, CartView.revision(cart)}
      else
        issue_claim(cart, hash, base_url, ctx)
      end
    end
  end

  defp claim_base_url(ctx) do
    hosts = Enum.map(ctx[:hosts] || [], &String.downcase/1)
    canonical = canonical_site()
    uri = URI.parse(ctx[:base_url] || "")

    cond do
      served?(uri, hosts, canonical) ->
        {:ok, ctx.base_url}

      hosts != [] ->
        {:ok, "#{if uri.scheme == "http", do: "http", else: "https"}://#{hd(hosts)}"}

      canonical ->
        {:ok, URI.to_string(%{canonical | path: nil, query: nil, fragment: nil, userinfo: nil})}

      true ->
        {:error, :internal_error, "The checkout link could not be created.", %{}}
    end
  end

  defp served?(%URI{scheme: scheme, host: host}, hosts, canonical) do
    served = hosts ++ List.wrap(canonical && canonical.host)
    scheme in ["http", "https"] and is_binary(host) and String.downcase(host) in served
  end

  # The install's own address (`site_url` setting), when it is set and usable;
  # core's MCP origin check reads the same setting.
  defp canonical_site do
    with site_url when is_binary(site_url) and site_url != "" <-
           Settings.get_setting_cached("site_url", ""),
         {:ok, %URI{scheme: scheme, host: host} = uri}
         when scheme in ["http", "https"] and is_binary(host) and host != "" <-
           URI.new(String.trim(site_url)) do
      %URI{uri | host: String.downcase(host)}
    else
      _unset_or_unusable -> nil
    end
  end

  defp linkable_cart(hash) do
    case CartStore.resolve(hash) do
      {:ok, %Cart{items: [_ | _]} = cart} -> {:ok, cart}
      {:ok, %Cart{}} -> cart_empty("Add items to the cart before asking for a checkout link.")
      :empty -> cart_empty("Add items to the cart before asking for a checkout link.")
      {:locked, _claim} -> locked()
      :not_found -> cart_not_found()
    end
  end

  defp issue_claim(cart, hash, base_url, ctx) do
    language = ctx[:language] || Shop.get_default_language()

    case Claims.issue(cart, hash, language) do
      {:ok, %{token: raw, claim: claim}} ->
        {:ok,
         %{
           url: base_url <> Claims.path(raw),
           expires_at: DateTime.to_iso8601(claim.expires_at),
           expires_in_seconds: max(0, DateTime.diff(claim.expires_at, DateTime.utc_now()))
         }}

      # The cart was handed over or swept between the read and the lock: a
      # benign race, answered like any other call on that token.
      {:error, :cart_unavailable} ->
        hash |> CartStore.gone() |> write_failed()

      {:error, _reason} ->
        {:error, :internal_error, "The checkout link could not be created.", %{}}
    end
  end

  # --- shared ----------------------------------------------------------------------------

  # Success and preview answers go out without nil values (`CartView.compact/1`):
  # the declared output schemas have no nullable types and the public read tools
  # omit nils.
  defp ok(map), do: {:ok, CartView.compact(map)}
  defp preview(map, fingerprint), do: {:preview, CartView.compact(map), fingerprint}

  # The language and currency this call is made in: an explicit `language` /
  # `currency` input must be enabled, else the host hook's value (`ctx.language`,
  # `ctx.currency`), else the shop's default; resolved by `API.Context.build/2`
  # and carried on in the handler context. The handler runs inside
  # `API.Context.with_request_currency/2`, as every public handler must.
  defp in_context(input, ctx, fun) do
    with {:ok, context} <- Context.build(input, ctx) do
      ctx = Map.merge(ctx, %{language: context.language, currency: context.currency.code})
      Context.with_request_currency(context, fn -> fun.(input, ctx) end)
    end
  end

  # The tools that take a cart token check its signature before anything else
  # is looked up: a token this server did not sign (anyone can send one) costs
  # no language or currency lookup, and the hash the handler goes on with is
  # always the one `CartToken.verify/1` returned.
  defp in_cart_context(input, ctx, fun) do
    with {:ok, hash} <- token_hash(input) do
      in_context(input, ctx, fn input, ctx -> fun.(hash, input, ctx) end)
    end
  end

  defp token_hash(input) do
    case CartToken.verify(input["cart_token"]) do
      {:ok, hash} -> {:ok, hash}
      :error -> cart_not_found()
    end
  end

  defp writable_cart(hash) do
    case CartStore.resolve(hash) do
      {:ok, cart} -> {:ok, cart}
      :empty -> {:ok, :empty}
      {:locked, _claim} -> locked()
      :not_found -> cart_not_found()
    end
  end

  # What a rolled-back write means to the agent. `CartStore.lock_active!/2`
  # rolls back with `{:locked, claim}` or `:not_found` when the cart was handed
  # to a buyer (or merged) or swept while the call waited for the row lock: a
  # benign race, answered like any other call on that token. Anything else is
  # unexpected.
  defp write_failed({:locked, _claim}), do: locked()
  defp write_failed(:not_found), do: cart_not_found()
  defp write_failed({:method_unavailable, available}), do: method_unavailable(available)

  defp write_failed(other) do
    Logger.error("[Shop] cart write failed: #{Meta.term_class(other)}")
    {:error, :internal_error, "The cart could not be updated.", %{}}
  end

  defp claimed_currency(claim, ctx) do
    case repo().one(from(c in Cart, where: c.uuid == ^claim.cart_uuid, select: c.currency)) do
      nil -> CartStore.display_currency(ctx)
      currency -> currency
    end
  end

  defp country(input) do
    code = input |> Map.get("country", "") |> to_string() |> String.trim() |> String.upcase()

    if String.match?(code, ~r/\A[A-Z]{2}\z/) and CountryData.get_country(code) do
      {:ok, code}
    else
      invalid("country", "Use a two-letter ISO 3166-1 country code such as DE.", nil)
    end
  end

  defp invalid(path, message, allowed) do
    {:error, :validation_failed, message,
     %{errors: [%{path: path, message: message, limit: nil, allowed: allowed}]}}
  end

  defp cart_empty(message) do
    {:error, :validation_failed, message,
     %{
       reason: "cart_empty",
       errors: [%{path: "cart_token", message: message, limit: nil, allowed: nil}]
     }}
  end

  defp cart_not_found, do: {:error, :cart_not_found, "Unknown or expired cart token.", %{}}

  defp locked do
    {:error, :cart_locked, "This cart was handed over for checkout and can no longer be changed.",
     %{}}
  end

  defp repo, do: RepoHelper.repo()
end
