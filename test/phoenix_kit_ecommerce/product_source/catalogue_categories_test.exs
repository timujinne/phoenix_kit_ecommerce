defmodule PhoenixKitEcommerce.ProductSource.CatalogueCategoriesTest do
  use PhoenixKitEcommerce.DataCase, async: false

  # Needs `phoenix_kit_catalogue` loaded (with its own migrations applied
  # to the test DB) — excluded via `test_helper.exs`'s
  # `ExUnit.configure(exclude: ...)` whenever the optional dependency
  # isn't present, same as `catalogue_query_test.exs`. `async: false`:
  # `Query.catalogue_uuid/0` resolves the shop's one catalogue by NAME
  # across the whole test DB, so two async tests both bootstrapping a
  # catalogue named "decor3dprint" would race.
  @moduletag :catalogue

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce.Category
  alias PhoenixKitEcommerce.ProductSource.Catalogue, as: CatalogueSource

  setup do
    {:ok, catalogue} = Catalogue.create_catalogue(%{name: "decor3dprint"})
    %{catalogue: catalogue}
  end

  defp create_item(catalogue, attrs) do
    {:ok, item} = Catalogue.create_item(Map.merge(%{catalogue_uuid: catalogue.uuid}, attrs))
    item
  end

  describe "list_categories/1" do
    test "attaches each category's resolved featured-item image, in a constant number of queries",
         %{catalogue: catalogue} do
      for n <- 1..5 do
        {:ok, category} =
          Catalogue.create_category(%{name: "Cat #{n}", catalogue_uuid: catalogue.uuid})

        create_item(catalogue, %{
          name: "Item #{n}",
          base_price: Decimal.new("1.00"),
          category_uuid: category.uuid,
          data: %{
            "ecommerce" => %{"shop_status" => "active"},
            "featured_image_uuid" => "img-#{n}"
          }
        })
      end

      handler_id = {:list_categories_query_count, self()}
      test_pid = self()

      # Counts only queries against `phoenix_kit_cat_items` — the table
      # `resolve_category_images/1`'s auto-detect step reads. Every OTHER
      # query `list_categories/1` fires (catalogue/category lookups,
      # `Translations.enabled_languages/0` per category building its
      # view) is pre-existing behavior this task doesn't touch; counting
      # everything would conflate that with what's actually under test
      # here — whether the ITEM read is batched.
      :telemetry.attach(
        handler_id,
        [:phoenix_kit_ecommerce, :test, :repo, :query],
        fn _event, _measurements, %{query: query}, _config ->
          if query =~ "phoenix_kit_cat_items", do: send(test_pid, :items_query_ran)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      result = CatalogueSource.list_categories()

      assert length(result) == 5
      images = Enum.map(result, &Category.get_image_url/1)
      assert Enum.all?(images, &(&1 != nil))

      # All 5 categories auto-detect their image (none set an explicit
      # `featured_item_uuid`) — one batched query against
      # `phoenix_kit_cat_items` for the whole page, never one per
      # category (which would show as 5 here).
      assert count_received(:items_query_ran) == 1
    end

    test "a category with no featured-item image resolved has no image", %{catalogue: catalogue} do
      {:ok, _category} =
        Catalogue.create_category(%{name: "Bare Cat", catalogue_uuid: catalogue.uuid})

      [result] = CatalogueSource.list_categories()

      assert Category.get_image_url(result) == nil
    end

    test "a picture uploaded for the category itself beats the chosen featured item", %{
      catalogue: catalogue
    } do
      {:ok, category} =
        Catalogue.create_category(%{name: "Own Picture", catalogue_uuid: catalogue.uuid})

      {:ok, item} =
        Catalogue.create_item(%{
          name: "Demo Item",
          base_price: Decimal.new("1.00"),
          catalogue_uuid: catalogue.uuid,
          category_uuid: category.uuid,
          data: %{"featured_image_uuid" => "item-picture"}
        })

      # Both set at once: the category carries its own uploaded picture AND
      # names this item as its demonstration piece.
      {:ok, _category} =
        Catalogue.update_category(category, %{
          data: %{
            "featured_image_uuid" => "category-own-picture",
            "ecommerce" => %{"featured_item_uuid" => item.uuid}
          }
        })

      [result] = CatalogueSource.list_categories()

      assert result.image_uuid == "category-own-picture"

      assert Category.get_image_url(result) ==
               Category.get_image_url(%Category{image_uuid: "category-own-picture"})
    end

    defp count_received(message, acc \\ 0) do
      receive do
        ^message -> count_received(message, acc + 1)
      after
        0 -> acc
      end
    end
  end

  describe "get_category/2" do
    test "resolves the featured-item image for a single category", %{catalogue: catalogue} do
      {:ok, category} =
        Catalogue.create_category(%{name: "Cat", catalogue_uuid: catalogue.uuid})

      create_item(catalogue, %{
        name: "Item",
        base_price: Decimal.new("1.00"),
        category_uuid: category.uuid,
        data: %{
          "ecommerce" => %{"shop_status" => "active"},
          "featured_image_uuid" => "img-single"
        }
      })

      result = CatalogueSource.get_category(category.uuid)

      assert Category.get_image_url(result) != nil
    end

    test "nil for an unknown uuid", %{catalogue: _catalogue} do
      assert CatalogueSource.get_category(Ecto.UUID.generate()) == nil
    end
  end
end
