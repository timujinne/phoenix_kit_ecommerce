defmodule PhoenixKitEcommerce.API.GetOrders do
  @moduledoc """
  `ecommerce.get_orders`: orders by reference (`{"id"}` or `{"number"}`), up to
  100. One result per reference, in the order given: the order, or the error of
  that reference (`not_found`, `validation_failed`); a bad reference does not
  stop the others. Read only.

  Personal data of the buyer is part of an answer only when the key also holds
  `ecommerce.orders:customer`.
  """

  alias PhoenixKitEcommerce.API.{OrderExport, OrderRefs, OrderTools}

  @doc "Handler of the tool."
  @spec run(map(), map()) :: {:ok, map()}
  def run(input, ctx) do
    answers = OrderRefs.resolve(input["refs"])
    orders = for {:ok, order} <- answers, do: order

    serialized =
      orders
      |> OrderExport.serialize_many(
        include: OrderTools.include(input["include"]),
        contacts: OrderTools.contacts?(ctx)
      )
      |> Map.new(&{&1["id"], &1})

    results =
      input["refs"]
      |> Enum.zip(answers)
      |> Enum.map(fn
        {ref, {:ok, order}} -> %{"ref" => ref, "order" => Map.fetch!(serialized, order.uuid)}
        {ref, {:error, error}} -> %{"ref" => ref, "error" => error}
      end)

    {:ok,
     %{
       "results" => results,
       "summary" => %{
         "found" => Enum.count(results, &Map.has_key?(&1, "order")),
         "error" => Enum.count(results, &Map.has_key?(&1, "error"))
       }
     }}
  end
end
