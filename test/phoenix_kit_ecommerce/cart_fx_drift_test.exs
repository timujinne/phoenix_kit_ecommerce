defmodule PhoenixKitEcommerce.CartFxDriftTest do
  @moduledoc "§4.4: drift of a cart's frozen rate against the live one, and the shopper's EXPLICIT reprice."
  use PhoenixKitEcommerce.DataCase, async: false
  alias PhoenixKitBilling.Currency
  alias PhoenixKitEcommerce, as: Shop

  defp lang,
    do:
      PhoenixKitEcommerce.SlugResolver.normalize_language_public(
        PhoenixKitEcommerce.Translations.default_language()
      )

  setup do
    PhoenixKit.Cache.clear(:billing_currencies)
    Currency.put_request_currency(nil)
    on_exit(fn -> Currency.put_request_currency(nil) end)
    Repo.delete_all(PhoenixKitBilling.Currency)
    PhoenixKit.Settings.update_setting("fx_rate_drift_alert_pct", "5")

    {:ok, _} =
      PhoenixKitBilling.create_currency(%{
        code: "USD",
        name: "Dollar",
        symbol: "$",
        is_default: true,
        exchange_rate: "1.0"
      })

    {:ok, eur} =
      PhoenixKitBilling.create_currency(%{
        code: "EUR",
        name: "Euro",
        symbol: "€",
        exchange_rate: "0.909091"
      })

    n = System.unique_integer([:positive])

    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Consulting #{n}", lang() => "Consulting #{n}"},
        "slug" => %{lang() => "drift-#{n}"},
        "price" => Decimal.new("138.00"),
        "compare_at_price" => Decimal.new("180.00"),
        "status" => "active",
        "currency" => "USD"
      })

    Currency.put_request_currency("EUR")
    {:ok, cart} = Shop.create_cart(session_id: "drift-#{n}")
    {:ok, cart} = Shop.add_to_cart(cart, product, 2)
    Currency.put_request_currency(nil)
    %{eur: eur, cart: cart, product: product}
  end

  # Returns the UPDATED struct — a caller that reprices twice must thread
  # it through rather than reusing the original: `update_currency/2`'s
  # changeset diffs the new value against the struct it is CALLED with,
  # not against the database, so calling it twice with the same stale
  # struct and a value that happens to equal that struct's original
  # field produces an empty changeset (no perceived change) and silently
  # writes nothing on the second call.
  defp set_rate(eur, rate) do
    {:ok, updated} = PhoenixKitBilling.update_currency(eur, %{exchange_rate: rate})
    updated
  end

  test "no drift at or under the threshold, drift above it", %{cart: cart, eur: eur} do
    assert Shop.cart_rate_drift(cart) == nil
    set_rate(eur, "0.95")
    assert Shop.cart_rate_drift(cart) == nil
    set_rate(eur, "1.0")
    assert %{frozen: frozen, current: current, pct: pct} = Shop.cart_rate_drift(cart)
    assert Decimal.equal?(frozen, Decimal.new("0.909091"))
    assert Decimal.equal?(current, Decimal.new("1.0"))
    assert Decimal.equal?(pct, Decimal.new("10.00"))
    PhoenixKit.Settings.update_setting("fx_rate_drift_alert_pct", "15")
    assert Shop.cart_rate_drift(cart) == nil
  end

  test "a cart in the base currency, or without a frozen rate, never drifts", %{eur: eur} do
    {:ok, usd_cart} =
      Shop.create_cart(session_id: "drift-base-#{System.unique_integer([:positive])}")

    set_rate(eur, "2.0")
    assert Shop.cart_rate_drift(usd_cart) == nil
    assert Shop.cart_rate_drift(%{usd_cart | currency: "EUR", exchange_rate: nil}) == nil
  end

  test "a disabled cart currency is not reported as drift (§6.3 fail-safe must not leak in)", %{
    cart: cart,
    eur: eur
  } do
    {:ok, _} = PhoenixKitBilling.update_currency(eur, %{enabled: false})
    assert Shop.cart_rate_drift(cart) == nil
  end

  test "a non-numeric threshold falls back to 5" do
    PhoenixKit.Settings.update_setting("fx_rate_drift_alert_pct", "lots")
    assert Decimal.equal?(Shop.fx_rate_drift_alert_pct(), Decimal.new("5"))
  end

  test "a plain add never reprices a drifted cart (§4.4: no silent recalculation)", %{
    cart: cart,
    eur: eur,
    product: product
  } do
    set_rate(eur, "1.0")
    {:ok, cart} = Shop.add_to_cart(cart, product, 1)
    assert Decimal.equal?(cart.exchange_rate, Decimal.new("0.909091"))
    assert Enum.all?(cart.items, &Decimal.equal?(&1.unit_price, Decimal.new("125.45")))
  end

  test "refresh_cart_rate/1 re-snapshots every line at the new frozen rate and the totals follow",
       %{
         cart: cart,
         eur: eur
       } do
    set_rate(eur, "1.0")
    assert {:ok, cart} = Shop.refresh_cart_rate(cart)
    assert Decimal.equal?(cart.exchange_rate, Decimal.new("1.0"))
    [item] = cart.items
    assert Decimal.equal?(item.unit_price, Decimal.new("138.00"))
    assert Decimal.equal?(item.base_unit_price, Decimal.new("138.00"))
    assert Decimal.equal?(item.compare_at_price, Decimal.new("180.00"))
    assert Decimal.equal?(item.line_total, Decimal.new("276.00"))
    assert Decimal.equal?(cart.subtotal, Decimal.new("276.00"))
    assert Decimal.equal?(cart.total, Decimal.new("276.00"))
    assert Shop.cart_rate_drift(cart) == nil
  end

  # §4.3.1 known rounding bound: `compare_at_price` has no `base_compare_at_price`
  # column to re-derive from exactly the way `unit_price` re-derives from
  # `base_unit_price` (a new column means a migration, deliberately
  # deferred — the owner's call, not worth it for a crossed-out price).
  # Each reprice therefore inverts it through `to_base/2`'s 2-decimal
  # rounding before reconverting, so REPEATED reprices CAN drift the
  # displayed "was" price by a cent or two against a fresh conversion —
  # but do not always: this pins the COMMON, drift-free case (round-
  # tripping 0.909091 -> 1.0 -> 0.909091 loses nothing here, because the
  # return leg divides by exactly 1.0). See the next test for a pair of
  # rates where the loss actually happens, hard-coded rather than
  # asserted-within-a-tolerance-that-nothing-exercises.
  test "two consecutive reprices on a drift-free pair of rates: both unit_price and compare_at_price land back exactly",
       %{cart: cart, eur: eur} do
    original_compare_at = List.first(cart.items).compare_at_price

    eur = set_rate(eur, "1.0")
    assert {:ok, cart} = Shop.refresh_cart_rate(cart)

    _eur = set_rate(eur, "0.909091")
    assert {:ok, cart} = Shop.refresh_cart_rate(cart)

    [item] = cart.items
    assert Decimal.equal?(cart.exchange_rate, Decimal.new("0.909091"))
    assert Decimal.equal?(item.unit_price, Decimal.new("125.45"))
    assert Decimal.equal?(item.compare_at_price, original_compare_at)
  end

  # §4.3.1 known rounding bound, the LOSSY case: a single reprice whose
  # rates actually make the two-decimal intermediate in the
  # to-base-then-reconvert round trip lose a cent. Base price 6.99 /
  # compare_at 9.99, cart frozen at 0.615, repriced once to 1.13 —
  # `unit_price` re-derives EXACTLY from `base_unit_price` at the new
  # rate (6.99 x 1.13 = 7.8987 -> 7.90, same as a fresh add would
  # compute), but `compare_at_price` round-trips through the frozen
  # 6.14 (9.99 x 0.615 = 6.14385 -> 6.14) inverted back to base (6.14 /
  # 0.615 = 9.98374... -> 9.98, ALREADY off by a cent from the true
  # 9.99) before reconverting (9.98 x 1.13 = 11.2774 -> 11.28). A fresh
  # conversion of the true base compare_at (9.99 x 1.13 = 11.2887 ->
  # 11.29) differs by exactly 0.01 - inside the documented 0.02 bound,
  # and the reason `compare_at_price` is hard-coded here rather than
  # compared with a tolerance against itself: a tolerance nothing
  # exercises passes silently even after a regression, which is exactly
  # what the previous version of this pin (against the drift-free
  # 138.00/180.00/0.909091 fixture) did.
  test "a single reprice on a lossy pair of rates: unit_price exact, compare_at_price hard-coded and bounded against a fresh conversion" do
    n = System.unique_integer([:positive])

    {:ok, eur} =
      PhoenixKitBilling.update_currency(
        PhoenixKitBilling.get_currency_by_code("EUR"),
        %{exchange_rate: "0.615"}
      )

    Currency.put_request_currency("EUR")

    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Lossy #{n}", lang() => "Lossy #{n}"},
        "slug" => %{lang() => "lossy-#{n}"},
        "price" => Decimal.new("6.99"),
        "compare_at_price" => Decimal.new("9.99"),
        "status" => "active",
        "currency" => "USD"
      })

    {:ok, cart} = Shop.create_cart(session_id: "lossy-#{n}")
    {:ok, cart} = Shop.add_to_cart(cart, product, 1)
    Currency.put_request_currency(nil)

    [frozen_item] = cart.items
    assert Decimal.equal?(frozen_item.unit_price, Decimal.new("4.30"))
    assert Decimal.equal?(frozen_item.compare_at_price, Decimal.new("6.14"))

    _eur = set_rate(eur, "1.13")
    assert {:ok, cart} = Shop.refresh_cart_rate(cart)
    [item] = cart.items

    assert Decimal.equal?(item.unit_price, Decimal.new("7.90"))
    assert Decimal.equal?(item.compare_at_price, Decimal.new("11.28"))

    fresh_compare_at = Currency.present(Decimal.new("9.99"), "EUR", rate: Decimal.new("1.13"))
    assert Decimal.equal?(fresh_compare_at, Decimal.new("11.29"))

    drift = fresh_compare_at |> Decimal.sub(item.compare_at_price) |> Decimal.abs()
    assert Decimal.compare(drift, Decimal.new("0.02")) != :gt
  end

  test "refresh_cart_rate/1 refuses when a line has no base price or the currency is gone", %{
    cart: cart,
    eur: eur
  } do
    [item] = cart.items

    Repo.update_all(
      Ecto.Query.from(i in PhoenixKitEcommerce.CartItem, where: i.uuid == ^item.uuid),
      set: [base_unit_price: nil]
    )

    assert {:error, :no_base_price} = Shop.refresh_cart_rate(cart)
    {:ok, _} = PhoenixKitBilling.update_currency(eur, %{enabled: false})
    assert {:error, :currency_unavailable} = Shop.refresh_cart_rate(cart)
  end
end
