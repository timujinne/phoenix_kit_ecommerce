defmodule PhoenixKitEcommerce.Shipping.MethodConfigTest do
  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.Shipping.MethodConfig
  alias PhoenixKitEcommerce.ShippingMethod

  defp method(block),
    do: %ShippingMethod{
      metadata: %{"shipping_provider" => Map.put_new(block, "provider", "table")}
    }

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
            "provider" => "acme_post",
            "service" => "warehouse",
            "settings" => %{"sender_city" => %{"id" => "c1", "name" => "Springfield"}},
            "pricing" => %{"markup_percent" => "10", "markup_fixed" => "5", "round_to" => "5"}
          })
        )

      assert config.provider == "acme_post"
      assert config.service == "warehouse"
      assert config.settings == %{"sender_city" => %{"id" => "c1", "name" => "Springfield"}}
      assert Decimal.equal?(config.pricing.markup_percent, 10)
      assert Decimal.equal?(config.pricing.markup_fixed, 5)
      assert Decimal.equal?(config.pricing.round_to, 5)
    end

    test "a block with one service is read as the list of that service" do
      config =
        MethodConfig.from_method(method(%{"provider" => "acme_post", "service" => "branch"}))

      assert config.services == ["branch"]
      assert config.service == "branch"
    end

    test "reads the allowed services, the first of them is the default" do
      config =
        MethodConfig.from_method(
          method(%{"provider" => "acme_post", "services" => ["branch", "locker", "courier"]})
        )

      assert config.services == ["branch", "locker", "courier"]
      assert config.service == "branch"
    end

    test "the stored default service is kept when it is allowed" do
      config =
        MethodConfig.from_method(
          method(%{
            "provider" => "acme_post",
            "service" => "locker",
            "services" => ["branch", "locker"]
          })
        )

      assert config.service == "locker"
    end

    test "a default service that is not allowed gives way to the first allowed one" do
      config =
        MethodConfig.from_method(
          method(%{
            "provider" => "acme_post",
            "service" => "courier",
            "services" => ["branch", "locker"]
          })
        )

      assert config.service == "branch"
    end

    test "services are trimmed, deduplicated and cleaned of garbage" do
      config =
        MethodConfig.from_method(
          method(%{"provider" => "acme_post", "services" => [" branch ", "branch", "", nil, %{}]})
        )

      assert config.services == ["branch"]
    end

    test "no service at all is an empty list" do
      config = MethodConfig.from_method(method(%{"provider" => "acme_post"}))

      assert config.services == []
      assert config.service == nil
    end

    test "pricing defaults to no markup and no rounding" do
      %{pricing: pricing} = MethodConfig.from_method(method(%{"provider" => "table"}))

      assert Decimal.equal?(pricing.markup_percent, 0)
      assert Decimal.equal?(pricing.markup_fixed, 0)
      assert pricing.round_to == nil
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
      assert pricing.round_to == nil
    end

    test "negative markups use the defaults and a non-positive rounding step means no rounding" do
      %{pricing: pricing} =
        MethodConfig.from_method(
          method(%{
            "pricing" => %{"markup_percent" => "-5", "markup_fixed" => "-1", "round_to" => "0"}
          })
        )

      assert Decimal.equal?(pricing.markup_percent, 0)
      assert Decimal.equal?(pricing.markup_fixed, 0)
      assert pricing.round_to == nil
    end

    test "blank provider and service" do
      config = MethodConfig.from_method(method(%{"provider" => "  ", "service" => ""}))

      assert config.provider == "fixed"
      assert config.service == nil
    end

    test "a fixed block is read as no block" do
      config =
        MethodConfig.from_method(
          method(%{
            "provider" => "fixed",
            "service" => "default",
            "settings" => %{"destination" => "address"}
          })
        )

      assert config == %MethodConfig{}
    end

    test "non-map settings become an empty map" do
      assert %{settings: %{}} = MethodConfig.from_method(method(%{"settings" => "oops"}))
    end
  end

  describe "calculated?/1" do
    test "is true for any provider but fixed" do
      assert MethodConfig.calculated?(method(%{"provider" => "table"}))
      assert MethodConfig.calculated?(method(%{"provider" => "acme_post"}))
      refute MethodConfig.calculated?(method(%{"provider" => "fixed"}))
      refute MethodConfig.calculated?(%ShippingMethod{})
    end

    test "accepts a config struct" do
      assert MethodConfig.calculated?(%MethodConfig{provider: "table"})
      refute MethodConfig.calculated?(%MethodConfig{})
    end
  end
end
