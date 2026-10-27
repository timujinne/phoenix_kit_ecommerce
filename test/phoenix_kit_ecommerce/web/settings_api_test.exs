defmodule PhoenixKitEcommerce.Web.SettingsApiTest do
  @moduledoc """
  The Admin API card of the E-Commerce settings page: where the API's keys
  live, whether the API is on, what it means for a shop with and without
  Shopify, and the one e-commerce setting of the API, the confirmation
  threshold for price changes.

  The card exists only on a core that ships the API: `:core_api`.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  @moduletag :core_api

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitEcommerce.API.Settings, as: ApiSettings

  @path "/en/admin/shop/settings"

  setup %{conn: conn} do
    shopify = PhoenixKitEcommerce.shopify_enabled?()
    api = ApiSettings.admin_enabled?()

    on_exit(fn ->
      Settings.update_boolean_setting_with_module("shop_shopify_enabled", shopify, "shop")
      Settings.update_boolean_setting_with_module("api_admin_enabled", api, "api")
    end)

    # Everything the page needs, plus core's `api` permission, which changing the
    # threshold takes.
    {:ok, conn: put_test_scope(conn, fake_scope(permissions: shop_permissions() ++ ["api"]))}
  end

  defp submit(view, value) do
    view |> form("#shop-api-confirm-pct-form", %{"pct" => value}) |> render_submit()
  end

  test "shows the card with the threshold and a link to the API settings page", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)

    assert has_element?(view, "#shop-api-card")
    assert has_element?(view, "#shop-api-confirm-pct-input[value='30']")

    assert has_element?(
             view,
             ~s(#shop-api-settings-link[href="#{Routes.path("/admin/settings/api")}"])
           )
  end

  test "says whether the API is on", %{conn: conn} do
    {:ok, view, _html} = live(conn, @path)
    assert has_element?(view, "#shop-api-status[data-enabled='false']")

    Settings.update_boolean_setting_with_module("api_admin_enabled", true, "api")

    {:ok, view, _html} = live(conn, @path)
    assert has_element?(view, "#shop-api-status[data-enabled='true']")
  end

  test "tells a shop without Shopify that the API is how products come in, and a shop with Shopify what a sync does to API prices",
       %{conn: conn} do
    Settings.update_boolean_setting_with_module("shop_shopify_enabled", false, "shop")
    {:ok, view, _html} = live(conn, @path)

    assert has_element?(view, "#shop-api-shopify-off")
    refute has_element?(view, "#shop-api-shopify-on")

    Settings.update_boolean_setting_with_module("shop_shopify_enabled", true, "shop")
    {:ok, view, _html} = live(conn, @path)

    assert has_element?(view, "#shop-api-shopify-on")
    refute has_element?(view, "#shop-api-shopify-off")
  end

  describe "saving the threshold" do
    test "stores a whole number and logs it", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)

      submit(view, "45")

      assert ApiSettings.price_change_pct() == 45
      assert has_element?(view, "#shop-api-confirm-pct-input[value='45']")

      assert_activity_logged("shop.api_confirm_price_change_pct_changed",
        metadata_has: %{
          "setting" => "api_confirm_price_change_pct",
          "value" => 45,
          "previous" => 30
        }
      )
    end

    test "refuses what is not a whole number from 0 to 1000 and keeps the old value", %{
      conn: conn
    } do
      ApiSettings.put_price_change_pct(20)
      {:ok, view, _html} = live(conn, @path)

      for bad <- ["abc", "-1", "1001", "2.5", ""] do
        submit(view, bad)
        assert ApiSettings.price_change_pct() == 20, "#{inspect(bad)} must not be stored"
      end

      refute_activity_logged("shop.api_confirm_price_change_pct_changed")
    end

    test "zero is allowed: every price change then needs a confirmation", %{conn: conn} do
      {:ok, view, _html} = live(conn, @path)
      submit(view, "0")
      assert ApiSettings.price_change_pct() == 0
    end
  end

  describe "authorization" do
    test "saving is denied without shop.manage_settings, even with the api permission", %{
      conn: conn
    } do
      scope = fake_scope(permissions: ["shop", "shop.manage_catalog", "api"])
      {:ok, view, _html} = live_narrowed(put_test_scope(conn, scope), @path)

      render_hook(view, "save_api_confirm_price_change_pct", %{"pct" => "45"})

      assert ApiSettings.price_change_pct() == 30
      refute_activity_logged("shop.api_confirm_price_change_pct_changed")
    end

    test "without core's api permission the threshold is read-only and saving is denied", %{
      conn: conn
    } do
      {:ok, view, _html} = live(put_test_scope(conn, fake_scope()), @path)

      assert has_element?(view, "#shop-api-confirm-pct-readonly")
      refute has_element?(view, "#shop-api-confirm-pct-form")

      # a forged event: the page never renders the form for this user
      render_hook(view, "save_api_confirm_price_change_pct", %{"pct" => "1000"})

      assert ApiSettings.price_change_pct() == 30
      refute_activity_logged("shop.api_confirm_price_change_pct_changed")
    end
  end
end
