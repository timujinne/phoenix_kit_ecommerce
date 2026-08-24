defmodule PhoenixKitEcommerce.Web.SettingsNotificationsTest do
  @moduledoc """
  Admin Settings page: the storefront-notifications card added in
  PhoenixKitEcommerce.Web.Settings — the three cart/checkout notify
  toggles and the recipient checkbox list.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles

  setup %{conn: conn} do
    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  test "renders the notifications card", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/en/admin/shop/settings")
    assert html =~ ~s(id="shop-notifications-card")
  end

  test "toggles flip the three notify settings", %{conn: conn} do
    {:ok, view, html} = live(conn, "/en/admin/shop/settings")
    assert html =~ ~s(id="shop-notifications-card")

    render_click(element(view, "#toggle-notify-cart-first-item"))
    assert PhoenixKit.Settings.get_setting("shop_notify_cart_first_item") == "true"

    render_click(element(view, "#toggle-notify-cart-item"))
    assert PhoenixKit.Settings.get_setting("shop_notify_cart_item") == "true"

    render_click(element(view, "#toggle-notify-checkout-started"))
    assert PhoenixKit.Settings.get_setting("shop_notify_checkout_started") == "true"
  end

  test "recipient checkboxes persist the JSON list", %{conn: conn} do
    # Explicit grant rather than relying on being first-in-database: Sandbox
    # only rolls back this test's own transaction, so a committed Owner from
    # outside it (a shared test database's seed account, say) silently skips
    # the auto-promotion this used to lean on. `Roles.assign_role/2` refuses
    # "Owner" directly (owner_role_protected), so grant "Admin" plus the
    # permission `admin_recipients/1` actually unions over — same pattern as
    # `create_admin_user/0` in notifications_test.exs.
    admin = PhoenixKitEcommerce.DataCase.fixture_user()
    admin_role = Roles.get_role_by_name("Admin")
    {:ok, _} = Roles.assign_role(admin, "Admin")
    {:ok, _} = Permissions.grant_permission(admin_role.uuid, "shop.manage_carts")

    {:ok, view, html} = live(conn, "/en/admin/shop/settings")
    assert html =~ admin.email

    view
    |> element("#shop-notification-recipients-form")
    |> render_submit(%{"recipients" => %{admin.uuid => "true"}})

    assert PhoenixKit.Settings.get_json_setting("shop_notification_recipients") == %{
             "uuids" => [admin.uuid]
           }
  end
end
