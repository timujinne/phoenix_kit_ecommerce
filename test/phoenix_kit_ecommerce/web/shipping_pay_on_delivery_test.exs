defmodule PhoenixKitEcommerce.Web.ShippingPayOnDeliveryTest do
  @moduledoc """
  A pay-on-delivery shipping method renders as "Paid on delivery" wherever a
  shipping price is shown — the method lists, the summaries, the review step,
  the confirmation page and the admin pages — never as FREE or a bare 0.00.
  A genuinely free method (its `free_above_amount` cleared) still reads FREE.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.ShippingMethod

  describe "cart page" do
    setup :shippable_cart_session

    test "lists and summarises a pay-on-delivery method as paid on delivery",
         %{conn: conn} do
      method = method!("Carrier Rates", pay_on_delivery: true)

      {:ok, view, _html} = live(conn, "/cart")

      price = view |> element("#cart-shipping-price-#{method.uuid}") |> render()
      assert price =~ "Paid on delivery"
      refute price =~ "FREE"

      # The only method is auto-selected on mount.
      summary = view |> element("#cart-summary-shipping") |> render()
      assert summary =~ "Paid on delivery"
      refute summary =~ "FREE"

      assert has_element?(view, "#cart-shipping-pay-on-delivery-note")
    end

    test "a cart still charging a method that became pay-on-delivery is re-priced on mount",
         %{conn: conn, cart: cart} do
      method = method!("Acme Post", price: "5.00")
      {:ok, cart} = Shop.set_cart_shipping(cart, method, nil)
      assert Decimal.equal?(cart.total, Decimal.new("30.00"))

      {:ok, _} = Shop.update_shipping_method(method, %{"pay_on_delivery" => "true"})

      {:ok, view, _html} = live(conn, "/cart")

      assert view |> element("#cart-summary-shipping") |> render() =~ "Paid on delivery"
      assert has_element?(view, "#cart-shipping-pay-on-delivery-note")
      assert view |> element("#cart-summary-total") |> render() =~ "25.00"
      refute view |> element("#cart-summary-total") |> render() =~ "30.00"
    end

    test "a method over its free threshold still reads FREE", %{conn: conn} do
      method = method!("Free Over 10", price: "5.00", free_above_amount: "10.00")

      {:ok, view, _html} = live(conn, "/cart")

      price = view |> element("#cart-shipping-price-#{method.uuid}") |> render()
      assert price =~ "FREE"
      refute price =~ "Paid on delivery"

      assert view |> element("#cart-summary-shipping") |> render() =~ "FREE"
      refute has_element?(view, "#cart-shipping-pay-on-delivery-note")
    end
  end

  describe "checkout page" do
    setup :shippable_cart_session

    test "shipping step, review and summary show paid on delivery", %{conn: conn} do
      PhoenixKit.Settings.update_setting_with_module(
        "shop_shipping_selection_position",
        "checkout",
        "shop"
      )

      method = method!("Carrier Rates", pay_on_delivery: true, countries: ["EE"])

      {:ok, view, _html} = live(conn, "/checkout")

      view |> fill_billing_form(country: "EE") |> render_change()
      view |> element("button[phx-click='proceed_to_review']") |> render_click()

      option = view |> element("#checkout-shipping-method-#{method.uuid}") |> render()
      assert option =~ "Paid on delivery"
      refute option =~ "FREE"

      view
      |> element("#checkout-shipping-method-#{method.uuid} input[type='radio']")
      |> render_click()

      view |> element("#checkout-shipping-continue") |> render_click()

      assert has_element?(view, "button[phx-click='confirm_order']")

      review = view |> element("#checkout-review-shipping-price") |> render()
      assert review =~ "Paid on delivery"
      refute review =~ "FREE"

      summary = view |> element("#checkout-summary-shipping") |> render()
      assert summary =~ "Paid on delivery"
      refute summary =~ "FREE"

      assert has_element?(view, "#checkout-shipping-pay-on-delivery-note")
    end

    test "a cart still charging a method that became pay-on-delivery is re-priced on mount",
         %{conn: conn, cart: cart} do
      method = method!("Acme Post", price: "5.00")
      {:ok, _cart} = Shop.set_cart_shipping(cart, method, nil)

      {:ok, _} = Shop.update_shipping_method(method, %{"pay_on_delivery" => "true"})

      {:ok, view, _html} = live(conn, "/checkout")

      assert view |> element("#checkout-summary-shipping") |> render() =~ "Paid on delivery"
      assert has_element?(view, "#checkout-shipping-pay-on-delivery-note")
      assert view |> element("#checkout-summary-total") |> render() =~ "25.00"
      refute view |> element("#checkout-summary-total") |> render() =~ "30.00"
    end

    test "a free method still reads FREE on the shipping step", %{conn: conn} do
      PhoenixKit.Settings.update_setting_with_module(
        "shop_shipping_selection_position",
        "checkout",
        "shop"
      )

      method =
        method!("Free Over 10", price: "5.00", free_above_amount: "10.00", countries: ["EE"])

      {:ok, view, _html} = live(conn, "/checkout")

      view |> fill_billing_form(country: "EE") |> render_change()
      view |> element("button[phx-click='proceed_to_review']") |> render_click()

      option = view |> element("#checkout-shipping-method-#{method.uuid}") |> render()
      assert option =~ "FREE"
      refute option =~ "Paid on delivery"
    end
  end

  describe "order confirmation page" do
    test "the shipping line reads paid on delivery, not 0.00", %{conn: conn} do
      session_id = "pod-complete-#{System.unique_integer([:positive])}"
      method = method!("Carrier Rates", pay_on_delivery: true)

      {:ok, cart} = Shop.create_cart(session_id: session_id)
      {:ok, cart} = Shop.add_to_cart(cart, physical_product!(), 1)
      {:ok, cart} = Shop.set_cart_shipping(cart, method, "EE")

      {:ok, order} =
        Shop.convert_cart_to_order(cart, billing_data: complete_billing("EE", "pod-complete"))

      conn =
        Plug.Test.init_test_session(conn, %{
          "shop_session_id" => session_id,
          "shop_session_trusted" => true
        })

      {:ok, view, _html} = live(conn, "/checkout/complete/#{order.uuid}")

      assert view |> element("#order-line-shipping") |> render() =~ "Paid on delivery"
      assert has_element?(view, "#order-shipping-pay-on-delivery-note")
    end
  end

  describe "user order details page" do
    test "the shipping line says paid on delivery once", %{conn: conn} do
      PhoenixKit.Settings.update_boolean_setting_with_module("billing_enabled", true, "billing")

      method = method!("Carrier Rates", pay_on_delivery: true, description: "Branch pickup")

      {:ok, cart} =
        Shop.create_cart(session_id: "pod-details-#{System.unique_integer([:positive])}")

      {:ok, cart} = Shop.add_to_cart(cart, physical_product!(), 1)
      {:ok, cart} = Shop.set_cart_shipping(cart, method, "EE")

      {:ok, order} =
        Shop.convert_cart_to_order(cart, billing_data: complete_billing("EE", "pod-details"))

      conn = put_test_scope(conn, fake_scope(user_uuid: order.user_uuid))

      {:ok, view, _html} = live(conn, "/dashboard/orders/#{order.uuid}")

      line = view |> element("#order-line-shipping") |> render()
      assert line =~ "Branch pickup"
      assert length(String.split(line, ~r/paid on delivery/i)) == 2
      assert has_element?(view, "#order-shipping-pay-on-delivery-note")
    end
  end

  describe "admin" do
    setup %{conn: conn} do
      %{conn: put_test_scope(conn, fake_scope())}
    end

    test "the form's checkbox stores the flag and zeroes the price", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")

      assert has_element?(view, "input[type='checkbox'][name='shipping_method[pay_on_delivery]']")

      view
      |> form("form", %{
        "shipping_method" => %{
          "name" => "Acme Post",
          "price" => "3.00",
          "pay_on_delivery" => "true"
        }
      })
      |> render_submit()

      method = Enum.find(Shop.list_shipping_methods(), &(&1.name == "Acme Post"))

      assert ShippingMethod.pay_on_delivery?(method)
      assert Decimal.equal?(method.price, Decimal.new("0"))
    end

    test "checking the box disables the price and threshold inputs", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")

      # One required marker while editable (core adds it), none while locked.
      assert price_label_asterisks(view) == 1

      assert has_element?(view, "input[name='shipping_method[price]'][required]")
      refute has_element?(view, "input[name='shipping_method[price]'][disabled]")

      view
      |> form("form", %{
        "shipping_method" => %{
          "name" => "Acme Post",
          "price" => "3.00",
          "pay_on_delivery" => "true"
        }
      })
      |> render_change()

      assert has_element?(view, "input[name='shipping_method[price]'][disabled]")
      refute has_element?(view, "input[name='shipping_method[price]'][required]")
      assert has_element?(view, "input[name='shipping_method[free_above_amount]'][disabled]")
      assert price_label_asterisks(view) == 0
    end

    test "the activity log records the flag", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")

      view
      |> form("form", %{
        "shipping_method" => %{
          "name" => "Logged Carrier",
          "price" => "0",
          "pay_on_delivery" => "true"
        }
      })
      |> render_submit()

      method = Enum.find(Shop.list_shipping_methods(), &(&1.name == "Logged Carrier"))

      assert_activity_logged("shop.shipping_method_created",
        resource_uuid: method.uuid,
        metadata_has: %{"pay_on_delivery" => true}
      )
    end

    test "the list shows paid on delivery instead of a price", %{conn: conn} do
      method!("Carrier Rates", pay_on_delivery: true)

      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping")

      assert render(view) =~ "Paid on delivery"
    end
  end

  defp price_label_asterisks(view) do
    view
    |> element("label[for='shipping_method_price']")
    |> render()
    |> String.graphemes()
    |> Enum.count(&(&1 == "*"))
  end

  defp shippable_cart_session(%{conn: conn}) do
    session_id = "pod-lv-#{System.unique_integer([:positive])}"

    {:ok, cart} = Shop.create_cart(session_id: session_id)
    {:ok, cart} = Shop.add_to_cart(cart, physical_product!(), 1)

    %{conn: Plug.Test.init_test_session(conn, %{"shop_session_id" => session_id}), cart: cart}
  end

  defp physical_product! do
    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Pay On Delivery Widget"},
        "price" => Decimal.new("25.00"),
        "status" => "active",
        "currency" => "USD",
        "product_type" => "physical",
        "requires_shipping" => true,
        "weight_grams" => 500
      })

    product
  end

  defp method!(name, opts) do
    {:ok, method} =
      Shop.create_shipping_method(%{
        # The name drives the unique slug.
        "name" => "#{name} #{System.unique_integer([:positive])}",
        "price" => Keyword.get(opts, :price, "0"),
        "free_above_amount" => Keyword.get(opts, :free_above_amount),
        "description" => Keyword.get(opts, :description),
        "pay_on_delivery" => Keyword.get(opts, :pay_on_delivery, false),
        "countries" => Keyword.get(opts, :countries, []),
        "active" => true
      })

    method
  end
end
