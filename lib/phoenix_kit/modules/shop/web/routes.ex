defmodule PhoenixKit.Modules.Shop.Web.Routes do
  @moduledoc """
  Shop module routes.

  Provides route definitions for e-commerce functionality including
  admin, public catalog, and user dashboard routes.
  """

  @doc """
  Returns quoted `live` route declarations for non-localized shop public pages.

  These declarations are included directly inside the unified `:phoenix_kit_public`
  live_session defined in `phoenix_kit_public_routes/1` in `PhoenixKitWeb.Integration`.
  Routes use full module names (alias: false) and non-localized route aliases.
  """
  def public_live_routes do
    quote do
      live "/shop", PhoenixKit.Modules.Shop.Web.ShopCatalog, :index, as: :shop_catalog

      live "/shop/category/:slug", PhoenixKit.Modules.Shop.Web.CatalogCategory, :show,
        as: :shop_category

      live "/shop/product/:slug", PhoenixKit.Modules.Shop.Web.CatalogProduct, :show,
        as: :shop_product

      live "/cart", PhoenixKit.Modules.Shop.Web.CartPage, :index, as: :shop_cart
      live "/checkout", PhoenixKit.Modules.Shop.Web.CheckoutPage, :index, as: :shop_checkout

      live "/checkout/complete/:uuid", PhoenixKit.Modules.Shop.Web.CheckoutComplete, :show,
        as: :shop_checkout_complete
    end
  end

  @doc """
  Returns quoted `live` route declarations for localized shop public pages.

  These declarations are included directly inside the unified `:phoenix_kit_public_locale`
  live_session defined in `phoenix_kit_public_routes/1` in `PhoenixKitWeb.Integration`.
  Routes use full module names (alias: false) and localized route aliases.
  """
  def public_live_locale_routes do
    quote do
      live "/shop", PhoenixKit.Modules.Shop.Web.ShopCatalog, :index, as: :shop_catalog_localized

      live "/shop/category/:slug", PhoenixKit.Modules.Shop.Web.CatalogCategory, :show,
        as: :shop_category_localized

      live "/shop/product/:slug", PhoenixKit.Modules.Shop.Web.CatalogProduct, :show,
        as: :shop_product_localized

      live "/cart", PhoenixKit.Modules.Shop.Web.CartPage, :index, as: :shop_cart_localized

      live "/checkout", PhoenixKit.Modules.Shop.Web.CheckoutPage, :index,
        as: :shop_checkout_localized

      live "/checkout/complete/:uuid", PhoenixKit.Modules.Shop.Web.CheckoutComplete, :show,
        as: :shop_checkout_complete_localized
    end
  end

  @doc """
  Returns quoted code for shop public routes.

  Shop public routes are now included in the unified `:phoenix_kit_public` live_session
  via `phoenix_kit_public_routes/1` in `PhoenixKitWeb.Integration`. This function
  returns an empty block for backward compatibility.
  """
  def generate_public_routes(_url_prefix) do
    quote do
    end
  end

  @doc """
  Returns quoted `live` route declarations for shop admin pages (non-localized).
  Called via safe_route_call from PhoenixKitWeb.Integration.
  """
  def admin_routes do
    quote do
      live "/admin/shop", PhoenixKit.Modules.Shop.Web.Dashboard, :index, as: :shop_dashboard

      live "/admin/shop/products", PhoenixKit.Modules.Shop.Web.Products, :index,
        as: :shop_products

      live "/admin/shop/products/new", PhoenixKit.Modules.Shop.Web.ProductForm, :new,
        as: :shop_product_new

      live "/admin/shop/products/:id", PhoenixKit.Modules.Shop.Web.ProductDetail, :show,
        as: :shop_product_detail

      live "/admin/shop/products/:id/edit", PhoenixKit.Modules.Shop.Web.ProductForm, :edit,
        as: :shop_product_edit

      live "/admin/shop/categories", PhoenixKit.Modules.Shop.Web.Categories, :index,
        as: :shop_categories

      live "/admin/shop/categories/new", PhoenixKit.Modules.Shop.Web.CategoryForm, :new,
        as: :shop_category_new

      live "/admin/shop/categories/:id/edit", PhoenixKit.Modules.Shop.Web.CategoryForm, :edit,
        as: :shop_category_edit

      live "/admin/shop/shipping", PhoenixKit.Modules.Shop.Web.ShippingMethods, :index,
        as: :shop_shipping_methods

      live "/admin/shop/shipping/new", PhoenixKit.Modules.Shop.Web.ShippingMethodForm, :new,
        as: :shop_shipping_new

      live "/admin/shop/shipping/:id/edit", PhoenixKit.Modules.Shop.Web.ShippingMethodForm, :edit,
        as: :shop_shipping_edit

      live "/admin/shop/carts", PhoenixKit.Modules.Shop.Web.Carts, :index, as: :shop_carts

      live "/admin/shop/settings", PhoenixKit.Modules.Shop.Web.Settings, :index,
        as: :shop_settings

      live "/admin/shop/settings/options", PhoenixKit.Modules.Shop.Web.OptionsSettings, :index,
        as: :shop_options_settings

      live "/admin/shop/settings/import-configs",
           PhoenixKit.Modules.Shop.Web.ImportConfigs,
           :index,
           as: :shop_import_configs

      live "/admin/shop/imports", PhoenixKit.Modules.Shop.Web.Imports, :index, as: :shop_imports

      live "/admin/shop/imports/:uuid", PhoenixKit.Modules.Shop.Web.ImportShow, :show,
        as: :shop_import_show

      live "/admin/shop/test", PhoenixKit.Modules.Shop.Web.TestShop, :index, as: :shop_test
    end
  end

  @doc """
  Returns quoted `live` route declarations for shop admin pages (localized).
  """
  def admin_locale_routes do
    admin_routes()
  end
end
