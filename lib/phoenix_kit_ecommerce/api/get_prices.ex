defmodule PhoenixKitEcommerce.API.GetPrices do
  @moduledoc """
  `ecommerce.get_prices`: prices and visibility of products by reference.
  Read only.

  Answers, per product: `price` and `compare_at` as money objects in the
  product's currency, the `price_modifiers` (option => value => amount, the
  shape `ecommerce.set_prices` takes back), `visibility`, `made_to_order`,
  the catalogue `item_status`, and `shop_status_visible`, which is the
  storefront's own verdict on the product's own `status` and `shop_status`
  (`View.product_status/2`). It does not look at the product's category or
  catalogue, which the storefront also checks (a product in a `hidden`
  category is not shown whatever this says). A product that was
  never linked to Shopify answers like any other: nothing here reads the
  `shopify` sub-map.
  """

  import PhoenixKitEcommerce.API.PlanSupport, only: [ecommerce: 1]

  alias PhoenixKitEcommerce.API.{AvailabilityPlan, Gate, Money, PricePlan, Refs}
  alias PhoenixKitEcommerce.ProductSource.Catalogue.View

  @doc "Handler of the tool."
  @spec run(map(), map()) :: {:ok, map()} | Gate.refusal()
  def run(input, _ctx) do
    with {:ok, catalogue_uuid} <- Gate.check(input) do
      refs = input["refs"]
      base = base_currency()

      results =
        refs
        |> Refs.resolve(catalogue_uuid)
        |> Enum.zip(refs)
        |> Enum.map(fn
          {{:ok, item}, ref} -> found(item, ref, base)
          {{:error, error}, ref} -> %{"ref" => ref, "error" => error}
        end)

      {:ok,
       %{
         "results" => results,
         "summary" => %{
           "found" => Enum.count(results, &Map.has_key?(&1, "id")),
           "error" => Enum.count(results, &Map.has_key?(&1, "error"))
         }
       }}
    end
  end

  defp found(item, ref, base) do
    current = PricePlan.current(item)
    availability = AvailabilityPlan.current(item)
    ecommerce = ecommerce(item)
    currency = ecommerce["currency"] || base

    %{
      "ref" => ref,
      "id" => item.uuid,
      "currency" => currency,
      "price" => priced(current.price, currency),
      "compare_at" => priced(current.compare_at, currency),
      "price_modifiers" => modifiers(current.price_modifiers),
      "visibility" => availability.visibility,
      "made_to_order" => availability.made_to_order,
      "item_status" => item.status,
      "shop_status_visible" => View.product_status(item, ecommerce) == "active"
    }
  end

  # An amount without a currency is not a price a client can use: it is
  # answered as no price rather than as money in no currency.
  defp priced(_amount, nil), do: nil
  defp priced(amount, currency), do: Money.money(amount, currency)

  # Amounts as decimal strings, whatever was stored (a host migration may have
  # stored numbers); a leaf that is not a number is shown as it is.
  defp modifiers(modifiers) do
    Map.new(modifiers, fn
      {option, %{} = values} ->
        {option, Map.new(values, fn {value, leaf} -> {value, show(leaf)} end)}

      {option, other} ->
        {option, other}
    end)
  end

  defp show(leaf) do
    case Money.to_decimal(leaf) do
      %Decimal{} = decimal -> Money.format(decimal)
      nil -> leaf
    end
  end

  defp base_currency do
    case PhoenixKitEcommerce.get_base_currency() do
      %{code: code} when is_binary(code) -> code
      _ -> nil
    end
  end
end
