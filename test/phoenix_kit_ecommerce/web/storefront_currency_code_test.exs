defmodule PhoenixKitEcommerce.Web.StorefrontCurrencyCodeTest do
  @moduledoc """
  Storefront LiveViews assign the shopper's DISPLAY currency as a CODE
  (Э1-E4, spec §4.2, §4.2.1, §12.4) — resolved per-request through
  Billing's own fail-safe, not the base currency `get_default_currency/0`
  always was. `PriceDisplay` converts and formats at RENDER time off
  that code, so a currency-table change is picked up by the NEXT mount
  (a fresh page load, or a new visitor) rather than staying pinned to
  whatever rate was live when a still-open tab first mounted.

  NOT tested here: whether an ALREADY-MOUNTED LiveView's price display
  updates itself without any further interaction. It does not, and that
  is a LiveView mechanic, not a currency-conversion bug — HEEx's
  compile-time change tracking only re-evaluates an expression when one
  of the `@assign`s it statically reads has itself changed; a currency
  row changing in the database touches no assign, so `render(view)`
  alone keeps showing the last-rendered figure. An interaction whose
  event handler reassigns `@quantity` DOES force the whole template to
  re-render — and the total (which also multiplies by `@quantity`)
  picks up the new rate then — but the bare price display next to it,
  reading only `@product`/`@currency`/`@calculated_price`, is skipped by
  change tracking and stays stale until something re-touches ITS OWN
  assigns. Flagged to the team lead as a real gap outside this task's
  scope (no PubSub/broadcast exists yet to push a currency change to
  open storefront tabs); not fixed here.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Test.Repo

  defp lang do
    PhoenixKitEcommerce.SlugResolver.normalize_language_public(
      PhoenixKitEcommerce.Translations.default_language()
    )
  end

  setup do
    PhoenixKit.Cache.clear(:billing_currencies)
    Repo.delete_all(PhoenixKitBilling.Currency)

    {:ok, _usd} =
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

    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Consulting", lang() => "Consulting"},
        "slug" => %{lang() => "storefront-currency-code-test"},
        "price" => Decimal.new("138.00"),
        "status" => "active",
        "currency" => "USD"
      })

    on_exit(fn -> PhoenixKitBilling.Currency.put_request_currency(nil) end)

    %{eur: eur, product: product}
  end

  test "a domain mapped to EUR shows the converted price and assigns the code", %{
    conn: conn,
    product: product
  } do
    conn = put_test_currency(conn, "EUR")

    {:ok, view, html} = live(conn, "/shop/product/#{product.slug[lang()]}")

    assert html =~ "€125.45"
    assert :sys.get_state(view.pid).socket.assigns.currency == "EUR"
  end

  test "a currency-table change is picked up on the NEXT mount, not frozen at first load", %{
    conn: conn,
    product: product,
    eur: eur
  } do
    conn = put_test_currency(conn, "EUR")

    {:ok, _view, html} = live(conn, "/shop/product/#{product.slug[lang()]}")
    assert html =~ "€125.45"

    {:ok, _} = PhoenixKitBilling.update_currency(eur, %{exchange_rate: "0.95"})

    # A second, independent mount (a fresh page load) re-resolves the
    # display currency and re-converts against the CURRENT rate — it is
    # not pinned to whatever was live when the module first compiled or
    # when some other visitor's tab happened to mount.
    {:ok, _view2, html2} = live(conn, "/shop/product/#{product.slug[lang()]}")
    assert html2 =~ "€131.10"
  end

  test "no domain mapping falls back to the base currency", %{conn: conn, product: product} do
    {:ok, _view, html} = live(conn, "/shop/product/#{product.slug[lang()]}")

    assert html =~ "$138.00"
  end
end
