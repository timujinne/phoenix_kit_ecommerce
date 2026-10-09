defmodule PhoenixKitEcommerce.Shipping.CompatShopTest do
  use ExUnit.Case, async: true

  # The shim core still calls must carry every public shipping function.
  test "PhoenixKit.Modules.Shop delegates the calculated shipping API" do
    functions = [
      shipping_parcel_defaults: 0,
      update_shipping_parcel_defaults: 1,
      cart_parcels: 1,
      cart_declared_value: 1,
      cart_shipping_destination: 1,
      set_cart_shipping_destination: 2,
      build_cart_rate_request: 1,
      quote_cart_shipping: 1,
      quote_cart_shipping: 2,
      shipping_quote_status: 1,
      cart_shipping_quote: 1,
      shipping_quote_blocks_checkout?: 1,
      shipping_quote_snapshot: 1,
      shipping_quote_snapshot: 2,
      present_shipping_method: 2,
      refresh_pay_on_delivery_shipping: 1
    ]

    shim = PhoenixKit.Modules.Shop

    for {name, arity} <- functions do
      assert function_exported?(shim, name, arity), "#{name}/#{arity} is not delegated"
      assert function_exported?(PhoenixKitEcommerce, name, arity)
    end
  end

  test "the shim answers like the module for a call that needs no database" do
    assert PhoenixKit.Modules.Shop.cart_shipping_destination(%PhoenixKitEcommerce.Cart{
             metadata: %{}
           }) == nil
  end
end
