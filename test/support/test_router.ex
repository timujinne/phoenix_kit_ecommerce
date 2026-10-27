defmodule PhoenixKitEcommerce.Test.Router do
  @moduledoc """
  Minimal Router used by the LiveView test suite. Routes match the URLs
  produced by the ecommerce module's admin tabs so `live/2` calls in tests
  work with exactly the same URLs the LiveViews push themselves to.

  `PhoenixKit.Utils.Routes.path/1` defaults to no URL prefix when the
  phoenix_kit_settings table is unavailable, and admin paths always get
  the default locale ("en") prefix — so our base becomes
  `/en/admin/shop` for the shop admin tabs.

  Most storefront pages (product_detail) are intentionally omitted here —
  the harness covers the admin LVs plus the public catalog page (`/shop`),
  `/cart` (needed by the cart-page shipping-modes test), `/checkout`
  (needed by the checkout-started signal test), and `/checkout/complete/:uuid`
  (needed by the completion-page copy test), which the storefront-search
  / checkout-signal / cart-page / checkout-complete tests drive.

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

  # The claim route, the way `Web.Routes.generate/1` emits it in a host: the
  # browser pipeline plus the shop-session plug. `assign_test_user/2` stands in
  # for core's auto-setup pipeline (it assigns the logged-in user).
  pipeline :claim_session do
    plug(PhoenixKitEcommerce.Web.Plugs.ShopSession)
    plug(:assign_test_user)
  end

  def assign_test_user(conn, _opts) do
    case Plug.Conn.get_session(conn, "phoenix_kit_test_scope") do
      %{user: user} -> Plug.Conn.assign(conn, :phoenix_kit_current_user, user)
      _ -> conn
    end
  end

  scope "/" do
    pipe_through([:browser, :claim_session])

    get("/checkout/claim/:token", PhoenixKitEcommerce.Web.ClaimController, :show)
    post("/checkout/claim/:token", PhoenixKitEcommerce.Web.ClaimController, :create)
  end

  scope "/", PhoenixKitEcommerce.Web do
    pipe_through(:browser)

    live_session :storefront_test,
      layout: {PhoenixKitEcommerce.Test.Layouts, :app},
      on_mount: [
        {PhoenixKitEcommerce.Test.Hooks, :assign_scope},
        {PhoenixKitEcommerce.Test.Hooks, :assign_locale},
        {PhoenixKitEcommerce.Test.Hooks, :assign_currency}
      ] do
      live("/shop", ShopCatalog, :index, as: :shop_catalog)
      live("/shop/category/:slug", CatalogCategory, :show, as: :shop_category)
      live("/shop/product/:slug", CatalogProduct, :show, as: :shop_product)
      live("/cart", CartPage, :index, as: :shop_cart)
      live("/checkout", CheckoutPage, :index, as: :shop_checkout)

      live("/checkout/complete/:uuid", CheckoutComplete, :show, as: :shop_checkout_complete)
      live("/dashboard/orders", UserOrders, :index, as: :shop_user_orders)
      live("/dashboard/orders/:uuid", UserOrderDetails, :show, as: :shop_user_order_details)

      # `Shop.catalog_url/1` resolves to the locale-prefixed form in the
      # test env, so patches from filter events land here.
      live("/:locale/shop", ShopCatalog, :index, as: :shop_catalog_localized)

      live("/:locale/shop/category/:slug", CatalogCategory, :show, as: :shop_category_localized)
      live("/:locale/shop/product/:slug", CatalogProduct, :show, as: :shop_product_localized)
      live("/:locale/cart", CartPage, :index, as: :shop_cart_localized)
      live("/:locale/checkout", CheckoutPage, :index, as: :shop_checkout_localized)
    end
  end

  # Both URL shapes of the admin screens live in ONE live_session: a
  # `push_patch` from `/admin/shop/...` to `/admin/shop/...?tab=x` must stay
  # inside the session it started in, and the two shapes are what `Routes.path/2`
  # emits for a single-language site (no locale segment, a core with the URL
  # language policy) and for a multi-language one (`/en` segment, an older core).
  scope "/", PhoenixKitEcommerce.Web do
    pipe_through(:browser)

    live_session :shop_test,
      layout: {PhoenixKitEcommerce.Test.Layouts, :app},
      on_mount: {PhoenixKitEcommerce.Test.Hooks, :assign_scope} do
      scope "/en/admin/shop" do
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

        # Shopify Sync
        live("/shopify-sync", ShopifySync, :index, as: :shop_shopify_sync)

        # Translations
        live("/translations", Translations, :index, as: :shop_translations)

        # Test shop (diagnostics)
        live("/test", TestShop, :index, as: :shop_test)
      end

      scope "/admin/shop" do
        # The same screens without the locale segment: what `Routes.path/2`
        # emits on a single-language site on a core with the URL language
        # policy. Every admin LiveView patches/navigates to such a path, and
        # `single_language_links_test.exs` mounts the main ones.
        live("/", Dashboard, :index, as: :shop_dashboard_prefixless)

        # Products
        live("/products", Products, :index, as: :shop_products_prefixless)
        live("/products/new", ProductForm, :new, as: :shop_product_new_prefixless)
        live("/products/:id", ProductDetail, :show, as: :shop_product_detail_prefixless)
        live("/products/:id/edit", ProductForm, :edit, as: :shop_product_edit_prefixless)

        # Categories
        live("/categories", Categories, :index, as: :shop_categories_prefixless)
        live("/categories/new", CategoryForm, :new, as: :shop_category_new_prefixless)
        live("/categories/:id/edit", CategoryForm, :edit, as: :shop_category_edit_prefixless)

        # Shipping methods
        live("/shipping", ShippingMethods, :index, as: :shop_shipping_methods_prefixless)
        live("/shipping/new", ShippingMethodForm, :new, as: :shop_shipping_new_prefixless)
        live("/shipping/:id/edit", ShippingMethodForm, :edit, as: :shop_shipping_edit_prefixless)

        # Carts
        live("/carts", Carts, :index, as: :shop_carts_prefixless)

        # Settings
        live("/settings", Settings, :index, as: :shop_settings_prefixless)
        live("/settings/options", OptionsSettings, :index, as: :shop_options_settings_prefixless)

        live("/settings/import-configs", ImportConfigs, :index,
          as: :shop_import_configs_prefixless
        )

        # Imports
        live("/imports", Imports, :index, as: :shop_imports_prefixless)
        live("/imports/:uuid", ImportShow, :show, as: :shop_import_show_prefixless)

        # Shopify Sync
        live("/shopify-sync", ShopifySync, :index, as: :shop_shopify_sync_prefixless)

        # Translations
        live("/translations", Translations, :index, as: :shop_translations_prefixless)
        live("/test", TestShop, :index, as: :shop_test_prefixless)
      end
    end
  end
end
