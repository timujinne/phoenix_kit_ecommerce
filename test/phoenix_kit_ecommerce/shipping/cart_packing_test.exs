defmodule PhoenixKitEcommerce.Shipping.CartPackingTest do
  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.{CartItem, Category, Product}
  alias PhoenixKitEcommerce.Shipping.CartPacking
  alias PhoenixKitEcommerce.Shipping.PackItem

  defp item(attrs) do
    struct(CartItem, Map.merge(%{quantity: 1, weight_grams: 0, metadata: %{}}, Map.new(attrs)))
  end

  describe "profile/2" do
    test "the dimensions of the product win over the category box" do
      product = %Product{length_mm: 100, width_mm: 50, height_mm: 20}
      category = %Category{metadata: %{"parcel_defaults" => %{"length_mm" => 9}}}

      assert %{"dims_mm" => [100, 50, 20]} = CartPacking.profile(product, category)
    end

    test "a product without dimensions takes the category box and weight" do
      category = %Category{
        metadata: %{
          "parcel_defaults" => %{
            "length_mm" => 100,
            "width_mm" => 300,
            "height_mm" => 200,
            "weight_g" => 450
          }
        }
      }

      assert CartPacking.profile(%Product{}, category) ==
               %{"dims_mm" => [300, 200, 100], "default_weight_g" => 450}
    end

    test "the product dimensions are combined with the category weight" do
      product = %Product{length_mm: 10, width_mm: 10, height_mm: 10}
      category = %Category{metadata: %{"parcel_defaults" => %{"weight_g" => 700}}}

      assert CartPacking.profile(product, category) ==
               %{"dims_mm" => [10, 10, 10], "default_weight_g" => 700}
    end

    test "knows nothing without a category and dimensions" do
      assert CartPacking.profile(%Product{}, nil) ==
               %{"dims_mm" => nil, "default_weight_g" => nil}
    end

    test "is JSON safe" do
      profile = CartPacking.profile(%Product{length_mm: 3, width_mm: 2, height_mm: 1}, nil)

      assert profile |> Jason.encode!() |> Jason.decode!() == profile
    end
  end

  describe "pack_items/1" do
    test "turns a line into a pack item" do
      line =
        item(
          quantity: 3,
          weight_grams: 250,
          metadata: %{
            "requires_shipping" => true,
            "shipping_profile" => %{"dims_mm" => [30, 20, 10], "default_weight_g" => 400}
          }
        )

      assert [
               %PackItem{
                 weight_g: 250,
                 dims_mm: [30, 20, 10],
                 default_weight_g: 400,
                 quantity: 3
               }
             ] = CartPacking.pack_items([line])
    end

    test "a line that does not ship is left out" do
      shipping = item(metadata: %{"requires_shipping" => true})
      digital = item(metadata: %{"requires_shipping" => false})

      assert [%PackItem{}] = CartPacking.pack_items([digital, shipping, digital])
    end

    test "a line without the shipping flag counts as shipping" do
      assert [%PackItem{}] = CartPacking.pack_items([item(metadata: %{})])
      assert [%PackItem{}] = CartPacking.pack_items([item(metadata: nil)])
    end

    test "a zero weight is an unknown weight" do
      assert [%PackItem{weight_g: nil}] = CartPacking.pack_items([item(weight_grams: 0)])
      assert [%PackItem{weight_g: nil}] = CartPacking.pack_items([item(weight_grams: nil)])
    end

    test "a missing or damaged profile gives no dimensions and no default weight" do
      for profile <- [nil, "junk", %{}, %{"dims_mm" => [1, 2], "default_weight_g" => "x"}] do
        line = item(metadata: %{"shipping_profile" => profile})

        assert [%PackItem{dims_mm: nil, default_weight_g: nil}] = CartPacking.pack_items([line])
      end
    end

    test "dimensions with a zero side are unknown" do
      line = item(metadata: %{"shipping_profile" => %{"dims_mm" => [10, 0, 5]}})

      assert [%PackItem{dims_mm: nil}] = CartPacking.pack_items([line])
    end

    test "tolerates numbers that went through other types" do
      line =
        item(
          metadata: %{
            "shipping_profile" => %{"dims_mm" => ["10", 20.0, 5], "default_weight_g" => "300"}
          }
        )

      assert [%PackItem{dims_mm: [10, 20, 5], default_weight_g: 300}] =
               CartPacking.pack_items([line])
    end

    test "no lines, no items" do
      assert CartPacking.pack_items([]) == []
    end
  end
end
