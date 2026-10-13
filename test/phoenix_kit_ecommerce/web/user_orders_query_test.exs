defmodule PhoenixKitEcommerce.Web.UserOrdersQueryTest do
  @moduledoc """
  The account's order list keeps its filter and page in the URL. The filter and
  pagination events patch to a path built by `Helpers.page_path/3`; it used to
  hand the query to `Routes.path/2`, which reads only `:locale`, so every patch
  went to the bare list and the filter and the page never applied.
  """
  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Web.Helpers

  defp order! do
    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Query Probe"},
        "slug" => %{"en" => "query-probe-#{System.unique_integer([:positive])}"},
        "price" => Decimal.new("10.00"),
        "status" => "active",
        "currency" => "USD",
        "product_type" => "digital",
        "requires_shipping" => false
      })

    {:ok, cart} =
      Shop.create_cart(session_id: "orders-query-#{System.unique_integer([:positive])}")

    {:ok, cart} = Shop.add_to_cart(cart, product, 1)

    {:ok, order} =
      Shop.convert_cart_to_order(cart, billing_data: complete_billing("EE", "orders-query"))

    order
  end

  setup %{conn: conn} do
    Settings.update_boolean_setting_with_module("billing_enabled", true, "billing")
    order = order!()
    {:ok, conn: put_test_scope(conn, fake_scope(user_uuid: order.user_uuid))}
  end

  test "the status filter patches to a URL that carries it", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dashboard/orders")

    view |> element("form") |> render_change(%{"filters" => %{"status" => "pending"}})

    assert_patch(view, "/dashboard/orders?status=pending")
  end

  test "clearing the filter patches back to the bare list", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dashboard/orders?status=pending")

    render_hook(view, "clear_filters", %{})

    assert_patch(view, "/dashboard/orders")
  end

  test "changing the page keeps the filter and the page in the URL", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/dashboard/orders?status=pending")

    render_hook(view, "change_page", %{"page" => "2"})

    assert_patch(view, "/dashboard/orders?page=2&status=pending")
  end

  describe "Helpers.page_path/3" do
    test "appends the query, encoded, after the localized path" do
      assigns = %{current_locale: "en"}

      assert Helpers.page_path(assigns, "/dashboard/orders", status: "a b&c", page: 2) ==
               Helpers.page_path(assigns, "/dashboard/orders") <> "?status=a+b%26c&page=2"
    end

    test "an empty query adds no question mark" do
      assigns = %{current_locale: "en"}

      assert Helpers.page_path(assigns, "/cart", []) == Helpers.page_path(assigns, "/cart")
    end
  end
end
