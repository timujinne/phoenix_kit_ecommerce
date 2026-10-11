defmodule PhoenixKitEcommerce.Web.SettingsStockTrackingTest do
  @moduledoc """
  Admin Settings page: the "Stock tracking" switch (spec 8.1, D13).

  The switch is a module setting that only takes effect while Warehouse is
  installed and enabled. The Warehouse side is stubbed (see
  `PhoenixKitEcommerce.Test.FakeWarehouse`), so these tests also run when the
  optional `phoenix_kit_warehouse` dependency is not resolved.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Test.FakeWarehouse

  @settings_path "/en/admin/shop/settings"
  @toggle "#toggle-shop-stock-tracking"
  @hint "#shop-stock-tracking-hint"
  @link "#shop-stock-tracking-hint-link"

  setup %{conn: conn} do
    # The settings cache is ETS-backed and is not rolled back by the sandbox.
    on_exit(fn ->
      Settings.update_boolean_setting_with_module("shop_stock_tracking_enabled", false, "shop")
      FakeWarehouse.reset()
    end)

    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  defp link_href(view),
    do:
      view
      |> element(@link)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute("href")
      |> List.first()

  describe "Warehouse not installed" do
    setup do: FakeWarehouse.put_not_installed()

    test "toggle is disabled and the hint points at Modules -> Not installed", %{conn: conn} do
      {:ok, view, _html} = live(conn, @settings_path)

      assert has_element?(view, @toggle <> "[disabled]")
      refute has_element?(view, @toggle <> "[checked]")

      assert has_element?(
               view,
               @hint,
               "Stock tracking needs the Warehouse module. Install it from Modules"
             )

      assert link_href(view) == Routes.path("/admin/modules?tab=not_installed")
    end

    test "turning it on is refused by the server", %{conn: conn} do
      {:ok, view, _html} = live(conn, @settings_path)

      html = render_hook(view, "toggle_shop_stock_tracking", %{})

      assert html =~ "Stock tracking was not turned on: the Warehouse module is not installed."
      refute Settings.get_boolean_setting("shop_stock_tracking_enabled", false)
      refute has_element?(view, @toggle <> "[checked]")
      refute Shop.stock_tracking_enabled?()
      refute_activity_logged("shop.stock_tracking_changed")
    end
  end

  describe "Warehouse installed but disabled" do
    setup do: FakeWarehouse.put_state(enabled: false)

    test "toggle is disabled and the hint points at Modules -> Disabled", %{conn: conn} do
      {:ok, view, _html} = live(conn, @settings_path)

      assert has_element?(view, @toggle <> "[disabled]")

      assert has_element?(
               view,
               @hint,
               "Stock tracking needs the Warehouse module. Enable it in Modules"
             )

      assert link_href(view) == Routes.path("/admin/modules?tab=disabled")
    end

    test "turning it on is refused by the server", %{conn: conn} do
      {:ok, view, _html} = live(conn, @settings_path)

      html = render_hook(view, "toggle_shop_stock_tracking", %{})

      assert html =~ "Stock tracking was not turned on: the Warehouse module is disabled."
      refute Settings.get_boolean_setting("shop_stock_tracking_enabled", false)
      refute has_element?(view, @toggle <> "[checked]")
    end
  end

  describe "Warehouse enabled, no default location" do
    setup do: FakeWarehouse.put_state(enabled: true, default_location: nil)

    test "toggle is enabled and the hint points at Warehouse settings", %{conn: conn} do
      {:ok, view, _html} = live(conn, @settings_path)

      assert has_element?(view, @toggle)
      refute has_element?(view, @toggle <> "[disabled]")

      assert has_element?(
               view,
               @hint,
               "Choose a default warehouse in Warehouse settings first."
             )

      assert link_href(view) == Routes.path("/admin/settings/warehouse")
    end

    test "turning it on persists and logs", %{conn: conn} do
      {:ok, view, _html} = live(conn, @settings_path)

      render_click(element(view, @toggle))

      assert Settings.get_boolean_setting("shop_stock_tracking_enabled", false)
      assert has_element?(view, @toggle <> "[checked]")
      assert Shop.stock_tracking_enabled?()

      assert_activity_logged("shop.stock_tracking_changed", metadata_has: %{"enabled" => true})
    end
  end

  describe "Warehouse enabled and configured" do
    setup do: FakeWarehouse.put_state(enabled: true, default_location: "loc-1")

    test "toggle is enabled and the hint links to the Warehouse stock page", %{conn: conn} do
      {:ok, view, _html} = live(conn, @settings_path)

      refute has_element?(view, @toggle <> "[disabled]")
      refute has_element?(view, @toggle <> "[checked]")
      assert has_element?(view, @hint, "Stock is kept by the Warehouse module.")
      refute has_element?(view, @hint, "Choose a default warehouse")
      assert link_href(view) == Routes.path("/admin/warehouse")
    end

    test "can be turned on and off again", %{conn: conn} do
      {:ok, view, _html} = live(conn, @settings_path)

      render_click(element(view, @toggle))
      assert has_element?(view, @toggle <> "[checked]")
      assert Settings.get_boolean_setting("shop_stock_tracking_enabled", false)

      render_click(element(view, @toggle))
      refute has_element?(view, @toggle <> "[checked]")
      refute Settings.get_boolean_setting("shop_stock_tracking_enabled", false)

      assert_activity_logged("shop.stock_tracking_changed", metadata_has: %{"enabled" => false})
    end

    test "shows off once Warehouse is disabled, without touching the setting", %{conn: conn} do
      {:ok, view, _html} = live(conn, @settings_path)
      render_click(element(view, @toggle))
      assert has_element?(view, @toggle <> "[checked]")

      FakeWarehouse.put_state(enabled: false)
      {:ok, view, _html} = live(conn, @settings_path)

      refute has_element?(view, @toggle <> "[checked]")
      assert has_element?(view, @toggle <> "[disabled]")
      assert Settings.get_boolean_setting("shop_stock_tracking_enabled", false)
      refute Shop.stock_tracking_enabled?()
    end
  end
end
