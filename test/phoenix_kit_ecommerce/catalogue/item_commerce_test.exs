defmodule PhoenixKitEcommerce.Catalogue.ItemCommerceTest do
  @moduledoc """
  Level 1 — pure embedded-schema tests, no database required.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.Catalogue.ItemCommerce

  describe "cast/2 validity" do
    test "rejects a negative compare_at_price" do
      assert {:error, errors} = ItemCommerce.cast(%{"compare_at_price" => "-1"}, %{})
      assert Keyword.has_key?(errors, :compare_at_price)
    end

    test "rejects an unknown shop_status" do
      assert {:error, errors} = ItemCommerce.cast(%{"shop_status" => "weird"}, %{})
      assert Keyword.has_key?(errors, :shop_status)
    end

    test "rejects an unknown product_type" do
      assert {:error, errors} = ItemCommerce.cast(%{"product_type" => "vapor"}, %{})
      assert Keyword.has_key?(errors, :product_type)
    end

    test "rejects a currency that is not 3 characters" do
      assert {:error, errors} = ItemCommerce.cast(%{"currency" => "US"}, %{})
      assert Keyword.has_key?(errors, :currency)
    end

    test "rejects a non-positive download_limit" do
      assert {:error, errors} = ItemCommerce.cast(%{"download_limit" => "0"}, %{})
      assert Keyword.has_key?(errors, :download_limit)
    end

    test "rejects a negative weight_grams" do
      assert {:error, errors} = ItemCommerce.cast(%{"weight_grams" => "-5"}, %{})
      assert Keyword.has_key?(errors, :weight_grams)
    end
  end

  describe "cast/2 price_modifiers validation" do
    test "accepts decimal strings and numeric leaves" do
      modifiers = %{"size" => %{"large" => "5.00", "small" => 0, "xl" => 2.5}}
      assert {:ok, stored} = ItemCommerce.cast(%{"price_modifiers" => modifiers}, %{})
      assert stored["price_modifiers"] == modifiers
    end

    test "rejects a non-numeric amount and names the option key" do
      modifiers = %{"size" => %{"large" => "five"}, "color" => %{"red" => "1"}}
      assert {:error, errors} = ItemCommerce.cast(%{"price_modifiers" => modifiers}, %{})
      assert [{:price_modifiers, message}] = errors
      assert message =~ "size"
      refute message =~ "color"
    end

    test "rejects a value that is not a per-slug map" do
      assert {:error, errors} = ItemCommerce.cast(%{"price_modifiers" => %{"size" => "5"}}, %{})
      assert Keyword.has_key?(errors, :price_modifiers)
    end
  end

  describe "cast/2 round trip" do
    test "an empty map applies the documented defaults" do
      assert {:ok, map} = ItemCommerce.cast(%{}, %{})

      assert map == %{
               "shop_status" => "draft",
               "product_type" => "physical",
               "vendor" => nil,
               "tags" => [],
               "compare_at_price" => nil,
               "cost_per_item" => nil,
               "currency" => nil,
               "taxable" => true,
               "weight_grams" => 0,
               "requires_shipping" => true,
               "made_to_order" => false,
               "file_uuid" => nil,
               "download_limit" => nil,
               "download_expiry_days" => nil,
               "price_unit" => %{},
               "price_from" => false,
               "price_on_request" => false,
               "price_modifiers" => %{},
               "price_fit_rule" => nil,
               "shopify" => %{},
               "legacy_product_uuid" => nil,
               "translation_fingerprints" => %{}
             }
    end

    test "valid params round-trip to a plain map with string keys and decimal strings" do
      assert {:ok, map} =
               ItemCommerce.cast(
                 %{"compare_at_price" => "12.50", "shop_status" => "active", "vendor" => "Acme"},
                 %{}
               )

      assert map["compare_at_price"] == "12.50"
      assert map["shop_status"] == "active"
      assert map["vendor"] == "Acme"
      assert is_binary(map["compare_at_price"])
    end

    test "merges params over the existing namespace" do
      current = %{"shop_status" => "active", "vendor" => "Acme", "taxable" => false}

      assert {:ok, map} = ItemCommerce.cast(%{"vendor" => "Beta"}, current)
      assert map["shop_status"] == "active"
      assert map["vendor"] == "Beta"
      assert map["taxable"] == false
    end

    test "a comma-separated tags string becomes a trimmed list" do
      assert {:ok, map} = ItemCommerce.cast(%{"tags" => "red, blue ,  green"}, %{})
      assert map["tags"] == ["red", "blue", "green"]
    end

    test "an empty tags string becomes an empty list" do
      assert {:ok, map} = ItemCommerce.cast(%{"tags" => ""}, %{})
      assert map["tags"] == []
    end

    test "a blank price_unit language entry is dropped instead of stored empty" do
      assert {:ok, map} =
               ItemCommerce.cast(
                 %{"price_unit" => %{"en-US" => "", "fr-FR" => "par heure"}},
                 %{}
               )

      assert map["price_unit"] == %{"fr-FR" => "par heure"}
    end

    test "an unknown key already under data[\"ecommerce\"] survives a form save" do
      current = %{"shop_status" => "active", "future_flag" => true}

      assert {:ok, map} = ItemCommerce.cast(%{"vendor" => "Acme"}, current)
      assert map["vendor"] == "Acme"
      assert map["shop_status"] == "active"
      assert map["future_flag"] == true
    end
  end

  describe "price_fit_rule" do
    test "accepts both rules and nil" do
      for value <- ["never_cheaper", "cheapest", nil] do
        assert {:ok, map} = ItemCommerce.cast(%{"price_fit_rule" => value}, %{})
        assert map["price_fit_rule"] == value
      end
    end

    test "rejects anything else" do
      assert {:error, errors} = ItemCommerce.cast(%{"price_fit_rule" => "weird"}, %{})
      assert Keyword.has_key?(errors, :price_fit_rule)
    end

    test "a form save keeps the sync-written price_fit" do
      current = %{
        "shopify" => %{"handle" => "h", "price_fit" => %{"rule" => "never_cheaper", "over" => 5}}
      }

      assert {:ok, map} =
               ItemCommerce.cast(%{"vendor" => "Acme", "price_fit_rule" => "cheapest"}, current)

      assert map["shopify"]["price_fit"] == %{"rule" => "never_cheaper", "over" => 5}
    end
  end
end
