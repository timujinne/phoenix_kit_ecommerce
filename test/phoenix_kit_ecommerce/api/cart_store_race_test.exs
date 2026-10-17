defmodule PhoenixKitEcommerce.API.CartStoreRaceTest do
  @moduledoc """
  Parallel first writes must leave one active cart.

  The SQL sandbox wraps a test in one transaction, so a race cannot happen
  there. These tests run the callers on real connections (`unboxed_run`, the
  way `Search.QueryTypoUnboxedTest` does), release them together, and count the
  committed rows. Without the identity lock every caller finds nothing and
  inserts its own cart.

  `async: false`: they commit to a shared database. What they create (carts and,
  when the database has none, a default currency) is removed afterwards.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import PhoenixKitEcommerce.CartApiFixtures, only: [put_secret!: 0, new_token!: 0, ctx: 0]

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.API.CartStore
  alias PhoenixKitEcommerce.API.CartToken
  alias PhoenixKitEcommerce.Cart
  alias PhoenixKitEcommerce.Test.Repo

  @moduletag :integration

  @callers 6
  @rounds 3

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

  @tag :requires_core_api
  test "parallel first writes of one cart token create one cart, once" do
    for _round <- 1..@rounds do
      {:ok, hash} = CartToken.verify(new_token!())
      session_id = CartToken.session_id(hash)
      cleanup_on_exit(session_id)

      outcomes =
        race(fn ->
          {:ok, result} =
            Repo.transaction(fn -> CartStore.for_write(hash, ctx(), count_row: false) end)

          result
        end)

      assert outcomes |> Enum.map(&elem(&1, 2)) |> Enum.sort() ==
               [:created | List.duplicate(:existing, @callers - 1)]

      assert outcomes |> Enum.map(&elem(&1, 1).uuid) |> Enum.uniq() |> length() == 1
      assert count_carts(session_id) == 1
    end
  end

  test "parallel get_or_create_cart calls of one session create one cart" do
    for _round <- 1..@rounds do
      session_id = "race-#{System.unique_integer([:positive])}"
      cleanup_on_exit(session_id)

      carts = race(fn -> Shop.get_or_create_cart(session_id: session_id) end)

      assert Enum.all?(carts, &match?({:ok, %Cart{}}, &1))
      assert carts |> Enum.map(fn {:ok, cart} -> cart.uuid end) |> Enum.uniq() |> length() == 1
      assert count_carts(session_id) == 1
    end
  end

  # Starts `@callers` tasks, each on its own real connection, holds them until
  # every one is ready and releases them together.
  defp race(fun) do
    parent = self()
    tasks = for _caller <- 1..@callers, do: Task.async(fn -> wait_then(parent, fun) end)

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

  defp count_carts(session_id) do
    unboxed(fn -> Repo.aggregate(from(c in Cart, where: c.session_id == ^session_id), :count) end)
  end

  defp cleanup_on_exit(session_id) do
    on_exit(fn ->
      unboxed(fn -> Repo.delete_all(from(c in Cart, where: c.session_id == ^session_id)) end)
    end)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
