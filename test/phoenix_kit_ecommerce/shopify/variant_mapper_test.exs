defmodule PhoenixKitEcommerce.Shopify.VariantMapperTest do
  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.Shopify.VariantMapper

  # 2 options (Size, Color) x 6 variants (every combination). Size drives
  # the bigger price swing, Color a smaller one, on TOP of Size's - the
  # exact case the modulel's moduledoc calls out (a single "first variant
  # seen" price would misattribute this).
  defp two_option_product do
    %{
      "id" => 999,
      "options" => [
        %{"name" => "Size", "position" => 1, "values" => ["Small", "Medium", "Large"]},
        %{"name" => "Color", "position" => 2, "values" => ["Red", "Blue"]}
      ],
      "variants" => [
        %{"option1" => "Small", "option2" => "Red", "price" => "10.00"},
        %{"option1" => "Small", "option2" => "Blue", "price" => "11.00"},
        %{"option1" => "Medium", "option2" => "Red", "price" => "12.00"},
        %{"option1" => "Medium", "option2" => "Blue", "price" => "13.00"},
        %{"option1" => "Large", "option2" => "Red", "price" => "15.00"},
        %{"option1" => "Large", "option2" => "Blue", "price" => "16.00"}
      ]
    }
  end

  describe "build/1 — two real options" do
    setup do
      %{result: VariantMapper.build(two_option_product())}
    end

    test "one set per option, in Shopify's option order", %{result: result} do
      assert [
               %{name: "Size", slug: "size", position: 1, values: ["Small", "Medium", "Large"]},
               %{name: "Color", slug: "color", position: 2, values: ["Red", "Blue"]}
             ] = result.sets
    end

    test "values are ordered by first appearance across variants", %{result: result} do
      [size_set, color_set] = result.sets
      assert size_set.values == ["Small", "Medium", "Large"]
      assert color_set.values == ["Red", "Blue"]
    end

    test "modifier per value is min(price for that value) - min(all prices)", %{result: result} do
      assert %{
               "Small" => small,
               "Medium" => medium,
               "Large" => large
             } = result.modifiers["size"]

      assert Decimal.equal?(small, Decimal.new("0.00"))
      assert Decimal.equal?(medium, Decimal.new("2.00"))
      assert Decimal.equal?(large, Decimal.new("5.00"))

      assert %{"Red" => red, "Blue" => blue} = result.modifiers["color"]
      assert Decimal.equal?(red, Decimal.new("0.00"))
      assert Decimal.equal?(blue, Decimal.new("1.00"))
    end

    test "the cheapest value's modifier prints with two decimals, not bare zero", %{
      result: result
    } do
      assert Decimal.to_string(result.modifiers["size"]["Small"]) == "0.00"
      assert Decimal.to_string(result.modifiers["color"]["Red"]) == "0.00"
    end
  end

  describe "build/1 — Shopify's auto-generated default option" do
    test "a lone Title/Default Title option is skipped entirely" do
      product = %{
        "options" => [%{"name" => "Title", "position" => 1, "values" => ["Default Title"]}],
        "variants" => [%{"option1" => "Default Title", "price" => "9.99"}]
      }

      assert VariantMapper.build(product) == %{sets: [], modifiers: %{}}
    end

    test "no options/variants at all yields the same empty shape" do
      assert VariantMapper.build(%{}) == %{sets: [], modifiers: %{}}
    end
  end
end
