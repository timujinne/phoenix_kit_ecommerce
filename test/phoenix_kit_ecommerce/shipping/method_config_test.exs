defmodule PhoenixKitEcommerce.Shipping.MethodConfigTest do
  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.Shipping.MethodConfig
  alias PhoenixKitEcommerce.ShippingMethod

  defp method(block), do: %ShippingMethod{metadata: %{"shipping_provider" => block}}

  describe "from_method/1" do
    test "a method without the block is a fixed-price method" do
      config = MethodConfig.from_method(%ShippingMethod{metadata: %{}})

      assert config.provider == "fixed"
      assert config.service == nil
      assert config.settings == %{}
      refute MethodConfig.calculated?(config)
    end

    test "nil, nil metadata and non-methods fall back to defaults" do
      assert %MethodConfig{provider: "fixed"} = MethodConfig.from_method(nil)
      assert %MethodConfig{provider: "fixed"} = MethodConfig.from_method(%{metadata: nil})
      assert %MethodConfig{provider: "fixed"} = MethodConfig.from_metadata("junk")
    end

    test "reads provider, service, settings and pricing" do
      config =
        MethodConfig.from_method(
          method(%{
            "provider" => "nova_poshta",
            "service" => "warehouse",
            "settings" => %{"sender_city" => %{"id" => "c1", "name" => "Poltava"}},
            "pricing" => %{"markup_percent" => "10", "markup_fixed" => "5", "round_to" => "5"}
          })
        )

      assert config.provider == "nova_poshta"
      assert config.service == "warehouse"
      assert config.settings == %{"sender_city" => %{"id" => "c1", "name" => "Poltava"}}
      assert Decimal.equal?(config.pricing.markup_percent, 10)
      assert Decimal.equal?(config.pricing.markup_fixed, 5)
      assert Decimal.equal?(config.pricing.round_to, 5)
    end

    test "pricing defaults to no markup and whole-unit rounding" do
      %{pricing: pricing} = MethodConfig.from_method(method(%{"provider" => "table"}))

      assert Decimal.equal?(pricing.markup_percent, 0)
      assert Decimal.equal?(pricing.markup_fixed, 0)
      assert Decimal.equal?(pricing.round_to, 1)
    end

    test "pricing accepts decimal commas, numbers and ignores garbage" do
      %{pricing: pricing} =
        MethodConfig.from_method(
          method(%{
            "pricing" => %{"markup_percent" => "7,5", "markup_fixed" => 3, "round_to" => "abc"}
          })
        )

      assert Decimal.equal?(pricing.markup_percent, "7.5")
      assert Decimal.equal?(pricing.markup_fixed, 3)
      assert Decimal.equal?(pricing.round_to, 1)
    end

    test "negative markups and non-positive rounding step use the defaults" do
      %{pricing: pricing} =
        MethodConfig.from_method(
          method(%{
            "pricing" => %{"markup_percent" => "-5", "markup_fixed" => "-1", "round_to" => "0"}
          })
        )

      assert Decimal.equal?(pricing.markup_percent, 0)
      assert Decimal.equal?(pricing.markup_fixed, 0)
      assert Decimal.equal?(pricing.round_to, 1)
    end

    test "blank provider and service" do
      config = MethodConfig.from_method(method(%{"provider" => "  ", "service" => ""}))

      assert config.provider == "fixed"
      assert config.service == nil
    end

    test "non-map settings become an empty map" do
      assert %{settings: %{}} = MethodConfig.from_method(method(%{"settings" => "oops"}))
    end
  end

  describe "calculated?/1" do
    test "is true for any provider but fixed" do
      assert MethodConfig.calculated?(method(%{"provider" => "table"}))
      assert MethodConfig.calculated?(method(%{"provider" => "nova_poshta"}))
      refute MethodConfig.calculated?(method(%{"provider" => "fixed"}))
      refute MethodConfig.calculated?(%ShippingMethod{})
    end

    test "accepts a config struct" do
      assert MethodConfig.calculated?(%MethodConfig{provider: "table"})
      refute MethodConfig.calculated?(%MethodConfig{})
    end
  end
end
