defmodule PhoenixKitEcommerce.Catalogue.ShopSectionsTest do
  @moduledoc """
  DB-backed coverage for `ShopSections.category/1`'s featured-item picker
  (`Query.category_item_image_options/1`-driven `<.select>`), complementing
  the no-DB render checks in `Catalogue.ExtensionTest`.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  # Needs `phoenix_kit_catalogue` loaded — excluded via `test_helper.exs`'s
  # `ExUnit.configure(exclude: ...)` whenever the optional dependency
  # isn't present, same as `catalogue_query_test.exs`. `async: false`:
  # `Query.catalogue_uuid/0` resolves the shop's one catalogue by NAME
  # across the whole test DB.
  @moduletag :catalogue

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}

  import Phoenix.LiveViewTest

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce.Catalogue.ShopSections

  setup do
    {:ok, catalogue} = Catalogue.create_catalogue(%{name: "decor3dprint"})

    {:ok, category} =
      Catalogue.create_category(%{name: "Vases", catalogue_uuid: catalogue.uuid})

    %{catalogue: catalogue, category: category}
  end

  defp create_item(catalogue, attrs) do
    {:ok, item} = Catalogue.create_item(Map.merge(%{catalogue_uuid: catalogue.uuid}, attrs))
    item
  end

  describe "category/1 featured item picker" do
    test "lists only items in this category that carry an image", %{
      catalogue: catalogue,
      category: category
    } do
      create_item(catalogue, %{
        name: "No Image Here",
        base_price: Decimal.new("1.00"),
        category_uuid: category.uuid
      })

      with_image =
        create_item(catalogue, %{
          name: "With Image",
          base_price: Decimal.new("1.00"),
          category_uuid: category.uuid,
          data: %{"featured_image_uuid" => "img-1"}
        })

      html =
        render_component(&ShopSections.category/1,
          form: nil,
          category: category,
          data: %{},
          current_language: "en-US"
        )

      assert html =~ ~s(name="category[ecommerce][featured_item_uuid]")
      assert html =~ with_image.name
      refute html =~ "No Image Here"
    end

    test "the currently selected featured item is preselected", %{
      catalogue: catalogue,
      category: category
    } do
      item =
        create_item(catalogue, %{
          name: "Featured One",
          base_price: Decimal.new("1.00"),
          category_uuid: category.uuid,
          data: %{"featured_image_uuid" => "img-1"}
        })

      html =
        render_component(&ShopSections.category/1,
          form: nil,
          category: category,
          data: %{"ecommerce" => %{"featured_item_uuid" => item.uuid}},
          current_language: "en-US"
        )

      [radio] = Regex.run(~r/<input[^>]*value="#{item.uuid}"[^>]*>/, html)
      assert radio =~ "checked"

      # The tile shows the picture the item would give the category, not
      # just its name.
      assert html =~ ~s(alt="Featured One")
      assert html =~ "/file/img-1/small"
    end

    test "shows an explanatory message instead of an empty picker when no items have images", %{
      category: category
    } do
      html =
        render_component(&ShopSections.category/1,
          form: nil,
          category: category,
          data: %{},
          current_language: "en-US"
        )

      refute html =~ ~s(name="category[ecommerce][featured_item_uuid]")
      assert html =~ "No items with images in this category"
    end

    test "a category not yet saved (uuid: nil) shows the explanatory message, no query crash" do
      html =
        render_component(&ShopSections.category/1,
          form: nil,
          category: %PhoenixKitCatalogue.Schemas.Category{uuid: nil},
          data: %{},
          current_language: "en-US"
        )

      refute html =~ ~s(name="category[ecommerce][featured_item_uuid]")
      assert html =~ "No items with images in this category"
    end
  end
end
