defmodule PhoenixKitEcommerce.Web.PublicEventFallbackTest do
  @moduledoc """
  Anyone can push any event at a public page. A known event with an empty
  or wrong-shaped payload, and an event the page has never heard of, are
  ignored: the view stays up and still renders.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitEcommerce, as: Shop

  @malformed [%{}, %{"item_uuid" => %{"nested" => "map"}, "unexpected" => ["list"]}]

  defp assert_survives(view, events) do
    for event <- events ++ ["no_such_event"], payload <- [hd(@malformed)] do
      html = render_hook(view, event, payload)
      assert is_binary(html) and html != "", "#{event} left nothing rendered"
    end

    # still the same live process, still answering
    assert render(view) =~ "<"
    assert Process.alive?(view.pid)
  end

  defp product!(extra \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, product} =
      Shop.create_product(
        Map.merge(
          %{
            "title" => %{"en" => "Fallback Widget #{n}"},
            "slug" => %{"en" => "fallback-widget-#{n}"},
            "price" => Decimal.new("10.00"),
            "status" => "active",
            "currency" => "USD",
            "product_type" => "digital",
            "requires_shipping" => false
          },
          extra
        )
      )

    product
  end

  defp cart_session(conn) do
    session_id = "fallback-#{System.unique_integer([:positive])}"
    {:ok, cart} = Shop.create_cart(session_id: session_id)
    {:ok, cart} = Shop.add_to_cart(cart, product!(), 1)

    {Plug.Test.init_test_session(conn, %{
       "shop_session_id" => session_id,
       "shop_session_trusted" => true
     }), cart}
  end

  test "the cart page", %{conn: conn} do
    {conn, cart} = cart_session(conn)
    {:ok, view, _html} = live(conn, "/cart")

    # The quantity form carries an id, so LiveView can recover it.
    [item] = Shop.get_cart!(cart.uuid).items

    assert has_element?(
             view,
             "form#cart-quantity-form-#{item.uuid}[phx-change='update_quantity']"
           )

    assert_survives(view, ["remove_item", "select_shipping", "update_quantity"])

    # a wrong-shaped value for the right key is not acted on either
    render_hook(view, "remove_item", Enum.at(@malformed, 1))
    assert length(Shop.get_cart!(cart.uuid).items) == 1
  end

  test "the checkout page", %{conn: conn} do
    {conn, _cart} = cart_session(conn)
    {:ok, view, _html} = live(conn, "/checkout")

    assert_survives(view, [
      "select_payment_option",
      "select_profile",
      "select_checkout_shipping",
      "update_billing"
    ])
  end

  test "the product page", %{conn: conn} do
    product = product!()
    {:ok, view, _html} = live(conn, "/shop/product/#{product.slug["en"]}")

    assert_survives(view, ["select_image", "select_storage_image", "set_quantity"])
  end

  test "the catalog page", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/shop")

    assert_survives(view, ["clear_filter", "toggle_filter", "filter_search"])
  end

  test "a category page", %{conn: conn} do
    {:ok, category} =
      Shop.create_category(%{
        "name" => %{"en" => "Fallback Category"},
        "slug" => %{"en" => "fallback-category"},
        "status" => "active"
      })

    {:ok, view, _html} = live(conn, "/shop/category/#{category.slug["en"]}")

    assert_survives(view, ["clear_filter", "toggle_filter", "filter_search"])
  end

  describe "order pages" do
    setup %{conn: conn} do
      PhoenixKit.Settings.update_boolean_setting_with_module("billing_enabled", true, "billing")

      {conn, cart} = cart_session(conn)

      {:ok, order} =
        Shop.convert_cart_to_order(cart, billing_data: complete_billing("EE", "fallback"))

      %{conn: conn, order: order}
    end

    test "the confirmation page", %{conn: conn, order: order} do
      {:ok, view, _html} = live(conn, "/checkout/complete/#{order.uuid}")

      assert_survives(view, ["confirm_order"])
    end

    test "the customer's order list and order page", %{conn: conn, order: order} do
      conn = put_test_scope(conn, fake_scope(user_uuid: order.user_uuid))

      {:ok, list, _html} = live(conn, "/dashboard/orders")
      assert_survives(list, ["change_page"])

      {:ok, details, _html} = live(conn, "/dashboard/orders/#{order.uuid}")
      assert_survives(details, ["change_page"])
    end
  end
end
