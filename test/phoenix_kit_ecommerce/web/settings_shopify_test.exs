defmodule PhoenixKitEcommerce.Web.SettingsShopifyTest do
  @moduledoc """
  Admin Settings page: the Shopify sync existence card (design §4.7).

  Like the AI Translations card (`Web.SettingsTranslationsTest`), this
  toggle defaults to off: Shopify is one optional product source, so a
  fresh install shows no Shopify UI until an admin turns it on. (Installs
  that already used Shopify get the row written by the chain's V3 step.)
  It is also a single key (design §12.4): there is no paired "autonomy"
  setting to also flip, because the sync has no background actor.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKit.Integrations
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  setup %{conn: conn} do
    # The settings row rolls back with the sandbox, but the toggle (and
    # `enable_shopify!/0`) leave `Integrations.Providers`' process-global
    # `:persistent_term` cache showing Shopify as registered.
    on_exit(fn -> Integrations.Providers.clear_cache() end)

    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  test "renders the card, toggle off by default and no sync link", %{conn: conn} do
    {:ok, view, html} = live(conn, "/en/admin/shop/settings")

    assert html =~ ~s(id="shop-shopify-card")
    assert has_element?(view, "#toggle-shop-shopify-enabled")
    refute has_element?(view, "#toggle-shop-shopify-enabled[checked]")
    refute html =~ Routes.path("/admin/shop/shopify-sync")
    refute Settings.get_boolean_setting("shop_shopify_enabled", false)
  end

  test "a link to the Shopify sync page appears while enabled", %{conn: conn} do
    enable_shopify!()

    {:ok, _view, html} = live(conn, "/en/admin/shop/settings")
    assert html =~ Routes.path("/admin/shop/shopify-sync")
  end

  describe "the Connect link" do
    setup %{conn: conn} do
      enable_shopify!()
      permissions = ["integrations_system" | shop_permissions()]

      {:ok, with_integrations: put_test_scope(conn, fake_scope(permissions: permissions))}
    end

    test "goes to the Integrations list while nothing is connected", ctx do
      {:ok, view, _html} = live(ctx.with_integrations, "/en/admin/shop/settings")

      assert has_element?(view, ~s(#shop-shopify-connect[href$="/admin/settings/integrations"]))
    end

    test "goes to the Shopify connection's own page once there is one", ctx do
      {:ok, %{uuid: uuid}} = Integrations.add_connection("shopify", "Test Shop")

      {:ok, view, _html} = live(ctx.with_integrations, "/en/admin/shop/settings")

      assert has_element?(
               view,
               ~s(#shop-shopify-connect[href$="/admin/settings/integrations/#{uuid}"])
             )
    end

    test "is not offered to a role without access to Integrations", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope(roles: ["Admin"]))
      {:ok, view, _html} = live(conn, "/en/admin/shop/settings")

      refute has_element?(view, "#shop-shopify-connect")
    end
  end

  test "disabling flips the setting, logs Activity, and drops the link", %{conn: conn} do
    enable_shopify!()

    {:ok, view, _html} = live(conn, "/en/admin/shop/settings")

    html = render_click(element(view, "#toggle-shop-shopify-enabled"))

    refute Settings.get_boolean_setting("shop_shopify_enabled", true)
    refute html =~ Routes.path("/admin/shop/shopify-sync")

    assert_activity_logged("shop.shopify_enabled_changed", metadata_has: %{"enabled" => false})
  end

  test "enabling flips the setting on and logs Activity", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/en/admin/shop/settings")
    render_click(element(view, "#toggle-shop-shopify-enabled"))

    assert Settings.get_boolean_setting("shop_shopify_enabled", false)

    assert_activity_logged("shop.shopify_enabled_changed", metadata_has: %{"enabled" => true})
  end

  test "toggling off does not touch a saved connection or its token", %{conn: conn} do
    enable_shopify!()

    {:ok, %{uuid: uuid}} =
      Integrations.add_connection("shopify", "Test Shop #{System.unique_integer([:positive])}")

    {:ok, _} =
      Integrations.save_setup(uuid, %{
        "shop_domain" => "test-shop.myshopify.com",
        "access_token" => "shpat_test_token"
      })

    [before_toggle] = Integrations.list_connections("shopify", owner: :system)

    {:ok, view, _html} = live(conn, "/en/admin/shop/settings")
    render_click(element(view, "#toggle-shop-shopify-enabled"))

    [after_toggle] = Integrations.list_connections("shopify", owner: :system)

    assert before_toggle.uuid == after_toggle.uuid
    assert before_toggle.data == after_toggle.data
  end

  test "toggling off immediately drops Shopify from the provider list (persistent_term cache is cleared)",
       %{conn: conn} do
    enable_shopify!()

    # Warm the cache before touching the setting, the same way the running
    # integrations page would have on an earlier visit.
    assert Enum.any?(Integrations.Providers.all(), &(&1.key == "shopify"))

    {:ok, view, _html} = live(conn, "/en/admin/shop/settings")
    render_click(element(view, "#toggle-shop-shopify-enabled"))

    refute Enum.any?(Integrations.Providers.all(), &(&1.key == "shopify"))
  end

  describe "authz" do
    setup %{conn: conn} do
      {:ok, conn: put_test_scope(conn, fake_scope(permissions: ["shop", "shop.manage_catalog"]))}
    end

    test "toggling is denied without shop.manage_settings", %{conn: conn} do
      enable_shopify!()

      {:ok, view, _html} = live(conn, "/en/admin/shop/settings")

      html = render_click(element(view, "#toggle-shop-shopify-enabled"))

      assert html =~ "You don&#39;t have permission to do that"
      assert Settings.get_boolean_setting("shop_shopify_enabled", false)
    end
  end
end
