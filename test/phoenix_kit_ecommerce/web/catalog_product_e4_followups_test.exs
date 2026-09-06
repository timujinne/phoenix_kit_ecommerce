defmodule PhoenixKitEcommerce.Web.CatalogProductE4FollowupsTest do
  @moduledoc """
  Regression coverage for two bugs found on Э1-E4's review (storefront
  `@currency` assigns carry a display CODE, not the base-currency struct
  they used to):

  1. `CatalogProduct`'s add-to-cart flash formatted a LIVE base amount
     under the display currency's code with no conversion. Fixed by
     using the STORED cart line's `unit_price` (already converted and
     rounded at add-to-cart time) instead of re-deriving one from
     `product.price`/`calculated_price` — what the flash shows is
     exactly what the shopper was charged, with no possibility of
     drifting a cent from the persisted snapshot.
  2. `ProductDetail` (admin)'s own `format_price/2`/`format_modifier/3`
     called billing's `Currency.format_amount/2` directly, which
     requires a `%Currency{}` struct - it would raise the moment
     `@currency` became a plain code. Fixed by delegating to
     `Web.Helpers.format_price/2` (§12.1), which accepts either.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitBilling.Currency
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Test.Repo

  defp lang do
    PhoenixKitEcommerce.SlugResolver.normalize_language_public(
      PhoenixKitEcommerce.Translations.default_language()
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

  test "add-to-cart on a EUR-mapped request flashes the CONVERTED, STORED price", %{conn: conn} do
    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Consulting", lang() => "Consulting"},
        "slug" => %{lang() => "e4-followup-#{System.unique_integer([:positive])}"},
        "price" => Decimal.new("138.00"),
        "status" => "active",
        "currency" => "USD",
        "requires_shipping" => false
      })

    conn = put_test_currency(conn, "EUR")
    {:ok, view, _html} = live(conn, "/shop/product/#{product.slug[lang()]}")

    html = view |> element("button[phx-click=add_to_cart]") |> render_click()

    # 138.00 base -> 125.45 EUR (0.909091), the same figure the cart
    # actually stored on its line - not the raw 138.00 base number
    # unconverted (the E1 bug) and not a second, independently
    # recomputed conversion that could disagree with the stored line.
    assert html =~ "€125.45"
    refute html =~ "$138.00"
  end

  test "ProductDetail (admin) renders the base price with its symbol and does not crash on a code @currency",
       %{conn: conn} do
    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Consulting", lang() => "Consulting"},
        "slug" => %{lang() => "e4-followup-admin-#{System.unique_integer([:positive])}"},
        "price" => Decimal.new("40.00"),
        "status" => "active",
        "currency" => "USD"
      })

    conn = put_test_scope(conn, fake_scope())
    {:ok, _view, html} = live(conn, "/en/admin/shop/products/#{product.uuid}")

    assert html =~ "$40.00"
  end
end
