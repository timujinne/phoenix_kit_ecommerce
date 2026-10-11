defmodule PhoenixKitEcommerce.ShopifyFixtures do
  @moduledoc """
  Turns the Shopify integration on for one test.

  `PhoenixKitEcommerce.shopify_enabled?/0` defaults to off, and while it is
  off the Shopify provider is not registered, so
  `PhoenixKit.Integrations.add_connection("shopify", _)` answers
  `{:error, :unknown_provider}`. Tests that connect Shopify call
  `enable_shopify!/0` first.

  The settings row is rolled back with the sandbox transaction, but
  `Integrations.Providers`' `:persistent_term` cache is process-global, so
  it is cleared on the way in and again on the way out. That shared cache is
  also why every test using this must be `async: false`.

  Imported into `PhoenixKitEcommerce.DataCase` and
  `PhoenixKitEcommerce.LiveCase`.
  """

  alias PhoenixKit.Integrations.Providers
  alias PhoenixKit.Settings

  @doc "Writes `shop_shopify_enabled = true` and refreshes the provider cache; undone on exit."
  @spec enable_shopify!() :: :ok
  def enable_shopify! do
    {:ok, _} = Settings.update_boolean_setting_with_module("shop_shopify_enabled", true, "shop")
    Providers.clear_cache()

    ExUnit.Callbacks.on_exit(fn ->
      Settings.update_boolean_setting_with_module("shop_shopify_enabled", false, "shop")
      Providers.clear_cache()
    end)

    :ok
  end
end
