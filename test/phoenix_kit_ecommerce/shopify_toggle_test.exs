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

  # `shop_shopify_enabled = true` here is only ever transient within a
  # test — the ETS-backed `Settings` cache (unlike the table row) is NOT
  # rolled back by the sandbox transaction, and `Providers`' own
  # `:persistent_term` cache is process-global. Left "true", either would
  # let a later test (any file) see Shopify registered when it expects the
  # default (off). Restoring the default on every exit, unconditionally,
  # is cheaper than reasoning about which individual test needs it.
  setup do
    on_exit(fn ->
      Settings.update_boolean_setting_with_module("shop_shopify_enabled", false, "shop")
      Providers.clear_cache()
    end)
  end

  defp shopify_tab do
    Enum.find(PhoenixKitEcommerce.admin_tabs(), &(&1.id == :admin_shop_shopify_sync))
  end

  describe "shopify_enabled?/0" do
    test "defaults to false — Shopify is one optional source, not part of every shop" do
      refute PhoenixKitEcommerce.shopify_enabled?()
    end

    test "reflects a stored true" do
      enable_shopify!()
      assert PhoenixKitEcommerce.shopify_enabled?()
    end

    test "reflects a stored false" do
      Settings.update_boolean_setting_with_module("shop_shopify_enabled", false, "shop")
      refute PhoenixKitEcommerce.shopify_enabled?()
    end

    test "reflects a stored true after having been turned off" do
      Settings.update_boolean_setting_with_module("shop_shopify_enabled", false, "shop")
      enable_shopify!()
      assert PhoenixKitEcommerce.shopify_enabled?()
    end
  end

  describe "required_integrations/0 (design §4.7: core treats this as informational only)" do
    test "is empty by default" do
      assert PhoenixKitEcommerce.required_integrations() == []
    end

    test "names shopify once the toggle is on" do
      enable_shopify!()
      assert PhoenixKitEcommerce.required_integrations() == ["shopify"]
    end

    test "is empty once the toggle is turned off again" do
      enable_shopify!()
      Settings.update_boolean_setting_with_module("shop_shopify_enabled", false, "shop")
      assert PhoenixKitEcommerce.required_integrations() == []
    end
  end

  describe "integration_providers/0" do
    test "is empty by default, so Shopify is not offered on the integrations page" do
      assert PhoenixKitEcommerce.integration_providers() == []
    end

    test "registers the Shopify provider with credentials auth once the toggle is on" do
      enable_shopify!()
      assert [provider] = PhoenixKitEcommerce.integration_providers()

      assert provider.key == "shopify"
      assert provider.auth_type == :credentials

      field_keys = Enum.map(provider.setup_fields, & &1.key)
      assert "shop_domain" in field_keys
      assert "access_token" in field_keys

      access_token_field = Enum.find(provider.setup_fields, &(&1.key == "access_token"))
      assert access_token_field.required
      assert access_token_field.type == :password
    end

    test "is empty once the toggle is turned off again, so Shopify drops out of the integrations page" do
      enable_shopify!()
      Settings.update_boolean_setting_with_module("shop_shopify_enabled", false, "shop")
      assert PhoenixKitEcommerce.integration_providers() == []
    end
  end

  describe "admin_shop_shopify_sync tab visibility" do
    test "is hidden by default" do
      refute Tab.visible?(shopify_tab(), %{})
    end

    test "shows once the toggle is on" do
      enable_shopify!()
      assert Tab.visible?(shopify_tab(), %{})
    end

    test "hides again once turned off" do
      enable_shopify!()
      Settings.update_boolean_setting_with_module("shop_shopify_enabled", false, "shop")
      refute Tab.visible?(shopify_tab(), %{})
    end
  end
end
