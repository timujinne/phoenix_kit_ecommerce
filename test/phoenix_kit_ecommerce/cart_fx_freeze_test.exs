defmodule PhoenixKitEcommerce.CartFxFreezeTest do
  @moduledoc """
  Cart currency/base/rate freeze at creation, and its two consequences
  (per-domain-currency spec §4.4, §12.2): a line snapshots in the cart's
  frozen currency at the cart's frozen rate — never a fresh table lookup —
  and only emptying the cart (never a plain add/remove with items left
  over) refreshes the rate.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKitBilling.Currency
  alias PhoenixKitEcommerce, as: Shop

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
        "price" => Decimal.new("40.00"),
        "status" => "active",
        "currency" => "USD"
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

  test "a cart created under a EUR request freezes currency, base and rate; lines snapshot in cart currency" do
    Currency.put_request_currency("EUR")
    {:ok, cart} = Shop.create_cart(session_id: "s-#{System.unique_integer([:positive])}")
    assert %{currency: "EUR", base_currency: "USD"} = cart
    assert Decimal.equal?(cart.exchange_rate, Decimal.new("0.909091"))

    {:ok, product} = Shop.create_product(product_attrs(%{"price" => Decimal.new("138.00")}))
    {:ok, cart} = Shop.add_to_cart(cart, product, 1)
    [item] = cart.items
    assert Decimal.equal?(item.unit_price, Decimal.new("125.45"))
    assert Decimal.equal?(item.base_unit_price, Decimal.new("138.00"))
    assert item.currency == "EUR"
    assert Decimal.equal?(cart.subtotal, Decimal.new("125.45"))
  end

  test "the frozen rate wins over a later table change on a non-empty cart (§4.4)" do
    Currency.put_request_currency("EUR")
    {:ok, cart} = Shop.create_cart(session_id: "s-#{System.unique_integer([:positive])}")
    {:ok, p} = Shop.create_product(product_attrs(%{"price" => Decimal.new("138.00")}))
    {:ok, cart} = Shop.add_to_cart(cart, p, 1)

    {:ok, _} =
      PhoenixKitBilling.update_currency(PhoenixKitBilling.get_currency_by_code("EUR"), %{
        exchange_rate: "0.95"
      })

    {:ok, p2} = Shop.create_product(product_attrs(%{"price" => Decimal.new("100.00")}))
    {:ok, cart} = Shop.add_to_cart(cart, p2, 1)

    assert Decimal.equal?(cart.exchange_rate, Decimal.new("0.909091"))
    assert Enum.any?(cart.items, &Decimal.equal?(&1.unit_price, Decimal.new("90.91")))
  end

  test "emptying the cart refreshes the rate; nothing else does" do
    Currency.put_request_currency("EUR")
    {:ok, cart} = Shop.create_cart(session_id: "s-#{System.unique_integer([:positive])}")
    {:ok, p} = Shop.create_product(product_attrs(%{"price" => Decimal.new("138.00")}))
    {:ok, cart} = Shop.add_to_cart(cart, p, 1)
    assert Decimal.equal?(cart.exchange_rate, Decimal.new("0.909091"))

    {:ok, _} =
      PhoenixKitBilling.update_currency(PhoenixKitBilling.get_currency_by_code("EUR"), %{
        exchange_rate: "0.95"
      })

    [item] = cart.items
    {:ok, cart_after_removal} = Shop.remove_from_cart(item)

    # The cart is empty now — the removal itself refreshed the rate to the
    # table's current value, still under the same EUR request override.
    assert cart_after_removal.items_count == 0
    assert Decimal.equal?(cart_after_removal.exchange_rate, Decimal.new("0.95"))
    assert cart_after_removal.currency == "EUR"
    assert cart_after_removal.base_currency == "USD"

    # Adding a new line now snapshots at the REFRESHED rate, not the
    # original 0.909091 — proving the refresh actually took, not just the
    # column value.
    {:ok, p2} = Shop.create_product(product_attrs(%{"price" => Decimal.new("100.00")}))
    {:ok, cart_after_readd} = Shop.add_to_cart(cart_after_removal, p2, 1)
    [new_item] = cart_after_readd.items
    assert Decimal.equal?(new_item.unit_price, Decimal.new("95.00"))
  end

  test "a new line still converts at the frozen rate after the cart's currency is disabled (§12.2)" do
    # Regression, traced by review through Currency.present/3: calling
    # present(amount, cart.currency, rate: cart.exchange_rate) did NOT
    # fully bypass the currency table, because present/3 still
    # re-resolved its TARGET currency live on every call via
    # resolve_display_currency/1. Disabling (not deleting, not changing
    # the rate of) the cart's own currency made that resolution
    # substitute the base as present/3's target, which then hit
    # present/3's `target.code == base.code` early return and skipped
    # conversion entirely for any line added after the disable — a base
    # amount silently mislabeled as the cart's currency. Fixed in
    # present/3 itself (phoenix_kit_billing feature/currency-e1): with
    # `:rate` given, the code is looked up only for decimal_places,
    # never through resolve_display_currency/1 (§12.1 — present/3 stays
    # the one conversion implementation; this test exercises it through
    # the cart, not a second one in this package).
    Currency.put_request_currency("EUR")
    {:ok, cart} = Shop.create_cart(session_id: "s-#{System.unique_integer([:positive])}")
    assert Decimal.equal?(cart.exchange_rate, Decimal.new("0.909091"))

    {:ok, p1} = Shop.create_product(product_attrs(%{"price" => Decimal.new("138.00")}))
    {:ok, cart} = Shop.add_to_cart(cart, p1, 1)
    assert Decimal.equal?(hd(cart.items).unit_price, Decimal.new("125.45"))

    {:ok, _} =
      PhoenixKitBilling.update_currency(PhoenixKitBilling.get_currency_by_code("EUR"), %{
        enabled: false
      })

    {:ok, p2} = Shop.create_product(product_attrs(%{"price" => Decimal.new("100.00")}))
    {:ok, cart} = Shop.add_to_cart(cart, p2, 1)

    new_item = Enum.find(cart.items, &(&1.product_uuid == p2.uuid))

    # Still converted at the FROZEN rate (0.909091) — 90.91, not left as
    # the raw base amount (100.00) the bug produced.
    assert Decimal.equal?(new_item.unit_price, Decimal.new("90.91"))
    assert Decimal.equal?(new_item.base_unit_price, Decimal.new("100.00"))
    assert new_item.currency == "EUR"
  end

  test "no request currency -> base cart, rate 1.0, unit_price == product price (unchanged behaviour)" do
    Currency.put_request_currency(nil)
    {:ok, cart} = Shop.create_cart(session_id: "s-#{System.unique_integer([:positive])}")
    assert %{currency: "USD", base_currency: "USD"} = cart
    assert Decimal.equal?(cart.exchange_rate, Decimal.new("1.0"))

    {:ok, product} = Shop.create_product(product_attrs(%{"price" => Decimal.new("40.00")}))
    {:ok, cart} = Shop.add_to_cart(cart, product, 1)
    [item] = cart.items
    assert Decimal.equal?(item.unit_price, Decimal.new("40.00"))
    assert Decimal.equal?(item.base_unit_price, Decimal.new("40.00"))
  end
end
