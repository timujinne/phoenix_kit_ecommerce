defmodule PhoenixKitEcommerce.Catalogue.CategoryCommerceTest do
  @moduledoc """
  Level 1 — pure embedded-schema tests, no database required.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.Catalogue.CategoryCommerce

  describe "cast/2 validity" do
    test "rejects an unknown shop_status" do
      assert {:error, errors} = CategoryCommerce.cast(%{"shop_status" => "weird"}, %{})
      assert Keyword.has_key?(errors, :shop_status)
    end

    test "accepts each documented shop_status" do
      for status <- ~w(active unlisted hidden) do
        assert {:ok, map} = CategoryCommerce.cast(%{"shop_status" => status}, %{})
        assert map["shop_status"] == status
      end
    end

    test "rejects an option_schema entry missing required keys" do
      assert {:error, errors} =
               CategoryCommerce.cast(%{"option_schema" => [%{"key" => "size"}]}, %{})

      assert Keyword.has_key?(errors, :option_schema)
    end

    test "accepts a well-formed option_schema" do
      option = %{"key" => "size", "label" => "Size", "type" => "text"}
      assert {:ok, map} = CategoryCommerce.cast(%{"option_schema" => [option]}, %{})
      assert [%{"key" => "size"}] = map["option_schema"]
    end
  end

  describe "cast/2 round trip" do
    test "an empty map applies the documented defaults" do
      assert {:ok, map} = CategoryCommerce.cast(%{}, %{})

      assert map == %{
               "shop_status" => "active",
               "option_schema" => [],
               "featured_item_uuid" => nil,
               "storefront_filters" => %{},
               "parcel_length_mm" => nil,
               "parcel_width_mm" => nil,
               "parcel_height_mm" => nil,
               "parcel_weight_g" => nil
             }
    end

    test "merges params over the existing namespace" do
      current = %{"shop_status" => "hidden"}
      assert {:ok, map} = CategoryCommerce.cast(%{"featured_item_uuid" => nil}, current)
      assert map["shop_status"] == "hidden"
    end

    test "a submitted value wins over the same key already in the namespace" do
      current = %{"shop_status" => "hidden", "storefront_filters" => %{"a" => 1}}

      assert {:ok, map} = CategoryCommerce.cast(%{"shop_status" => "unlisted"}, current)

      assert map["shop_status"] == "unlisted"
      assert map["storefront_filters"] == %{"a" => 1}
    end
  end

  describe "cast/2 parcel defaults" do
    test "round-trips the box and weight as integers" do
      params = %{
        "parcel_length_mm" => "300",
        "parcel_width_mm" => 200,
        "parcel_height_mm" => "100",
        "parcel_weight_g" => "450"
      }

      assert {:ok, map} = CategoryCommerce.cast(params, %{})

      assert %{
               "parcel_length_mm" => 300,
               "parcel_width_mm" => 200,
               "parcel_height_mm" => 100,
               "parcel_weight_g" => 450
             } = map
    end

    test "merges over the existing namespace and keeps its other keys" do
      current = %{"parcel_weight_g" => 450, "shop_status" => "hidden", "extra" => 1}

      assert {:ok, map} = CategoryCommerce.cast(%{"parcel_length_mm" => "10"}, current)
      assert map["parcel_weight_g"] == 450
      assert map["parcel_length_mm"] == 10
      assert map["shop_status"] == "hidden"
      assert map["extra"] == 1
    end

    test "rejects a negative value on each field" do
      for field <- ~w(parcel_length_mm parcel_width_mm parcel_height_mm parcel_weight_g) do
        assert {:error, errors} = CategoryCommerce.cast(%{field => "-1"}, %{})
        assert Keyword.has_key?(errors, String.to_existing_atom(field))
      end
    end

    test "zero is accepted (unset)" do
      assert {:ok, %{"parcel_weight_g" => 0}} =
               CategoryCommerce.cast(%{"parcel_weight_g" => "0"}, %{})
    end
  end
end
