defmodule PhoenixKitEcommerce.StorefrontFiltersMergeTest do
  @moduledoc """
  Pure tests for `PhoenixKitEcommerce.merge_storefront_filters/2` — the
  per-category `storefront_filters` override merge (2026-09-06 plan,
  Task 2). No database required.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce, as: Shop

  @global [
    %{
      "key" => "search",
      "type" => "search",
      "label" => "Search",
      "enabled" => true,
      "position" => 0
    },
    %{
      "key" => "price",
      "type" => "price_range",
      "label" => "Price",
      "enabled" => true,
      "position" => 1
    },
    %{
      "key" => "size",
      "type" => "attribute_set",
      "set_slug" => "size",
      "label" => "Size",
      "enabled" => true,
      "position" => 2
    }
  ]

  describe "merge_storefront_filters/2" do
    test "no overrides returns the global list unchanged" do
      assert Shop.merge_storefront_filters(@global, %{}) == @global
    end

    test "an override on a matching key replaces enabled/position/label/set_slug only" do
      overrides = %{"price" => %{"enabled" => false, "position" => 9, "label" => "Preis"}}

      merged = Shop.merge_storefront_filters(@global, overrides)

      assert Enum.find(merged, &(&1["key"] == "price")) == %{
               "key" => "price",
               "type" => "price_range",
               "label" => "Preis",
               "enabled" => false,
               "position" => 9
             }
    end

    test "an override cannot change a matching filter's type" do
      overrides = %{"price" => %{"type" => "attribute_set"}}

      merged = Shop.merge_storefront_filters(@global, overrides)

      assert Enum.find(merged, &(&1["key"] == "price"))["type"] == "price_range"
    end

    test "a category-only key is appended as a brand-new filter" do
      overrides = %{
        "material" => %{
          "type" => "attribute_set",
          "set_slug" => "material",
          "label" => "Material",
          "enabled" => true,
          "position" => 5
        }
      }

      merged = Shop.merge_storefront_filters(@global, overrides)

      assert length(merged) == length(@global) + 1

      assert Enum.find(merged, &(&1["key"] == "material")) == %{
               "key" => "material",
               "type" => "attribute_set",
               "set_slug" => "material",
               "label" => "Material",
               "enabled" => true,
               "position" => 5
             }
    end

    test "multiple category-only filters are appended sorted by {position, key}, not map order (review fix)" do
      overrides = %{
        "zzz" => %{
          "type" => "attribute_set",
          "set_slug" => "zzz",
          "label" => "Zzz",
          "position" => 2
        },
        "aaa" => %{
          "type" => "attribute_set",
          "set_slug" => "aaa",
          "label" => "Aaa",
          "position" => 2
        },
        "no_position" => %{"type" => "attribute_set", "set_slug" => "np", "label" => "NP"}
      }

      merged = Shop.merge_storefront_filters(@global, overrides)
      category_only_keys = merged |> Enum.drop(length(@global)) |> Enum.map(& &1["key"])

      assert category_only_keys == ["no_position", "aaa", "zzz"]
    end

    test "global filters absent from the override map are untouched, in original order" do
      overrides = %{"size" => %{"enabled" => false}}

      merged = Shop.merge_storefront_filters(@global, overrides)

      assert Enum.map(merged, & &1["key"]) == ["search", "price", "size"]
      assert Enum.find(merged, &(&1["key"] == "search")) == Enum.at(@global, 0)
    end
  end
end
