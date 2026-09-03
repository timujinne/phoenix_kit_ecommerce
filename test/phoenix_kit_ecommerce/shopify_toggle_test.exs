defmodule PhoenixKitEcommerce.ShopifyToggleTest do
  @moduledoc """
  Unit coverage for the `shop_shopify_enabled` existence toggle (design
  §4.7, §12.4): the reader's default, and the three call sites that must
  react to it — `required_integrations/0`, `integration_providers/0`, and
  the `admin_shop_shopify_sync` sidebar tab's `visible:` closure. The
  LiveView-level effects (sync page redirect, settings card, live
  `:persistent_term` cache clearing) are covered separately in
  `Web.ShopifySyncTest` and `Web.SettingsShopifyTest`.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Integrations.Providers
  alias PhoenixKit.Settings

  # `shop_shopify_enabled = false` here is only ever transient within a
  # test — the ETS-backed `Settings` cache (unlike the table row) is NOT
  # rolled back by the sandbox transaction, and `Providers`' own
  # `:persistent_term` cache is process-global. Left "false", either would
  # poison `connect_shopify()`/`Integrations.add_connection/2` in a later
  # test (any file) with `{:error, :unknown_provider}` — see
  # `Web.ShopifySyncTest`'s own moduledoc note on this. Restoring the
  # documented default on every exit, unconditionally, is cheaper than
  # reasoning about which individual test needs it.
  setup do
    on_exit(fn ->
      Settings.update_boolean_setting_with_module("shop_shopify_enabled", true, "shop")
      Providers.clear_cache()
    end)
  end

  defp shopify_tab do
    Enum.find(PhoenixKitEcommerce.admin_tabs(), &(&1.id == :admin_shop_shopify_sync))
  end

  describe "shopify_enabled?/0" do
    test "defaults to true — the current stand's behaviour must not change silently" do
      assert PhoenixKitEcommerce.shopify_enabled?()
    end

    test "reflects a stored false" do
      Settings.update_boolean_setting_with_module("shop_shopify_enabled", false, "shop")
      refute PhoenixKitEcommerce.shopify_enabled?()
    end

    test "reflects a stored true after having been turned off" do
      Settings.update_boolean_setting_with_module("shop_shopify_enabled", false, "shop")
      Settings.update_boolean_setting_with_module("shop_shopify_enabled", true, "shop")
      assert PhoenixKitEcommerce.shopify_enabled?()
    end
  end

  describe "required_integrations/0 (design §4.7: core treats this as informational only)" do
    test "names shopify by default" do
      assert PhoenixKitEcommerce.required_integrations() == ["shopify"]
    end

    test "is empty once the toggle is off" do
      Settings.update_boolean_setting_with_module("shop_shopify_enabled", false, "shop")
      assert PhoenixKitEcommerce.required_integrations() == []
    end
  end

  describe "integration_providers/0" do
    test "registers the Shopify provider by default" do
      assert [%{key: "shopify"}] = PhoenixKitEcommerce.integration_providers()
    end

    test "is empty once the toggle is off, so Shopify drops out of the integrations page" do
      Settings.update_boolean_setting_with_module("shop_shopify_enabled", false, "shop")
      assert PhoenixKitEcommerce.integration_providers() == []
    end
  end

  describe "admin_shop_shopify_sync tab visibility" do
    test "is visible by default" do
      assert Tab.visible?(shopify_tab(), %{})
    end

    test "hides once the toggle is off" do
      Settings.update_boolean_setting_with_module("shop_shopify_enabled", false, "shop")
      refute Tab.visible?(shopify_tab(), %{})
    end

    test "reappears once turned back on" do
      Settings.update_boolean_setting_with_module("shop_shopify_enabled", false, "shop")
      Settings.update_boolean_setting_with_module("shop_shopify_enabled", true, "shop")
      assert Tab.visible?(shopify_tab(), %{})
    end
  end
end
