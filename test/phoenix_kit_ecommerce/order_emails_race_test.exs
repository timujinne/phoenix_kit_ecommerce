defmodule PhoenixKitEcommerce.OrderEmailsRaceTest do
  @moduledoc """
  Overlapping deliveries of one email send it once, on a committed order. Each
  caller uses a real connection: a shared sandbox transaction cannot test the
  row lock a claim is taken under.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitBilling.Order
  alias PhoenixKitEcommerce.OrderEmails
  alias PhoenixKitEcommerce.Test.Repo

  @moduletag :integration

  test "parallel deliveries of the same snapshot send one email" do
    order =
      unboxed(fn ->
        Repo.insert!(%Order{
          order_number: "EMAIL-RACE-#{System.unique_integer([:positive])}",
          status: "confirmed",
          currency: "USD",
          subtotal: Decimal.new("10"),
          total: Decimal.new("10"),
          billing_snapshot: %{"email" => "email-race@example.com"},
          metadata: %{"source" => "shop_checkout", "checkout_language" => "en"}
        })
      end)

    on_exit(fn ->
      unboxed(fn -> Repo.delete_all(from(o in Order, where: o.uuid == ^order.uuid)) end)
    end)

    parent = self()

    tasks =
      for _caller <- 1..4 do
        Task.async(fn ->
          unboxed(fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> OrderEmails.deliver("buyer_placed", order)
            end
          end)
        end)
      end

    for _task <- tasks, do: assert_receive({:ready, _pid}, 5_000)
    Enum.each(tasks, &send(&1.pid, :go))

    results = Task.await_many(tasks, 30_000)

    # One caller sends. Another either finds the claim and is told to come back,
    # or arrives after the mark and has nothing to do.
    assert :ok in results

    assert Enum.all?(
             results,
             &match?(result when result == :ok or elem(result, 0) == :snooze, &1)
           )

    assert_received {:email, %{to: [{"", "email-race@example.com"}]}}
    refute_received {:email, _}

    assert :ok = unboxed(fn -> OrderEmails.deliver("buyer_placed", order) end)
    refute_received {:email, _}

    assert unboxed(fn -> Repo.get!(Order, order.uuid).metadata["_shop_emails"] end) ==
             %{"buyer_placed" => true}
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
