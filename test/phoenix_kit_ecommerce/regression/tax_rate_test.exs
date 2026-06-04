defmodule PhoenixKitEcommerce.Regression.TaxRateTest do
  @moduledoc """
  Regression guard for the cart->order tax_rate bug.

  `build_order_attrs/3` previously hardcoded `"tax_rate" => Decimal.new(0)`,
  so converted orders always recorded a 0% tax rate even when billing tax
  was enabled. The fix passes `get_tax_rate(cart)` instead, which derives
  the rate from the billing settings (single source of truth) whenever the
  cart has a `shipping_country`.

  This test drives the real public `convert_cart_to_order/2` path end to
  end (product -> cart -> shipping country -> guest checkout -> order) and
  asserts the resulting order's `tax_rate` is the applied fraction, not 0.

  It MUST fail if the hardcoded `Decimal.new(0)` is reinstated.

  Touches global billing settings via `PhoenixKit.Settings`, so it runs
  `async: false`.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitEcommerce, as: Shop

  # 8.625% expressed as the fraction billing computes (8.625 / 100).
  @rate_percent "8.625"
  @rate_fraction Decimal.new("0.08625")
  # The billing `orders.tax_rate` column has scale 4, so the stored value
  # is the fraction rounded to 4 decimal places (0.08625 -> 0.0863).
  @stored_rate Decimal.new("0.0863")

  setup do
    # Enable tax at a distinctive, non-round rate so a hardcoded 0 (or any
    # accidental constant) is unambiguously distinguishable.
    Settings.update_setting("billing_tax_enabled", "true")
    Settings.update_setting("billing_default_tax_rate", @rate_percent)

    on_exit(fn ->
      Settings.update_setting("billing_tax_enabled", "false")
      Settings.update_setting("billing_default_tax_rate", "0")
    end)

    :ok
  end

  defp create_product do
    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Tax Widget"},
        "price" => Decimal.new("100.00"),
        "status" => "active",
        "currency" => "USD"
      })

    product
  end

  defp create_shipping_method do
    {:ok, method} =
      Shop.create_shipping_method(%{
        "name" => "Standard",
        "price" => Decimal.new("0"),
        "active" => true
      })

    method
  end

  test "convert_cart_to_order records the billing tax_rate, not zero" do
    # Sanity check: billing helper resolves the configured rate.
    assert Decimal.equal?(Billing.get_tax_rate(), @rate_fraction)

    product = create_product()
    method = create_shipping_method()

    {:ok, cart} = Shop.create_cart(session_id: "tax-regression-#{System.unique_integer()}")
    {:ok, cart} = Shop.add_to_cart(cart, product, 2)

    # Setting a US shipping country is what makes get_tax_rate/1 apply the
    # billing rate (it returns 0 for a nil shipping_country).
    {:ok, cart} = Shop.set_cart_shipping(cart, method, "US")

    assert cart.shipping_country == "US"

    {:ok, order} =
      Shop.convert_cart_to_order(cart,
        billing_data: %{
          "email" => "tax-guest-#{System.unique_integer([:positive])}@example.com",
          "country" => "US"
        }
      )

    order = Billing.get_order_by_uuid(order.uuid)

    # The load-bearing assertion: a reverted fix would store Decimal.new(0).
    refute Decimal.equal?(order.tax_rate, Decimal.new(0))

    # And it equals the applied fraction derived from billing settings
    # (stored at the column's 4-decimal scale).
    assert Decimal.equal?(order.tax_rate, @stored_rate)

    # tax_amount must be consistent with the recalculated cart's tax_amount
    # (subtotal 200.00 * 0.08625 = 17.25), propagated onto the order.
    assert Decimal.equal?(cart.tax_amount, Decimal.new("17.25"))
    assert Decimal.equal?(order.tax_amount, Decimal.new("17.25"))
  end

  test "tax_rate is zero when billing tax is disabled" do
    # Counterpart: with tax disabled the same flow legitimately yields 0,
    # proving the non-zero result above comes from the setting, not noise.
    Settings.update_setting("billing_tax_enabled", "false")

    product = create_product()
    method = create_shipping_method()

    {:ok, cart} = Shop.create_cart(session_id: "tax-off-#{System.unique_integer()}")
    {:ok, cart} = Shop.add_to_cart(cart, product, 1)
    {:ok, cart} = Shop.set_cart_shipping(cart, method, "US")

    {:ok, order} =
      Shop.convert_cart_to_order(cart,
        billing_data: %{
          "email" => "tax-off-#{System.unique_integer([:positive])}@example.com",
          "country" => "US"
        }
      )

    order = Billing.get_order_by_uuid(order.uuid)
    assert Decimal.equal?(order.tax_rate, Decimal.new(0))
  end
end
