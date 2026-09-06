defmodule PhoenixKitEcommerce.ShippingFxTest do
  @moduledoc """
  Shipping methods are admin-configured in BASE currency (their price and
  `free_above_amount` threshold — spec §4.7, §2.11); a cart's `subtotal` is
  its own, potentially non-base, display-currency snapshot (§4.4). Before
  this fix a EUR cart's converted subtotal was compared straight against a
  USD threshold and charged the USD rate as if both were the same number.
  `calculate_shipping/3` now round-trips through base: convert the
  subtotal TO base for `calculate_method_shipping/4` (§12.3 — unchanged,
  knows nothing about display currency), then convert the resulting cost
  back to the cart's currency (§10.14/§10.16 — the same one-conversion
  discipline as `snapshot_unit_price/2`, just inverted).
  """

  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKitBilling.Currency
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Cart

  defp lang do
    PhoenixKitEcommerce.SlugResolver.normalize_language_public(
      PhoenixKitEcommerce.Translations.default_language()
    )
  end

  defp product_attrs(extra) do
    n = System.unique_integer([:positive])

    Map.merge(
      %{
        "title" => %{"en" => "Consulting #{n}", lang() => "Consulting #{n}"},
        "slug" => %{lang() => "consulting-#{n}"},
        "price" => Decimal.new("138.00"),
        "status" => "active",
        "currency" => "USD"
      },
      extra
    )
  end

  defp method_attrs(extra) do
    Map.merge(
      %{
        "name" => "M#{System.unique_integer([:positive])}",
        "price" => Decimal.new("10.00"),
        "active" => true
      },
      extra
    )
  end

  setup do
    PhoenixKit.Cache.clear(:billing_currencies)
    Currency.put_request_currency(nil)
    on_exit(fn -> Currency.put_request_currency(nil) end)

    Repo.delete_all(PhoenixKitBilling.Currency)

    {:ok, _usd} =
      PhoenixKitBilling.create_currency(%{
        code: "USD",
        name: "Dollar",
        symbol: "$",
        is_default: true,
        exchange_rate: "1.0"
      })

    {:ok, _eur} =
      PhoenixKitBilling.create_currency(%{
        code: "EUR",
        name: "Euro",
        symbol: "€",
        exchange_rate: "0.909091"
      })

    :ok
  end

  defp eur_cart_with_product! do
    Currency.put_request_currency("EUR")
    {:ok, cart} = Shop.create_cart(session_id: "s-#{System.unique_integer([:positive])}")
    {:ok, product} = Shop.create_product(product_attrs(%{}))
    {:ok, cart} = Shop.add_to_cart(cart, product, 1)
    assert Decimal.equal?(cart.subtotal, Decimal.new("125.45"))
    cart
  end

  test "$10 free above $130 (base): a EUR cart's $138 product converts back to base for the threshold check" do
    cart = eur_cart_with_product!()

    {:ok, method} =
      Shop.create_shipping_method(method_attrs(%{"free_above_amount" => Decimal.new("130.00")}))

    {:ok, cart} = Shop.set_cart_shipping(cart, method, "US")

    # Comparing the DISPLAY subtotal (125.45) straight against the 130
    # threshold would wrongly deny free shipping; the underlying base
    # amount (138.00) clears it.
    assert Decimal.equal?(cart.shipping_amount, Decimal.new("0"))
  end

  test "threshold unreachable: the $10 base rate converts to €9.09" do
    cart = eur_cart_with_product!()

    {:ok, method} =
      Shop.create_shipping_method(method_attrs(%{"free_above_amount" => Decimal.new("1000.00")}))

    {:ok, cart} = Shop.set_cart_shipping(cart, method, "US")

    assert Decimal.equal?(cart.shipping_amount, Decimal.new("9.09"))
  end

  test "eligibility: a $130 min_order_amount OFFERS and auto-selects for a EUR cart holding the $138 product" do
    cart = eur_cart_with_product!()

    {:ok, method} =
      Shop.create_shipping_method(method_attrs(%{"min_order_amount" => Decimal.new("130.00")}))

    # 125.45 (the EUR display subtotal) is BELOW 130 — comparing on the
    # display amount would wrongly deny this method; 138.00 base clears it.
    available = Shop.get_available_shipping_methods(cart)
    assert Enum.any?(available, &(&1.uuid == method.uuid))

    {:ok, cart} = Shop.auto_select_shipping_method(cart, available)
    assert cart.shipping_method_uuid == method.uuid
  end

  test "eligibility: a $130 max_order_amount EXCLUDES a EUR cart holding the $138 product" do
    cart = eur_cart_with_product!()

    {:ok, method} =
      Shop.create_shipping_method(method_attrs(%{"max_order_amount" => Decimal.new("130.00")}))

    # 125.45 (display) is still under 130 and would wrongly pass; 138.00
    # base is over it and must be excluded — from the offered list, and
    # therefore from auto-selection too (which only ranks what it's given).
    available = Shop.get_available_shipping_methods(cart)
    refute Enum.any?(available, &(&1.uuid == method.uuid))

    {:ok, cart} = Shop.auto_select_shipping_method(cart, available)
    refute cart.shipping_method_uuid == method.uuid
  end

  test "§12.3: all four addends non-zero on a EUR cart agree with the total identity" do
    cart = eur_cart_with_product!()

    {:ok, cart} =
      cart
      |> Cart.changeset(%{"discount_amount" => "5.00"})
      |> Repo.update()

    PhoenixKit.Settings.update_setting("billing_tax_enabled", "true")
    PhoenixKit.Settings.update_setting("billing_default_tax_rate", "20")

    {:ok, method} =
      Shop.create_shipping_method(method_attrs(%{"free_above_amount" => Decimal.new("1000.00")}))

    {:ok, cart} = Shop.set_cart_shipping(cart, method, "US")

    assert Decimal.equal?(cart.subtotal, Decimal.new("125.45"))
    assert Decimal.equal?(cart.shipping_amount, Decimal.new("9.09"))
    assert Decimal.equal?(cart.discount_amount, Decimal.new("5.00"))
    # round((125.45 - 5.00) * 0.20, 2) = round(24.09, 2) = 24.09
    assert Decimal.equal?(cart.tax_amount, Decimal.new("24.09"))
    # 125.45 + 9.09 + 24.09 - 5.00 = 153.63
    assert Decimal.equal?(cart.total, Decimal.new("153.63"))

    assert Decimal.equal?(
             cart.subtotal
             |> Decimal.add(cart.shipping_amount)
             |> Decimal.add(cart.tax_amount)
             |> Decimal.sub(cart.discount_amount),
             cart.total
           )
  end
end
