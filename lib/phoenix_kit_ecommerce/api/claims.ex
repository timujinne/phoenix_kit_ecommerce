defmodule PhoenixKitEcommerce.API.Claims do
  @moduledoc """
  The checkout hand-off of the public cart API: a one-time claim that turns an
  assistant-built cart into the buyer's own cart.

    * `issue/3` creates the claim (superseding earlier unused ones of the
      cart) and returns the raw token once;
    * `peek/1` is what the GET page uses: it reads, it consumes nothing, so
      link-preview bots cannot burn a claim;
    * `redeem/3` is what the CSRF POST uses: one transaction that locks the
      browser's identity, the claim, the API cart and the browser's active
      cart, re-checks what the page offered, and then moves the cart,
      replaces the browser's cart, or merges into it. It never leaves the
      storefront two carts to choose from (see `browser_cart/1`), and a claim is
      used exactly once.

  `redeem/3` takes its locks in one order everywhere: the browser's identity
  (user key, then session key), the API cart's own identity (the key
  `CartStore.for_write/3` takes, so a write in flight finishes first), the API
  cart row, the claim row, the browser's cart row. The claim row comes after
  the cart row because `issue/3` locks the cart row and then updates claim
  rows; the opposite order is a deadlock between a redeem and a new link.

  Lines are validated before `add_to_cart` is called (the product is
  `:listed` by the one visibility rule of the public API, its options are
  valid), because a rollback inside `add_to_cart` dooms the surrounding
  transaction.
  """

  import Ecto.Query, warn: false

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.API.CartOptions
  alias PhoenixKitEcommerce.API.CartSettings
  alias PhoenixKitEcommerce.API.CartToken
  alias PhoenixKitEcommerce.API.CartView
  alias PhoenixKitEcommerce.API.CartWriter
  alias PhoenixKitEcommerce.API.Loader
  alias PhoenixKitEcommerce.Cart
  alias PhoenixKitEcommerce.CartClaim
  alias PhoenixKitEcommerce.Events

  @preloads [:items, :shipping_method]

  @type browser :: %{
          required(:session_id) => String.t(),
          optional(:user_uuid) => String.t() | nil
        }
  @type decision :: %{
          required(:offer) => String.t(),
          optional(:choice) => String.t() | nil,
          required(:revision) => String.t()
        }
  @type outcome :: %{
          language: String.t(),
          skipped: [String.t()],
          mode: :moved | :replaced | :merged
        }

  # --- issue / peek -------------------------------------------------------------

  @doc """
  Issues a claim for an active cart and returns the raw token (shown once; only
  its digest is stored). Every earlier unused claim of the cart is superseded,
  and a claim that was superseded before is deleted, so a cart never holds more
  than two unused claims however often a link is asked for. A cart that is no
  longer active, or no longer carries the session id of `cart_token_hash` (it
  was handed over), is `{:error, :cart_unavailable}`.
  """
  @spec issue(Cart.t(), String.t(), String.t()) ::
          {:ok, %{token: String.t(), claim: CartClaim.t()}} | {:error, term()}
  def issue(%Cart{uuid: cart_uuid}, cart_token_hash, language)
      when is_binary(cart_token_hash) and is_binary(language) do
    raw = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
    now = UtilsDate.utc_now()
    expires_at = DateTime.add(now, CartSettings.claim_ttl_minutes() * 60, :second)

    expected = CartToken.session_id(cart_token_hash)

    result =
      repo().transaction(fn ->
        lock_still_api_cart!(cart_uuid, expected, now)

        # Bounded table: a link superseded earlier can be redeemed by nobody, so
        # it goes (it reads as `:invalid`, the same notice for the buyer); the
        # link being replaced now stays as `:superseded` until the prune.
        # Used claims are never touched: they are what `cart_locked` reads.
        from(k in CartClaim,
          where: k.cart_uuid == ^cart_uuid and is_nil(k.used_at) and not is_nil(k.superseded_at)
        )
        |> repo().delete_all()

        from(k in CartClaim,
          where: k.cart_uuid == ^cart_uuid and is_nil(k.used_at) and is_nil(k.superseded_at)
        )
        |> repo().update_all(set: [superseded_at: now])

        %CartClaim{}
        |> CartClaim.changeset(%{
          token_hash: CartToken.digest(raw),
          cart_uuid: cart_uuid,
          cart_token_hash: cart_token_hash,
          language: language,
          expires_at: expires_at
        })
        |> repo().insert!()
      end)

    case result do
      {:ok, claim} -> {:ok, %{token: raw, claim: claim}}
      {:error, reason} -> {:error, reason}
    end
  end

  # The cart row, locked, and still the cart of the token: active and not handed
  # over (a handed-over cart carries the buyer's session id). The row is also
  # written (`updated_at`): a sweep whose UPDATE waits on a row that is only
  # locked resumes on the same row version and decides on what it saw before the
  # link existed, while a changed row version is checked again against the
  # sweep's conditions, where the cart is no longer idle.
  defp lock_still_api_cart!(cart_uuid, expected_session_id, now) do
    case repo().one(
           from(c in Cart,
             where: c.uuid == ^cart_uuid,
             lock: "FOR UPDATE",
             select: {c.status, c.session_id}
           )
         ) do
      {"active", ^expected_session_id} ->
        repo().update_all(from(c in Cart, where: c.uuid == ^cart_uuid), set: [updated_at: now])

      _handed_over_or_gone ->
        repo().rollback(:cart_unavailable)
    end
  end

  @doc "The URL path of a claim: outside the locale prefix, so one analytics pattern covers it."
  @spec path(String.t()) :: String.t()
  def path(raw), do: Routes.path("/checkout/claim/" <> raw, locale: :none)

  @doc "The language a claim was issued for, nil for an unknown token. Reads only."
  @spec language_of(String.t()) :: String.t() | nil
  def language_of(raw) do
    case get_by_raw(raw) do
      %CartClaim{language: language} -> language
      nil -> nil
    end
  end

  @doc """
  The claim and its cart for the GET page, or why there is none. Reads only:
  nothing is locked, marked or consumed.
  """
  @spec peek(String.t()) ::
          {:ok, %{claim: CartClaim.t(), cart: Cart.t()}}
          | {:error, :invalid | :used | :superseded | :expired | :cart_unavailable}
  def peek(raw) do
    with %CartClaim{} = claim <- get_by_raw(raw),
         :ok <- usable(claim),
         %Cart{} = cart <- Shop.get_cart(claim.cart_uuid),
         true <- still_api_cart?(cart, claim) do
      {:ok, %{claim: claim, cart: cart}}
    else
      nil -> {:error, :invalid}
      {:error, _reason} = error -> error
      _unavailable -> {:error, :cart_unavailable}
    end
  end

  # The claim's cart is the one the token still stands for: active, and not yet
  # handed over (a handed-over cart carries the buyer's session id).
  defp still_api_cart?(%Cart{status: "active", session_id: session_id}, claim),
    do: session_id == CartToken.session_id(claim.cart_token_hash)

  defp still_api_cart?(_cart, _claim), do: false

  # --- redeem -----------------------------------------------------------------------

  @doc """
  Consumes the claim for a browser. `decision.offer` is what the page showed
  (`"none"`, or the uuid of the browser's non-empty cart); `decision.choice` is
  `"replace"` or `"add"` when the browser has a cart.

  What the page offered must still be what the browser has, and the cart the
  page showed (`decision.revision`, the `CartView.revision/1` of the cart at
  the time of the GET) must still be the cart now: the agent can change it
  between the page and the click, and the buyer must not confirm lines they
  were not shown. Any difference, or a missing choice when the browser has a
  cart, is `{:error, :reshow}` and nothing changes. A decision without a
  `revision` cannot match the cart and is answered `{:error, :reshow}` too, so
  a caller that forgets it can never claim a cart the buyer was not shown.

  A Postgres `deadlock_detected` (a merge holds the browser's cart and then
  locks product rows inside `add_to_cart`, while a storefront add in another
  tab of the same browser holds the product row and waits for that cart) is
  `{:error, :busy}`: nothing was claimed, the buyer can try again.
  Any other atom is a refusal this module does not know; a caller fails closed.
  """
  # The trailing `atom()` is deliberate: without it dialyzer proves the caller's
  # fail-closed clause (any refusal not listed here) unreachable and warns.
  @spec redeem(String.t(), browser(), decision()) ::
          {:ok, outcome()}
          | {:error,
             :reshow
             | :busy
             | :invalid
             | :used
             | :superseded
             | :expired
             | :cart_unavailable
             | atom()}
  def redeem(raw, %{session_id: session_id} = browser, %{offer: offer} = decision)
      when is_binary(raw) and byte_size(raw) in 16..256 and is_binary(session_id) and
             is_binary(offer) do
    result =
      repo().transaction(fn ->
        Shop.lock_cart_identity!(Map.get(browser, :user_uuid), session_id)
        claim = find_claim!(raw)
        Shop.lock_cart_identity!(nil, CartToken.session_id(claim.cart_token_hash))
        api_cart = lock_api_cart!(claim)
        claim = lock_claim!(raw)
        browser_cart = lock_browser_cart(browser)
        decide!(claim, api_cart, browser_cart, browser, decision)
      end)

    case result do
      {:ok, {outcome, cart}} ->
        Events.broadcast_cart_updated(cart)
        {:ok, outcome}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error ->
      if CartWriter.deadlock?(error), do: {:error, :busy}, else: reraise(error, __STACKTRACE__)
  end

  def redeem(_raw, _browser, _decision), do: {:error, :invalid}

  # The claim, read WITHOUT a lock (see the lock order in the moduledoc).
  defp find_claim!(raw) do
    with %CartClaim{} = claim <- get_by_raw(raw),
         :ok <- usable(claim) do
      claim
    else
      nil -> repo().rollback(:invalid)
      {:error, reason} -> repo().rollback(reason)
    end
  end

  # The claim row, locked, and checked again: another redeem may have used it
  # while this one waited for the cart row.
  defp lock_claim!(raw) do
    digest = CartToken.digest(raw)

    case repo().one(from(k in CartClaim, where: k.token_hash == ^digest, lock: "FOR UPDATE")) do
      nil ->
        repo().rollback(:invalid)

      %CartClaim{} = claim ->
        case usable(claim) do
          :ok -> claim
          {:error, reason} -> repo().rollback(reason)
        end
    end
  end

  # The claim's cart must still be active and still be the cart of the claim's
  # token (it has not been moved by another claim).
  defp lock_api_cart!(%CartClaim{cart_uuid: cart_uuid, cart_token_hash: cart_token_hash}) do
    expected = CartToken.session_id(cart_token_hash)

    case repo().one(from(c in Cart, where: c.uuid == ^cart_uuid, lock: "FOR UPDATE")) do
      %Cart{status: "active", session_id: ^expected} = cart ->
        repo().preload(cart, @preloads, force: true)

      _gone ->
        repo().rollback(:cart_unavailable)
    end
  end

  defp lock_browser_cart(browser) do
    browser |> browser_cart_query() |> lock("FOR UPDATE") |> repo().one() |> preload_cart()
  end

  @doc """
  The active cart a claim of this browser is compared against, or nil. Reads
  only. It is the cart the storefront shows the browser (`Shop.find_active_cart/1`):
  the logged-in user's own cart first, the browser's unowned session cart only
  when the user has none; of several candidates the newest wins, ties broken by
  creation time and uuid. The page and `redeem/3` share this one definition, so
  what the page offers is exactly what a POST finds, and a claim never leaves the
  storefront with two carts to choose from.
  """
  @spec browser_cart(browser()) :: Cart.t() | nil
  def browser_cart(%{session_id: _session_id} = browser) do
    browser |> browser_cart_query() |> repo().one() |> preload_cart()
  end

  defp browser_cart_query(%{session_id: session_id} = browser) do
    user_uuid = Map.get(browser, :user_uuid)

    query =
      from(c in Cart,
        where: c.status == "active",
        order_by: [
          asc: is_nil(c.user_uuid),
          desc: c.updated_at,
          desc: c.inserted_at,
          desc: c.uuid
        ],
        limit: 1
      )

    if user_uuid do
      where(
        query,
        [c],
        c.user_uuid == ^user_uuid or (c.session_id == ^session_id and is_nil(c.user_uuid))
      )
    else
      where(query, [c], c.session_id == ^session_id and is_nil(c.user_uuid))
    end
  end

  defp preload_cart(nil), do: nil
  defp preload_cart(cart), do: repo().preload(cart, @preloads, force: true)

  # What the page offered (`offer`) must still be what the browser has: "none"
  # while it has no cart with lines, the uuid of its cart while it has one. Any
  # other pair, or a missing choice, shows the page again.
  defp decide!(claim, api_cart, browser_cart, browser, decision) do
    :ok = bound_to_shown_cart!(api_cart, decision)

    case {offered(browser_cart), decision.offer, Map.get(decision, :choice)} do
      {"none", "none", _choice} ->
        move!(claim, api_cart, browser_cart, browser, :moved)

      {uuid, uuid, "replace"} when uuid != "none" ->
        abandon!(browser_cart)
        finish!(claim, :replaced, relocate!(api_cart, browser), [])

      {uuid, uuid, "add"} when uuid != "none" ->
        merge!(claim, api_cart, browser_cart)

      _stale ->
        repo().rollback(:reshow)
    end
  end

  # A decision without a revision binds to no cart: it takes the reshow path.
  defp bound_to_shown_cart!(api_cart, decision) do
    if Map.get(decision, :revision) == CartView.revision(api_cart),
      do: :ok,
      else: repo().rollback(:reshow)
  end

  defp offered(nil), do: "none"
  defp offered(%Cart{items: []}), do: "none"
  defp offered(%Cart{uuid: uuid}), do: uuid

  # No cart with lines in the browser: an empty active cart is abandoned first,
  # so the move never leaves two active carts.
  defp move!(claim, api_cart, browser_cart, browser, mode) do
    if browser_cart, do: abandon!(browser_cart)
    finish!(claim, mode, relocate!(api_cart, browser), [])
  end

  defp merge!(claim, api_cart, browser_cart) do
    records = load_records(api_cart.items, claim.language)

    # Product-uuid order, like the writer: two merges (or a merge and a write)
    # that share two products must not lock their rows crosswise.
    {merged, skipped} =
      api_cart.items
      |> Enum.sort_by(&(CartView.line_product_id(&1) || ""))
      |> Enum.reduce({browser_cart, []}, fn item, {cart, skipped} ->
        add_line(cart, item, records, claim.language, skipped)
      end)

    api_cart
    |> Cart.status_changeset("merged", %{merged_into_cart_uuid: merged.uuid})
    |> repo().update!()

    finish!(claim, :merged, merged, Enum.reverse(skipped))
  end

  defp finish!(claim, mode, cart, skipped) do
    claim |> Ecto.Changeset.change(used_at: UtilsDate.utc_now()) |> repo().update!()
    {%{language: claim.language, skipped: skipped, mode: mode}, cart}
  end

  defp abandon!(cart), do: cart |> Cart.status_changeset("abandoned") |> repo().update!()

  # A cart that becomes a logged-in buyer's has no expiry (guest carts do), the
  # way `Shop.merge_guest_cart/2` leaves it.
  defp relocate!(api_cart, browser) do
    user_uuid = Map.get(browser, :user_uuid)
    attrs = %{session_id: browser.session_id, user_uuid: user_uuid}
    attrs = if user_uuid, do: Map.put(attrs, :expires_at, nil), else: attrs

    api_cart
    |> Cart.changeset(attrs)
    |> repo().update!()
    |> repo().preload(@preloads, force: true)
  end

  # --- merging lines ---------------------------------------------------------------------

  # One loader call for every product of the API cart: the records carry the
  # visibility state of the public API (the same rule the writer applies).
  defp load_records(items, language),
    do: Loader.load(Enum.map(items, &CartView.line_product_id/1), language: language)

  # One API line into the browser's cart through the normal add_to_cart path
  # (re-priced in that cart's currency, re-validated). The line is validated
  # here first: a refusal made inside add_to_cart's own transaction would doom
  # this one. A line that no longer validates is skipped and named.
  defp add_line(cart, item, records, language, skipped) do
    with product_id when is_binary(product_id) <- CartView.line_product_id(item),
         {:ok, product} <- listed_product(records, product_id),
         {:ok, specs} <- specs_for(product, item),
         quantity when quantity > 0 <- room_for(cart, product, specs, item.quantity) do
      add_checked(cart, item, product, quantity, specs, language, skipped)
    else
      # Also the line the buyer's cart already holds at the cap (`room_for/4` is
      # 0): named, not dropped quietly with the claim consumed.
      _not_addable -> {cart, [item.product_title | skipped]}
    end
  end

  # Only a refusal that `add_to_cart` makes before it writes anything skips the
  # line. Any other answer means the product changed since the check above and
  # the surrounding transaction may be doomed: nothing is claimed, the buyer
  # tries again.
  defp add_checked(cart, item, product, quantity, specs, language, skipped) do
    opts = [selected_specs: specs, language: language, via: :assistant]

    case Shop.add_to_cart(cart, product, quantity, opts) do
      {:ok, updated} ->
        {updated, skipped}

      {:error, reason} when is_atom(reason) ->
        if CartWriter.refused_before_write?(reason),
          do: {cart, [item.product_title | skipped]},
          else: repo().rollback(:busy)

      _other ->
        repo().rollback(:busy)
    end
  end

  defp listed_product(records, product_id) do
    with id when is_binary(id) <- Loader.canonical_uuid(product_id) do
      CartWriter.addable_product(Map.get(records, id))
    end
  end

  defp specs_for(product, item) do
    case CartOptions.to_specs(product, CartOptions.from_item(item, product)) do
      {:ok, specs} ->
        {:ok, specs}

      {:error, _code, _context} ->
        specs = item.selected_specs || %{}
        if Shop.validate_selected_specs(product, specs) == :ok, do: {:ok, specs}, else: :error
    end
  end

  defp room_for(cart, product, specs, wanted) do
    existing =
      Enum.find(cart.items, fn line ->
        CartView.line_product_id(line) == product.uuid and (line.selected_specs || %{}) == specs
      end)

    max(0, min(wanted, CartWriter.max_quantity() - ((existing && existing.quantity) || 0)))
  end

  # --- shared ---------------------------------------------------------------------------

  defp get_by_raw(raw) when is_binary(raw) and byte_size(raw) in 16..256 do
    digest = CartToken.digest(raw)
    repo().one(from(k in CartClaim, where: k.token_hash == ^digest))
  end

  defp get_by_raw(_other), do: nil

  defp usable(%CartClaim{used_at: used_at}) when not is_nil(used_at), do: {:error, :used}

  defp usable(%CartClaim{superseded_at: superseded_at}) when not is_nil(superseded_at),
    do: {:error, :superseded}

  defp usable(%CartClaim{expires_at: expires_at}) do
    if DateTime.compare(expires_at, UtilsDate.utc_now()) == :gt, do: :ok, else: {:error, :expired}
  end

  defp repo, do: RepoHelper.repo()
end
