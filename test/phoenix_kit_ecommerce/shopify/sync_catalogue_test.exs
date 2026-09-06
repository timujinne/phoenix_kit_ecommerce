defmodule PhoenixKitEcommerce.Shopify.SyncCatalogueTest do
  @moduledoc """
  Shopify sync 6a against a catalogue-backed item — the write side of
  Block 3 (`docs/superpowers/specs/2026-09-05-catalogue-as-shop-product-
  list-design.md` §5 Блок 3). `PhoenixKitEcommerce.Shopify.ProductDiff`'s
  own pure unit coverage (compare_at_price, `metadata["_shopify"]`
  handle matching, `new_product_changes/3`) lives in
  `ProductDiffTest` — this file covers what needs a real catalogue item:
  `PhoenixKitEcommerce.Catalogue.Writer` actually writing through
  `Catalogue.update_item/2`/`create_item/2`, `Shopify.Sync.apply_change/2`
  dispatching to it instead of `Shop.update_product/2`, `ai_translatables/0`
  gating, and the imports LiveView's catalogue-source notice.

  Needs `phoenix_kit_catalogue` loaded (with its own migrations applied to
  the test DB) — excluded via `test_helper.exs`'s `catalogue_exclude`
  whenever the optional dependency isn't present, same as
  `catalogue_view_test.exs`/`catalogue_query_test.exs`/`cart_catalogue_test.exs`.
  `async: false`: flips the process-wide `shop_product_source` config key.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  @moduletag :catalogue

  # Quiets the compiler's static xref check for `mix test` runs where the
  # optional `phoenix_kit_catalogue` dependency isn't declared — every test
  # in this module is excluded in that case (see `test_helper.exs`), so the
  # calls below are never actually reached.
  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}
  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue.Slugs}

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Catalogue.Writer
  alias PhoenixKitEcommerce.ProductSource.Catalogue, as: CatalogueSource
  alias PhoenixKitEcommerce.ShopConfig
  alias PhoenixKitEcommerce.Shopify.ProductDiff
  alias PhoenixKitEcommerce.Shopify.Sync
  alias PhoenixKitEcommerce.Test.Repo

  setup do
    set_product_source("catalogue")
    on_exit(fn -> set_product_source("legacy") end)

    {:ok, catalogue} = Catalogue.create_catalogue(%{name: "decor3dprint"})

    {:ok, item} =
      Catalogue.create_item(%{
        catalogue_uuid: catalogue.uuid,
        name: "Ceramic Vase",
        base_price: Decimal.new("25.00"),
        status: "active",
        data: %{
          "_primary_language" => "en",
          "en" => %{},
          "fr" => %{"_name" => "Vase en céramique"},
          "ecommerce" => %{
            "shop_status" => "active",
            "shopify" => %{"handle" => "ceramic-vase", "product_id" => 555}
          }
        }
      })

    %{catalogue: catalogue, item: item}
  end

  # No `PhoenixKitEcommerce.update_config/2` exists yet (that setter is
  # built in a later, app-level task) — writes the `phoenix_kit_shop_config`
  # row directly, mirroring `cart_catalogue_test.exs`'s own helper.
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

  defp shopify_payload(overrides) do
    Map.merge(
      %{
        "handle" => "ceramic-vase",
        "title" => "Ceramic Vase Deluxe",
        "variants" => [%{"price" => "30.00", "compare_at_price" => "45.00"}],
        "tags" => "red, ceramic"
      },
      overrides
    )
  end

  describe "diff + apply against a catalogue item" do
    test "diff reports exactly the 4 requested fields", %{item: item} do
      product = CatalogueSource.get_product(item.uuid, [])

      assert [change] =
               ProductDiff.diff([product], [shopify_payload(%{})], "en",
                 only: [:title, :price, :compare_at_price, :tags]
               )

      assert change.product_uuid == item.uuid
      assert change.handle == "ceramic-vase"
      assert Enum.sort(Map.keys(change.changes)) == [:compare_at_price, :price, :tags, :title]
    end

    test "apply writes the item's name column, base_price, compare_at_price and tags, leaving the fr override untouched",
         %{item: item} do
      product = CatalogueSource.get_product(item.uuid, [])

      assert [change] =
               ProductDiff.diff([product], [shopify_payload(%{})], "en",
                 only: [:title, :price, :compare_at_price, :tags]
               )

      assert {:ok, updated_view} = Sync.apply_change(change)
      assert updated_view.title["en"] == "Ceramic Vase Deluxe"

      updated_item = Catalogue.get_item!(item.uuid)
      assert updated_item.name == "Ceramic Vase Deluxe"
      assert Decimal.equal?(updated_item.base_price, Decimal.new("30.00"))
      assert updated_item.data["ecommerce"]["compare_at_price"] == "45.00"
      assert updated_item.data["ecommerce"]["tags"] == ["red", "ceramic"]
      # Untouched: the change was applied in the item's PRIMARY language
      # ("en"), so title landed on the :name column, not on a multilang
      # override — the existing "fr" override must survive byte-for-byte.
      assert updated_item.data["fr"] == %{"_name" => "Vase en céramique"}
      # The shopify handle/product_id already on the item survive too —
      # `update_from_shopify/3` merges `ecommerce_params/1`'s changes onto
      # `current_ecommerce`, it never replaces the sub-map wholesale.
      assert updated_item.data["ecommerce"]["shopify"]["handle"] == "ceramic-vase"
    end

    test "apply preserves the legacy_metadata snapshot — ItemCommerce.cast/2 doesn't carry non-schema keys through",
         %{catalogue: catalogue} do
      {:ok, item} =
        Catalogue.create_item(%{
          catalogue_uuid: catalogue.uuid,
          name: "Snapshot Vase",
          base_price: Decimal.new("25.00"),
          status: "active",
          data: %{
            "_primary_language" => "en",
            "en" => %{},
            "ecommerce" => %{
              "shop_status" => "active",
              "shopify" => %{"handle" => "snapshot-vase", "product_id" => 777},
              "legacy_metadata" => %{
                "_option_slots" => [%{"key" => "size", "type" => "select"}],
                "_image_mappings" => %{"size" => %{"small" => "img-uuid"}}
              }
            }
          }
        })

      product = CatalogueSource.get_product(item.uuid, [])

      assert [change] =
               ProductDiff.diff(
                 [product],
                 [shopify_payload(%{"handle" => "snapshot-vase"})],
                 "en",
                 only: [:title, :price, :compare_at_price, :tags]
               )

      assert {:ok, _updated_view} = Sync.apply_change(change)

      updated_item = Catalogue.get_item!(item.uuid)

      assert updated_item.data["ecommerce"]["legacy_metadata"] == %{
               "_option_slots" => [%{"key" => "size", "type" => "select"}],
               "_image_mappings" => %{"size" => %{"small" => "img-uuid"}}
             }

      # The write itself still landed.
      assert Decimal.equal?(updated_item.base_price, Decimal.new("30.00"))
    end

    test "applying a single field leaves the others untouched", %{item: item} do
      product = CatalogueSource.get_product(item.uuid, [])

      assert [change] =
               ProductDiff.diff([product], [shopify_payload(%{})], "en",
                 only: [:title, :price, :compare_at_price, :tags]
               )

      assert {:ok, _updated_view} = Sync.apply_change(change, [:price])

      updated_item = Catalogue.get_item!(item.uuid)
      assert Decimal.equal?(updated_item.base_price, Decimal.new("30.00"))
      assert updated_item.name == "Ceramic Vase"
      assert updated_item.data["ecommerce"]["compare_at_price"] == nil
    end
  end

  describe "a new Shopify handle creates a catalogue item" do
    test "Writer.create_from_shopify/2 creates an item with slug, shopify handle and shop_status" do
      shopify_product = %{
        "handle" => "brand-new-mug",
        "title" => "Brand New Mug",
        "id" => 999,
        "status" => "active",
        "variants" => [%{"price" => "12.50"}]
      }

      assert {:ok, item} = Writer.create_from_shopify(shopify_product, "en")

      assert item.name == "Brand New Mug"
      assert item.slug["en"] == Catalogue.Slugs.from_title("Brand New Mug", "en")
      assert item.data["ecommerce"]["shopify"]["handle"] == "brand-new-mug"
      assert item.data["ecommerce"]["shopify"]["product_id"] == 999
      assert item.data["ecommerce"]["shop_status"] == "active"
      assert Decimal.equal?(item.markup_percentage, Decimal.new(0))
      assert Decimal.equal?(item.base_price, Decimal.new("12.50"))
    end

    test "retries the slug with a numeric suffix on a collision" do
      shopify_product = %{"handle" => "unique-mug", "title" => "Ceramic Vase"}

      # "Ceramic Vase" already produced a slug earlier in this test's own
      # catalogue via the `item` fixture created in `setup` — but that
      # item's slug map is empty (created without `maybe_generate/3`), so
      # seed the collision directly at the same base slug `from_title/3`
      # would derive, under the same language.
      base_slug = Catalogue.Slugs.from_title("Ceramic Vase", "en")
      {:ok, catalogue} = Catalogue.create_catalogue(%{name: "collision-catalogue"})

      {:ok, _colliding_item} =
        Catalogue.create_item(%{
          catalogue_uuid: catalogue.uuid,
          name: "Some Other Item",
          base_price: Decimal.new("1.00"),
          slug: %{"en" => base_slug}
        })

      assert {:ok, item} = Writer.create_from_shopify(shopify_product, "en")
      assert item.slug["en"] == "#{base_slug}-2"
    end

    test "ProductDiff.new_product_changes/3 surfaces an unmatched handle, and Sync.apply_change/2 creates it",
         %{item: item} do
      product = CatalogueSource.get_product(item.uuid, [])

      shopify_products = [
        shopify_payload(%{}),
        %{"handle" => "brand-new-mug", "title" => "Brand New Mug", "id" => 42}
      ]

      assert [change] = ProductDiff.new_product_changes([product], shopify_products, "en")
      assert change.create?
      assert change.product_uuid == nil
      assert change.handle == "brand-new-mug"

      assert {:ok, created_view} = Sync.apply_change(change)
      assert created_view.title["en"] == "Brand New Mug"
      assert created_view.metadata["_shopify"]["handle"] == "brand-new-mug"
    end
  end

  describe "ai_translatables/0" do
    test "is empty under the catalogue source" do
      assert Shop.ai_translatables() == []
    end
  end

  describe "imports LiveView" do
    test "shows the catalogue-source notice and hides the CSV upload wizard", %{conn: conn} do
      {:ok, view, html} = live(conn, "/en/admin/shop/imports")

      assert html =~ "CSV import is disabled"
      assert has_element?(view, "#imports-catalogue-notice")
      refute has_element?(view, "#csv-upload-form")
    end
  end
end
