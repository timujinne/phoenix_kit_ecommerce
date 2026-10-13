defmodule PhoenixKitEcommerce.ShippingPayOnDeliveryTest do
  @moduledoc """
  A pay-on-delivery shipping method (`metadata["pay_on_delivery"]`): the shop
  charges nothing for it and the buyer pays the carrier's own rates on
  delivery. Its 0 price must never read as free shipping — not in what the
  storefront is handed, not in auto-selection, not on the order.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.PriceDisplay
  alias PhoenixKitEcommerce.ShippingMethod

  setup do
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

    {:ok, cart} = Shop.create_cart(session_id: "pod-#{System.unique_integer([:positive])}")
    {:ok, cart} = Shop.add_to_cart(cart, product, 1)

    %{cart: cart}
  end

  describe "present_shipping_method/2" do
    test "a pay-on-delivery method is flagged and never free", %{cart: cart} do
      method = method!("Carrier Rates", pay_on_delivery: true)

      assert %{pay_on_delivery?: true, free?: false} = Shop.present_shipping_method(cart, method)
    end

    # The changeset clears the threshold, so only a row written around it
    # (SQL, an import) can carry both - the guard is what keeps it off FREE.
    test "a flagged method that still carries a threshold is never free", %{cart: cart} do
      method = %ShippingMethod{
        price: Decimal.new("0"),
        free_above_amount: Decimal.new("10.00"),
        metadata: %{"pay_on_delivery" => true}
      }

      assert %{pay_on_delivery?: true, free?: false} = Shop.present_shipping_method(cart, method)
    end

    test "a method whose free threshold the cart clears is still free", %{cart: cart} do
      method = method!("Free Over 10", price: "5.00", free_above_amount: "10.00")

      assert %{pay_on_delivery?: false, free?: true} = Shop.present_shipping_method(cart, method)
    end
  end

  describe "auto_select_shipping_method/2" do
    test "a pay-on-delivery method is not picked as the cheapest over a priced one",
         %{cart: cart} do
      pod = method!("Carrier Rates", pay_on_delivery: true)
      courier = method!("Courier", price: "5.00")

      assert {:ok, cart} = Shop.auto_select_shipping_method(cart, [pod, courier])
      assert cart.shipping_method_uuid == courier.uuid
    end

    test "it is still picked when it is the only method", %{cart: cart} do
      pod = method!("Carrier Rates", pay_on_delivery: true)

      assert {:ok, cart} = Shop.auto_select_shipping_method(cart, [pod])
      assert cart.shipping_method_uuid == pod.uuid
    end
  end

  describe "refresh_pay_on_delivery_shipping/1" do
    test "re-prices a cart still charging a method that became pay-on-delivery",
         %{cart: cart} do
      method = method!("Acme Post", price: "5.00")
      {:ok, cart} = Shop.set_cart_shipping(cart, method, "EE")
      assert Decimal.equal?(cart.shipping_amount, Decimal.new("5.00"))

      {:ok, _} = Shop.update_shipping_method(method, %{"pay_on_delivery" => "true"})
      stale = Shop.get_cart(cart.uuid)
      refute PriceDisplay.cart_shipping_pay_on_delivery?(stale)

      assert {:ok, refreshed} = Shop.refresh_pay_on_delivery_shipping(stale)
      assert Decimal.equal?(refreshed.shipping_amount, Decimal.new("0"))
      assert Decimal.equal?(refreshed.total, Decimal.sub(stale.total, Decimal.new("5.00")))
      assert PriceDisplay.cart_shipping_pay_on_delivery?(refreshed)

      persisted = Shop.get_cart(cart.uuid)
      assert Decimal.equal?(persisted.shipping_amount, Decimal.new("0"))
    end

    # A row flagged around the changeset keeps its price; recalculating
    # stores the same amount again, so it must not count as stale or every
    # page view would lock, write and broadcast.
    test "leaves a cart alone when the flagged method still has a price", %{cart: cart} do
      method = method!("Imported Carrier", price: "5.00")
      {:ok, _cart} = Shop.set_cart_shipping(cart, method, "EE")

      ShippingMethod
      |> where([m], m.uuid == ^method.uuid)
      |> Repo.update_all(set: [metadata: %{"pay_on_delivery" => true}])

      cart = Shop.get_cart(cart.uuid)
      assert ShippingMethod.pay_on_delivery?(cart.shipping_method)
      PhoenixKitEcommerce.Events.subscribe_to_cart(cart)

      assert {:ok, ^cart} = Shop.refresh_pay_on_delivery_shipping(cart)
      refute_receive {:cart_updated, _}
    end

    test "leaves a cart with nothing stale untouched", %{cart: cart} do
      method = method!("Courier", price: "5.00")
      {:ok, cart} = Shop.set_cart_shipping(cart, method, "EE")

      assert {:ok, ^cart} = Shop.refresh_pay_on_delivery_shipping(cart)
    end
  end

  describe "PriceDisplay.cart_shipping_pay_on_delivery?/1" do
    test "only while the selected method is flagged AND the stored amount is 0" do
      pod = %ShippingMethod{uuid: "m", metadata: %{"pay_on_delivery" => true}}
      cart = %{shipping_method_uuid: "m", shipping_method: pod, shipping_amount: Decimal.new("0")}

      assert PriceDisplay.cart_shipping_pay_on_delivery?(cart)

      refute PriceDisplay.cart_shipping_pay_on_delivery?(%{
               cart
               | shipping_amount: Decimal.new("5")
             })

      refute PriceDisplay.cart_shipping_pay_on_delivery?(%{cart | shipping_method_uuid: nil})

      refute PriceDisplay.cart_shipping_pay_on_delivery?(%{
               cart
               | shipping_method: %ShippingMethod{uuid: "m"}
             })
    end
  end

  describe "PriceDisplay shipping line description" do
    test "line_description/1 strips exactly what the stored description added" do
      stored = PriceDisplay.pay_on_delivery_line_description("Branch pickup")
      assert stored == "Branch pickup — Carrier rates, paid on delivery"

      line = %{"description" => stored, "pay_on_delivery" => true}
      assert PriceDisplay.line_description(line) == "Branch pickup"

      bare = PriceDisplay.pay_on_delivery_line_description(nil)
      assert bare == "Carrier rates, paid on delivery"
      assert PriceDisplay.line_description(%{line | "description" => bare}) == ""

      assert PriceDisplay.line_description(%{"description" => stored}) == stored
    end
  end

  describe "convert_cart_to_order/2" do
    test "the shipping line and the order say the carrier is paid on delivery",
         %{cart: cart} do
      method = method!("Acme Post", pay_on_delivery: true, description: "Branch pickup")
      {:ok, cart} = Shop.set_cart_shipping(cart, method, "EE")

      assert {:ok, order} =
               Shop.convert_cart_to_order(cart, billing_data: complete_billing("EE", "pod"))

      line = Enum.find(order.line_items, &(&1["type"] == "shipping"))

      assert line["pay_on_delivery"] == true
      assert line["description"] == "Branch pickup — Carrier rates, paid on delivery"
      assert Decimal.equal?(Decimal.new(line["total"]), Decimal.new("0"))
      assert order.metadata["shipping_pay_on_delivery"] == true
      assert order.metadata["shipping_skipped"] == false
      assert Decimal.equal?(order.total, Decimal.add(order.subtotal, order.tax_amount))
    end

    test "an ordinary method's line and order carry the flag as false", %{cart: cart} do
      method = method!("Courier", price: "5.00")
      {:ok, cart} = Shop.set_cart_shipping(cart, method, "EE")

      assert {:ok, order} =
               Shop.convert_cart_to_order(cart, billing_data: complete_billing("EE", "pod"))

      line = Enum.find(order.line_items, &(&1["type"] == "shipping"))

      assert line["pay_on_delivery"] == false
      assert line["description"] == ""
      assert order.metadata["shipping_pay_on_delivery"] == false
    end
  end

  defp method!(name, opts) do
    attrs =
      %{
        "name" => "#{name} #{System.unique_integer([:positive])}",
        "price" => Keyword.get(opts, :price, "0"),
        "free_above_amount" => Keyword.get(opts, :free_above_amount),
        "description" => Keyword.get(opts, :description),
        "pay_on_delivery" => Keyword.get(opts, :pay_on_delivery, false),
        "active" => true
      }

    {:ok, method} = Shop.create_shipping_method(attrs)
    method
  end
end
