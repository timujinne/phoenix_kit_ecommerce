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
               "storefront_filters" => %{}
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
end
