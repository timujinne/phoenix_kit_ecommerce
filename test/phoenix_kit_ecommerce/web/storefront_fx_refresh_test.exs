defmodule PhoenixKitEcommerce.Web.StorefrontFxRefreshTest do
  @moduledoc """
  §4.2.1 п.5: an OPEN storefront tab re-renders its converted prices when
  the currency table changes - without a reload or any shopper interaction.
  The store's write (`update_currency/2`) clears the currency cache, then
  broadcasts `{:currencies_changed, code}`; the LiveView re-marks `@currency`
  so every price expression re-evaluates through `present/3` (§12.1).
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

    n = System.unique_integer([:positive])

    {:ok, category} =
      Shop.create_category(%{
        "name" => %{"en" => "Fx", lang() => "Fx"},
        "slug" => %{lang() => "fx-refresh-#{n}"},
        "status" => "active"
      })

    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Consulting", lang() => "Consulting"},
        "slug" => %{lang() => "fx-refresh-#{n}"},
        "price" => Decimal.new("138.00"),
        "status" => "active",
        "currency" => "USD",
        "category_uuid" => category.uuid
      })

    on_exit(fn -> PhoenixKitBilling.Currency.put_request_currency(nil) end)
    %{eur: eur, product: product, category: category}
  end

  defp bump_rate(eur, rate),
    do: {:ok, _} = PhoenixKitBilling.update_currency(eur, %{exchange_rate: rate})

  test "product page: rate edit shows on the open tab", %{conn: conn, product: product, eur: eur} do
    conn = put_test_currency(conn, "EUR")
    {:ok, view, html} = live(conn, "/shop/product/#{product.slug[lang()]}")
    assert html =~ "€125.45"

    bump_rate(eur, "0.95")
    assert render(view) =~ "€131.10"
    refute render(view) =~ "€125.45"
    assert :sys.get_state(view.pid).socket.assigns.currency == "EUR"
  end

  test "catalog and category pages re-render their cards", %{
    conn: conn,
    eur: eur,
    category: category
  } do
    conn = put_test_currency(conn, "EUR")

    {:ok, catalog, html} = live(conn, "/shop")
    assert html =~ "€125.45"
    {:ok, cat_view, html} = live(conn, "/shop/category/#{category.slug[lang()]}")
    assert html =~ "€125.45"

    bump_rate(eur, "0.95")
    assert render(catalog) =~ "€131.10"
    assert render(cat_view) =~ "€131.10"
  end

  test "a rounding_rule edit shows on the open tab too (§5 via the same event)", %{
    conn: conn,
    product: product,
    eur: eur
  } do
    conn = put_test_currency(conn, "EUR")
    {:ok, view, _html} = live(conn, "/shop/product/#{product.slug[lang()]}")

    {:ok, _} = PhoenixKitBilling.update_currency(eur, %{rounding_rule: "charm_99"})
    assert render(view) =~ "€124.99"
  end

  test "a base-currency tab is untouched by the event", %{conn: conn, product: product, eur: eur} do
    {:ok, view, html} = live(conn, "/shop/product/#{product.slug[lang()]}")
    assert html =~ "$138.00"
    bump_rate(eur, "0.95")
    assert render(view) =~ "$138.00"
  end
end
