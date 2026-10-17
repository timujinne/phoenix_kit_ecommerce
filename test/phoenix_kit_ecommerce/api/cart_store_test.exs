defmodule PhoenixKitEcommerce.API.CartStoreTest do
  @moduledoc """
  Token -> cart rows: resolution, the lazy first write, the row limit, the
  revision snapshots. A test runs in one sandbox transaction, so the locks a
  write takes are asserted directly (`pg_locks` and the row's `xmax`) and the
  re-check after the lock is pinned in sequence; the race itself, with parallel
  callers on real connections, is in `CartStoreRaceTest`.
  """

  # async: false - settings and the Hammer counters are shared.
  use PhoenixKitEcommerce.DataCase, async: false
  @moduletag :requires_core_api

  import PhoenixKitEcommerce.CartApiFixtures

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.API.CartStore
  alias PhoenixKitEcommerce.API.CartToken
  alias PhoenixKitEcommerce.Cart
  alias PhoenixKitEcommerce.CartClaim

  setup do
    put_secret!()
    ensure_currencies!()
    token = new_token!()
    {:ok, hash} = CartToken.verify(token)
    %{token: token, hash: hash}
  end

  defp write(hash, ctx, opts \\ []) do
    {:ok, result} = Repo.transaction(fn -> CartStore.for_write(hash, ctx, opts) end)
    result
  end

  defp count_carts(session_id),
    do: Repo.aggregate(from(c in Cart, where: c.session_id == ^session_id), :count)

  defp claim!(cart, hash, attrs \\ %{}) do
    {:ok, claim} =
      %CartClaim{}
      |> CartClaim.changeset(
        Map.merge(
          %{
            token_hash: "th-#{System.unique_integer([:positive])}",
            cart_uuid: cart.uuid,
            cart_token_hash: hash,
            language: "en",
            expires_at:
              DateTime.utc_now() |> DateTime.add(1800, :second) |> DateTime.truncate(:second),
            used_at: DateTime.utc_now() |> DateTime.truncate(:second)
          },
          attrs
        )
      )
      |> Repo.insert()

    claim
  end

  describe "resolve/1" do
    test "a signed token with no row yet is an empty open cart", %{hash: hash} do
      assert CartStore.resolve(hash) == :empty
    end

    test "an active cart is found by the token's session id, with its lines preloaded", %{
      hash: hash
    } do
      {:ok, cart} = Shop.create_cart(session_id: CartToken.session_id(hash))

      assert {:ok, found} = CartStore.resolve(hash)
      assert found.uuid == cart.uuid
      assert found.items == []
      assert found.shipping_method == nil
    end

    test "the newest cart of the session wins over an older abandoned one", %{hash: hash} do
      {:ok, old} = Shop.create_cart(session_id: CartToken.session_id(hash))
      old |> Cart.status_changeset("abandoned") |> Repo.update!()

      an_hour_ago =
        DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

      Repo.update_all(from(c in Cart, where: c.uuid == ^old.uuid),
        set: [inserted_at: an_hour_ago]
      )

      {:ok, current} = Shop.create_cart(session_id: CartToken.session_id(hash))

      assert {:ok, %Cart{uuid: uuid}} = CartStore.resolve(hash)
      assert uuid == current.uuid
    end

    test "a cart of another token, or a lookalike session id, is not found", %{hash: hash} do
      {:ok, _} = Shop.create_cart(session_id: "api:" <> hash <> "x")
      {:ok, _} = Shop.create_cart(session_id: "apix" <> hash)
      {:ok, _} = Shop.create_cart(session_id: hash)

      assert CartStore.resolve(hash) == :empty
    end

    test "a swept (abandoned) cart is not found", %{hash: hash} do
      {:ok, cart} = Shop.create_cart(session_id: CartToken.session_id(hash))
      cart |> Cart.status_changeset("abandoned") |> Repo.update!()

      assert CartStore.resolve(hash) == :not_found
    end

    test "a claimed cart that was merged answers locked", %{hash: hash} do
      {:ok, cart} = Shop.create_cart(session_id: CartToken.session_id(hash))

      {:ok, target} =
        Shop.create_cart(session_id: "browser-#{System.unique_integer([:positive])}")

      cart
      |> Cart.status_changeset("merged", %{merged_into_cart_uuid: target.uuid})
      |> Repo.update!()

      claim = claim!(cart, hash)

      assert {:locked, %CartClaim{uuid: uuid}} = CartStore.resolve(hash)
      assert uuid == claim.uuid
    end

    test "a claimed cart that moved to a browser session answers locked", %{hash: hash} do
      {:ok, cart} = Shop.create_cart(session_id: CartToken.session_id(hash))

      cart
      |> Cart.changeset(%{session_id: "browser-#{System.unique_integer([:positive])}"})
      |> Repo.update!()

      claim!(cart, hash)

      assert {:locked, %CartClaim{}} = CartStore.resolve(hash)
    end

    test "an unused claim does not lock the cart", %{hash: hash} do
      {:ok, cart} = Shop.create_cart(session_id: CartToken.session_id(hash))
      claim!(cart, hash, %{used_at: nil})

      assert {:ok, _} = CartStore.resolve(hash)
    end

    # A link that was issued and not opened yet is not a hand-off: it must not
    # turn a swept cart into "checking out", nor an unwritten token either.
    test "an unused claim does not turn a swept cart into a locked one", %{hash: hash} do
      {:ok, cart} = Shop.create_cart(session_id: CartToken.session_id(hash))
      cart |> Cart.status_changeset("abandoned") |> Repo.update!()
      claim!(cart, hash, %{used_at: nil})

      assert CartStore.resolve(hash) == :not_found
    end

    test "an unused claim does not turn a token without a row into a locked one", %{hash: hash} do
      {:ok, browser} =
        Shop.create_cart(session_id: "browser-#{System.unique_integer([:positive])}")

      claim!(browser, hash, %{used_at: nil})

      assert CartStore.resolve(hash) == :empty
    end
  end

  describe "empty?/1" do
    test "is true only for a token that has no cart row yet", %{hash: hash} do
      assert CartStore.empty?(hash)

      {:ok, cart} = Shop.create_cart(session_id: CartToken.session_id(hash))
      refute CartStore.empty?(hash)

      cart |> Cart.status_changeset("abandoned") |> Repo.update!()
      refute CartStore.empty?(hash)
    end
  end

  describe "for_write/3" do
    test "creates the row on the first write, with the token's session id and the request currency",
         %{hash: hash} do
      ctx = ctx(%{currency: "EUR"})

      assert {:ok, cart, :created} = write(hash, ctx)
      assert cart.session_id == "api:" <> hash
      assert cart.status == "active"
      assert cart.currency == "EUR"
      assert cart.items == []
    end

    test "without a request currency the cart takes the shop's display currency", %{hash: hash} do
      assert {:ok, cart, :created} = write(hash, ctx())
      assert cart.currency == "USD"
    end

    test "the request currency does not leak out of the call", %{hash: hash} do
      PhoenixKitBilling.Currency.put_request_currency(nil)
      write(hash, ctx(%{currency: "EUR"}))

      assert PhoenixKitBilling.Currency.get_request_currency() == nil
    end

    test "the second write finds the same row and creates nothing", %{hash: hash} do
      {:ok, first, :created} = write(hash, ctx())

      assert {:ok, second, :existing} = write(hash, ctx())
      assert second.uuid == first.uuid
      assert second.items == []
      assert second.shipping_method == nil
      assert count_carts("api:" <> hash) == 1
    end

    test "the write path holds the token's session lock, for a new token and an existing cart",
         %{hash: hash} do
      key = "shop_cart_session:" <> CartToken.session_id(hash)
      refute advisory_lock_held?(key)

      assert {:ok, {:ok, _cart, :created}} =
               Repo.transaction(fn ->
                 result = CartStore.for_write(hash, ctx())
                 assert advisory_lock_held?(key)
                 result
               end)

      existing = new_token!()
      {:ok, existing_hash} = CartToken.verify(existing)
      existing_key = "shop_cart_session:" <> CartToken.session_id(existing_hash)
      {:ok, _} = Shop.create_cart(session_id: CartToken.session_id(existing_hash))
      refute advisory_lock_held?(existing_key)

      assert {:ok, {:ok, _cart, :existing}} =
               Repo.transaction(fn ->
                 result = CartStore.for_write(existing_hash, ctx())
                 assert advisory_lock_held?(existing_key)
                 result
               end)
    end

    test "an existing cart is row-locked for the rest of the transaction", %{hash: hash} do
      {:ok, cart} = Shop.create_cart(session_id: CartToken.session_id(hash))
      refute cart_row_locked?(cart.uuid)

      assert {:ok, {:ok, %Cart{}, :existing}} =
               Repo.transaction(fn ->
                 result = CartStore.for_write(hash, ctx())
                 assert cart_row_locked?(cart.uuid)
                 result
               end)
    end

    test "the locks are only meaningful inside a transaction, so outside one it raises",
         %{hash: hash} do
      assert_raise ArgumentError, ~r/inside a transaction/, fn ->
        CartStore.for_write(hash, ctx())
      end
    end

    test "a locked token is refused, an abandoned one is not found", %{hash: hash} do
      {:ok, cart, :created} = write(hash, ctx())
      cart |> Cart.status_changeset("abandoned") |> Repo.update!()
      assert write(hash, ctx()) == :not_found

      other = new_token!()
      {:ok, other_hash} = CartToken.verify(other)
      {:ok, moved} = Shop.create_cart(session_id: "browser-#{System.unique_integer([:positive])}")
      claim!(moved, other_hash)
      assert {:locked, %CartClaim{}} = write(other_hash, ctx())
    end

    test "the first write of a new cart is charged to the per-network row limit", %{hash: hash} do
      put_setting!("api_public_cart_rows_per_ip_hour", 1)
      ctx = ctx()
      second = new_token!()
      {:ok, second_hash} = CartToken.verify(second)

      assert {:ok, _cart, :created} = write(hash, ctx)
      assert {:error, :rate_limited, retry} = write(second_hash, ctx)
      assert is_integer(retry) and retry > 0
      assert CartStore.resolve(second_hash) == :empty
      assert count_carts("api:" <> second_hash) == 0
    end

    test "the same charge counts against the global limit, whatever the network", %{hash: hash} do
      put_setting!("api_public_cart_rows_global_hour", 1)
      second = new_token!()
      {:ok, second_hash} = CartToken.verify(second)

      # Two contexts, two different client addresses, so only the global limit can refuse. The
      # global bucket is shared by every test of the run, so it may already hold a count: the
      # first creation may pass or be refused, the second is refused either way.
      first = write(hash, ctx())
      assert match?({:ok, _cart, :created}, first) or match?({:error, :rate_limited, _}, first)

      assert {:error, :rate_limited, retry} = write(second_hash, ctx())
      assert is_integer(retry) and retry > 0
      assert CartStore.resolve(second_hash) == :empty
    end

    test "an existing cart is not charged", %{hash: hash} do
      put_setting!("api_public_cart_rows_per_ip_hour", 1)
      ctx = ctx()

      assert {:ok, _, :created} = write(hash, ctx)
      assert {:ok, _, :existing} = write(hash, ctx)
      assert {:ok, _, :existing} = write(hash, ctx)
    end

    test "count_row: false creates the row without charging the limit (dry runs)", %{hash: hash} do
      put_setting!("api_public_cart_rows_per_ip_hour", 1)
      ctx = ctx()

      assert {:ok, _, :created} = write(hash, ctx, count_row: false)
      other = new_token!()
      {:ok, other_hash} = CartToken.verify(other)
      assert {:ok, _, :created} = write(other_hash, ctx)
    end
  end

  describe "lock_active!/2" do
    test "returns the locked cart with its lines and shipping method preloaded", %{hash: hash} do
      {:ok, cart} = Shop.create_cart(session_id: CartToken.session_id(hash))

      assert {:ok, locked} = Repo.transaction(fn -> CartStore.lock_active!(cart.uuid, hash) end)
      assert locked.uuid == cart.uuid
      assert locked.items == []
      assert locked.shipping_method == nil
    end

    test "holds the row lock for the rest of the transaction", %{hash: hash} do
      {:ok, cart} = Shop.create_cart(session_id: CartToken.session_id(hash))
      refute cart_row_locked?(cart.uuid)

      assert {:ok, true} =
               Repo.transaction(fn ->
                 CartStore.lock_active!(cart.uuid, hash)
                 cart_row_locked?(cart.uuid)
               end)
    end

    test "raises outside a transaction", %{hash: hash} do
      {:ok, cart} = Shop.create_cart(session_id: CartToken.session_id(hash))

      assert_raise ArgumentError, ~r/inside a transaction/, fn ->
        CartStore.lock_active!(cart.uuid, hash)
      end
    end

    test "rolls the transaction back with :not_found for a swept cart, or none", %{hash: hash} do
      {:ok, cart} = Shop.create_cart(session_id: CartToken.session_id(hash))
      cart |> Cart.status_changeset("abandoned") |> Repo.update!()

      assert {:error, :not_found} =
               Repo.transaction(fn -> CartStore.lock_active!(cart.uuid, hash) end)

      assert {:error, :not_found} =
               Repo.transaction(fn -> CartStore.lock_active!(Ecto.UUID.generate(), hash) end)
    end

    # The race of the module doc: the caller resolved the cart, then a claim
    # committed before the caller got the row lock. The sandbox runs a test in
    # one transaction, so the order is reproduced by committing the claim
    # first and then locking with the uuid resolved earlier.
    test "a cart that a claim moved to a browser after the caller resolved it is locked, not written",
         %{
           hash: hash
         } do
      {:ok, cart} = Shop.create_cart(session_id: CartToken.session_id(hash))
      assert {:ok, %Cart{uuid: resolved_uuid}} = CartStore.resolve(hash)

      cart
      |> Cart.changeset(%{session_id: "browser-#{System.unique_integer([:positive])}"})
      |> Repo.update!()

      claim!(cart, hash)

      assert {:error, {:locked, %CartClaim{}}} =
               Repo.transaction(fn -> CartStore.lock_active!(resolved_uuid, hash) end)
    end

    test "a cart that a claim merged after the caller resolved it is locked, not not-found", %{
      hash: hash
    } do
      {:ok, cart} = Shop.create_cart(session_id: CartToken.session_id(hash))

      {:ok, target} =
        Shop.create_cart(session_id: "browser-#{System.unique_integer([:positive])}")

      cart
      |> Cart.status_changeset("merged", %{merged_into_cart_uuid: target.uuid})
      |> Repo.update!()

      claim!(cart, hash)

      assert {:error, {:locked, %CartClaim{}}} =
               Repo.transaction(fn -> CartStore.lock_active!(cart.uuid, hash) end)
    end

    test "a token only ever locks its own cart", %{hash: hash} do
      {:ok, other} = Shop.create_cart(session_id: "api:" <> hash <> "x")

      assert {:error, :not_found} =
               Repo.transaction(fn -> CartStore.lock_active!(other.uuid, hash) end)
    end
  end

  describe "gone/1" do
    test "is :locked for a handed-over token and :not_found otherwise", %{hash: hash} do
      assert CartStore.gone(hash) == :not_found

      {:ok, cart} = Shop.create_cart(session_id: "browser-#{System.unique_integer([:positive])}")
      claim!(cart, hash)

      assert {:locked, %CartClaim{}} = CartStore.gone(hash)
    end
  end

  describe "display_currency/1" do
    test "is the call's currency when it has one, else the shop's display currency" do
      assert CartStore.display_currency(ctx(%{currency: "EUR"})) == "EUR"
      assert CartStore.display_currency(ctx()) == "USD"
      assert PhoenixKitBilling.Currency.get_request_currency() == nil
    end
  end

  describe "put_snapshot!/2" do
    test "keeps the 10 newest, newest first, one per revision, and the other metadata keys" do
      {:ok, cart} = Shop.create_cart(session_id: "api:snap-#{System.unique_integer([:positive])}")
      Shop.claim_cart_flag(cart, "first_item_notified")
      cart = Repo.get!(Cart, cart.uuid)

      cart =
        Enum.reduce(1..12, cart, fn n, acc ->
          :ok = CartStore.put_snapshot!(acc, %{"revision" => "r#{n}", "lines" => []})
          Repo.get!(Cart, acc.uuid)
        end)

      revisions = Enum.map(cart.metadata["api_revisions"], & &1["revision"])
      assert revisions == Enum.map(12..3//-1, &"r#{&1}")
      assert cart.metadata["first_item_notified"] == true

      :ok = CartStore.put_snapshot!(cart, %{"revision" => "r5", "lines" => []})
      cart = Repo.get!(Cart, cart.uuid)

      assert Enum.map(cart.metadata["api_revisions"], & &1["revision"]) ==
               ~w(r5 r12 r11 r10 r9 r8 r7 r6 r4 r3)
    end
  end
end
