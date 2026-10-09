defmodule PhoenixKitEcommerce.Schemas.ProductDimensionsTest do
  use PhoenixKitEcommerce.DataCase, async: true

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Product

  @valid %{"title" => %{"en" => "Widget"}, "price" => Decimal.new("19.99")}

  defp changeset(attrs, product \\ %Product{}),
    do: Product.changeset(product, Map.merge(@valid, attrs))

  describe "changeset/2" do
    test "stores the sides in metadata[\"dimensions_mm\"]" do
      cs = changeset(%{"length_mm" => "300", "width_mm" => "200", "height_mm" => "100"})

      assert cs.valid?

      assert get_field(cs, :metadata) == %{
               "dimensions_mm" => %{"length_mm" => 300, "width_mm" => 200, "height_mm" => 100}
             }

      assert get_field(cs, :length_mm) == 300
    end

    test "atom keys work as well" do
      cs = Product.changeset(%Product{}, %{title: %{"en" => "W"}, price: 1, length_mm: 5})

      assert get_field(cs, :metadata) == %{"dimensions_mm" => %{"length_mm" => 5}}
    end

    test "other metadata keys survive" do
      product = %Product{metadata: %{"color" => "red", "_option_values" => %{"a" => 1}}}
      cs = changeset(%{"length_mm" => "10", "width_mm" => "20", "height_mm" => "30"}, product)

      metadata = get_field(cs, :metadata)
      assert metadata["color"] == "red"
      assert metadata["_option_values"] == %{"a" => 1}
      assert metadata["dimensions_mm"]["width_mm"] == 20
    end

    test "metadata given in the same params is the base" do
      cs = changeset(%{"metadata" => %{"color" => "blue"}, "length_mm" => "10"})

      assert get_field(cs, :metadata) == %{
               "color" => "blue",
               "dimensions_mm" => %{"length_mm" => 10}
             }
    end

    test "a save without dimension params leaves the metadata alone" do
      product = %Product{metadata: %{"dimensions_mm" => %{"length_mm" => 5}}}
      cs = changeset(%{"vendor" => "Acme"}, product)

      refute Map.has_key?(cs.changes, :metadata)
      assert get_field(cs, :metadata) == %{"dimensions_mm" => %{"length_mm" => 5}}
    end

    test "a side missing from the params keeps the stored one" do
      product = %Product{
        metadata: %{"dimensions_mm" => %{"length_mm" => 5, "width_mm" => 6, "height_mm" => 7}}
      }

      cs = changeset(%{"length_mm" => "50"}, product)

      assert get_field(cs, :metadata)["dimensions_mm"] ==
               %{"length_mm" => 50, "width_mm" => 6, "height_mm" => 7}
    end

    test "blank sides clear the stored dimensions and only them" do
      product = %Product{
        metadata: %{
          "color" => "red",
          "dimensions_mm" => %{"length_mm" => 5, "width_mm" => 6, "height_mm" => 7}
        }
      }

      cs = changeset(%{"length_mm" => "", "width_mm" => nil, "height_mm" => "0"}, product)

      assert cs.valid?
      assert get_field(cs, :metadata) == %{"color" => "red"}
    end

    test "rejects negative and non-integer sides" do
      for field <- ~w(length_mm width_mm height_mm) do
        assert %{} = errors = errors_on(changeset(%{field => "-1"}))
        assert Map.has_key?(errors, String.to_existing_atom(field))
      end

      assert %{length_mm: ["is invalid"]} = errors_on(changeset(%{"length_mm" => "abc"}))
    end

    test "an invalid side leaves the metadata untouched" do
      cs = changeset(%{"length_mm" => "-5", "width_mm" => "10"})

      refute cs.valid?
      refute Map.has_key?(cs.changes, :metadata)
    end
  end

  describe "dimensions_mm/1" do
    test "is nil without any dimensions" do
      assert Product.dimensions_mm(%Product{}) == nil
      assert Product.dimensions_mm(nil) == nil
    end

    test "reads the virtual fields and sorts the sides from the longest" do
      assert Product.dimensions_mm(%Product{length_mm: 100, width_mm: 300, height_mm: 200}) ==
               [300, 200, 100]
    end

    test "reads the stored metadata when no virtual field is set" do
      product = %Product{
        metadata: %{"dimensions_mm" => %{"length_mm" => 1, "width_mm" => 3, "height_mm" => 2}}
      }

      assert Product.dimensions_mm(product) == [3, 2, 1]
    end

    test "virtual fields win over the stored metadata" do
      product = %Product{
        length_mm: 10,
        width_mm: 20,
        height_mm: 30,
        metadata: %{"dimensions_mm" => %{"length_mm" => 1, "width_mm" => 1, "height_mm" => 1}}
      }

      assert Product.dimensions_mm(product) == [30, 20, 10]
    end

    test "is nil unless all three sides are positive" do
      assert Product.dimensions_mm(%Product{length_mm: 10, width_mm: 20}) == nil
      assert Product.dimensions_mm(%Product{length_mm: 10, width_mm: 20, height_mm: 0}) == nil

      partial = %Product{metadata: %{"dimensions_mm" => %{"length_mm" => 1, "width_mm" => 2}}}
      assert Product.dimensions_mm(partial) == nil
    end

    test "tolerates numeric strings in the metadata" do
      product = %Product{
        metadata: %{"dimensions_mm" => %{"length_mm" => "5", "width_mm" => "6", "height_mm" => 7}}
      }

      assert Product.dimensions_mm(product) == [7, 6, 5]
    end
  end

  describe "with_dimensions/1" do
    test "fills the virtual fields from the metadata" do
      product = %Product{
        metadata: %{"dimensions_mm" => %{"length_mm" => 1, "width_mm" => 2, "height_mm" => 3}}
      }

      assert %Product{length_mm: 1, width_mm: 2, height_mm: 3} = Product.with_dimensions(product)
    end

    test "keeps the fields that are already set" do
      product = %Product{length_mm: 9, metadata: %{"dimensions_mm" => %{"length_mm" => 1}}}

      assert %Product{length_mm: 9} = Product.with_dimensions(product)
    end

    test "a product without dimensions stays blank" do
      assert %Product{length_mm: nil, width_mm: nil, height_mm: nil} =
               Product.with_dimensions(%Product{})
    end
  end

  describe "persistence" do
    test "dimensions survive a database round trip" do
      attrs =
        Map.merge(@valid, %{"length_mm" => "300", "width_mm" => "200", "height_mm" => "100"})

      assert {:ok, product} = Shop.create_product(attrs)

      reloaded = Shop.get_product!(product.uuid)

      assert reloaded.length_mm == nil
      assert Product.dimensions_mm(reloaded) == [300, 200, 100]

      assert %Product{length_mm: 300, width_mm: 200, height_mm: 100} =
               Product.with_dimensions(reloaded)
    end

    test "an update changes only the dimensions in the metadata" do
      {:ok, product} = Shop.create_product(Map.put(@valid, "metadata", %{"color" => "red"}))

      assert {:ok, updated} = Shop.update_product(product, %{"length_mm" => "10"})

      assert Shop.get_product!(updated.uuid).metadata ==
               %{"color" => "red", "dimensions_mm" => %{"length_mm" => 10}}
    end
  end
end
