defmodule PhoenixKitEcommerce.Workers.ApiCartPruneRaceTest do
  @moduledoc """
  The prune must never delete a cart that stopped being expired after the prune
  picked it. The SQL sandbox wraps a test in one transaction, so this runs the
  prune on a real connection (`unboxed_run`, the way `ClaimsRaceTest` does)
  while a second transaction holds the cart row, changes it and commits: the
  DELETE waits for the row, then has to decide on the new row version.

  `async: false`: it commits to a shared database. The carts are removed on exit.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitEcommerce.Cart
  alias PhoenixKitEcommerce.Test.Repo
  alias PhoenixKitEcommerce.Workers.ApiCartPruneWorker

  @moduletag :integration

  defp days_ago(days),
    do: DateTime.utc_now() |> DateTime.add(-days * 86_400, :second) |> DateTime.truncate(:second)

  # What happens to the cart between the moment the prune picks it and the moment
  # it deletes it: each one makes one of the three conditions false.
  for {name, change} <- [
        {"becomes active again", quote(do: [status: "active"])},
        {"is handed to a browser", quote(do: [session_id: "browser-prune-race"])},
        {"is written to",
         quote(do: [updated_at: DateTime.utc_now() |> DateTime.truncate(:second)])}
      ] do
    test "a cart that #{name} while the prune waits for its row is kept" do
      cart = expired_api_cart!()
      holder = hold_cart_row(cart, unquote(change))

      pruner = Task.async(fn -> unboxed(fn -> ApiCartPruneWorker.prune() end) end)

      assert Task.yield(pruner, 300) == nil, "the prune did not wait for the cart row"
      release(holder)

      assert {:ok, _count} = Task.await(pruner, 10_000)
      assert unboxed(fn -> Repo.get(Cart, cart.uuid) end) != nil
    end
  end

  test "the same cart, left alone while the prune waits, is deleted" do
    cart = expired_api_cart!()
    holder = hold_cart_row(cart, [])

    pruner = Task.async(fn -> unboxed(fn -> ApiCartPruneWorker.prune() end) end)

    assert Task.yield(pruner, 300) == nil, "the prune did not wait for the cart row"
    release(holder)

    assert {:ok, count} = Task.await(pruner, 10_000)
    assert count >= 1
    assert unboxed(fn -> Repo.get(Cart, cart.uuid) end) == nil
  end

  # --- helpers ------------------------------------------------------------------

  defp expired_api_cart! do
    session_id = "api:prune-race-" <> Integer.to_string(System.unique_integer([:positive]))
    cart = unboxed(fn -> elem(PhoenixKitEcommerce.create_cart(session_id: session_id), 1) end)

    # Registered before any further write, so a raise below cannot leak the cart.
    on_exit(fn ->
      unboxed(fn -> Repo.delete_all(from(c in Cart, where: c.uuid == ^cart.uuid)) end)
    end)

    unboxed(fn ->
      Repo.update_all(from(c in Cart, where: c.uuid == ^cart.uuid),
        set: [status: "abandoned", updated_at: days_ago(40)]
      )
    end)

    cart
  end

  # A transaction on its own connection that locks the cart row, applies `set`
  # (nothing for `[]`) and commits when `release/1` says so. Returns once the lock
  # is held.
  defp hold_cart_row(cart, set) do
    test = self()

    task = Task.async(fn -> unboxed(fn -> Repo.transaction(hold(cart, set, test)) end) end)

    assert_receive :holding, 5_000
    task
  end

  defp hold(cart, set, test) do
    fn ->
      Repo.one(from(c in Cart, where: c.uuid == ^cart.uuid, lock: "FOR UPDATE"))
      send(test, :holding)

      receive do
        :release -> change(cart, set)
      end
    end
  end

  defp change(_cart, []), do: :ok

  defp change(cart, set),
    do: Repo.update_all(from(c in Cart, where: c.uuid == ^cart.uuid), set: set)

  defp release(%Task{pid: pid} = task) do
    send(pid, :release)
    assert {:ok, _} = Task.await(task, 10_000)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
