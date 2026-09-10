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

  describe "update_from_shopify/3 — primary-language column/bucket agreement" do
    # Reproduces the live bug: an item whose primary-language ("en")
    # override bucket already carries a value (written by the ordinary
    # catalogue edit form, which writes both the column and the bucket)
    # goes stale once a Shopify sync updates the :name/:description
    # column ONLY — `Translations.translated_name/2` unconditionally
    # prefers the bucket, so the sync "succeeds" but nothing visible
    # changes.
    setup %{item: item} do
      {:ok, item} =
        Catalogue.update_item(item, %{
          data: %{
            "_primary_language" => "en",
            "en" => %{"_name" => "Stale Title", "_description" => "Stale description"},
            "fr" => %{"_name" => "Titre existant"},
            "ecommerce" => item.data["ecommerce"],
            "featured_image_uuid" => "01a00000-0000-7000-0000-000000000001",
            "media_order" => ["01a00000-0000-7000-0000-000000000002"]
          }
        })

      %{item: item}
    end

    test "title synced at the primary locale overwrites both the :name column and the stale \"en\" _name override",
         %{item: item} do
      assert {:ok, updated} = Writer.update_from_shopify(item, %{title: "Fresh Title"}, "en")

      assert updated.name == "Fresh Title"
      assert updated.data["en"]["_name"] == "Fresh Title"
    end

    test "body_html synced at the primary locale overwrites both the :description column and the stale \"en\" _description override",
         %{item: item} do
      assert {:ok, updated} =
               Writer.update_from_shopify(item, %{body_html: "Fresh description"}, "en")

      assert updated.description == "Fresh description"
      assert updated.data["en"]["_description"] == "Fresh description"
    end

    test "title synced at a SECONDARY locale still only writes the override bucket, column and primary bucket untouched",
         %{item: item} do
      assert {:ok, updated} = Writer.update_from_shopify(item, %{title: "Titre frais"}, "fr")

      assert updated.data["fr"]["_name"] == "Titre frais"
      assert updated.name == item.name
      # The primary "en" bucket, stale or not, is exclusively the sync's
      # business when base_locale IS "en" — a secondary-locale sync must
      # not touch it.
      assert updated.data["en"] == item.data["en"]
    end

    test "no pre-existing \"en\" bucket: a primary-locale sync creates one holding only the mirrored field",
         %{item: item} do
      {:ok, item} = Catalogue.update_item(item, %{data: Map.delete(item.data, "en")})

      assert {:ok, updated} = Writer.update_from_shopify(item, %{title: "Brand New"}, "en")

      assert updated.name == "Brand New"
      assert updated.data["en"] == %{"_name" => "Brand New"}
    end

    test "sibling data survives untouched: other-language override, ecommerce sub-map, and top-level image/media keys",
         %{item: item} do
      assert {:ok, updated} = Writer.update_from_shopify(item, %{title: "Fresh Title"}, "en")

      assert updated.data["fr"] == %{"_name" => "Titre existant"}
      assert updated.data["ecommerce"]["shopify"]["handle"] == "backfill-mug"
      assert updated.data["featured_image_uuid"] == "01a00000-0000-7000-0000-000000000001"
      assert updated.data["media_order"] == ["01a00000-0000-7000-0000-000000000002"]
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

    test "converts body_html to Markdown and does not raise on a junk variant price" do
      shopify_product = %{
        "handle" => "html-widget",
        "title" => "HTML Widget",
        "id" => 555_124,
        "vendor" => "Acme",
        "tags" => "red, blue",
        "status" => "active",
        "body_html" => "<p>Hello <strong>there</strong>.</p>",
        "variants" => [%{"price" => "n/a"}, %{"price" => "12.50"}]
      }

      assert {:ok, item} = Writer.create_from_shopify(shopify_product, "en")
      assert item.description == "Hello **there**."
      assert Decimal.equal?(item.base_price, Decimal.new("12.50"))
      assert item.data["ecommerce"]["vendor"] == "Acme"
      assert item.data["ecommerce"]["tags"] == ["red", "blue"]
    end

    test "stores a multi-paragraph body_html as Markdown, like the update path does" do
      # Shopify always sends raw HTML. The storefront renders the stored
      # description as Markdown, so an HTML block would print the `**`
      # inside it literally — and the item would read as permanently
      # changed against the next sync, whose diff normalises first.
      shopify_product = %{
        "handle" => "md-widget",
        "title" => "MD Widget",
        "id" => 555_124,
        "body_html" => "<p><strong>Handmade.</strong></p><p>Ships in 2 days.</p>",
        "variants" => [%{"price" => "9.99"}]
      }

      assert {:ok, item} = Writer.create_from_shopify(shopify_product, "en")

      assert item.description == "**Handmade.**\n\nShips in 2 days."
      refute item.description =~ "<p>"
    end

    test "writes name/description as columns only — no per-language override bucket for a brand new item" do
      shopify_product = %{
        "handle" => "no-bucket-widget",
        "title" => "No Bucket Widget",
        "id" => 555_125,
        "body_html" => "<p>Plain.</p>",
        "variants" => [%{"price" => "5.00"}]
      }

      assert {:ok, item} = Writer.create_from_shopify(shopify_product, "en")

      assert item.name == "No Bucket Widget"
      refute Map.has_key?(item.data, "en")
    end
  end
end
