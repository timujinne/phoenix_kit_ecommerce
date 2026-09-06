defmodule PhoenixKitEcommerce.CartCurrencyEnforceTest do
  @moduledoc """
  `validate_cart_currency/2` (§7.2 of the per-domain-currency spec):
  compares `product.currency` against the shop's BASE currency, not the
  cart's — a product has no opinion on the shopper's display currency.
  By default a known, foreign product currency only logs; behind
  `shop_enforce_product_currency` it refuses. `nil`/unknown codes always
  pass — there's no actionable signal either way.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  import ExUnit.CaptureLog

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
    PhoenixKit.Cache.invalidate(:settings, "shop_enforce_product_currency")

    on_exit(fn ->
      PhoenixKit.Cache.invalidate(:settings, "shop_enforce_product_currency")
    end)

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

  test "default: a foreign product currency only logs" do
    {:ok, p} = Shop.create_product(product_attrs(%{"currency" => "EUR"}))
    {:ok, cart} = Shop.create_cart(session_id: "s-#{System.unique_integer([:positive])}")

    assert capture_log(fn -> assert {:ok, _} = Shop.add_to_cart(cart, p, 1) end) =~ "EUR"
  end

  test "enforced: a foreign product currency is refused; nil/unknown pass" do
    PhoenixKit.Settings.update_boolean_setting_with_module(
      "shop_enforce_product_currency",
      true,
      "shop"
    )

    PhoenixKit.Cache.invalidate(:settings, "shop_enforce_product_currency")

    {:ok, cart} = Shop.create_cart(session_id: "s-#{System.unique_integer([:positive])}")

    {:ok, p} = Shop.create_product(product_attrs(%{"currency" => "EUR"}))
    assert {:error, :currency_mismatch} = Shop.add_to_cart(cart, p, 1)

    {:ok, p2} = Shop.create_product(product_attrs(%{"currency" => "ZZZ"}))
    assert {:ok, _} = Shop.add_to_cart(cart, p2, 1)
  end

  test "enforced: a product carrying the base currency is unaffected" do
    PhoenixKit.Settings.update_boolean_setting_with_module(
      "shop_enforce_product_currency",
      true,
      "shop"
    )

    PhoenixKit.Cache.invalidate(:settings, "shop_enforce_product_currency")

    {:ok, cart} = Shop.create_cart(session_id: "s-#{System.unique_integer([:positive])}")
    {:ok, p} = Shop.create_product(product_attrs(%{"currency" => "USD"}))
    assert {:ok, _} = Shop.add_to_cart(cart, p, 1)
  end
end
