defmodule PhoenixKitEcommerce.Shopify.CollectionSyncTest do
  @moduledoc """
  `PhoenixKitEcommerce.Shopify.CollectionSync.run/1` — Block 7 Task 4
  (`docs/superpowers/plans/2026-09-06-block7-shopify-media-collections.md`):
  Shopify collections mapped onto catalogue categories with order
  preserved, and catalogue items placed into the right category at the
  right position from the collections' product lists; plus Block 7b
  Task 2 (`docs/superpowers/plans/2026-09-06-block7b-shopify-live-fixes.md`):
  the `:filter` allowlist (collections not matching are skipped
  entirely) and most-specific-collection-wins assignment.

  Needs `phoenix_kit_catalogue` loaded (real `Catalogue.create_category/2`
  / `update_category/3` / `update_item/2` against a live catalogue) —
  tagged `:catalogue` and excluded via `test_helper.exs` whenever the
  optional dependency isn't present, same as `writer_variants_test.exs`/
  `writer_images_test.exs`. `async: false`: flips the process-wide
  `shop_product_source` config key. `opts[:client]` is a stub module
  (this test's own `@stub`) — no real HTTP, per Global Constraints.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :catalogue

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce.ShopConfig
  alias PhoenixKitEcommerce.Shopify.CollectionSync
  alias PhoenixKitEcommerce.Test.Repo

  setup do
    on_exit(fn -> set_product_source("legacy") end)

    {:ok, catalogue} =
      Catalogue.create_catalogue(%{name: "collection-sync-#{System.unique_integer([:positive])}"})

    %{catalogue: catalogue}
  end

  defp set_product_source(value) do
    case Repo.get(ShopConfig, "shop_product_source") do
      nil ->
        %ShopConfig{}
        |> ShopConfig.changeset(%{key: "shop_product_source", value: %{"value" => value}})
        |> Repo.insert!()

      config ->
        config
        |> ShopConfig.changeset(%{value: %{"value" => value}})
        |> Repo.update!()
    end
  end

  defp create_item(catalogue_uuid, name, product_id, attrs \\ %{}) do
    {:ok, item} =
      Catalogue.create_item(
        Map.merge(
          %{
            catalogue_uuid: catalogue_uuid,
            name: name,
            base_price: Decimal.new("10.00"),
            status: "active",
            data: %{
              "ecommerce" => %{
                "shop_status" => "active",
                "shopify" => %{"product_id" => to_string(product_id)}
              }
            }
          },
          attrs
        )
      )

    item
  end

  # Two Shopify collections, both listing 2 products (a tie in
  # specificity — see `target_category_and_position/1`'s own comment on
  # ties breaking to (filtered) API order, which lists "frames" first):
  #   - "frames" (id 1, position 0) — matches a pre-existing category by
  #     handle, product 111 already lives there from a previous run.
  #   - "gifts" (id 2, position 1) — no local category, gets created;
  #     product 111 is ALSO listed here (tied with frames, so the
  #     API-order tie-break keeps it in Frames); product 222 is new and
  #     gets assigned to Gifts; product 999 is unknown.
  defmodule Stub do
    @moduledoc false

    def fetch_collections(_opts) do
      {:ok,
       [
         %{
           "id" => 1,
           "handle" => "frames",
           "title" => "Frames",
           "kind" => "custom",
           "position" => 0
         },
         %{
           "id" => 2,
           "handle" => "gifts",
           "title" => "Gifts",
           "kind" => "custom",
           "position" => 1
         }
       ]}
    end

    def fetch_collection_product_ids(1, _opts), do: {:ok, [111, 999]}
    def fetch_collection_product_ids(2, _opts), do: {:ok, [111, 222]}
  end

  # Same two collections as `Stub`, except product 111 has moved out of
  # "frames" entirely and now lives only in "gifts" — used by the
  # moved-product test below.
  defmodule MovedStub do
    @moduledoc false

    def fetch_collections(_opts) do
      {:ok,
       [
         %{"id" => 1, "handle" => "frames", "title" => "Frames", "position" => 0},
         %{"id" => 2, "handle" => "gifts", "title" => "Gifts", "position" => 1}
       ]}
    end

    def fetch_collection_product_ids(1, _opts), do: {:ok, []}
    def fetch_collection_product_ids(2, _opts), do: {:ok, [111]}
  end

  # A single collection whose handle collides, cross-catalogue, with an
  # already-taken slug — used by the create-path error-propagation test.
  defmodule CollisionStub do
    @moduledoc false

    def fetch_collections(_opts) do
      {:ok, [%{"id" => 1, "handle" => "gifts", "title" => "Gifts", "position" => 0}]}
    end

    def fetch_collection_product_ids(1, _opts), do: {:ok, []}
  end

  # Same two collections as `Stub`, except "frames" now lists 3 products
  # (111, 999, 888) against "gifts"'s 2 (111, 222) — no longer a tie, so
  # the most-specific rule has a real winner to test.
  defmodule MostSpecificStub do
    @moduledoc false

    def fetch_collections(_opts) do
      {:ok,
       [
         %{"id" => 1, "handle" => "frames", "title" => "Frames", "position" => 0},
         %{"id" => 2, "handle" => "gifts", "title" => "Gifts", "position" => 1}
       ]}
    end

    def fetch_collection_product_ids(1, _opts), do: {:ok, [111, 999, 888]}
    def fetch_collection_product_ids(2, _opts), do: {:ok, [111, 222]}
  end

  # Four Shopify collections mimicking the live store's shape: two
  # `3d-printed-*` categories that should pass an allowlist filter, an
  # explicitly excluded `3d-printed-*` ("featured mix"), and an
  # unrelated collection that doesn't match the prefix at all.
  # `fetch_collection_product_ids/2` has NO clause for ids 2 or 3 —
  # calling it for either would raise, proving a filtered-out collection
  # is never even asked for its products.
  defmodule FilterStub do
    @moduledoc false

    def fetch_collections(_opts) do
      {:ok,
       [
         %{"id" => 1, "handle" => "3d-printed-frames", "title" => "Frames", "position" => 0},
         %{"id" => 2, "handle" => "3d-printed-items", "title" => "Items", "position" => 1},
         %{"id" => 3, "handle" => "imported-from-etsy", "title" => "Etsy", "position" => 2},
         %{"id" => 4, "handle" => "3d-printed-gifts", "title" => "Gifts", "position" => 3}
       ]}
    end

    def fetch_collection_product_ids(1, _opts), do: {:ok, [111]}
    def fetch_collection_product_ids(4, _opts), do: {:ok, [222]}
  end

  describe "run/1 — legacy source" do
    test "is a no-op returning :catalogue_source_inactive" do
      assert CollectionSync.run(client: Stub, catalogue_uuid: Ecto.UUID.generate()) ==
               {:error, :catalogue_source_inactive}
    end
  end

  describe "run/1 — catalogue source" do
    setup do
      set_product_source("catalogue")
      :ok
    end

    test "requires a catalogue_uuid" do
      assert CollectionSync.run(client: Stub) == {:error, :missing_catalogue_uuid}
    end

    test "matches an existing category by handle and updates its position", %{
      catalogue: catalogue
    } do
      {:ok, frames} =
        Catalogue.create_category(%{
          name: "Frames (old title)",
          catalogue_uuid: catalogue.uuid,
          slug: %{"en" => "frames"},
          position: 9
        })

      create_item(catalogue.uuid, "Frame A", 111)
      create_item(catalogue.uuid, "Gift A", 222)

      assert {:ok, result} = CollectionSync.run(client: Stub, catalogue_uuid: catalogue.uuid)
      assert result.categories_matched == 1
      assert result.categories_created == 1

      updated_frames = Catalogue.get_category!(frames.uuid)
      assert updated_frames.position == 0
      assert updated_frames.data["ecommerce"]["shopify"]["collection_id"] == "1"
    end

    test "creates a category for a collection with no local match, position = collection position",
         %{catalogue: catalogue} do
      create_item(catalogue.uuid, "Frame A", 111)

      assert {:ok, _result} = CollectionSync.run(client: Stub, catalogue_uuid: catalogue.uuid)

      [gifts] =
        catalogue.uuid
        |> Catalogue.list_categories_metadata_for_catalogue()
        |> Enum.filter(&(&1.name == "Gifts"))

      assert gifts.position == 1
      assert gifts.data["ecommerce"]["shopify"]["collection_id"] == "2"
      assert gifts.parent_uuid == nil
      assert gifts.slug["en"] == "gifts"
    end

    test "assigns an unassigned item to its collection's category, at its list position", %{
      catalogue: catalogue
    } do
      item = create_item(catalogue.uuid, "Gift A", 222)
      assert item.category_uuid == nil

      assert {:ok, result} = CollectionSync.run(client: Stub, catalogue_uuid: catalogue.uuid)
      assert result.items_assigned == 1
      # A brand-new category assignment is counted only under
      # `items_assigned` — counting it under `items_repositioned` too
      # would overstate the number of items whose position changed
      # WITHIN an already-correct category.
      assert result.items_repositioned == 0

      [gifts] =
        catalogue.uuid
        |> Catalogue.list_categories_metadata_for_catalogue()
        |> Enum.filter(&(&1.name == "Gifts"))

      updated = Catalogue.get_item!(item.uuid)
      assert updated.category_uuid == gifts.uuid
      assert updated.position == 1
    end

    test "a product tied for specificity across two collections settles on the API-order tie-break",
         %{catalogue: catalogue} do
      {:ok, frames} =
        Catalogue.create_category(%{
          name: "Frames",
          catalogue_uuid: catalogue.uuid,
          slug: %{"en" => "frames"},
          position: 0
        })

      item =
        create_item(catalogue.uuid, "Frame A", 111, %{category_uuid: frames.uuid, position: 5})

      assert {:ok, result} = CollectionSync.run(client: Stub, catalogue_uuid: catalogue.uuid)

      updated = Catalogue.get_item!(item.uuid)
      assert updated.category_uuid == frames.uuid
      # Frames is collection id 1, product 111 is at index 0 in its list.
      assert updated.position == 0
      assert result.items_repositioned == 1
      assert result.items_assigned == 0
    end

    test "a product moved to a different collection in Shopify is reassigned, not left in its old category",
         %{catalogue: catalogue} do
      {:ok, frames} =
        Catalogue.create_category(%{
          name: "Frames",
          catalogue_uuid: catalogue.uuid,
          slug: %{"en" => "frames"},
          position: 0
        })

      # Product 111 currently sits in Frames locally, but THIS stub's
      # frames list is empty and its gifts list carries 111 — Shopify
      # itself moved it, and its own current category is no longer even
      # a candidate (empty list -> not one of `product_categories`'s
      # entries for 111 at all).
      item =
        create_item(catalogue.uuid, "Frame A", 111, %{category_uuid: frames.uuid, position: 3})

      assert {:ok, result} = CollectionSync.run(client: MovedStub, catalogue_uuid: catalogue.uuid)
      assert result.items_assigned == 1

      [gifts] =
        catalogue.uuid
        |> Catalogue.list_categories_metadata_for_catalogue()
        |> Enum.filter(&(&1.name == "Gifts"))

      updated = Catalogue.get_item!(item.uuid)
      assert updated.category_uuid == gifts.uuid
      assert updated.position == 0
    end

    test "an item in several allowed collections is assigned to the most specific one (fewest products), even over its current (bigger) category",
         %{catalogue: catalogue} do
      {:ok, frames} =
        Catalogue.create_category(%{
          name: "Frames",
          catalogue_uuid: catalogue.uuid,
          slug: %{"en" => "frames"},
          position: 0
        })

      # Product 111 currently sits in Frames (3 products: less specific)
      # but is also listed in Gifts (2 products: more specific) — the
      # most-specific rule wins regardless of the item's current
      # category.
      item =
        create_item(catalogue.uuid, "Frame A", 111, %{category_uuid: frames.uuid, position: 5})

      assert {:ok, result} =
               CollectionSync.run(client: MostSpecificStub, catalogue_uuid: catalogue.uuid)

      [gifts] =
        catalogue.uuid
        |> Catalogue.list_categories_metadata_for_catalogue()
        |> Enum.filter(&(&1.name == "Gifts"))

      updated = Catalogue.get_item!(item.uuid)
      assert updated.category_uuid == gifts.uuid
      assert updated.position == 0
      assert result.items_assigned == 1
    end

    test "a product id with no matching local item is reported unmatched", %{catalogue: catalogue} do
      create_item(catalogue.uuid, "Frame A", 111)
      create_item(catalogue.uuid, "Gift A", 222)

      assert {:ok, result} = CollectionSync.run(client: Stub, catalogue_uuid: catalogue.uuid)
      assert result.unmatched_products == [999]
    end

    test "a second run against the same fixture is idempotent", %{catalogue: catalogue} do
      create_item(catalogue.uuid, "Frame A", 111)
      create_item(catalogue.uuid, "Gift A", 222)

      assert {:ok, _first} = CollectionSync.run(client: Stub, catalogue_uuid: catalogue.uuid)
      assert {:ok, second} = CollectionSync.run(client: Stub, catalogue_uuid: catalogue.uuid)

      assert second.categories_created == 0
      assert second.categories_matched == 2
      assert second.items_assigned == 0
      assert second.items_repositioned == 0
      assert second.unmatched_products == [999]
    end

    test "a create-path slug collision returns an error tuple instead of crashing", %{
      catalogue: catalogue
    } do
      # `phoenix_kit_cat_category_slugs`'s PK is `(lang, value)` — global
      # across every catalogue, not scoped to this one — so a category in
      # a completely unrelated catalogue can already own the slug
      # `create_matched_category/6` is about to write for a collection
      # with no LOCAL match by handle or name.
      {:ok, other_catalogue} = Catalogue.create_catalogue(%{name: "unrelated-catalogue"})

      {:ok, _colliding} =
        Catalogue.create_category(%{
          name: "Unrelated Category",
          catalogue_uuid: other_catalogue.uuid,
          slug: %{"en" => "gifts"}
        })

      assert {:error, %Ecto.Changeset{}} =
               CollectionSync.run(client: CollisionStub, catalogue_uuid: catalogue.uuid)
    end

    test "a category with no matching collection is left untouched", %{catalogue: catalogue} do
      {:ok, other} =
        Catalogue.create_category(%{
          name: "Other 3d",
          catalogue_uuid: catalogue.uuid,
          position: 3
        })

      assert {:ok, _result} = CollectionSync.run(client: Stub, catalogue_uuid: catalogue.uuid)

      untouched = Catalogue.get_category!(other.uuid)
      assert untouched.position == 3
      assert untouched.data == %{}
    end
  end

  describe "run/1 — collections filter (Block 7b Task 2)" do
    setup do
      set_product_source("catalogue")
      :ok
    end

    test "a prefix/exclude filter skips non-matching collections entirely — no category, no product fetch, positions re-indexed without gaps",
         %{catalogue: catalogue} do
      create_item(catalogue.uuid, "Frame A", 111)
      create_item(catalogue.uuid, "Gift A", 222)

      filter = %{"prefix" => "3d-printed-", "exclude" => ["3d-printed-items"]}

      assert {:ok, result} =
               CollectionSync.run(
                 client: FilterStub,
                 catalogue_uuid: catalogue.uuid,
                 filter: filter
               )

      # "3d-printed-items" (excluded) and "imported-from-etsy" (prefix
      # mismatch) are both skipped; had either been fetched for its
      # products, `FilterStub.fetch_collection_product_ids/2` (no clause
      # for ids 2/3) would have raised instead of returning `{:ok, _}`.
      assert result.collections_skipped_by_filter == 2
      assert result.categories_created == 2
      assert result.categories_matched == 0

      categories = catalogue.uuid |> Catalogue.list_categories_metadata_for_catalogue()
      assert Enum.map(categories, & &1.name) |> Enum.sort() == ["Frames", "Gifts"]

      # Re-indexed 0, 1 within the ALLOWED subset — not the original API
      # positions (0, 3) the two surviving collections carried.
      [frames] = Enum.filter(categories, &(&1.name == "Frames"))
      [gifts] = Enum.filter(categories, &(&1.name == "Gifts"))
      assert frames.position == 0
      assert gifts.position == 1
    end

    test "an empty filter (never configured) behaves as no filter at all",
         %{catalogue: catalogue} do
      create_item(catalogue.uuid, "Frame A", 111)
      create_item(catalogue.uuid, "Gift A", 222)

      assert {:ok, result} =
               CollectionSync.run(client: Stub, catalogue_uuid: catalogue.uuid, filter: %{})

      assert result.collections_skipped_by_filter == 0
      assert result.categories_created == 2
    end

    test "opts[:filter] defaults to the shop_config key \"shopify_collections_filter\"",
         %{catalogue: catalogue} do
      %ShopConfig{}
      |> ShopConfig.changeset(%{
        key: "shopify_collections_filter",
        value: %{"value" => %{"prefix" => "3d-printed-", "exclude" => ["3d-printed-items"]}}
      })
      |> Repo.insert!()

      create_item(catalogue.uuid, "Frame A", 111)
      create_item(catalogue.uuid, "Gift A", 222)

      assert {:ok, result} =
               CollectionSync.run(client: FilterStub, catalogue_uuid: catalogue.uuid)

      assert result.collections_skipped_by_filter == 2
      assert result.categories_created == 2
    end
  end
end
