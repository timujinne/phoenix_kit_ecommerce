defmodule PhoenixKitEcommerce.ProductSource do
  @moduledoc """
  Behaviour for the storefront's product/category read path.

  Two adapters implement it: `PhoenixKitEcommerce.ProductSource.Legacy`
  (today's `phoenix_kit_shop_products`/`phoenix_kit_shop_categories`
  tables, unchanged) and, once `phoenix_kit_catalogue` is present,
  `PhoenixKitEcommerce.ProductSource.Catalogue` (reads catalogue items
  and returns hand-built `%Product{}`/`%Category{}` view-structs so the
  facade, guards, `CartItem`, `Options` and sitemap need no changes).

  `current/0` picks the adapter at runtime; `PhoenixKitEcommerce`'s
  public read functions delegate to it so callers never choose an
  adapter themselves.
  """

  alias PhoenixKitEcommerce.Category
  alias PhoenixKitEcommerce.Product

  @callback list_products(keyword()) :: [Product.t()]
  @callback list_products_with_count(keyword()) :: {[Product.t()], non_neg_integer()}
  @callback list_products_by_ids([String.t()]) :: [Product.t()]
  @callback get_product(String.t(), keyword()) :: Product.t() | nil
  @callback get_product_by_slug_localized(String.t(), String.t(), keyword()) ::
              {:ok, Product.t()} | {:error, :not_found}
  @callback get_product_by_any_slug(String.t(), keyword()) ::
              {:ok, Product.t(), String.t()} | {:error, :not_found}
  @callback list_categories(keyword()) :: [Category.t()]
  @callback get_category(String.t(), keyword()) :: Category.t() | nil
  @callback get_category_by_slug_localized(String.t(), String.t(), keyword()) ::
              {:ok, Category.t()} | {:error, :not_found}
  @callback get_category_by_any_slug(String.t(), keyword()) ::
              {:ok, Category.t(), String.t()} | {:error, :not_found}
  @callback product_counts_by_category() :: %{String.t() => non_neg_integer()}
  @callback aggregate_filter_values(keyword()) :: map()
  @callback get_price_range_for(keyword()) :: {Decimal.t() | nil, Decimal.t() | nil}

  @legacy_module PhoenixKitEcommerce.ProductSource.Legacy
  @catalogue_module PhoenixKitEcommerce.ProductSource.Catalogue

  @doc """
  Returns the adapter module for the currently active product source.

  `Catalogue` only when `phoenix_kit_catalogue` is loaded AND the
  `shop_product_source` config key (`phoenix_kit_shop_config`) is
  `"catalogue"`; `Legacy` otherwise — including when the key is absent
  or the catalogue module isn't loaded, so a host without the optional
  `phoenix_kit_catalogue` dependency always gets `Legacy` regardless of
  the stored key.

  Reads the config on every call rather than caching it here:
  `PhoenixKitEcommerce.get_config/1` is a plain `repo().get/2` against
  `phoenix_kit_shop_config` (no ETS/settings-cache layer sits in front
  of it today), so this is a real extra query per call — accepted so
  that the switch takes effect without a restart, rather than adding
  process state here that could make it lag behind the stored value.
  """
  def current do
    if Code.ensure_loaded?(PhoenixKitCatalogue) and
         PhoenixKitEcommerce.get_config("shop_product_source") == "catalogue" do
      @catalogue_module
    else
      @legacy_module
    end
  end
end
