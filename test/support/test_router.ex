defmodule PhoenixKitEcommerce.Test.Router do
  @moduledoc """
  Minimal Router used by the LiveView test suite. Routes match the URLs
  produced by the ecommerce module's admin tabs so `live/2` calls in tests
  work with exactly the same URLs the LiveViews push themselves to.

  `PhoenixKit.Utils.Routes.path/1` defaults to no URL prefix when the
  phoenix_kit_settings table is unavailable, and admin paths always get
  the default locale ("en") prefix — so our base becomes
  `/en/admin/shop` for the shop admin tabs.

  Storefront pages (shop_catalog / checkout / cart_page / product_detail)
  are intentionally omitted here — this harness covers the admin LVs only.

  The ecommerce LV modules have no `Live` suffix, so each `live/2` passes
  an explicit `as:` to avoid colliding auto-generated route helper names.
  """

  use Phoenix.Router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, {PhoenixKitEcommerce.Test.Layouts, :root})
    plug(:protect_from_forgery)
  end

  scope "/en/admin/shop", PhoenixKitEcommerce.Web do
    pipe_through(:browser)

    live_session :shop_test,
      layout: {PhoenixKitEcommerce.Test.Layouts, :app},
      on_mount: {PhoenixKitEcommerce.Test.Hooks, :assign_scope} do
      # Dashboard / index
      live("/", Dashboard, :index, as: :shop_dashboard)

      # Products
      live("/products", Products, :index, as: :shop_products)
      live("/products/new", ProductForm, :new, as: :shop_product_new)
      live("/products/:id", ProductDetail, :show, as: :shop_product_detail)
      live("/products/:id/edit", ProductForm, :edit, as: :shop_product_edit)

      # Categories
      live("/categories", Categories, :index, as: :shop_categories)
      live("/categories/new", CategoryForm, :new, as: :shop_category_new)
      live("/categories/:id/edit", CategoryForm, :edit, as: :shop_category_edit)

      # Shipping methods
      live("/shipping", ShippingMethods, :index, as: :shop_shipping_methods)
      live("/shipping/new", ShippingMethodForm, :new, as: :shop_shipping_new)
      live("/shipping/:id/edit", ShippingMethodForm, :edit, as: :shop_shipping_edit)

      # Carts
      live("/carts", Carts, :index, as: :shop_carts)

      # Settings
      live("/settings", Settings, :index, as: :shop_settings)
      live("/settings/options", OptionsSettings, :index, as: :shop_options_settings)
      live("/settings/import-configs", ImportConfigs, :index, as: :shop_import_configs)

      # Imports
      live("/imports", Imports, :index, as: :shop_imports)
      live("/imports/:uuid", ImportShow, :show, as: :shop_import_show)
    end
  end
end
