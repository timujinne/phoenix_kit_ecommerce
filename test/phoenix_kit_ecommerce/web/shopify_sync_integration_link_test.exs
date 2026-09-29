defmodule PhoenixKitEcommerce.Web.ShopifySyncIntegrationLinkTest do
  @moduledoc """
  The Settings tab links straight at the connected integration's own
  settings page.

  The shop domain and the Admin API token are stored on the integration,
  not on the sync page, and nothing on the page pointed there once a
  connection existed — the only link was the "not connected yet" warning,
  which goes to the generic Integrations list and disappears the moment a
  connection is made. An operator who wanted to rotate a token had to
  remember the Integrations path and work out which of the connections was
  the Shopify one.

  Needs `phoenix_kit_catalogue` loaded — the Settings tab's other panel is
  gated on the catalogue product source — so tagged `:catalogue` and
  excluded via `test_helper.exs`, same as the rest of this page's suite.
  `async: false`: flips the process-wide `shop_product_source` key.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  @moduletag :catalogue

  alias PhoenixKit.Integrations
  alias PhoenixKitEcommerce.ShopConfig
  alias PhoenixKitEcommerce.Test.Repo

  @page "/en/admin/shop/shopify-sync"

  setup %{conn: conn} do
    on_exit(fn -> set_product_source("legacy") end)
    set_product_source("catalogue")

    permissions = ["integrations_system" | shop_permissions()]
    {:ok, conn: put_test_scope(conn, fake_scope(permissions: permissions))}
  end

  defp set_product_source(value) do
    case Repo.get(ShopConfig, "shop_product_source") do
      nil ->
        %ShopConfig{}
        |> ShopConfig.changeset(%{key: "shop_product_source", value: %{"value" => value}})
        |> Repo.insert!()

      config ->
        config
        |> ShopConfig.changeset(%{value: %{"value" => value}})
        |> Repo.update!()
    end
  end

  defp connect_shopify do
    {:ok, %{uuid: uuid}} =
      Integrations.add_connection("shopify", "Test Shop #{System.unique_integer([:positive])}")

    {:ok, _} =
      Integrations.save_setup(uuid, %{
        "shop_domain" => "test-shop.myshopify.com",
        "access_token" => "shpat_test_token"
      })

    uuid
  end

  describe "connected" do
    test "the Settings tab links at that connection's own settings page", %{conn: conn} do
      uuid = connect_shopify()

      {:ok, view, _html} = live(conn, @page <> "?tab=settings")

      assert has_element?(
               view,
               ~s(#open-shopify-integration[href$="/admin/settings/integrations/#{uuid}"])
             )
    end

    # The uuid in the href is the point: a link to the Integrations list
    # would still pass an "is there a link" assertion while leaving the
    # operator to work out which connection is the Shopify one.
    test "the link carries the uuid, not the generic Integrations list", %{conn: conn} do
      uuid = connect_shopify()

      {:ok, view, _html} = live(conn, @page <> "?tab=settings")

      refute has_element?(
               view,
               ~s(#open-shopify-integration[href$="/admin/settings/integrations"])
             )

      assert has_element?(view, ~s(#open-shopify-integration[href*="#{uuid}"]))
    end

    test "it is on the Settings tab only, not on Changes", %{conn: conn} do
      connect_shopify()

      {:ok, view, _html} = live(conn, @page)

      refute has_element?(view, "#open-shopify-integration")
    end
  end

  describe "not connected" do
    test "no link to a connection that does not exist", %{conn: conn} do
      {:ok, view, _html} = live(conn, @page <> "?tab=settings")

      refute has_element?(view, "#open-shopify-integration")
    end
  end
end
