defmodule PhoenixKitEcommerce.Catalogue.ExtensionTest do
  @moduledoc """
  Level 1 — component render + pure function tests, no database required.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKitEcommerce.Catalogue.Extension

  test "PhoenixKitEcommerce.catalogue_extensions/0 registers the extension" do
    assert PhoenixKitEcommerce.catalogue_extensions() == [Extension]
  end

  test "key/0 is the ecommerce namespace" do
    assert Extension.key() == "ecommerce"
  end

  test "enabled?/0 mirrors PhoenixKitEcommerce.enabled?/0" do
    assert Extension.enabled?() == PhoenixKitEcommerce.enabled?()
  end

  test "cast_item/2 delegates to ItemCommerce.cast/2" do
    assert {:ok, map} = Extension.cast_item(%{"vendor" => "Acme"}, %{})
    assert map["vendor"] == "Acme"
  end

  test "cast_category/2 delegates to CategoryCommerce.cast/2" do
    assert {:ok, map} = Extension.cast_category(%{"shop_status" => "hidden"}, %{})
    assert map["shop_status"] == "hidden"
  end

  describe "duplicate_data/2" do
    test "an item copy leaves out the Shopify link and the legacy product" do
      data = %{
        "shop_status" => "active",
        "vendor" => "Acme",
        "price_modifiers" => %{"color" => %{"red" => "2.00"}},
        "shopify" => %{
          "product_id" => "123",
          "handle" => "oak-door",
          "image_ids" => %{"456" => "01a0ae3b-0000-7000-8000-000000000002"},
          "set_slugs" => ["color"]
        },
        "legacy_product_uuid" => "01a0ae3b-0000-7000-8000-000000000001"
      }

      assert Extension.duplicate_data(:item, data) == %{
               "shop_status" => "active",
               "vendor" => "Acme",
               "price_modifiers" => %{"color" => %{"red" => "2.00"}}
             }
    end

    test "a category copy keeps its shop fields but not the Shopify collection" do
      data = %{"shop_status" => "hidden", "featured_item_uuid" => "x", "option_schema" => []}

      assert Extension.duplicate_data(:category, data) == data

      assert Extension.duplicate_data(
               :category,
               Map.put(data, "shopify", %{"collection_id" => "gid://shopify/Collection/1"})
             ) == data
    end
  end

  describe "item_section/1" do
    test "renders inputs named item[ecommerce][*]" do
      html =
        render_component(&Extension.item_section/1,
          form: nil,
          item: nil,
          data: %{},
          current_language: "en-US"
        )

      assert html =~ ~s(id="ext-ecommerce-section")
      assert html =~ ~s(name="item[ecommerce][shop_status]")
      assert html =~ ~s(name="item[ecommerce][product_type]")
      assert html =~ ~s(name="item[ecommerce][vendor]")
      assert html =~ ~s(name="item[ecommerce][compare_at_price]")
    end

    test "renders the current values from data[\"ecommerce\"]" do
      html =
        render_component(&Extension.item_section/1,
          form: nil,
          item: nil,
          data: %{"ecommerce" => %{"vendor" => "Acme Co"}},
          current_language: "en-US"
        )

      assert html =~ "Acme Co"
    end

    test "carries every other language's price_unit forward as a hidden input" do
      html =
        render_component(&Extension.item_section/1,
          form: nil,
          item: nil,
          data: %{
            "ecommerce" => %{
              "price_unit" => %{"en-US" => "per hour", "fr-FR" => "par heure"}
            }
          },
          current_language: "en-US"
        )

      assert html =~
               ~s(<input type="hidden" name="item[ecommerce][price_unit][fr-FR]" value="par heure">)

      # The current language's price_unit has no hidden carry-forward
      # input of its own — only the visible one.
      refute html =~ ~s(<input type="hidden" name="item[ecommerce][price_unit][en-US]")
    end
  end

  describe "category_section/1" do
    test "renders inputs named category[ecommerce][*]" do
      html =
        render_component(&Extension.category_section/1,
          form: nil,
          category: nil,
          data: %{},
          current_language: "en-US"
        )

      assert html =~ ~s(id="ext-ecommerce-section")
      assert html =~ ~s(name="category[ecommerce][shop_status]")
    end
  end

  describe "extension cast errors surface in the section" do
    test "item_section/1 renders a compare_at_price error tagged for this extension" do
      form = form_with_extension_error(:compare_at_price, "must be greater than or equal to 0")

      html =
        render_component(&Extension.item_section/1,
          form: form,
          item: nil,
          data: %{},
          current_language: "en-US"
        )

      assert html =~ ~s(id="ext-ecommerce-section")
      assert html =~ "must be greater than or equal to 0"
    end

    test "item_section/1 does not render another extension's error" do
      form = form_with_extension_error(:compare_at_price, "wrong extension", extension: "other")

      html =
        render_component(&Extension.item_section/1,
          form: form,
          item: nil,
          data: %{},
          current_language: "en-US"
        )

      refute html =~ "wrong extension"
    end

    test "category_section/1 renders a shop_status error tagged for this extension" do
      form = form_with_extension_error(:shop_status, "is invalid")

      html =
        render_component(&Extension.category_section/1,
          form: form,
          category: nil,
          data: %{},
          current_language: "en-US"
        )

      assert html =~ ~s(id="ext-ecommerce-section")
      assert html =~ "is invalid"
    end
  end

  defp form_with_extension_error(field, message, opts \\ []) do
    extension = Keyword.get(opts, :extension, "ecommerce")

    {%{}, %{}}
    |> Ecto.Changeset.cast(%{}, [])
    |> Ecto.Changeset.add_error(:data, message, extension: extension, field: field)
    |> Phoenix.Component.to_form(as: :item, action: :validate)
  end
end
