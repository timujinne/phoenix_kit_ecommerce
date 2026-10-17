defmodule PhoenixKitEcommerce.API.ClaimsTest do
  @moduledoc """
  Issue, peek and redeem of checkout claims: a GET consumes
  nothing, a claim is used once, a changed browser cart is a choice again and
  never two active carts, and the old cart token answers `cart_locked`.
  """

  # async: false - settings are shared.
  use PhoenixKitEcommerce.DataCase, async: false
  @moduletag :requires_core_api

  import PhoenixKitEcommerce.CartApiFixtures

  alias PhoenixKitBilling.Currency
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.API.CartStore
  alias PhoenixKitEcommerce.API.CartToken
  alias PhoenixKitEcommerce.API.CartView
  alias PhoenixKitEcommerce.API.CartWriter
  alias PhoenixKitEcommerce.API.Claims
  alias PhoenixKitEcommerce.Cart
  alias PhoenixKitEcommerce.CartClaim
  alias PhoenixKitEcommerce.CartItem

  setup do
    put_secret!()
    ensure_currencies!()
    %{p1: product!(), p2: product!()}
  end

  defp opt(key, value), do: %{"attribute_key" => key, "value_key" => value}

  # An API cart written through the real writer: `lines` is [{product, quantity}]
  # or [{product, quantity, options}].
  defp api_cart!(lines) do
    token = new_token!()
    {:ok, hash} = CartToken.verify(token)

    input = %{
      "items" =>
        Enum.map(lines, fn line ->
          {product, quantity, options} = with_options(line)
          %{"product_id" => product.uuid, "quantity" => quantity, "options" => options}
        end)
    }

    {:ok, _} = CartWriter.set_items(hash, input, ctx_for(token))
    {:ok, cart} = CartStore.resolve(hash)
    %{token: token, hash: hash, cart: cart}
  end

  defp with_options({product, quantity}), do: {product, quantity, []}
  defp with_options({_product, _quantity, _options} = line), do: line

  defp issue!(%{cart: cart, hash: hash}, language \\ "en") do
    {:ok, %{token: raw, claim: claim}} = Claims.issue(cart, hash, language)
    {raw, claim}
  end

  defp browser(user_uuid \\ nil),
    do: %{session_id: "browser-#{System.unique_integer([:positive])}", user_uuid: user_uuid}

  defp browser_cart!(%{session_id: sid}, lines, currency \\ nil) do
    Currency.put_request_currency(currency)
    {:ok, cart} = Shop.create_cart(session_id: sid)
    Currency.put_request_currency(nil)
    fill!(cart, lines)
  end

  # `lines` is [{product, quantity}] or [{product, quantity, selected_specs}].
  defp fill!(cart, lines) do
    Enum.reduce(lines, cart, fn line, acc ->
      {product, quantity, specs} =
        case line do
          {product, quantity} -> {product, quantity, %{}}
          {_product, _quantity, _specs} = full -> full
        end

      {:ok, updated} = Shop.add_to_cart(acc, product, quantity, selected_specs: specs)
      updated
    end)
  end

  # A cart the user owns under a session of another browser.
  defp user_cart!(user, lines) do
    {:ok, cart} = Shop.create_cart(user_uuid: user.uuid, session_id: "elsewhere-#{unique()}")
    fill!(cart, lines)
  end

  defp unique, do: System.unique_integer([:positive])

  defp active_user_carts(user),
    do: Repo.all(from c in Cart, where: c.status == "active" and c.user_uuid == ^user.uuid)

  # A claim for `cart` written straight to the table (no cart row lock, unlike
  # `issue/3`): returns the raw token.
  defp insert_claim!(cart, hash) do
    raw = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    %CartClaim{}
    |> CartClaim.changeset(%{
      token_hash: CartToken.digest(raw),
      cart_uuid: cart.uuid,
      cart_token_hash: hash,
      language: "en",
      expires_at: DateTime.utc_now() |> DateTime.add(600, :second) |> DateTime.truncate(:second)
    })
    |> Repo.insert!()

    raw
  end

  # An API cart row and a claim for it that `redeem/3` is the first to lock. (The
  # claim's foreign key takes a share lock on the cart row, so the cart row itself
  # cannot be told apart from outside: `lock_trace/1` covers it.)
  defp untouched_api_cart! do
    {:ok, hash} = CartToken.verify(new_token!())
    {:ok, cart} = Shop.create_cart(session_id: CartToken.session_id(hash))
    raw = insert_claim!(cart, hash)
    claim = Repo.get_by!(CartClaim, token_hash: CartToken.digest(raw))
    %{raw: raw, hash: hash, cart: cart, claim: claim}
  end

  # The lock statements `fun` runs in this process, in order: `{:advisory, key}`
  # and `{:row, table}` for a `FOR UPDATE` read.
  defp lock_trace(fun) do
    id = {__MODULE__, make_ref()}
    test = self()

    :telemetry.attach(
      id,
      [:phoenix_kit_ecommerce, :test, :repo, :query],
      fn _event, _measurements, meta, _config ->
        cond do
          String.contains?(meta.query, "pg_advisory_xact_lock") ->
            send(test, {:lock, {:advisory, hd(meta.params)}})

          String.contains?(meta.query, "FOR UPDATE") ->
            send(test, {:lock, {:row, meta.source}})

          true ->
            :ok
        end
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(id)
    end

    drain_locks([])
  end

  defp drain_locks(acc) do
    receive do
      {:lock, lock} -> drain_locks([lock | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp claim_row_locked?(claim_uuid) do
    %{rows: [[xmax]]} =
      Repo.query!(
        "SELECT xmax::text::bigint FROM phoenix_kit_shop_cart_claims WHERE uuid = $1",
        [Ecto.UUID.dump!(claim_uuid)]
      )

    xmax != 0
  end

  defp active_carts(session_id),
    do: Repo.all(from c in Cart, where: c.status == "active" and c.session_id == ^session_id)

  defp redeem(raw, browser, offer, choice \\ nil),
    do: redeem_shown(raw, browser, %{offer: offer, choice: choice})

  defp quantities(cart), do: cart.items |> Enum.map(& &1.quantity) |> Enum.sort()

  # After a hand-off (moved, replaced or merged) the old token must answer
  # cart_locked to a write, never write into the buyer's cart.
  defp assert_write_locked(api, product) do
    input = %{"items" => [%{"product_id" => product.uuid, "quantity" => 3}]}

    assert {:error, :cart_locked, _message, %{}} =
             CartWriter.set_items(api.hash, input, ctx_for(api.token))
  end

  describe "issue/3" do
    test "stores the digest of a fresh token, not the token, with the configured lifetime", ctx do
      api = api_cart!([{ctx.p1, 1}])
      {raw, claim} = issue!(api)

      assert byte_size(raw) == 43
      assert claim.token_hash == CartToken.digest(raw)
      refute claim.token_hash == raw
      assert claim.cart_token_hash == api.hash
      assert claim.language == "en"
      assert claim.used_at == nil and claim.superseded_at == nil

      now = DateTime.utc_now()
      assert DateTime.diff(claim.expires_at, now) in 1790..1810

      put_setting!("api_checkout_claim_ttl_minutes", 5)
      {_raw2, claim2} = issue!(api)
      assert DateTime.diff(claim2.expires_at, DateTime.utc_now()) in 290..310
    end

    test "a new link supersedes every earlier unused claim of the cart", ctx do
      api = api_cart!([{ctx.p1, 1}])
      {first, _} = issue!(api)
      {second, _} = issue!(api)

      assert {:error, :superseded} = Claims.peek(first)
      assert {:ok, %{cart: cart}} = Claims.peek(second)
      assert cart.uuid == api.cart.uuid
      assert Repo.aggregate(from(k in CartClaim, where: is_nil(k.superseded_at)), :count) == 1
    end

    # One token can ask for a link about 120 times a minute; without a bound
    # that is a row each, kept until 7 days after expiry.
    test "the table stays bounded: the live link and the one it just replaced, nothing older",
         ctx do
      api = api_cart!([{ctx.p1, 1}])
      links = for _ <- 1..5, do: elem(issue!(api), 0)

      assert Repo.aggregate(from(k in CartClaim, where: k.cart_uuid == ^api.cart.uuid), :count) ==
               2

      assert {:ok, _} = Claims.peek(List.last(links))
      assert {:error, :superseded} = Claims.peek(Enum.at(links, 3))
      assert {:error, :invalid} = Claims.peek(hd(links))
    end
  end

  describe "peek/1" do
    test "reads, and never consumes, however often it is called", ctx do
      api = api_cart!([{ctx.p1, 2}])
      {raw, claim} = issue!(api)

      for _ <- 1..5 do
        assert {:ok, %{claim: found}} = Claims.peek(raw)
        assert found.uuid == claim.uuid
      end

      assert Repo.get!(CartClaim, claim.uuid).used_at == nil
    end

    test "answers invalid for an unknown, short or huge token" do
      for bad <- ["", "x", String.duplicate("a", 43), String.duplicate("b", 5000)] do
        assert {:error, :invalid} = Claims.peek(bad)
      end
    end

    test "answers expired, used and cart_unavailable", ctx do
      api = api_cart!([{ctx.p1, 1}])
      {raw, claim} = issue!(api)

      claim
      |> Ecto.Changeset.change(
        expires_at: DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.truncate(:second)
      )
      |> Repo.update!()

      assert {:error, :expired} = Claims.peek(raw)

      other = api_cart!([{ctx.p1, 1}])
      {raw2, claim2} = issue!(other)

      claim2
      |> Ecto.Changeset.change(used_at: DateTime.utc_now() |> DateTime.truncate(:second))
      |> Repo.update!()

      assert {:error, :used} = Claims.peek(raw2)

      third = api_cart!([{ctx.p1, 1}])
      {raw3, _} = issue!(third)
      third.cart |> Cart.status_changeset("abandoned") |> Repo.update!()
      assert {:error, :cart_unavailable} = Claims.peek(raw3)
    end
  end

  describe "redeem/3 when the browser has no cart" do
    test "moves the API cart to the browser's session and locks the old token", ctx do
      api = api_cart!([{ctx.p1, 2}, {ctx.p2, 1}])
      {raw, claim} = issue!(api, "de")
      browser = browser()

      assert {:ok, %{language: "de", skipped: [], mode: :moved}} = redeem(raw, browser, "none")

      assert [cart] = active_carts(browser.session_id)
      assert cart.uuid == api.cart.uuid
      assert Repo.get!(CartClaim, claim.uuid).used_at != nil
      assert {:locked, %CartClaim{}} = CartStore.resolve(api.hash)
      assert {:error, :used} = redeem(raw, browser, "none")

      assert {:error, :cart_locked, _message, %{}} =
               CartWriter.set_items(
                 api.hash,
                 %{"items" => [%{"product_id" => ctx.p1.uuid, "quantity" => 3}]},
                 ctx_for(api.token)
               )
    end

    test "an empty cart of the browser is abandoned, so there is never a second active cart",
         ctx do
      api = api_cart!([{ctx.p1, 1}])
      {raw, _} = issue!(api)
      browser = browser()
      empty = browser_cart!(browser, [])

      assert {:ok, %{mode: :moved}} = redeem(raw, browser, "none")

      assert Repo.get!(Cart, empty.uuid).status == "abandoned"
      assert [%Cart{uuid: uuid}] = active_carts(browser.session_id)
      assert uuid == api.cart.uuid
    end

    test "a logged-in buyer's cart is found by user", ctx do
      user = fixture_user()
      api = api_cart!([{ctx.p1, 1}])
      {raw, _} = issue!(api)
      browser = browser(user.uuid)

      assert {:ok, %{mode: :moved}} = redeem(raw, browser, "none")

      found = Shop.find_active_cart(user_uuid: user.uuid, session_id: browser.session_id)
      assert found.uuid == api.cart.uuid
    end
  end

  describe "redeem/3 when the browser already has a cart" do
    test "replace abandons the browser's cart and moves the API cart", ctx do
      api = api_cart!([{ctx.p1, 2}])
      {raw, _} = issue!(api)
      browser = browser()
      old = browser_cart!(browser, [{ctx.p2, 1}])

      assert {:ok, %{mode: :replaced, skipped: []}} = redeem(raw, browser, old.uuid, "replace")

      assert Repo.get!(Cart, old.uuid).status == "abandoned"
      assert [cart] = active_carts(browser.session_id)
      assert cart.uuid == api.cart.uuid
      assert {:locked, %CartClaim{}} = CartStore.resolve(api.hash)
      assert_write_locked(api, ctx.p1)
    end

    test "add merges the lines into the browser's cart and marks the API cart merged", ctx do
      api = api_cart!([{ctx.p1, 5}, {ctx.p2, 1}])
      {raw, _} = issue!(api)
      browser = browser()
      mine = browser_cart!(browser, [{ctx.p1, 98}])

      assert {:ok, %{mode: :merged, skipped: []}} = redeem(raw, browser, mine.uuid, "add")

      assert [cart] = active_carts(browser.session_id)
      assert cart.uuid == mine.uuid
      cart = Shop.get_cart(cart.uuid)
      assert quantities(cart) == [1, 99]

      merged = Repo.get!(Cart, api.cart.uuid)
      assert merged.status == "merged"
      assert merged.merged_into_cart_uuid == mine.uuid
      assert {:locked, %CartClaim{}} = CartStore.resolve(api.hash)
      assert_write_locked(api, ctx.p1)
    end

    # Two merges (or a merge and a writer) that share two products must not lock
    # their rows crosswise: the writer applies lines in product-uuid order and so
    # does the merge, whatever order the API cart happens to hold them in.
    test "add merges the lines in product-uuid order, whatever order the cart holds them",
         ctx do
      products = Enum.sort_by([ctx.p1, ctx.p2, product!()], & &1.uuid)
      token = new_token!()
      {:ok, hash} = CartToken.verify(token)

      # one line per call, highest uuid first: the cart holds them in that order
      for product <- Enum.reverse(products) do
        input = %{"items" => [%{"product_id" => product.uuid, "quantity" => 1}]}
        {:ok, _} = CartWriter.set_items(hash, input, ctx_for(token))
      end

      {:ok, cart} = CartStore.resolve(hash)
      {raw, _} = issue!(%{cart: cart, hash: hash})
      browser = browser()
      mine = browser_cart!(browser, [{product!(), 1}])

      inserted =
        inserted_item_products(products, fn ->
          assert {:ok, %{mode: :merged, skipped: []}} = redeem(raw, browser, mine.uuid, "add")
        end)

      assert inserted == Enum.map(products, & &1.uuid)
    end

    test "add re-prices in the browser cart's currency and keeps its shipping choice", ctx do
      api = api_cart!([{ctx.p1, 1}])
      {raw, _} = issue!(api)
      browser = browser()
      mine = browser_cart!(browser, [{ctx.p2, 1}], "EUR")

      {:ok, method} =
        Shop.create_shipping_method(%{
          "name" => "Post",
          "price" => Decimal.new("3.00"),
          "active" => true
        })

      {:ok, _} = Shop.set_cart_shipping(Shop.get_cart(mine.uuid), method, "DE")

      assert {:ok, %{mode: :merged}} = redeem(raw, browser, mine.uuid, "add")

      cart = Shop.get_cart(mine.uuid)
      assert cart.shipping_method_uuid == method.uuid
      added = Enum.find(cart.items, &(&1.product_uuid == ctx.p1.uuid))
      assert added.currency == "EUR"
      assert Decimal.compare(added.unit_price, Decimal.new("10.00")) == :lt
    end

    test "add skips a line that no longer validates and returns its title", ctx do
      api = api_cart!([{ctx.p1, 1}, {ctx.p2, 1}])
      {raw, _} = issue!(api)
      browser = browser()
      mine = browser_cart!(browser, [{product!(), 1}])
      {:ok, _} = Shop.update_product(ctx.p2, %{"status" => "archived"})

      assert {:ok, %{mode: :merged, skipped: [title]}} = redeem(raw, browser, mine.uuid, "add")

      assert title =~ "Widget"
      assert length(Shop.get_cart(mine.uuid).items) == 2
    end

    test "add names a line whose product the buyer's cart already holds at the cap", ctx do
      api = api_cart!([{ctx.p1, 1}, {ctx.p2, 1}])
      {raw, _} = issue!(api)
      browser = browser()
      mine = browser_cart!(browser, [{ctx.p1, CartWriter.max_quantity()}])

      assert {:ok, %{mode: :merged, skipped: [title]}} = redeem(raw, browser, mine.uuid, "add")

      assert title == ctx.p1.title["en"]
      added = Shop.get_cart(mine.uuid).items

      assert Enum.find(added, &(&1.product_uuid == ctx.p1.uuid)).quantity ==
               CartWriter.max_quantity()

      assert Enum.any?(added, &(&1.product_uuid == ctx.p2.uuid))
      assert Repo.get!(Cart, api.cart.uuid).status == "merged"
    end

    test "add skips a line that add_to_cart refuses for good, and keeps the others", ctx do
      foreign = product!(%{"currency" => "EUR"})
      api = api_cart!([{ctx.p1, 1}, {foreign, 1}])
      {raw, _} = issue!(api)
      browser = browser()
      mine = browser_cart!(browser, [{ctx.p2, 1}])
      put_setting!("shop_enforce_product_currency", true)

      assert {:ok, %{mode: :merged, skipped: [title]}} = redeem(raw, browser, mine.uuid, "add")

      assert title == foreign.title["en"]
      assert [_, _] = Shop.get_cart(mine.uuid).items
      refute Enum.any?(Shop.get_cart(mine.uuid).items, &(&1.product_uuid == foreign.uuid))
      assert Repo.get!(Cart, api.cart.uuid).status == "merged"
    end
  end

  describe "redeem/3 and the cart the page showed" do
    test "a cart that changed after the page was shown is a choice again; the shown one is claimed",
         ctx do
      api = api_cart!([{ctx.p1, 1}])
      {raw, claim} = issue!(api)
      browser = browser()
      shown = CartView.revision(api.cart)

      {:ok, _} =
        CartWriter.set_items(
          api.hash,
          %{"items" => [%{"product_id" => ctx.p1.uuid, "quantity" => 4}]},
          ctx_for(api.token)
        )

      assert {:error, :reshow} =
               Claims.redeem(raw, browser, %{offer: "none", revision: shown})

      assert Repo.get!(CartClaim, claim.uuid).used_at == nil
      assert Repo.get!(Cart, api.cart.uuid).session_id == "api:" <> api.hash
      assert active_carts(browser.session_id) == []

      {:ok, current} = CartStore.resolve(api.hash)

      assert {:ok, %{mode: :moved}} =
               Claims.redeem(raw, browser, %{offer: "none", revision: CartView.revision(current)})
    end

    test "a decision without a revision is a choice again and claims nothing", ctx do
      api = api_cart!([{ctx.p1, 1}])
      {raw, claim} = issue!(api)
      browser = browser()

      for decision <- [
            %{offer: "none"},
            %{offer: "none", revision: nil},
            %{offer: "none", revision: ""},
            %{offer: "none", revision: ["x"]}
          ] do
        assert {:error, :reshow} = Claims.redeem(raw, browser, decision), inspect(decision)
      end

      assert Repo.get!(CartClaim, claim.uuid).used_at == nil
      assert Repo.get!(Cart, api.cart.uuid).session_id == "api:" <> api.hash
      assert active_carts(browser.session_id) == []
    end

    test "a shipping choice made after the page was shown counts as a change too", ctx do
      api = api_cart!([{ctx.p1, 1}])
      {raw, _} = issue!(api)
      shown = CartView.revision(api.cart)

      Repo.update_all(from(c in Cart, where: c.uuid == ^api.cart.uuid),
        set: [shipping_country: "DE"]
      )

      assert {:error, :reshow} =
               Claims.redeem(raw, browser(), %{offer: "none", revision: shown})
    end
  end

  describe "redeem/3 when the choice is stale or missing" do
    test "a browser cart with items and no choice shows the choice again, nothing changes", ctx do
      api = api_cart!([{ctx.p1, 1}])
      {raw, claim} = issue!(api)
      browser = browser()
      mine = browser_cart!(browser, [{ctx.p2, 1}])

      for choice <- [nil, "continue", "merge", ""] do
        assert {:error, :reshow} = redeem(raw, browser, mine.uuid, choice)
      end

      assert Repo.get!(CartClaim, claim.uuid).used_at == nil
      assert Repo.get!(Cart, api.cart.uuid).session_id == "api:" <> api.hash
      assert [%Cart{uuid: uuid}] = active_carts(browser.session_id)
      assert uuid == mine.uuid
    end

    test "a cart that appeared after the page was shown is a choice again", ctx do
      api = api_cart!([{ctx.p1, 1}])
      {raw, _} = issue!(api)
      browser = browser()
      _appeared = browser_cart!(browser, [{ctx.p2, 1}])

      assert {:error, :reshow} = redeem(raw, browser, "none")
      assert [_one] = active_carts(browser.session_id)
    end

    test "a cart that was emptied or replaced after the page was shown is a choice again", ctx do
      api = api_cart!([{ctx.p1, 1}])
      {raw, _} = issue!(api)
      browser = browser()
      mine = browser_cart!(browser, [{ctx.p2, 1}])

      assert {:error, :reshow} = redeem(raw, browser, Ecto.UUID.generate(), "replace")
      assert {:error, :reshow} = redeem(raw, browser, "", "replace")

      {:ok, _} = Shop.clear_cart(Shop.get_cart(mine.uuid))
      assert {:error, :reshow} = redeem(raw, browser, mine.uuid, "replace")
    end

    test "a claim is used once; superseded, expired and unknown claims move nothing", ctx do
      api = api_cart!([{ctx.p1, 1}])
      {first, _} = issue!(api)
      {second, claim2} = issue!(api)
      browser = browser()

      assert {:error, :superseded} = redeem(first, browser, "none")
      assert {:error, :invalid} = redeem("nope", browser, "none")
      assert Repo.get!(Cart, api.cart.uuid).session_id == "api:" <> api.hash

      claim2
      |> Ecto.Changeset.change(
        expires_at: DateTime.add(DateTime.utc_now(), -5, :second) |> DateTime.truncate(:second)
      )
      |> Repo.update!()

      assert {:error, :expired} = redeem(second, browser, "none")
      assert active_carts(browser.session_id) == []
    end

    test "a cart swept between the page and the POST is unavailable", ctx do
      api = api_cart!([{ctx.p1, 1}])
      {raw, _} = issue!(api)
      api.cart |> Cart.status_changeset("abandoned") |> Repo.update!()

      assert {:error, :cart_unavailable} = redeem(raw, browser(), "none")
    end
  end

  describe "redeem/3 locks" do
    # The sandbox runs a test in one transaction, so a lock a production
    # transaction would drop at its commit is still visible afterwards: these
    # tests see that `redeem/3` takes each lock, and in which order (the race
    # itself is exercised against committed data in `ClaimsRaceTest`).
    test "takes the browser's and the API cart's identity locks, then the row locks" do
      %{raw: raw, hash: hash, claim: claim} = untouched_api_cart!()
      browser = browser()
      empty = browser_cart!(browser, [])

      browser_key = "shop_cart_session:" <> browser.session_id
      api_key = "shop_cart_session:" <> CartToken.session_id(hash)

      refute advisory_lock_held?(browser_key)
      refute advisory_lock_held?(api_key)
      refute cart_row_locked?(empty.uuid)
      refute claim_row_locked?(claim.uuid)

      trace = lock_trace(fn -> assert {:ok, %{mode: :moved}} = redeem(raw, browser, "none") end)

      # identity locks (browser, then the API cart's own), then the API cart row,
      # the claim row, the browser's cart row
      assert trace == [
               {:advisory, browser_key},
               {:advisory, api_key},
               {:row, "phoenix_kit_shop_carts"},
               {:row, "phoenix_kit_shop_cart_claims"},
               {:row, "phoenix_kit_shop_carts"}
             ]

      assert advisory_lock_held?(browser_key)
      assert advisory_lock_held?(api_key)
      assert cart_row_locked?(empty.uuid)
      assert claim_row_locked?(claim.uuid)
    end

    test "a logged-in buyer's user key is locked too" do
      user = fixture_user()
      %{raw: raw} = untouched_api_cart!()
      browser = browser(user.uuid)

      user_key = "shop_cart_user:" <> user.uuid
      session_key = "shop_cart_session:" <> browser.session_id
      refute advisory_lock_held?(user_key)
      refute advisory_lock_held?(session_key)

      assert {:ok, %{mode: :moved}} = redeem(raw, browser, "none")

      assert advisory_lock_held?(user_key)
      assert advisory_lock_held?(session_key)
    end

    test "the user key comes before the session key, both before the API cart's" do
      user = fixture_user()
      %{raw: raw, hash: hash} = untouched_api_cart!()
      browser = browser(user.uuid)

      trace = lock_trace(fn -> assert {:ok, %{mode: :moved}} = redeem(raw, browser, "none") end)

      assert Enum.take(trace, 3) == [
               {:advisory, "shop_cart_user:" <> user.uuid},
               {:advisory, "shop_cart_session:" <> browser.session_id},
               {:advisory, "shop_cart_session:" <> CartToken.session_id(hash)}
             ]
    end
  end

  describe "redeem/3 for a logged-in buyer" do
    setup do
      %{user: fixture_user()}
    end

    test "the moved cart belongs to the user and no longer expires; a guest's keeps its expiry",
         ctx do
      api = api_cart!([{ctx.p1, 1}])
      assert api.cart.expires_at != nil
      {raw, _} = issue!(api)
      browser = browser(ctx.user.uuid)

      assert {:ok, %{mode: :moved}} = redeem(raw, browser, "none")

      moved = Repo.get!(Cart, api.cart.uuid)
      assert moved.user_uuid == ctx.user.uuid
      assert moved.session_id == browser.session_id
      assert moved.expires_at == nil

      guest = api_cart!([{ctx.p1, 1}])
      {guest_raw, _} = issue!(guest)
      assert {:ok, %{mode: :moved}} = redeem(guest_raw, browser(), "none")

      kept = Repo.get!(Cart, guest.cart.uuid)
      assert kept.user_uuid == nil
      assert kept.expires_at == guest.cart.expires_at
    end

    test "a cart the user owns under another session is a choice, never overlooked", ctx do
      api = api_cart!([{ctx.p1, 1}])
      {raw, _} = issue!(api)
      mine = user_cart!(ctx.user, [{ctx.p2, 1}])
      browser = browser(ctx.user.uuid)

      assert {:error, :reshow} = redeem(raw, browser, "none")
      assert [%Cart{uuid: uuid}] = active_user_carts(ctx.user)
      assert uuid == mine.uuid
    end

    test "replace leaves the user exactly one active cart: the API cart", ctx do
      api = api_cart!([{ctx.p1, 2}])
      {raw, _} = issue!(api)
      mine = user_cart!(ctx.user, [{ctx.p2, 1}])

      assert {:ok, %{mode: :replaced}} =
               redeem(raw, browser(ctx.user.uuid), mine.uuid, "replace")

      assert [%Cart{uuid: uuid, user_uuid: user_uuid}] = active_user_carts(ctx.user)
      assert uuid == api.cart.uuid and user_uuid == ctx.user.uuid
      assert Repo.get!(Cart, mine.uuid).status == "abandoned"
    end

    test "add leaves the user exactly one active cart: theirs, with the lines merged", ctx do
      api = api_cart!([{ctx.p1, 2}])
      {raw, _} = issue!(api)
      mine = user_cart!(ctx.user, [{ctx.p2, 1}])

      assert {:ok, %{mode: :merged}} = redeem(raw, browser(ctx.user.uuid), mine.uuid, "add")

      assert [%Cart{uuid: uuid}] = active_user_carts(ctx.user)
      assert uuid == mine.uuid
      assert quantities(Shop.get_cart(mine.uuid)) == [1, 2]
    end

    test "an empty cart the user owns under another session is abandoned, not left beside it",
         ctx do
      api = api_cart!([{ctx.p1, 1}])
      {raw, _} = issue!(api)
      empty = user_cart!(ctx.user, [])

      assert {:ok, %{mode: :moved}} = redeem(raw, browser(ctx.user.uuid), "none")

      assert [%Cart{uuid: uuid}] = active_user_carts(ctx.user)
      assert uuid == api.cart.uuid
      assert Repo.get!(Cart, empty.uuid).status == "abandoned"
    end
  end

  describe "a cart that was handed over" do
    test "no new link is issued for it, and the links already stored read as unavailable",
         ctx do
      api = api_cart!([{ctx.p1, 1}])
      {raw, _} = issue!(api)
      assert {:ok, %{mode: :moved}} = redeem(raw, browser(), "none")

      assert {:error, :cart_unavailable} = Claims.issue(api.cart, api.hash, "en")

      # a link that was stored before the hand-off and never used
      stray = insert_claim!(api.cart, api.hash)
      assert {:error, :cart_unavailable} = Claims.peek(stray)
      assert {:error, :cart_unavailable} = redeem(stray, browser(), "none")

      # nothing was issued: the used claim and the stray one are all there is
      assert Repo.aggregate(from(k in CartClaim, where: k.cart_uuid == ^api.cart.uuid), :count) ==
               2
    end

    test "an abandoned cart gets no link either, and the earlier link is left as it was",
         ctx do
      api = api_cart!([{ctx.p1, 1}])
      {raw, claim} = issue!(api)
      api.cart |> Cart.status_changeset("abandoned") |> Repo.update!()

      assert {:error, :cart_unavailable} = Claims.issue(api.cart, api.hash, "en")

      assert Repo.get!(CartClaim, claim.uuid).superseded_at == nil
      assert {:error, :cart_unavailable} = Claims.peek(raw)
    end

    test "a cart moved by another path is unavailable to peek, issue and redeem", ctx do
      api = api_cart!([{ctx.p1, 1}])
      {raw, claim} = issue!(api)

      Repo.update_all(from(c in Cart, where: c.uuid == ^api.cart.uuid),
        set: [session_id: "someone-elses-browser"]
      )

      assert {:error, :cart_unavailable} = Claims.peek(raw)
      assert {:error, :cart_unavailable} = Claims.issue(api.cart, api.hash, "en")
      assert {:error, :cart_unavailable} = redeem(raw, browser(), "none")

      assert Repo.get!(CartClaim, claim.uuid).used_at == nil
      assert Repo.get!(Cart, api.cart.uuid).session_id == "someone-elses-browser"
    end
  end

  describe "redeem/3 merging lines that carry options" do
    setup do
      %{shirt: product_with_options!(%{"color" => ["Red", "Blue"]})}
    end

    test "the same product and option adds up, another option stays a line of its own", ctx do
      api =
        api_cart!([
          {ctx.shirt, 2, [opt("color", "red")]},
          {ctx.shirt, 1, [opt("color", "blue")]},
          {ctx.p1, 1}
        ])

      {raw, _} = issue!(api)
      browser = browser()
      mine = browser_cart!(browser, [{ctx.shirt, 4, %{"color" => "Red"}}])

      assert {:ok, %{mode: :merged, skipped: []}} = redeem(raw, browser, mine.uuid, "add")

      lines =
        mine.uuid
        |> Shop.get_cart()
        |> Map.fetch!(:items)
        |> Map.new(&{{&1.product_uuid, &1.selected_specs}, &1.quantity})

      assert lines == %{
               {ctx.shirt.uuid, %{"color" => "Red"}} => 6,
               {ctx.shirt.uuid, %{"color" => "Blue"}} => 1,
               {ctx.p1.uuid, %{}} => 1
             }
    end

    test "an option that is no longer offered skips the line and names it", ctx do
      api = api_cart!([{ctx.shirt, 2, [opt("color", "red")]}, {ctx.p1, 1}])
      {raw, _} = issue!(api)
      browser = browser()
      mine = browser_cart!(browser, [{ctx.p2, 1}])

      {:ok, _} =
        Shop.update_product(ctx.shirt, %{
          "metadata" => %{"_option_values" => %{"color" => ["Blue"]}}
        })

      assert {:ok, %{mode: :merged, skipped: [title]}} = redeem(raw, browser, mine.uuid, "add")

      assert title == ctx.shirt.title["en"]
      assert quantities(Shop.get_cart(mine.uuid)) == [1, 1]
    end
  end

  describe "redeem/3 when a line changes between the check and add_to_cart" do
    # `add_to_cart` makes some refusals inside its own transaction; that
    # dooms the surrounding one, so the merge may not go on and may not skip the
    # line: nothing is claimed and the buyer tries again.
    setup ctx do
      api = api_cart!([{ctx.p1, 1}])
      {raw, claim} = issue!(api)
      browser = browser()
      mine = browser_cart!(browser, [{ctx.p2, 1}])
      Map.merge(ctx, %{api: api, raw: raw, claim: claim, browser: browser, mine: mine})
    end

    defp assert_nothing_claimed(t) do
      assert Repo.get!(CartClaim, t.claim.uuid).used_at == nil
      api = Repo.get!(Cart, t.api.cart.uuid)
      assert api.status == "active" and api.session_id == "api:" <> t.api.hash
      assert [%Cart{uuid: uuid}] = active_carts(t.browser.session_id)
      assert uuid == t.mine.uuid
      assert quantities(Shop.get_cart(t.mine.uuid)) == [1]

      # the connection is still usable
      assert %{rows: [[1]]} = Repo.query!("SELECT 1")
    end

    test "a product that left the shop is a retry, not a skip", t do
      after_first_query("SELECT", "phoenix_kit_shop_products", fn ->
        {:ok, _} = Shop.update_product(t.p1, %{"status" => "archived"})
      end)

      assert {:error, :busy} = redeem(t.raw, t.browser, t.mine.uuid, "add")
      assert_nothing_claimed(t)
    end

    test "an option value that stopped being offered is a retry, not a skip", t do
      shirt = product_with_options!(%{"color" => ["Red", "Blue"]})
      api = api_cart!([{shirt, 1, [opt("color", "red")]}])
      {raw, claim} = issue!(api)
      t = %{t | api: api, raw: raw, claim: claim}

      after_first_query("SELECT", "phoenix_kit_shop_products", fn ->
        {:ok, _} =
          Shop.update_product(shirt, %{
            "metadata" => %{"_option_values" => %{"color" => ["Green"]}}
          })
      end)

      assert {:error, :busy} = redeem(t.raw, t.browser, t.mine.uuid, "add")
      assert_nothing_claimed(t)
    end

    # A trigger raises what Postgres raises for the aborted side of a deadlock
    # (SQLSTATE 40P01); the DDL rolls back with the test's transaction.
    test "a deadlock the database resolves against the merge is a retry, not an error page", t do
      Repo.query!("""
      CREATE FUNCTION pk_test_raise_deadlock() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN RAISE EXCEPTION 'simulated deadlock' USING ERRCODE = '40P01'; END
      $$
      """)

      Repo.query!("""
      CREATE TRIGGER pk_test_raise_deadlock BEFORE INSERT ON phoenix_kit_shop_cart_items
      FOR EACH ROW EXECUTE FUNCTION pk_test_raise_deadlock()
      """)

      assert {:error, :busy} = redeem(t.raw, t.browser, t.mine.uuid, "add")
    end

    test "a refusal inside the cart rebase is a retry, not a skip", t do
      Repo.update_all(CartItem, set: [base_unit_price: nil])

      assert {:ok, %{old_base: "USD"}} =
               PhoenixKitBilling.change_base_currency("EUR",
                 catalog_size: 1,
                 reprice: &Shop.reprice_for_base_change/3
               )

      assert {:error, :busy} = redeem(t.raw, t.browser, t.mine.uuid, "add")
      assert_nothing_claimed(t)
    end
  end

  describe "browser_cart/1" do
    setup do
      %{user: fixture_user()}
    end

    defp stamp!(cart, updated_at, inserted_at \\ nil) do
      set = [updated_at: updated_at] ++ if(inserted_at, do: [inserted_at: inserted_at], else: [])
      Repo.update_all(from(c in Cart, where: c.uuid == ^cart.uuid), set: set)
    end

    defp at(offset),
      do: DateTime.utc_now() |> DateTime.add(offset, :second) |> DateTime.truncate(:second)

    test "is nil for a browser with no active cart" do
      assert Claims.browser_cart(browser()) == nil
    end

    test "is the guest's unowned session cart with its lines, and nobody else's", ctx do
      browser = browser()
      mine = browser_cart!(browser, [{ctx.p1, 2}])
      _other = browser_cart!(browser(), [{ctx.p2, 1}])

      assert %Cart{uuid: uuid, items: [%CartItem{quantity: 2}]} = Claims.browser_cart(browser)
      assert uuid == mine.uuid
    end

    test "ignores an abandoned cart and a cart a user owns when the browser is a guest", ctx do
      browser = browser()
      {:ok, owned} = Shop.create_cart(user_uuid: ctx.user.uuid, session_id: browser.session_id)
      gone = browser_cart!(browser, [{ctx.p1, 1}])
      gone |> Cart.status_changeset("abandoned") |> Repo.update!()

      assert owned.status == "active"
      assert Claims.browser_cart(browser) == nil
    end

    test "is the user's own cart before a newer unowned session cart, as for the storefront",
         ctx do
      browser = browser(ctx.user.uuid)
      mine = user_cart!(ctx.user, [])
      guest = browser_cart!(browser, [{ctx.p1, 1}])
      stamp!(mine, at(-60))
      stamp!(guest, at(60))

      assert Claims.browser_cart(browser).uuid == mine.uuid

      found = Shop.find_active_cart(user_uuid: ctx.user.uuid, session_id: browser.session_id)
      assert found.uuid == mine.uuid
    end

    test "falls back to the unowned session cart when the user owns none", ctx do
      browser = browser(ctx.user.uuid)
      guest = browser_cart!(browser, [{ctx.p1, 1}])

      assert Claims.browser_cart(browser).uuid == guest.uuid
    end

    test "never takes another user's cart that carries this session", ctx do
      browser = browser(ctx.user.uuid)

      {:ok, _theirs} =
        Shop.create_cart(user_uuid: fixture_user().uuid, session_id: browser.session_id)

      assert Claims.browser_cart(browser) == nil
    end

    test "of several candidates the newest wins, ties by creation time and uuid", ctx do
      browser = browser()
      a = browser_cart!(browser, [{ctx.p1, 1}])
      b = browser_cart!(browser, [{ctx.p2, 1}])
      stamp!(a, at(-30), at(-30))
      stamp!(b, at(-10), at(-10))
      assert Claims.browser_cart(browser).uuid == b.uuid

      same = at(-5)
      stamp!(a, same, at(-20))
      stamp!(b, same, at(-20))
      expected = Enum.max([a.uuid, b.uuid])

      for _ <- 1..5, do: assert(Claims.browser_cart(browser).uuid == expected)
    end
  end

  describe "redeem/3 leaves the storefront one cart to find" do
    setup do
      %{user: fixture_user()}
    end

    test "an older empty cart of the user beside a newer guest cart with lines", ctx do
      api = api_cart!([{ctx.p1, 1}])
      {raw, _} = issue!(api)
      browser = browser(ctx.user.uuid)
      empty = user_cart!(ctx.user, [])
      guest = browser_cart!(browser, [{ctx.p2, 1}])
      stamp!(empty, at(-60))
      stamp!(guest, at(60))

      assert {:error, :reshow} = redeem(raw, browser, guest.uuid, "replace")
      assert {:ok, %{mode: :moved}} = redeem(raw, browser, "none")

      assert [%Cart{uuid: uuid}] = active_user_carts(ctx.user)
      assert uuid == api.cart.uuid
      assert Repo.get!(Cart, empty.uuid).status == "abandoned"

      found = Shop.find_active_cart(user_uuid: ctx.user.uuid, session_id: browser.session_id)
      assert found.uuid == api.cart.uuid
    end

    test "a cart of the user with lines beside a newer empty guest cart is still asked about",
         ctx do
      api = api_cart!([{ctx.p1, 1}])
      {raw, _} = issue!(api)
      browser = browser(ctx.user.uuid)
      mine = user_cart!(ctx.user, [{ctx.p2, 1}])
      empty = browser_cart!(browser, [])
      stamp!(mine, at(-60))
      stamp!(empty, at(60))

      assert {:error, :reshow} = redeem(raw, browser, "none")
      assert {:ok, %{mode: :replaced}} = redeem(raw, browser, mine.uuid, "replace")

      assert [%Cart{uuid: uuid}] = active_user_carts(ctx.user)
      assert uuid == api.cart.uuid

      found = Shop.find_active_cart(user_uuid: ctx.user.uuid, session_id: browser.session_id)
      assert found.uuid == api.cart.uuid
    end
  end

  describe "helpers" do
    test "path/1 is outside the locale prefix and carries the token", ctx do
      {raw, _} = issue!(api_cart!([{ctx.p1, 1}]))

      assert Claims.path(raw) == "/checkout/claim/" <> raw
    end

    test "language_of/1 reads the claim's language without consuming it", ctx do
      {raw, claim} = issue!(api_cart!([{ctx.p1, 1}]), "fr")

      assert Claims.language_of(raw) == "fr"
      assert Claims.language_of("nope") == nil
      assert Repo.get!(CartClaim, claim.uuid).used_at == nil
    end
  end
end
