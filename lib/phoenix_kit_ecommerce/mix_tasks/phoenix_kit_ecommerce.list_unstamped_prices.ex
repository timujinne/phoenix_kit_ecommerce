defmodule Mix.Tasks.PhoenixKitEcommerce.ListUnstampedPrices do
  # Ignore Mix.Task behaviour callback info (unavailable in PLT)
  @dialyzer :no_undefined_callbacks

  @moduledoc """
  Lists the shop catalogue's items that carry a price but no currency
  stamp (`data["ecommerce"]["currency"]`).

  A Shopify sync run while the shop had no base currency wrote amounts
  with no currency to mean. The storefront reads such a price as being in
  whatever the base currency is now, which is only right if that is what
  the amounts were entered in.

  ## Usage

      mix phoenix_kit_ecommerce.list_unstamped_prices

  Read-only: it prints one line per item and writes nothing. Stamping is a
  decision for a person who has checked the listed amounts against their
  source.
  """

  use Mix.Task

  alias PhoenixKitEcommerce.ProductSource.Catalogue.Query

  @compile {:no_warn_undefined, Query}

  @shortdoc "List catalogue items with a price but no currency stamp (read-only)"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    if Code.ensure_loaded?(PhoenixKitCatalogue.Catalogue) do
      items = Query.list_priced_items_without_currency()

      Enum.each(items, fn item ->
        Mix.shell().info(
          "#{item.uuid}  #{item.status}  base_price=#{item.base_price || "-"}  " <>
            "handle=#{item.shopify_handle || "-"}  #{item.name}"
        )
      end)

      Mix.shell().info("#{length(items)} priced item(s) without a currency stamp")
    else
      Mix.shell().info("phoenix_kit_catalogue is not installed: nothing to list")
    end
  end
end
