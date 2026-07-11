defmodule PhoenixKitEcommerce.Web.SettingsFiltersTest do
  @moduledoc """
  Storefront-filter management on the admin Settings page: configs saved
  before a built-in filter existed still surface it (disabled) so admins
  can discover and enable it.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitEcommerce, as: Shop

  setup %{conn: conn} do
    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  describe "storefront filters table" do
    test "shows built-in search filter for a pre-search saved config", %{conn: conn} do
      {:ok, _} =
        Shop.update_storefront_filters([
          %{
            "key" => "price",
            "type" => "price_range",
            "label" => "Price",
            "enabled" => true,
            "position" => 0
          }
        ])

      {:ok, _view, html} = live(conn, "/en/admin/shop/settings")
      assert html =~ ~s(phx-value-key="search")
    end

    test "enabling the merged-in search filter persists it", %{conn: conn} do
      {:ok, _} =
        Shop.update_storefront_filters([
          %{
            "key" => "price",
            "type" => "price_range",
            "label" => "Price",
            "enabled" => true,
            "position" => 0
          }
        ])

      {:ok, view, _html} = live(conn, "/en/admin/shop/settings")

      view
      |> element(~s{input[phx-click="toggle_storefront_filter"][phx-value-key="search"]})
      |> render_click()

      saved = Shop.get_storefront_filters()
      search = Enum.find(saved, &(&1["key"] == "search"))
      assert search["enabled"]
    end

    test "the merged-in search filter still sorts first on the storefront once enabled", %{
      conn: conn
    } do
      # Regression: the pre-search config's "price" already sits at
      # position 0, matching `search`'s default position — a naive merge
      # ties on position and, once enabled, `search` falls after `price`
      # instead of leading the sidebar as designed.
      {:ok, _} =
        Shop.update_storefront_filters([
          %{
            "key" => "price",
            "type" => "price_range",
            "label" => "Price",
            "enabled" => true,
            "position" => 0
          }
        ])

      {:ok, view, _html} = live(conn, "/en/admin/shop/settings")

      view
      |> element(~s{input[phx-click="toggle_storefront_filter"][phx-value-key="search"]})
      |> render_click()

      assert [%{"key" => "search"} | _] = Shop.get_enabled_storefront_filters()
    end
  end
end
