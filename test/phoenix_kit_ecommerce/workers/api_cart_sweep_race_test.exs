defmodule PhoenixKitEcommerce.Workers.ApiCartSweepRaceTest do
  @moduledoc """
  The sweep must not abandon a cart whose checkout link is being issued while
  it runs. The SQL sandbox wraps a test in one transaction, so this runs the
  sweep on a real connection (`unboxed_run`, the way `ClaimsRaceTest` does)
  while a second transaction issues the link and commits: the sweep's UPDATE
  waits for the cart row, then has to decide on the new row version. A lock
  alone leaves the row version as it was, so the sweep would decide on what it
  saw before the link existed.

  `async: false`: it commits to a shared database. The carts are removed on exit.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitEcommerce.API.CartToken
  alias PhoenixKitEcommerce.API.Claims
  alias PhoenixKitEcommerce.Cart
  alias PhoenixKitEcommerce.CartClaim
  alias PhoenixKitEcommerce.Test.Repo
  alias PhoenixKitEcommerce.Workers.ApiCartSweepWorker

  @moduletag :integration

  defp days_ago(days),
    do: DateTime.utc_now() |> DateTime.add(-days * 86_400, :second) |> DateTime.truncate(:second)

  test "a cart whose link is issued while the sweep waits for its row is kept" do
    {cart, hash} = idle_api_cart!()
    issuer = hold_issuing(cart, hash)

    sweeper = Task.async(fn -> unboxed(fn -> ApiCartSweepWorker.sweep() end) end)

    assert Task.yield(sweeper, 300) == nil, "the sweep did not wait for the cart row"
    release(issuer)

    assert {:ok, _count} = Task.await(sweeper, 10_000)
    assert %Cart{status: "active"} = unboxed(fn -> Repo.get(Cart, cart.uuid) end)
  end

  test "the same cart, with no link issued while the sweep waits, is abandoned" do
    {cart, _hash} = idle_api_cart!()
    holder = hold_cart_row(cart)

    sweeper = Task.async(fn -> unboxed(fn -> ApiCartSweepWorker.sweep() end) end)

    assert Task.yield(sweeper, 300) == nil, "the sweep did not wait for the cart row"
    release(holder)

    assert {:ok, count} = Task.await(sweeper, 10_000)
    assert count >= 1
    assert %Cart{status: "abandoned"} = unboxed(fn -> Repo.get(Cart, cart.uuid) end)
  end

  # --- helpers ------------------------------------------------------------------

  defp idle_api_cart! do
    hash =
      CartToken.digest("sweep-race-" <> Integer.to_string(System.unique_integer([:positive])))

    session_id = CartToken.session_id(hash)
    cart = unboxed(fn -> elem(PhoenixKitEcommerce.create_cart(session_id: session_id), 1) end)

    # Registered before any further write, so a raise below cannot leak the cart.
    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(from(k in CartClaim, where: k.cart_uuid == ^cart.uuid))
        Repo.delete_all(from(c in Cart, where: c.uuid == ^cart.uuid))
      end)
    end)

    unboxed(fn ->
      Repo.update_all(from(c in Cart, where: c.uuid == ^cart.uuid),
        set: [updated_at: days_ago(30)]
      )
    end)

    {cart, hash}
  end

  # A transaction on its own connection that issues the cart's link and commits
  # when `release/1` says so. Returns once the link is issued and the cart row
  # is still held.
  defp hold_issuing(cart, hash) do
    hold(fn ->
      {:ok, _issued} = Claims.issue(cart, hash, "en")
    end)
  end

  # The control: the same hold, nothing changed.
  defp hold_cart_row(cart) do
    hold(fn -> Repo.one(from(c in Cart, where: c.uuid == ^cart.uuid, lock: "FOR UPDATE")) end)
  end

  defp hold(work) do
    test = self()
    task = Task.async(fn -> unboxed(fn -> hold_transaction(work, test) end) end)

    assert_receive :holding, 5_000
    task
  end

  defp hold_transaction(work, test),
    do: Repo.transaction(fn -> work_then_wait(work, test) end)

  defp work_then_wait(work, test) do
    work.()
    send(test, :holding)

    receive do
      :release -> :ok
    end
  end

  defp release(%Task{pid: pid} = task) do
    send(pid, :release)
    assert {:ok, _} = Task.await(task, 10_000)
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
