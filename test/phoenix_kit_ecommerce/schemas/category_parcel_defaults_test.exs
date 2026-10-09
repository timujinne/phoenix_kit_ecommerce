defmodule PhoenixKitEcommerce.Schemas.CategoryParcelDefaultsTest do
  use PhoenixKitEcommerce.DataCase, async: true

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Category

  @valid %{"name" => %{"en" => "Electronics"}}

  defp changeset(attrs, category \\ %Category{}),
    do: Category.changeset(category, Map.merge(@valid, attrs))

  describe "changeset/2" do
    test "stores the box and weight in metadata[\"parcel_defaults\"]" do
      cs =
        changeset(%{
          "parcel_length_mm" => "300",
          "parcel_width_mm" => "200",
          "parcel_height_mm" => "100",
          "parcel_weight_g" => "450"
        })

      assert cs.valid?

      assert get_field(cs, :metadata) == %{
               "parcel_defaults" => %{
                 "length_mm" => 300,
                 "width_mm" => 200,
                 "height_mm" => 100,
                 "weight_g" => 450
               }
             }
    end

    test "other metadata keys survive" do
      category = %Category{metadata: %{"icon" => "box"}}
      cs = changeset(%{"parcel_weight_g" => "450"}, category)

      assert get_field(cs, :metadata) == %{
               "icon" => "box",
               "parcel_defaults" => %{"weight_g" => 450}
             }
    end

    test "a save without parcel params leaves the metadata alone" do
      category = %Category{metadata: %{"parcel_defaults" => %{"weight_g" => 450}}}
      cs = changeset(%{"position" => 3}, category)

      refute Map.has_key?(cs.changes, :metadata)
    end

    test "blank values clear the defaults and keep other keys" do
      category = %Category{
        metadata: %{"icon" => "box", "parcel_defaults" => %{"weight_g" => 450}}
      }

      cs = changeset(%{"parcel_weight_g" => ""}, category)

      assert get_field(cs, :metadata) == %{"icon" => "box"}
    end

    test "rejects a negative value on each field" do
      for field <- ~w(parcel_length_mm parcel_width_mm parcel_height_mm parcel_weight_g) do
        errors = errors_on(changeset(%{field => "-1"}))
        assert Map.has_key?(errors, String.to_existing_atom(field))
      end
    end
  end

  describe "parcel_defaults/1" do
    test "is empty for a category without defaults, nil or garbage" do
      empty = %{dims_mm: nil, weight_g: nil}

      assert Category.parcel_defaults(%Category{}) == empty
      assert Category.parcel_defaults(nil) == empty
      assert Category.parcel_defaults(%{}) == empty
    end

    test "reads the stored metadata" do
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

      assert Category.parcel_defaults(category) == %{dims_mm: [300, 200, 100], weight_g: 450}
    end

    test "the virtual fields win over the metadata" do
      category = %Category{
        parcel_length_mm: 10,
        parcel_width_mm: 20,
        parcel_height_mm: 30,
        metadata: %{"parcel_defaults" => %{"weight_g" => 450}}
      }

      assert Category.parcel_defaults(category) == %{dims_mm: [30, 20, 10], weight_g: nil}
    end

    test "a partial box has no dimensions but keeps the weight" do
      category = %Category{
        metadata: %{"parcel_defaults" => %{"length_mm" => 10, "weight_g" => 200}}
      }

      assert Category.parcel_defaults(category) == %{dims_mm: nil, weight_g: 200}
    end
  end

  describe "with_parcel_defaults/1" do
    test "fills the virtual fields from the metadata" do
      category = %Category{
        metadata: %{"parcel_defaults" => %{"length_mm" => 1, "weight_g" => 5}}
      }

      assert %Category{
               parcel_length_mm: 1,
               parcel_width_mm: nil,
               parcel_height_mm: nil,
               parcel_weight_g: 5
             } = Category.with_parcel_defaults(category)
    end
  end

  describe "persistence" do
    test "defaults survive a database round trip" do
      {:ok, category} =
        Shop.create_category(
          Map.merge(@valid, %{
            "parcel_length_mm" => "300",
            "parcel_width_mm" => "200",
            "parcel_height_mm" => "100",
            "parcel_weight_g" => "450"
          })
        )

      reloaded = Shop.get_category!(category.uuid)

      assert Category.parcel_defaults(reloaded) == %{dims_mm: [300, 200, 100], weight_g: 450}
    end
  end
end
