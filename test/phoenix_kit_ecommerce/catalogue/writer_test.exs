defmodule PhoenixKitEcommerce.Catalogue.WriterTest do
  @moduledoc """
  `PhoenixKitEcommerce.Catalogue.Writer.update_from_shopify/3` coverage
  specific to the Shopify identity backfill (Block 7 Task 1,
  `docs/superpowers/plans/2026-09-06-block7-shopify-media-collections.md`).
  The broader update/create paths (title/price/tags/legacy_metadata
  survival) are covered by `Shopify.SyncCatalogueTest`; this file is
  narrower: `:handle`/`:product_id` merging into `data["ecommerce"]
  ["shopify"]` without clobbering sibling keys later Shopify-sync writers
  (`sync_images/3`, `sync_variants/2`, `CollectionSync`) record there.

  Needs `phoenix_kit_catalogue` loaded — excluded via `test_helper.exs`'s
  `catalogue_exclude` whenever the optional dependency isn't present, same
  as `sync_catalogue_test.exs`.
  """

  use PhoenixKitEcommerce.DataCase, async: true

  @moduletag :catalogue

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce.Catalogue.Writer

  setup do
    {:ok, catalogue} =
      Catalogue.create_catalogue(%{name: "writer-test-#{System.unique_integer([:positive])}"})

    {:ok, item} =
      Catalogue.create_item(%{
        catalogue_uuid: catalogue.uuid,
        name: "Backfill Mug",
        base_price: Decimal.new("10.00"),
        status: "active",
        data: %{
          "_primary_language" => "en",
          "ecommerce" => %{
            "shop_status" => "active",
            "shopify" => %{"handle" => "backfill-mug"}
          }
        }
      })

    %{item: item}
  end

  describe "update_from_shopify/3 — Shopify identity backfill" do
    test "persists product_id as a string, alongside the existing handle", %{item: item} do
      assert {:ok, updated} =
               Writer.update_from_shopify(
                 item,
                 %{handle: "backfill-mug", product_id: 123_456},
                 "en"
               )

      assert updated.data["ecommerce"]["shopify"]["product_id"] == "123456"
      assert updated.data["ecommerce"]["shopify"]["handle"] == "backfill-mug"
    end

    test "a later apply with no product_id in change_fields leaves the previously-backfilled one untouched",
         %{item: item} do
      {:ok, item} = Writer.update_from_shopify(item, %{product_id: 42}, "en")

      assert {:ok, updated} = Writer.update_from_shopify(item, %{title: "Renamed"}, "en")

      assert updated.data["ecommerce"]["shopify"]["product_id"] == "42"
    end

    test "preserves sibling shopify keys written by other Shopify-sync writers (e.g. set_slugs)",
         %{item: item} do
      {:ok, item} =
        Catalogue.update_item(item, %{
          data: put_in(item.data, ["ecommerce", "shopify", "set_slugs"], ["color"])
        })

      assert {:ok, updated} = Writer.update_from_shopify(item, %{product_id: 7}, "en")

      assert updated.data["ecommerce"]["shopify"]["set_slugs"] == ["color"]
      assert updated.data["ecommerce"]["shopify"]["product_id"] == "7"
      assert updated.data["ecommerce"]["shopify"]["handle"] == "backfill-mug"
    end

    test "change_fields carrying neither :handle nor :product_id leaves the shopify sub-map untouched",
         %{item: item} do
      assert {:ok, updated} = Writer.update_from_shopify(item, %{title: "Renamed"}, "en")

      assert updated.data["ecommerce"]["shopify"] == %{"handle" => "backfill-mug"}
    end
  end

  describe "create_from_shopify/2 — Shopify identity" do
    setup do
      # `create_from_shopify/2` resolves ITS catalogue internally
      # (`Query.catalogue_uuid/0`, default name "decor3dprint") rather
      # than taking one as an argument — unlike this file's other
      # `setup`, which only needs SOME catalogue for `update_from_shopify/3`
      # (it never re-resolves one for an existing item).
      {:ok, _catalogue} = Catalogue.create_catalogue(%{name: "decor3dprint"})
      :ok
    end

    test "stringifies product_id, matching update_from_shopify/3's own backfill shape" do
      shopify_product = %{
        "handle" => "new-widget",
        "title" => "New Widget",
        "id" => 555_123,
        "variants" => [%{"price" => "9.99"}]
      }

      assert {:ok, item} = Writer.create_from_shopify(shopify_product, "en")

      assert item.data["ecommerce"]["shopify"]["product_id"] == "555123"
    end
  end
end
