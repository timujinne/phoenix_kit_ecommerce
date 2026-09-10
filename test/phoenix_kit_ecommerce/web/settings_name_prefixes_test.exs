defmodule PhoenixKitEcommerce.Web.SettingsNamePrefixesTest do
  @moduledoc """
  Admin Settings page: the "Hide name prefixes on the storefront" card
  (`shop_name_prefixes`), so the owner can turn the feature on without a
  console.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitEcommerce.NamePrefix

  setup %{conn: conn} do
    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  test "renders the card, empty by default", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/en/admin/shop/settings")
    assert html =~ ~s(id="shop-name-prefixes-card")
  end

  test "saving normalizes and persists the comma-separated list", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/en/admin/shop/settings")

    html =
      view
      |> element("#shop-name-prefixes-form")
      |> render_submit(%{"prefixes" => " 3D Printed ,, Hand Made "})

    assert PhoenixKit.Settings.get_setting(NamePrefix.setting_key()) == "3D Printed, Hand Made"
    assert html =~ "3D Printed, Hand Made"
    assert NamePrefix.prefixes() == ["3D Printed", "Hand Made"]
  end

  test "saving blank clears the setting back to no stripping", %{conn: conn} do
    PhoenixKit.Settings.update_setting(NamePrefix.setting_key(), "3D Printed")

    {:ok, view, _html} = live(conn, "/en/admin/shop/settings")

    view
    |> element("#shop-name-prefixes-form")
    |> render_submit(%{"prefixes" => ""})

    assert NamePrefix.prefixes() == []
  end
end
