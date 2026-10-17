defmodule PhoenixKitEcommerce.API.ClaimsRaceTest do
  @moduledoc """
  Parallel redeems must never leave two active carts for one browser, and a
  claim must be used once.

  The SQL sandbox wraps a test in one transaction, so a race cannot happen there.
  These tests run the callers on real connections (`unboxed_run`, the way
  `CartStoreRaceTest` does), release them together, and count the committed rows.
  Without the browser's identity lock two redeems (or a redeem and a storefront
  cart lookup) both find no cart and both create or move one.

  `async: false`: they commit to a shared database. The carts they create (and
  their claims, which go with them) and, when the database has none, a default
  currency are removed afterwards.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  import PhoenixKitEcommerce.CartApiFixtures,
    only: [put_secret!: 0, new_token!: 0, redeem_shown: 3]

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.API.CartToken
  alias PhoenixKitEcommerce.API.Claims
  alias PhoenixKitEcommerce.Cart
  alias PhoenixKitEcommerce.CartClaim
  alias PhoenixKitEcommerce.Test.Repo

  @moduletag :integration
  @moduletag :requires_core_api

  @rounds 5

  setup do
    put_secret!()

    unboxed(fn ->
      if Repo.aggregate(PhoenixKitBilling.Currency, :count) == 0 do
        {:ok, _} =
          PhoenixKitBilling.create_currency(%{
            code: "USD",
            name: "Dollar",
            symbol: "$",
            is_default: true,
            exchange_rate: "1.0"
          })

        PhoenixKit.Cache.clear(:billing_currencies)
        on_exit(fn -> unboxed(fn -> Repo.delete_all(PhoenixKitBilling.Currency) end) end)
      end
    end)

    :ok
  end

  test "parallel redeems of one claim by one browser: one moves the cart, the others see it used" do
    for _round <- 1..@rounds do
      {raw, _api} = api_cart_with_claim!()
      browser = browser!()

      outcomes = race(List.duplicate(fn -> redeem(raw, browser) end, 4))

      assert Enum.count(outcomes, &match?({:ok, %{mode: :moved}}, &1)) == 1
      assert Enum.count(outcomes, &(&1 == {:error, :used})) == 3
      assert count_active(browser) == 1
    end
  end

  test "parallel redeems of one claim by different browsers: the cart ends up in one of them" do
    for _round <- 1..@rounds do
      {raw, api} = api_cart_with_claim!()
      browsers = for _caller <- 1..4, do: browser!()

      outcomes = race(for browser <- browsers, do: fn -> redeem(raw, browser) end)

      assert Enum.count(outcomes, &match?({:ok, %{mode: :moved}}, &1)) == 1

      assert Enum.all?(outcomes, fn outcome ->
               match?({:ok, _}, outcome) or
                 outcome in [{:error, :used}, {:error, :cart_unavailable}]
             end)

      active = unboxed(fn -> Repo.get!(Cart, api.uuid) end)
      assert active.session_id in Enum.map(browsers, & &1.session_id)
    end
  end

  test "two claims redeemed into one empty browser at once leave it one active cart" do
    for _round <- 1..@rounds do
      {first, _} = api_cart_with_claim!()
      {second, _} = api_cart_with_claim!()
      browser = browser!()

      outcomes = race([fn -> redeem(first, browser) end, fn -> redeem(second, browser) end])

      assert Enum.all?(outcomes, &match?({:ok, %{mode: :moved}}, &1))
      assert count_active(browser) == 1
    end
  end

  test "a redeem racing the storefront's own cart lookup leaves the browser one active cart" do
    for _round <- 1..@rounds do
      {raw, _api} = api_cart_with_claim!()
      browser = browser!()

      lookup = fn -> Shop.get_or_create_cart(session_id: browser.session_id) end
      outcomes = race([fn -> redeem(raw, browser) end, lookup, lookup, lookup])

      assert Enum.all?(Enum.drop(outcomes, 1), &match?({:ok, %Cart{}}, &1))
      assert count_active(browser) == 1
    end
  end

  # `issue/3` and `redeem/3` meet on the API cart's row. Here one side is played
  # by a transaction that holds the row (as the real one would until its commit)
  # and the other is the real call: it must wait for the row, then decide on what
  # it finds there. The test fails when the call does not wait (no lock) or
  # decides on what it read before the wait (no re-check under the lock).
  test "a link asked for while the cart is being handed over waits for the hand-over and is refused" do
    {_raw, api} = api_cart_with_claim!()
    hash = String.replace_prefix(api.session_id, "api:", "")
    browser = browser!()

    holder =
      hold_cart_row(api, fn ->
        Repo.update_all(from(c in Cart, where: c.uuid == ^api.uuid),
          set: [session_id: browser.session_id]
        )
      end)

    issuer = Task.async(fn -> unboxed(fn -> Claims.issue(api, hash, "en") end) end)

    assert Task.yield(issuer, 300) == nil, "issue/3 did not wait for the cart row"
    release(holder)

    assert {:error, :cart_unavailable} = Task.await(issuer, 10_000)

    assert unboxed(fn ->
             Repo.aggregate(from(k in CartClaim, where: k.cart_uuid == ^api.uuid), :count)
           end) == 1
  end

  test "a redeem waiting for the cart row finds the claim superseded by the link that got there first" do
    {raw, api} = api_cart_with_claim!()
    browser = browser!()

    holder =
      hold_cart_row(api, fn ->
        Repo.update_all(from(k in CartClaim, where: k.cart_uuid == ^api.uuid),
          set: [superseded_at: DateTime.utc_now() |> DateTime.truncate(:second)]
        )
      end)

    redeemer = Task.async(fn -> unboxed(fn -> redeem(raw, browser) end) end)

    assert Task.yield(redeemer, 300) == nil, "redeem/3 did not wait for the cart row"
    release(holder)

    assert {:error, :superseded} = Task.await(redeemer, 10_000)
    assert count_active(browser) == 0
    assert unboxed(fn -> Repo.get!(Cart, api.uuid).session_id end) == api.session_id
  end

  # --- helpers ------------------------------------------------------------------

  # A transaction on its own connection that locks the cart row, runs `change`
  # and commits when `release/1` says so. Returns once the lock is held.
  defp hold_cart_row(cart, change) do
    test = self()

    task = Task.async(fn -> unboxed(fn -> Repo.transaction(hold(cart, change, test)) end) end)

    assert_receive :holding, 5_000
    task
  end

  defp hold(cart, change, test) do
    fn ->
      Repo.one(from(c in Cart, where: c.uuid == ^cart.uuid, lock: "FOR UPDATE"))
      send(test, :holding)

      receive do
        :release -> change.()
      end
    end
  end

  defp release(%Task{pid: pid} = task) do
    send(pid, :release)
    assert {:ok, _} = Task.await(task, 10_000)
  end

  defp redeem(raw, browser), do: redeem_shown(raw, browser, %{offer: "none", choice: nil})

  # A committed, empty API cart and an unused claim for it; both are removed on
  # exit with the cart (the claim goes with it).
  defp api_cart_with_claim! do
    {:ok, hash} = CartToken.verify(new_token!())
    session_id = CartToken.session_id(hash)
    cleanup_on_exit(session_id)

    unboxed(fn ->
      {:ok, cart} = Shop.create_cart(session_id: session_id)
      {:ok, %{token: raw}} = Claims.issue(cart, hash, "en")
      {raw, cart}
    end)
  end

  defp browser! do
    session_id = "claims-race-#{System.unique_integer([:positive])}"
    cleanup_on_exit(session_id)
    %{session_id: session_id, user_uuid: nil}
  end

  defp count_active(%{session_id: session_id}) do
    unboxed(fn ->
      Repo.aggregate(
        from(c in Cart, where: c.session_id == ^session_id and c.status == "active"),
        :count
      )
    end)
  end

  # Starts one task per function, each on its own real connection, holds them
  # until every one is ready and releases them together. The answers come back in
  # the order of `funs`.
  defp race(funs) do
    parent = self()
    tasks = for fun <- funs, do: Task.async(fn -> wait_then(parent, fun) end)

    for _task <- tasks, do: assert_receive({:ready, _pid}, 5_000)
    Enum.each(tasks, &send(&1.pid, :go))
    Task.await_many(tasks, 30_000)
  end

  defp wait_then(parent, fun) do
    unboxed(fn ->
      send(parent, {:ready, self()})

      receive do
        :go -> fun.()
      end
    end)
  end

  defp cleanup_on_exit(session_id) do
    on_exit(fn ->
      unboxed(fn -> Repo.delete_all(from(c in Cart, where: c.session_id == ^session_id)) end)
    end)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
