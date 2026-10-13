defmodule PhoenixKitEcommerce.Web.CartRebaseOnMountTest do
  @moduledoc """
  A cart frozen against a previous base currency is rebased when the shopper
  merely OPENS the cart or the checkout — not only when they change it — and
  the pages subscribe to cart updates before they read the cart.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Currency
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Test.Repo

  defp lang do
    PhoenixKitEcommerce.SlugResolver.normalize_language_public(
      PhoenixKitEcommerce.Translations.default_language()
    )
  end

  setup %{conn: conn} do
    PhoenixKit.Cache.clear(:billing_currencies)
    Currency.put_request_currency(nil)
    on_exit(fn -> Currency.put_request_currency(nil) end)

    Repo.delete_all(Currency)

    {:ok, _usd} =
      Billing.create_currency(%{
        code: "USD",
        name: "Dollar",
        symbol: "$",
        is_default: true,
        exchange_rate: "1.0"
      })

    {:ok, _eur} =
      Billing.create_currency(%{
        code: "EUR",
        name: "Euro",
        symbol: "€",
        exchange_rate: "0.909091"
      })

    n = System.unique_integer([:positive])

    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Vase #{n}", lang() => "Vase #{n}"},
        "slug" => %{lang() => "rebase-mount-#{n}"},
        "price" => Decimal.new("138.00"),
        "status" => "active",
        "currency" => "USD",
        "requires_shipping" => false
      })

    session_id = "rebase-mount-#{n}"
    Currency.put_request_currency("USD")
    {:ok, cart} = Shop.create_cart(session_id: session_id)
    Currency.put_request_currency(nil)
    {:ok, cart} = Shop.add_to_cart(cart, product, 1)

    conn = Plug.Test.init_test_session(conn, %{"shop_session_id" => session_id})
    %{conn: conn, cart: cart, product: product}
  end

  defp switch_base_to_eur! do
    assert {:ok, %{old_base: "USD"}} =
             Billing.change_base_currency("EUR",
               catalog_size: 1,
               reprice: &Shop.reprice_for_base_change/3
             )
  end

  for path <- ["/cart", "/checkout"] do
    test "opening #{path} brings a stale cart onto the current base", %{conn: conn, cart: cart} do
      switch_base_to_eur!()
      assert Shop.get_cart!(cart.uuid).base_currency == "USD"

      {:ok, _view, _html} = live(conn, unquote(path))

      rebased = Shop.get_cart!(cart.uuid)
      assert rebased.base_currency == "EUR"
      assert Decimal.equal?(hd(rebased.items).base_unit_price, Decimal.new("125.45"))
    end
  end

  test "the cart page shows a change made in another tab", ctx do
    %{conn: conn, cart: cart, product: product} = ctx
    {:ok, view, _html} = live(conn, "/cart")

    {:ok, _cart} = Shop.add_to_cart(Shop.get_cart!(cart.uuid), product, 2)

    assert view |> element("input[name='quantity']") |> render() =~ ~s(value="3")
  end
end
