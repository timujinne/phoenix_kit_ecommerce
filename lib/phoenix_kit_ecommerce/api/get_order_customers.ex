defmodule PhoenixKitEcommerce.API.GetOrderCustomers do
  @moduledoc """
  `ecommerce.get_order_customers`: the buyer of each order, with contacts
  (name, phone, email, company, tax id, address), by reference. Read only.

  It exists because a scope is granted through the tools that declare it:
  `ecommerce.orders:customer`, which lets the other order tools include the
  contacts, is held by the key of this tool.
  """

  alias PhoenixKitEcommerce.API.{OrderExport, OrderRefs}

  @doc "Handler of the tool."
  @spec run(map(), map()) :: {:ok, map()}
  def run(input, _ctx) do
    answers = OrderRefs.resolve(input["refs"])

    customers =
      for {:ok, order} <- answers do
        order
      end
      |> OrderExport.serialize_many(include: [:customer], contacts: true)
      |> Map.new(&{&1["id"], &1["customer"]})

    results =
      input["refs"]
      |> Enum.zip(answers)
      |> Enum.map(fn
        {ref, {:ok, order}} ->
          %{
            "ref" => ref,
            "id" => order.uuid,
            "number" => order.order_number,
            "customer" => Map.fetch!(customers, order.uuid)
          }

        {ref, {:error, error}} ->
          %{"ref" => ref, "error" => error}
      end)

    {:ok,
     %{
       "results" => results,
       "summary" => %{
         "found" => Enum.count(results, &Map.has_key?(&1, "customer")),
         "error" => Enum.count(results, &Map.has_key?(&1, "error"))
       }
     }}
  end
end
