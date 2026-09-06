defmodule PhoenixKitEcommerce.ProductSource.Catalogue.FiltersTest do
  @moduledoc """
  Storefront filters on catalogue attribute sets (2026-09-06 plan, Task 1):
  facet counts via `Query.attribute_set_counts/2`, slug filtering via the
  existing `Query.filter_by_metadata/2`, and the `metadata_option` (the
  live "size" filter) / `attribute_set` alias in
  `ProductSource.Catalogue.aggregate_filter_values/1`.

  Needs `phoenix_kit_catalogue` AND `phoenix_kit_entities` loaded (with
  their migrations applied to the test DB) — excluded via
  `test_helper.exs`'s `ExUnit.configure(exclude: ...)` whenever the
  optional dependency isn't present. `async: false`: `Query.catalogue_uuid/0`
  resolves the shop's one catalogue by NAME across the whole test DB.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :catalogue

  # Quiets the compiler's static xref check for `mix test` runs where the
  # optional `phoenix_kit_catalogue`/`phoenix_kit_entities` dependencies
  # aren't declared — every test in this module is excluded in that case
  # (see `test_helper.exs`), so the calls below are never actually reached.
  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}
  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue.AttributeSets}
  @compile {:no_warn_undefined, PhoenixKitEntities.EntityData}

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.AttributeSets
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.ProductSource.Catalogue, as: CatalogueSource
  alias PhoenixKitEcommerce.ProductSource.Catalogue.Query
  alias PhoenixKitEcommerce.ProductSource.Catalogue.View

  setup do
    # Entities gates on a settings toggle (default false) — same setup
    # `phoenix_kit_catalogue`'s own `AttributeSetsTest` uses.
    AttributeSets.register_deletion_guard()
    PhoenixKit.Settings.update_setting("entities_enabled", "true")
    on_exit(fn -> PhoenixKit.Settings.update_setting("entities_enabled", "false") end)

    {:ok, catalogue} = Catalogue.create_catalogue(%{name: "decor3dprint"})
    {:ok, set} = AttributeSets.create_set(%{name: "Size"}, actor_uuid: Ecto.UUID.generate())

    {:ok, small} =
      AttributeSets.create_value(set, %{label: "Small", slug: "s"},
        actor_uuid: Ecto.UUID.generate()
      )

    {:ok, medium} =
      AttributeSets.create_value(set, %{label: "Medium", slug: "m"},
        actor_uuid: Ecto.UUID.generate()
      )

    {:ok, large} =
      AttributeSets.create_value(set, %{label: "Large", slug: "l"},
        actor_uuid: Ecto.UUID.generate()
      )

    {:ok, category_x} = Catalogue.create_category(%{name: "X", catalogue_uuid: catalogue.uuid})

    {:ok, category_y} =
      Catalogue.create_category(%{
        name: "Y",
        catalogue_uuid: catalogue.uuid,
        data: %{"ecommerce" => %{"shop_status" => "hidden"}}
      })

    item_a = create_item(catalogue, category_x, "Item A")
    item_b = create_item(catalogue, category_x, "Item B")
    item_c = create_item(catalogue, category_y, "Item C", shop_status: "archived")

    attach(item_a, set, ["s", "m"])
    attach(item_b, set, ["m"])
    attach(item_c, set, ["l"])

    %{
      catalogue: catalogue,
      set: set,
      values: %{small: small, medium: medium, large: large},
      category_x: category_x,
      category_y: category_y,
      items: %{a: item_a, b: item_b, c: item_c}
    }
  end

  defp create_item(catalogue, category, name, opts \\ []) do
    shop_status = Keyword.get(opts, :shop_status, "active")

    {:ok, item} =
      Catalogue.create_item(%{
        catalogue_uuid: catalogue.uuid,
        category_uuid: category.uuid,
        name: name,
        base_price: Decimal.new("10.00"),
        status: "active",
        data: %{"ecommerce" => %{"shop_status" => shop_status}}
      })

    item
  end

  defp attach(item, set, slugs) do
    {:ok, _} = AttributeSets.attach_set(item.uuid, set.uuid)
    :ok = AttributeSets.set_attachment_selection(item.uuid, set.uuid, slugs)
  end

  describe "Query.attribute_set_counts/2" do
    test "counts storefront-visible items per value, scoped to a category, ordered by position",
         %{category_x: category_x} do
      assert Query.attribute_set_counts("size", category_uuid: category_x.uuid) == [
               %{slug: "s", label: "Small", count: 1},
               %{slug: "m", label: "Medium", count: 2}
             ]
    end

    test "excludes items from a hidden category via :exclude_hidden_categories", %{
      category_x: category_x,
      category_y: category_y,
      items: %{c: item_c}
    } do
      # Re-activate item C's shop_status so only its category's hidden
      # status is what excludes it from this assertion (it stays
      # attached to "l" from the setup block).
      {:ok, _} =
        Catalogue.update_item(item_c, %{data: %{"ecommerce" => %{"shop_status" => "active"}}})

      without_exclusion = Query.attribute_set_counts("size", [])
      assert Enum.find(without_exclusion, &(&1.slug == "l"))

      with_exclusion = Query.attribute_set_counts("size", exclude_hidden_categories: true)
      refute Enum.find(with_exclusion, &(&1.slug == "l"))

      # category_x/category_y are only used to keep the fixture realistic
      # (an "l" value exclusively in the hidden category).
      assert category_x.uuid != category_y.uuid
    end

    test "a draft (unpublished) value never appears in the facet", %{values: %{large: large}} do
      {:ok, _} = PhoenixKitEntities.EntityData.update(large, %{status: "draft"})

      refute Enum.find(Query.attribute_set_counts("size", []), &(&1.slug == "l"))
    end

    test "returns [] for an unknown set slug" do
      assert Query.attribute_set_counts("no-such-set", []) == []
    end
  end

  describe "Query.filter_by_metadata/2 via list_items/1 (value slugs)" do
    test "matches items whose selection includes any of the given slugs" do
      results = Query.list_items(metadata_filters: [%{key: "size", values: ["m"]}])
      assert Enum.map(results, & &1.name) |> Enum.sort() == ["Item A", "Item B"]
    end
  end

  describe "ProductSource.Catalogue.aggregate_filter_values/1" do
    test "a metadata_option filter (the live \"size\" filter, unmigrated) resolves through attribute_set_counts",
         %{category_x: category_x} do
      {:ok, _} =
        Shop.update_storefront_filters([
          %{
            "key" => "size",
            "type" => "metadata_option",
            "option_key" => "size",
            "label" => "Size",
            "enabled" => true,
            "position" => 0
          }
        ])

      values = CatalogueSource.aggregate_filter_values(category_uuid: category_x.uuid)

      assert values["size"] == [
               %{slug: "s", label: "Small", count: 1},
               %{slug: "m", label: "Medium", count: 2}
             ]
    end

    test "an attribute_set filter resolves the same way, by set_slug", %{category_x: category_x} do
      {:ok, _} =
        Shop.update_storefront_filters([
          %{
            "key" => "size",
            "type" => "attribute_set",
            "set_slug" => "size",
            "label" => "Size",
            "enabled" => true,
            "position" => 0
          }
        ])

      values = CatalogueSource.aggregate_filter_values(category_uuid: category_x.uuid)

      assert values["size"] == [
               %{slug: "s", label: "Small", count: 1},
               %{slug: "m", label: "Medium", count: 2}
             ]
    end

    test "forwards :exclude_hidden_categories to attribute_set_counts (review fix)", %{
      items: %{c: item_c}
    } do
      # Isolate the category-hidden exclusion from item C's own
      # shop_status (setup archives it) — only category_y being hidden
      # should decide whether "l" appears here.
      {:ok, _} =
        Catalogue.update_item(item_c, %{data: %{"ecommerce" => %{"shop_status" => "active"}}})

      {:ok, _} =
        Shop.update_storefront_filters([
          %{
            "key" => "size",
            "type" => "attribute_set",
            "set_slug" => "size",
            "label" => "Size",
            "enabled" => true,
            "position" => 0
          }
        ])

      without_exclusion = CatalogueSource.aggregate_filter_values([])
      assert Enum.find(without_exclusion["size"], &(&1.slug == "l"))

      with_exclusion = CatalogueSource.aggregate_filter_values(exclude_hidden_categories: true)
      refute Enum.find(with_exclusion["size"], &(&1.slug == "l"))
    end
  end

  describe "Query.set_display_names/2 and Query.set_label/2 (2026-09-06 plan, Task 3)" do
    test "resolves a set's translated display name, falling back to the bare name", %{set: set} do
      {:ok, _} =
        PhoenixKitEntities.set_entity_translation(set, "fr-FR", %{"display_name" => "Taille"})

      assert Query.set_display_names([set.uuid], "fr-FR") == %{set.uuid => "Taille"}
      # No fr-FR-specific data for a language with no translation saved —
      # falls back to the untranslated blueprint name.
      assert Query.set_display_names([set.uuid], "de-DE") == %{set.uuid => "Size"}
    end

    test "an unresolvable set uuid is simply absent from the result" do
      assert Query.set_display_names([Ecto.UUID.generate()], "fr-FR") == %{}
    end

    test "set_label/2 resolves by the filter config's slug (with or without the set prefix)", %{
      set: set
    } do
      {:ok, _} =
        PhoenixKitEntities.set_entity_translation(set, "fr-FR", %{"display_name" => "Taille"})

      assert Query.set_label("size", "fr-FR") == "Taille"
      assert Query.set_label("catalogue_set_size", "fr-FR") == "Taille"
    end

    test "set_label/2 is nil for a slug that resolves to no set" do
      assert Query.set_label("no-such-set", "fr-FR") == nil
    end
  end

  describe "ProductSource.Catalogue.translate_filter_label/2" do
    test "swaps an attribute_set filter's label for the set's translated display name", %{
      set: set
    } do
      {:ok, _} =
        PhoenixKitEntities.set_entity_translation(set, "fr-FR", %{"display_name" => "Taille"})

      filter = %{
        "key" => "size",
        "type" => "attribute_set",
        "set_slug" => "size",
        "label" => "Size"
      }

      assert CatalogueSource.translate_filter_label(filter, "fr-FR") ==
               Map.put(filter, "label", "Taille")
    end

    test "an unresolvable set falls back to the filter's own label unchanged" do
      filter = %{
        "key" => "x",
        "type" => "attribute_set",
        "set_slug" => "no-such-set",
        "label" => "X"
      }

      assert CatalogueSource.translate_filter_label(filter, "fr-FR") == filter
    end

    test "a non-attribute-set filter is returned unchanged" do
      filter = %{"key" => "vendor", "type" => "vendor", "label" => "Vendor"}
      assert CatalogueSource.translate_filter_label(filter, "fr-FR") == filter
    end
  end

  describe "aggregate_filter_values/1 threads :language into attribute_set_counts" do
    test "facet value labels are translated for the requested language", %{
      category_x: category_x,
      values: %{small: small}
    } do
      {:ok, _} = PhoenixKitEntities.EntityData.set_title_translation(small, "fr-FR", "Petit")

      {:ok, _} =
        Shop.update_storefront_filters([
          %{
            "key" => "size",
            "type" => "attribute_set",
            "set_slug" => "size",
            "label" => "Size",
            "enabled" => true,
            "position" => 0
          }
        ])

      values =
        CatalogueSource.aggregate_filter_values(category_uuid: category_x.uuid, language: "fr-FR")

      assert values["size"] == [
               %{slug: "s", label: "Petit", count: 1},
               %{slug: "m", label: "Medium", count: 2}
             ]
    end
  end

  describe "category-aware aggregate_filter_values/1 (Task 2 storefront_filters overrides)" do
    test "a category-only attribute_set filter gets its facet counted, not just listed empty",
         %{category_x: category_x} do
      {:ok, category_x} =
        Catalogue.update_category(category_x, %{
          data: %{
            "ecommerce" => %{
              "storefront_filters" => %{
                "size" => %{
                  "type" => "attribute_set",
                  "set_slug" => "size",
                  "label" => "Size",
                  "enabled" => true,
                  "position" => 0
                }
              }
            }
          }
        })

      category_view = View.category_view(category_x)

      values =
        CatalogueSource.aggregate_filter_values(
          category_uuid: category_x.uuid,
          category: category_view
        )

      assert values["size"] == [
               %{slug: "s", label: "Small", count: 1},
               %{slug: "m", label: "Medium", count: 2}
             ]
    end
  end
end
