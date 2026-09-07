defmodule PhoenixKitEcommerce.Web.CheckoutFxDriftTest do
  @moduledoc "§4.4 on the checkout page: the drift notice appears live, and only the Reprice button changes the cart."
  use PhoenixKitEcommerce.LiveCase, async: false
  alias PhoenixKitBilling.Currency
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Test.Repo

  setup %{conn: conn} do
    PhoenixKit.Cache.clear(:billing_currencies)
    Repo.delete_all(PhoenixKitBilling.Currency)
    PhoenixKit.Settings.update_setting("fx_rate_drift_alert_pct", "5")
    on_exit(fn -> Currency.put_request_currency(nil) end)

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

    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Drift Widget"},
        "price" => Decimal.new("138.00"),
        "status" => "active",
        "currency" => "USD",
        "product_type" => "digital",
        "requires_shipping" => false
      })

    session_id = "checkout-fx-drift-#{System.unique_integer([:positive])}"
    Currency.put_request_currency("EUR")
    {:ok, cart} = Shop.create_cart(session_id: session_id)
    {:ok, _cart} = Shop.add_to_cart(cart, product, 1)
    Currency.put_request_currency(nil)
    # ONE init_test_session: put_test_currency/2 would overwrite shop_session_id
    conn =
      Plug.Test.init_test_session(conn, %{
        "shop_session_id" => session_id,
        "phoenix_kit_test_currency" => "EUR"
      })

    %{conn: conn, eur: eur}
  end

  test "no notice without drift; the notice appears live after a rate edit; Reprice rewrites the cart",
       %{conn: conn, eur: eur} do
    {:ok, view, html} = live(conn, "/checkout")
    refute html =~ "checkout-fx-drift"
    assert html =~ "€125.45"
    {:ok, _} = PhoenixKitBilling.update_currency(eur, %{exchange_rate: "1.0"})
    html = render(view)
    assert has_element?(view, "#checkout-fx-drift")
    assert html =~ "€125.45"
    html = view |> element("#checkout-fx-drift-reprice") |> render_click()
    refute has_element?(view, "#checkout-fx-drift")
    assert html =~ "€138.00"
    refute html =~ "€125.45"
  end

  test "drift under the threshold shows nothing", %{conn: conn, eur: eur} do
    {:ok, view, _html} = live(conn, "/checkout")
    {:ok, _} = PhoenixKitBilling.update_currency(eur, %{exchange_rate: "0.93"})
    render(view)
    refute has_element?(view, "#checkout-fx-drift")
  end
end
