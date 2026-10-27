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

      live "/shop/product/:slug", PhoenixKitEcommerce.Web.CatalogProduct, :show, as: :shop_product

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

      live "/checkout", PhoenixKitEcommerce.Web.CheckoutPage, :index, as: :shop_checkout_localized

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
  Non-LiveView public routes, emitted by core for every module with a
  `route_module/0` (`PhoenixKitWeb.Integration`, before any `/:locale` surface,
  so a locale can never swallow them).

  The checkout claim page of the public cart API:
  `GET /checkout/claim/:token` shows the interstitial and consumes nothing,
  `POST` (with the CSRF token) consumes the claim. **Not locale-prefixed**, so
  one analytics exclusion pattern covers it. The pipelines are the host's
  `:browser` (session, CSRF, flash), core's `:phoenix_kit_auto_setup` (the
  logged-in user) and `:phoenix_kit_shop_session` (the browser's cart id).
  """
  @spec generate(String.t()) :: Macro.t()
  def generate(url_prefix) do
    quote do
      scope unquote(url_prefix) do
        pipe_through([:browser, :phoenix_kit_auto_setup, :phoenix_kit_shop_session])

        get("/checkout/claim/:token", PhoenixKitEcommerce.Web.ClaimController, :show)
        post("/checkout/claim/:token", PhoenixKitEcommerce.Web.ClaimController, :create)
      end
    end
  end

  @doc """
  Returns quoted `live` route declarations for shop admin pages (non-localized).
  Called via safe_route_call from PhoenixKitWeb.Integration.

  Only the pages with no tab of their own are declared here. The list pages
  (products, categories, shipping, carts, imports, Shopify sync,
  translations) and the settings page get their routes from their tab's
  `live_view:` in `admin_tabs/0` / `settings_tabs/0`, which is also what maps
  each to its sub-permission; declaring one here too would give the host two
  routes at the same path.
  """
  def admin_routes do
    quote do
      live "/admin/shop", PhoenixKitEcommerce.Web.Dashboard, :index, as: :shop_dashboard

      live "/admin/shop/products/new", PhoenixKitEcommerce.Web.ProductForm, :new,
        as: :shop_product_new

      live "/admin/shop/products/:id", PhoenixKitEcommerce.Web.ProductDetail, :show,
        as: :shop_product_detail

      live "/admin/shop/products/:id/edit", PhoenixKitEcommerce.Web.ProductForm, :edit,
        as: :shop_product_edit

      live "/admin/shop/categories/new", PhoenixKitEcommerce.Web.CategoryForm, :new,
        as: :shop_category_new

      live "/admin/shop/categories/:id/edit", PhoenixKitEcommerce.Web.CategoryForm, :edit,
        as: :shop_category_edit

      live "/admin/shop/shipping/new", PhoenixKitEcommerce.Web.ShippingMethodForm, :new,
        as: :shop_shipping_new

      live "/admin/shop/shipping/:id/edit", PhoenixKitEcommerce.Web.ShippingMethodForm, :edit,
        as: :shop_shipping_edit

      live "/admin/shop/settings/options", PhoenixKitEcommerce.Web.OptionsSettings, :index,
        as: :shop_options_settings

      live "/admin/shop/settings/import-configs",
           PhoenixKitEcommerce.Web.ImportConfigs,
           :index,
           as: :shop_import_configs

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
