defmodule PhoenixKitEcommerce.Shipping.PricingTest do
  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.Shipping.{MethodConfig, Pricing, Quote}
  alias PhoenixKitEcommerce.ShippingMethod

  defp config(pricing \\ %{}) do
    %MethodConfig{
      provider: "table",
      pricing:
        Map.merge(
          %{
            markup_percent: Decimal.new(0),
            markup_fixed: Decimal.new(0),
            round_to: nil
          },
          pricing
        )
    }
  end

  defp quote_of(amount, source \\ :api),
    do: %Quote{amount: Decimal.new(amount), currency: "UAH", source: source}

  defp method(attrs \\ []),
    do: struct(%ShippingMethod{price: Decimal.new("49"), free_above_amount: nil}, attrs)

  defp final(config, quote, method, subtotal \\ "100"),
    do: Pricing.final_amount(config, quote, method, Decimal.new(subtotal))

  test "passes the carrier price through without markup" do
    assert Decimal.equal?(final(config(), quote_of("85"), method()), 85)
  end

  test "does not round by default" do
    assert Decimal.equal?(final(config(), quote_of("85.10"), method()), "85.10")
  end

  test "a Table rate with the default pricing keeps its fractions" do
    config = MethodConfig.from_metadata(%{"shipping_provider" => %{"provider" => "table"}})

    assert Decimal.equal?(final(config, quote_of("4.35"), method()), "4.35")
  end

  test "a round_to of 1 rounds up to whole units" do
    config = config(%{round_to: Decimal.new(1)})

    assert Decimal.equal?(final(config, quote_of("85.10"), method()), 86)
  end

  test "applies the percent markup" do
    assert Decimal.equal?(
             final(config(%{markup_percent: Decimal.new(10)}), quote_of("100"), method()),
             110
           )
  end

  test "adds the fixed markup after the percent markup" do
    config = config(%{markup_percent: Decimal.new(10), markup_fixed: Decimal.new(5)})

    assert Decimal.equal?(final(config, quote_of("100"), method()), 115)
  end

  test "rounds up to a multiple of round_to" do
    config = config(%{round_to: Decimal.new(5)})

    assert Decimal.equal?(final(config, quote_of("81"), method()), 85)
    assert Decimal.equal?(final(config, quote_of("85"), method()), 85)
    assert Decimal.equal?(final(config, quote_of("85.01"), method()), 90)
  end

  test "rounds up to fractions" do
    config = config(%{round_to: Decimal.new("0.5")})

    assert Decimal.equal?(final(config, quote_of("10.1"), method()), "10.5")
  end

  test "markup and rounding combine" do
    config =
      config(%{
        markup_percent: Decimal.new(15),
        markup_fixed: Decimal.new(2),
        round_to: Decimal.new(10)
      })

    # 100 * 1.15 + 2 = 117 -> 120
    assert Decimal.equal?(final(config, quote_of("100"), method()), 120)
  end

  test "a zero carrier price stays zero without a fixed markup" do
    assert Decimal.equal?(final(config(), quote_of("0"), method()), 0)
  end

  describe "free shipping threshold" do
    test "gives 0 at or above the threshold" do
      method = method(free_above_amount: Decimal.new("500"))

      assert Decimal.equal?(final(config(), quote_of("85"), method, "500"), 0)
      assert Decimal.equal?(final(config(), quote_of("85"), method, "900.50"), 0)
    end

    test "charges below the threshold" do
      method = method(free_above_amount: Decimal.new("500"))

      assert Decimal.equal?(final(config(), quote_of("85"), method, "499.99"), 85)
    end

    test "also frees a fallback quote" do
      method = method(free_above_amount: Decimal.new("500"))

      assert Decimal.equal?(final(config(), quote_of("0", :fallback), method, "600"), 0)
    end
  end

  describe "fallback quote" do
    test "costs the method price and ignores markup" do
      config = config(%{markup_percent: Decimal.new(50), round_to: Decimal.new(10)})

      assert Decimal.equal?(final(config, quote_of("999", :fallback), method()), 49)
    end
  end

  describe "pay-on-delivery methods" do
    test "charge the shop price of 0 whatever the carrier says" do
      method = method(metadata: %{"pay_on_delivery" => true})

      assert Decimal.equal?(final(config(), quote_of("85"), method), 0)
      assert Decimal.equal?(final(config(), quote_of("0", :fallback), method), 0)
    end

    test "a method that is not pay-on-delivery is unaffected" do
      assert Decimal.equal?(
               final(config(), quote_of("85"), method(metadata: %{"pay_on_delivery" => false})),
               85
             )
    end
  end

  describe "carrier_estimate/1" do
    test "is the raw quote" do
      quote = %Quote{amount: Decimal.new("85.5"), currency: "UAH", cod_fee: Decimal.new("20")}

      assert %{amount: amount, currency: "UAH", cod_fee: fee} = Pricing.carrier_estimate(quote)
      assert Decimal.equal?(amount, "85.5")
      assert Decimal.equal?(fee, 20)
    end
  end
end
