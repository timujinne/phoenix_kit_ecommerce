defmodule PhoenixKitEcommerce.Web.SettingsShopifyTest do
  @moduledoc """
  Admin Settings page: the Shopify sync existence card (design §4.7).

  Unlike the AI Translations card (`Web.SettingsTranslationsTest`), this
  toggle defaults to `true` — Shopify sync predates the toggle, so a
  stand that never touches `shop_shopify_enabled` must keep behaving
  exactly as before (design §4.7's own framing). It is also a single
  key (design §12.4): there is no paired "autonomy" setting to also
  flip, because the sync has no background actor.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKit.Integrations
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  setup %{conn: conn} do
    # `shop_shopify_enabled = false` is only ever transient within a test
    # here — the ETS-backed `Settings` cache (unlike the settings TABLE
    # row) is not rolled back by the sandbox transaction, and
    # `Integrations.Providers`' own `:persistent_term` cache is
    # process-global. Left "false"/cleared, either would poison
    # `connect_shopify()`/`Integrations.add_connection/2` in a LATER test
    # (any file) with `{:error, :unknown_provider}`. Restoring both,
    # unconditionally, on every exit is cheaper than reasoning about
    # which individual test needs it.
    on_exit(fn ->
      Settings.update_boolean_setting_with_module("shop_shopify_enabled", true, "shop")
      Integrations.Providers.clear_cache()
    end)

    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  test "renders the card, toggle on by default", %{conn: conn} do
    {:ok, view, html} = live(conn, "/en/admin/shop/settings")

    assert html =~ ~s(id="shop-shopify-card")
    assert has_element?(view, "#toggle-shop-shopify-enabled[checked]")
    assert Settings.get_boolean_setting("shop_shopify_enabled", true)
  end

  test "a link to the Shopify sync page appears while enabled", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/en/admin/shop/settings")
    assert html =~ Routes.path("/admin/shop/shopify-sync")
  end

  test "disabling flips the setting, logs Activity, and drops the link", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/en/admin/shop/settings")

    html = render_click(element(view, "#toggle-shop-shopify-enabled"))

    refute Settings.get_boolean_setting("shop_shopify_enabled", true)
    refute html =~ Routes.path("/admin/shop/shopify-sync")

    assert_activity_logged("shop.shopify_enabled_changed", metadata_has: %{"enabled" => false})
  end

  test "re-enabling flips the setting back and logs Activity again", %{conn: conn} do
    Settings.update_boolean_setting_with_module("shop_shopify_enabled", false, "shop")

    {:ok, view, _html} = live(conn, "/en/admin/shop/settings")
    render_click(element(view, "#toggle-shop-shopify-enabled"))

    assert Settings.get_boolean_setting("shop_shopify_enabled", true)

    assert_activity_logged("shop.shopify_enabled_changed", metadata_has: %{"enabled" => true})
  end

  test "toggling off does not touch a saved connection or its token", %{conn: conn} do
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
      {:ok, view, _html} = live(conn, "/en/admin/shop/settings")

      html = render_click(element(view, "#toggle-shop-shopify-enabled"))

      assert html =~ "You don&#39;t have permission to do that"
      assert Settings.get_boolean_setting("shop_shopify_enabled", true)
    end
  end
end
