defmodule PhoenixKitEcommerce.Web.Routes do
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
      live "/shop", PhoenixKitEcommerce.Web.ShopCatalog, :index, as: :shop_catalog

      live "/shop/category/:slug", PhoenixKitEcommerce.Web.CatalogCategory, :show,
        as: :shop_category

      live "/shop/product/:slug", PhoenixKitEcommerce.Web.CatalogProduct, :show,
        as: :shop_product

      live "/cart", PhoenixKitEcommerce.Web.CartPage, :index, as: :shop_cart
      live "/checkout", PhoenixKitEcommerce.Web.CheckoutPage, :index, as: :shop_checkout

      live "/checkout/complete/:uuid", PhoenixKitEcommerce.Web.CheckoutComplete, :show,
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
      live "/shop", PhoenixKitEcommerce.Web.ShopCatalog, :index, as: :shop_catalog_localized

      live "/shop/category/:slug", PhoenixKitEcommerce.Web.CatalogCategory, :show,
        as: :shop_category_localized

      live "/shop/product/:slug", PhoenixKitEcommerce.Web.CatalogProduct, :show,
        as: :shop_product_localized

      live "/cart", PhoenixKitEcommerce.Web.CartPage, :index, as: :shop_cart_localized

      live "/checkout", PhoenixKitEcommerce.Web.CheckoutPage, :index,
        as: :shop_checkout_localized

      live "/checkout/complete/:uuid", PhoenixKitEcommerce.Web.CheckoutComplete, :show,
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
      live "/admin/shop", PhoenixKitEcommerce.Web.Dashboard, :index, as: :shop_dashboard

      live "/admin/shop/products", PhoenixKitEcommerce.Web.Products, :index,
        as: :shop_products

      live "/admin/shop/products/new", PhoenixKitEcommerce.Web.ProductForm, :new,
        as: :shop_product_new

      live "/admin/shop/products/:id", PhoenixKitEcommerce.Web.ProductDetail, :show,
        as: :shop_product_detail

      live "/admin/shop/products/:id/edit", PhoenixKitEcommerce.Web.ProductForm, :edit,
        as: :shop_product_edit

      live "/admin/shop/categories", PhoenixKitEcommerce.Web.Categories, :index,
        as: :shop_categories

      live "/admin/shop/categories/new", PhoenixKitEcommerce.Web.CategoryForm, :new,
        as: :shop_category_new

      live "/admin/shop/categories/:id/edit", PhoenixKitEcommerce.Web.CategoryForm, :edit,
        as: :shop_category_edit

      live "/admin/shop/shipping", PhoenixKitEcommerce.Web.ShippingMethods, :index,
        as: :shop_shipping_methods

      live "/admin/shop/shipping/new", PhoenixKitEcommerce.Web.ShippingMethodForm, :new,
        as: :shop_shipping_new

      live "/admin/shop/shipping/:id/edit", PhoenixKitEcommerce.Web.ShippingMethodForm, :edit,
        as: :shop_shipping_edit

      live "/admin/shop/carts", PhoenixKitEcommerce.Web.Carts, :index, as: :shop_carts

      live "/admin/shop/settings", PhoenixKitEcommerce.Web.Settings, :index,
        as: :shop_settings

      live "/admin/shop/settings/options", PhoenixKitEcommerce.Web.OptionsSettings, :index,
        as: :shop_options_settings

      live "/admin/shop/settings/import-configs",
           PhoenixKitEcommerce.Web.ImportConfigs,
           :index,
           as: :shop_import_configs

      live "/admin/shop/imports", PhoenixKitEcommerce.Web.Imports, :index, as: :shop_imports

      live "/admin/shop/imports/:uuid", PhoenixKitEcommerce.Web.ImportShow, :show,
        as: :shop_import_show

      live "/admin/shop/test", PhoenixKitEcommerce.Web.TestShop, :index, as: :shop_test
    end
  end

  @doc """
  Returns quoted `live` route declarations for shop admin pages (localized).
  """
  def admin_locale_routes do
    admin_routes()
  end
end
