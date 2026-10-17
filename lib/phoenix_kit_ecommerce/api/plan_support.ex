defmodule PhoenixKitEcommerce.API.PlanSupport do
  @moduledoc """
  The few helpers the row planners and `ecommerce.get_prices` share: the
  `data["ecommerce"]` namespace of an item, a conditional map put, and the
  error map of a planned row.
  """

  alias PhoenixKitEcommerce.Catalogue.ItemCommerce

  @doc "The `data[\"ecommerce\"]` map of an item; `%{}` when there is none."
  @spec ecommerce(map()) :: map()
  def ecommerce(item) do
    case item.data do
      %{"ecommerce" => %{} = ecommerce} -> ecommerce
      _ -> %{}
    end
  end

  @doc """
  Whether the next Shopify sync can overwrite what a tool writes to `item`:
  the sync is on (`shopify_enabled?`) and the item is linked to Shopify.
  """
  @spec shopify_sync_may_overwrite?(map(), boolean()) :: boolean()
  def shopify_sync_may_overwrite?(item, shopify_enabled?),
    do: shopify_enabled? and ItemCommerce.shopify_linked?(ecommerce(item))

  @doc "`Map.put/3` when `condition` is true, else the map unchanged."
  @spec put_if(map(), boolean(), term(), term()) :: map()
  def put_if(map, true, key, value), do: Map.put(map, key, value)
  def put_if(map, false, _key, _value), do: map

  @doc "The error of one field of a row; `allowed` names the accepted values, if any."
  @spec error(String.t(), String.t(), [String.t()] | nil) :: %{
          path: String.t(),
          message: String.t(),
          allowed: [String.t()] | nil
        }
  def error(path, message, allowed \\ nil), do: %{path: path, message: message, allowed: allowed}
end
