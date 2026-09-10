defmodule PhoenixKitEcommerce.Catalogue.Extension do
  @moduledoc """
  Structurally implements `PhoenixKitCatalogue.Extension` — the catalogue
  item/category form "extension slot" (spec §2 principle 8). `phoenix_kit_catalogue`
  is an optional dependency, so this module does NOT declare `@behaviour
  PhoenixKitCatalogue.Extension`; that would force it to be loaded at
  compile time. Discovery is duck-typed, the same pattern as
  `PhoenixKitEcommerce.AITranslatable` / `ai_translatables/0`: catalogue
  finds this module via `PhoenixKitEcommerce.catalogue_extensions/0` and is
  responsible for checking it is actually usable before calling it.
  """

  alias PhoenixKitEcommerce.Catalogue.CategoryCommerce
  alias PhoenixKitEcommerce.Catalogue.ItemCommerce
  alias PhoenixKitEcommerce.Catalogue.ShopSections
  alias PhoenixKitEcommerce.Catalogue.ShopStatusColumn

  @doc "Namespace under `data` this extension owns."
  @spec key() :: String.t()
  def key, do: "ecommerce"

  @doc "Whether the Shop section should be shown / absorbed."
  @spec enabled?() :: boolean()
  def enabled?, do: PhoenixKitEcommerce.enabled?()

  @doc "Renders the Shop section inside the catalogue item form."
  @spec item_section(map()) :: Phoenix.LiveView.Rendered.t()
  def item_section(assigns), do: ShopSections.item(assigns)

  @doc "Renders the Shop section inside the catalogue category form."
  @spec category_section(map()) :: Phoenix.LiveView.Rendered.t()
  def category_section(assigns), do: ShopSections.category(assigns)

  @doc "Validates and shapes `item[\"ecommerce\"]` — see `ItemCommerce.cast/2`."
  @spec cast_item(map(), map()) :: {:ok, map()} | {:error, [{atom(), String.t()}]}
  def cast_item(params, current), do: ItemCommerce.cast(params, current)

  @doc "Validates and shapes `category[\"ecommerce\"]` — see `CategoryCommerce.cast/2`."
  @spec cast_category(map(), map()) :: {:ok, map()} | {:error, [{atom(), String.t()}]}
  def cast_category(params, current), do: CategoryCommerce.cast(params, current)

  @doc """
  Extra column for the catalogue item table's Columns modal — surfaces
  the shop's own `shop_status` next to the catalogue's `status` so the
  two stop contradicting each other invisibly. See `ShopStatusColumn`.
  """
  @spec item_columns() :: [map()]
  def item_columns, do: ShopStatusColumn.item_columns()

  @doc "Same as `item_columns/0`, for the catalogue category table — categories carry their own `shop_status` too (`CategoryCommerce`)."
  @spec category_columns() :: [map()]
  def category_columns, do: ShopStatusColumn.category_columns()
end
