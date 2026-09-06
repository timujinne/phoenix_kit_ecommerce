defmodule PhoenixKitEcommerce.PriceDisplayFxTest do
  @moduledoc """
  `PriceDisplay.render/4`, `PriceDisplay.compare_at/4` and
  `Helpers.format_price/2` under per-domain currency (spec §2.10, §4.3,
  §4.3.1, §12): which numbers convert is decided by where the number
  CAME FROM, not by the rendering context alone. `:catalog` and
  `:selected` amounts are live base-currency numbers and convert exactly
  once (N1 — the double-conversion trap); `:cart`/`:order` amounts are
  already-stored snapshots in the record's own currency and never
  convert again.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.PriceDisplay
  alias PhoenixKitEcommerce.Web.Helpers

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

    {:ok, _gbp} =
      PhoenixKitBilling.create_currency(%{
        code: "GBP",
        name: "Pound",
        symbol: "£",
        enabled: false,
        exchange_rate: "0.772727"
      })

    :ok
  end

  describe "render/4 — provenance decides which numbers convert" do
    test ":catalog converts both range bounds; :cart/:order never convert" do
      {:ok, product} = Shop.create_product(product_attrs(%{"price" => Decimal.new("138.00")}))
      assert PriceDisplay.render(product, "EUR", :catalog) == "€125.45"

      assert PriceDisplay.render(nil, "EUR", :cart, amount: Decimal.new("125.45")) == "€125.45"
      assert PriceDisplay.render(nil, "EUR", :order, amount: Decimal.new("125.45")) == "€125.45"
    end

    test ":catalog range_style: :range converts both bounds of a real option range" do
      {:ok, _} =
        PhoenixKitEcommerce.Options.update_global_options([
          %{
            "key" => "material",
            "label" => "Material",
            "type" => "select",
            "options" => ["plain", "petg"],
            "affects_price" => true,
            "modifier_type" => "fixed",
            "price_modifiers" => %{"plain" => "0.00", "petg" => "10.00"}
          },
          %{
            "key" => "quality",
            "label" => "Quality",
            "type" => "select",
            "options" => ["standard", "premium"],
            "affects_price" => true,
            "modifier_type" => "percent",
            "price_modifiers" => %{"standard" => "0", "premium" => "20"}
          }
        ])

      {:ok, product} = Shop.create_product(product_attrs(%{"price" => Decimal.new("138.00")}))

      # base range is {138.00, 177.60} (138 + 10 = 148, * 1.20 = 177.60);
      # converted at 0.909091 -> {125.45, 161.45}
      assert PriceDisplay.render(product, "EUR", :catalog, range_style: :range) ==
               "€125.45 - €161.45"
    end

    test ":selected converts a live base amount exactly once (N1)" do
      {:ok, _} =
        PhoenixKitEcommerce.Options.update_global_options([
          %{
            "key" => "material",
            "label" => "Material",
            "type" => "select",
            "options" => ["plain", "petg"],
            "affects_price" => true,
            "modifier_type" => "fixed",
            "price_modifiers" => %{"plain" => "0.00", "petg" => "10.00"}
          },
          %{
            "key" => "quality",
            "label" => "Quality",
            "type" => "select",
            "options" => ["standard", "premium"],
            "affects_price" => true,
            "modifier_type" => "percent",
            "price_modifiers" => %{"standard" => "0", "premium" => "20"}
          }
        ])

      {:ok, product_with_options} =
        Shop.create_product(product_attrs(%{"price" => Decimal.new("138.00")}))

      live =
        Shop.calculate_product_price(product_with_options, %{
          "material" => "petg",
          "quality" => "premium"
        })

      # base, unconverted
      assert Decimal.equal?(live, Decimal.new("177.60"))

      assert PriceDisplay.render(product_with_options, "EUR", :selected, amount: live) ==
               "€161.45"
    end
  end

  describe "compare_at/4" do
    test "goes through the same present/3 and keeps the true discount (§4.3.1)" do
      {:ok, product} =
        Shop.create_product(
          product_attrs(%{
            "price" => Decimal.new("138.00"),
            "compare_at_price" => Decimal.new("180.00")
          })
        )

      # round(180 * 0.909091, 2) = 163.64; percent = (180-138)/180 = 23
      assert %{price: "€163.64", percent: 23} =
               PriceDisplay.compare_at(product, "EUR", :catalog, [])

      assert %{price: "$180.00", percent: 23} =
               PriceDisplay.compare_at(product, "USD", :catalog, [])
    end

    test ":selected compares against the live amount, in base, not the display amount" do
      {:ok, product} =
        Shop.create_product(
          product_attrs(%{
            "price" => Decimal.new("138.00"),
            "compare_at_price" => Decimal.new("180.00")
          })
        )

      # 190.00 (base) is ABOVE compare_at_price (180.00) -> no discount at all
      assert PriceDisplay.compare_at(product, "EUR", :selected, amount: Decimal.new("190.00")) ==
               nil
    end

    test "no compare_at_price, or on-request, or compare_at not above the amount -> nil" do
      {:ok, plain} = Shop.create_product(product_attrs(%{"price" => Decimal.new("40.00")}))
      assert PriceDisplay.compare_at(plain, "EUR", :catalog, []) == nil

      {:ok, not_a_discount} =
        Shop.create_product(
          product_attrs(%{
            "price" => Decimal.new("40.00"),
            "compare_at_price" => Decimal.new("40.00")
          })
        )

      assert PriceDisplay.compare_at(not_a_discount, "EUR", :catalog, []) == nil
    end
  end

  describe "struct compatibility" do
    test "a struct is still accepted and behaves as its code" do
      {:ok, product} = Shop.create_product(product_attrs(%{"price" => Decimal.new("138.00")}))
      eur = PhoenixKitBilling.get_currency_by_code("EUR")

      assert PriceDisplay.render(product, eur, :catalog) ==
               PriceDisplay.render(product, "EUR", :catalog)
    end

    test "compare_at also accepts a struct" do
      {:ok, product} =
        Shop.create_product(
          product_attrs(%{
            "price" => Decimal.new("138.00"),
            "compare_at_price" => Decimal.new("180.00")
          })
        )

      eur = PhoenixKitBilling.get_currency_by_code("EUR")

      assert PriceDisplay.compare_at(product, eur, :catalog, []) ==
               PriceDisplay.compare_at(product, "EUR", :catalog, [])
    end
  end

  describe "Helpers.format_price/2 by code" do
    test "a known code renders the symbol; unknown stays bare" do
      assert Helpers.format_price(Decimal.new("12.50"), "EUR") == "€12.50"
      assert Helpers.format_price(Decimal.new("12.50"), "XYZ") == "12.50 XYZ"
    end

    test "a disabled but known code still renders its symbol (format is not gated by enabled)" do
      assert Helpers.format_price(Decimal.new("12.50"), "GBP") == "£12.50"
    end
  end
end
