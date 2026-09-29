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
      # Catalogue form convention: sentence case, core labels (no daisyUI
      # `.fieldset`, which shrinks them to 12px), 16px heading with icon.
      assert html =~ "Product type"
      assert html =~ "Compare at price"
      assert html =~ "Cost per item"
      assert html =~ "text-base font-semibold text-base-content/80"
      refute html =~ "fieldset"
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

    test "renders the price-fit rule select on a Shopify-linked item, never_cheaper when unset" do
      html =
        render_component(&Extension.item_section/1,
          form: nil,
          item: nil,
          data: %{"ecommerce" => %{"shopify" => %{"handle" => "mug"}}},
          current_language: "en"
        )

      assert html =~ ~s(name="item[ecommerce][price_fit_rule]")

      assert html =~
               ~r/<option[^>]*selected[^>]*value="never_cheaper"|<option[^>]*value="never_cheaper"[^>]*selected/
    end

    test "shows the approximation note from shopify.price_fit" do
      data = %{
        "ecommerce" => %{
          "price_fit_rule" => "cheapest",
          "shopify" => %{
            "handle" => "sculpture",
            "price_fit" => %{
              "rule" => "cheapest",
              "variants" => 256,
              "over" => 0,
              "under" => 21,
              "max_over" => "0.00",
              "max_under" => "32.00"
            }
          }
        }
      }

      html =
        render_component(&Extension.item_section/1,
          form: nil,
          item: nil,
          data: data,
          current_language: "en"
        )

      assert html =~ ~s(id="ext-ecommerce-price-fit")
      # Nothing is priced above Shopify under this fit, so the note says
      # only what is below — never "0 of 256 above, up to +0.00".
      assert html =~ "21 of 256 variants below Shopify, up to -32.00"
      refute html =~ "above Shopify"
    end

    test "an over-only fit shows the amount without a below-Shopify sentence" do
      data = %{
        "ecommerce" => %{
          "shopify" => %{
            "product_id" => "9906019696978",
            "price_fit" => %{
              "rule" => "never_cheaper",
              "variants" => 14,
              "over" => 5,
              "under" => 0,
              "max_over" => "5.40",
              "max_under" => "0.00"
            }
          }
        }
      }

      html =
        render_component(&Extension.item_section/1,
          form: nil,
          item: nil,
          data: data,
          current_language: "en"
        )

      assert html =~ ~s(id="ext-ecommerce-price-fit")
      assert html =~ "5.40"
      refute html =~ "below Shopify"
    end

    test "no note for an exact product" do
      html =
        render_component(&Extension.item_section/1,
          form: nil,
          item: nil,
          data: %{"ecommerce" => %{"shopify" => %{"handle" => "mug"}}},
          current_language: "en"
        )

      refute html =~ ~s(id="ext-ecommerce-price-fit")
    end

    test "no price-fit control on an item the Shopify sync does not write" do
      html =
        render_component(&Extension.item_section/1,
          form: nil,
          item: nil,
          data: %{"ecommerce" => %{"shopify" => %{}}},
          current_language: "en"
        )

      refute html =~ ~s(name="item[ecommerce][price_fit_rule]")
    end

    test "a fit both above and below Shopify says both" do
      html = render_fit(%{"over" => 2, "under" => 3, "max_over" => "5.40", "max_under" => "3.60"})

      assert html =~ "2 of 14 variants above Shopify, up to +5.40."
      assert html =~ "3 below Shopify, up to -3.60."
    end

    test "a base price off Shopify's cheapest variant is named with its fix" do
      html = render_fit(%{"under" => 14, "max_under" => "19.28", "base_offset" => "-19.28"})

      assert html =~
               "At the last variants sync the base price was -19.28 off Shopify&#39;s cheapest variant"

      assert html =~ "Changes"
    end

    test "a base that only drifted says so, without calling the price approximated" do
      html =
        render_fit(%{
          "approximated" => false,
          "under" => 9,
          "max_under" => "34.00",
          "base_offset" => "-34.00"
        })

      assert html =~ "base price was -34.00 off"
      refute html =~ "Price approximated"
    end

    test "a zero base offset adds nothing" do
      html = render_fit(%{"over" => 5, "max_over" => "5.40", "base_offset" => "0.00"})
      refute html =~ "base price"
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
      # #61 lowercased the msgid; the fuzzy msgstr still said "products".
      assert html =~ "Active — category and items visible"
      refute html =~ "products visible"
      assert html =~ "text-base font-semibold text-base-content/80"
      refute html =~ "fieldset"
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

  defp render_fit(fields) do
    fit =
      Map.merge(
        %{
          "rule" => "never_cheaper",
          "variants" => 14,
          "over" => 0,
          "under" => 0,
          "max_over" => "0.00",
          "max_under" => "0.00"
        },
        fields
      )

    render_component(&Extension.item_section/1,
      form: nil,
      item: nil,
      data: %{"ecommerce" => %{"shopify" => %{"handle" => "personalized", "price_fit" => fit}}},
      current_language: "en"
    )
  end
end
