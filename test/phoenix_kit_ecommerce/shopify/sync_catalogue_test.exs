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

  alias PhoenixKit.Integrations
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Catalogue.Writer
  alias PhoenixKitEcommerce.ProductSource.Catalogue, as: CatalogueSource
  alias PhoenixKitEcommerce.ShopConfig
  alias PhoenixKitEcommerce.Shopify.ProductDiff
  alias PhoenixKitEcommerce.Shopify.Sync
  alias PhoenixKitEcommerce.Shopify.SyncScope
  alias PhoenixKitEcommerce.StorefrontCache
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

  # The storefront caches its category list and facets for about a minute
  # (`StorefrontCache`); the catalogue writes of a sync must clear it. The
  # cache's generation counts the clears, which tells "once per run" from
  # "once per change".
  describe "the storefront cache" do
    setup %{item: item} do
      start_supervised!(PhoenixKit.Cache.Registry)
      [spec] = StorefrontCache.children()
      start_supervised!(spec)

      product = CatalogueSource.get_product(item.uuid, [])

      assert [change] =
               ProductDiff.diff([product], [shopify_payload(%{})], "en", only: [:title])

      %{change: change}
    end

    defp generation do
      {_value, generation} =
        PhoenixKit.Cache.get_with_generation(:ecommerce_storefront, :generation_probe)

      generation
    end

    defp prefill_probe, do: :stale = StorefrontCache.fetch(:probe, fn -> :stale end)
    defp probe_cleared?, do: StorefrontCache.fetch(:probe, fn -> :fresh end) == :fresh

    test "apply_change/3 clears it after an update", %{change: change} do
      prefill_probe()
      before = generation()

      assert {:ok, _view} = Sync.apply_change(change)

      assert probe_cleared?()
      assert generation() == before + 1
    end

    test "apply_change/3 clears it after a create" do
      create = %ProductDiff.Change{
        create?: true,
        product_uuid: nil,
        handle: "brand-new-mug",
        title: "Brand New Mug",
        base_locale: "en",
        shopify_product: %{"handle" => "brand-new-mug", "title" => "Brand New Mug", "id" => 42}
      }

      prefill_probe()
      before = generation()

      assert {:ok, _view} = Sync.apply_change(create)

      assert probe_cleared?()
      assert generation() == before + 1
    end

    test "apply_change/3 leaves it alone when the write is refused", %{change: change} do
      prefill_probe()
      before = generation()

      # A currency mismatch refuses the price field, and nothing else is
      # asked for.
      priced = %{change | changes: %{price: %{current: "25.00", incoming: "30.00"}}}

      assert {:error, {:currency_mismatch, "USD", "EUR"}} =
               Sync.apply_change(priced, [:price], currency_verdict: {:mismatch, "USD", "EUR"})

      refute probe_cleared?()
      assert generation() == before
    end

    test "apply_changes/3 clears it once for the whole run, not once per change", %{
      change: change
    } do
      prefill_probe()
      before = generation()

      assert %{succeeded: [_, _, _], failed: []} = Sync.apply_changes([change, change, change])

      assert probe_cleared?()
      assert generation() == before + 1
    end

    # The reduce's accumulator is lost when a change raises (here: its item
    # was deleted since the diff), but the change written before it must show.
    test "apply_changes/3 still clears it when a later change raises", %{
      change: change,
      item: item
    } do
      ghost = %{change | product_uuid: Ecto.UUID.generate()}
      prefill_probe()
      before = generation()

      assert_raise Ecto.NoResultsError, fn -> Sync.apply_changes([change, ghost]) end

      assert Catalogue.get_item!(item.uuid).name == "Ceramic Vase Deluxe"
      assert probe_cleared?()
      assert generation() == before + 1
    end

    test "apply_changes/3 leaves it alone when the first change raises and nothing was written",
         %{change: change} do
      ghost = %{change | product_uuid: Ecto.UUID.generate()}
      prefill_probe()
      before = generation()

      assert_raise Ecto.NoResultsError, fn -> Sync.apply_changes([ghost, change]) end

      refute probe_cleared?()
      assert generation() == before
    end

    test "apply_changes/3 leaves it alone when no change was written", %{change: change} do
      prefill_probe()
      before = generation()

      priced = %{change | changes: %{price: %{current: "25.00", incoming: "30.00"}}}

      assert %{succeeded: [], failed: [_]} =
               Sync.apply_changes([priced], [:price], currency_verdict: {:mismatch, "USD", "EUR"})

      refute probe_cleared?()
      assert generation() == before
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
      # Stringified, same as `update_from_shopify/3`'s own backfill —
      # `CollectionSync`/the Task 5 worker both match `product_id` as a
      # string.
      assert item.data["ecommerce"]["shopify"]["product_id"] == "999"
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

  describe "check/2 — :new_products scoped by SyncScope" do
    @stub __MODULE__.CheckScopeStub

    defp connect_shopify do
      enable_shopify!()

      {:ok, %{uuid: uuid}} =
        Integrations.add_connection("shopify", "Test Shop #{System.unique_integer([:positive])}")

      {:ok, _} =
        Integrations.save_setup(uuid, %{
          "shop_domain" => "test-shop.myshopify.com",
          "access_token" => "shpat_test_token"
        })

      uuid
    end

    defp json_response(conn, status, body) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, JSON.encode!(body))
    end

    defp check_opts(extra \\ []) do
      Keyword.merge([admin_options: [req_options: [plug: {Req.Test, @stub}]]], extra)
    end

    # `item` (from `setup`) matches `"ceramic-vase"` — every scenario
    # below adds two more Shopify products with NO local counterpart,
    # one carrying `"catalog-3d"`, one not.
    defp unmatched_products do
      [
        %{
          "id" => 1,
          "handle" => "in-scope-mug",
          "title" => "In Scope Mug",
          "tags" => "catalog-3d"
        },
        %{
          "id" => 2,
          "handle" => "out-of-scope-poster",
          "title" => "Out of Scope Poster",
          "tags" => "wall-art"
        }
      ]
    end

    test "mode: all offers every unmatched product, out_of_scope is 0", %{item: item} do
      uuid = connect_shopify()
      product = CatalogueSource.get_product(item.uuid, [])

      Req.Test.stub(@stub, fn conn ->
        json_response(conn, 200, %{"products" => [shopify_payload(%{}) | unmatched_products()]})
      end)

      assert {:ok, %{new_products: new_products, new_products_out_of_scope: 0}} =
               Sync.check(uuid, check_opts(scope: SyncScope.all()))

      assert Enum.map(new_products, & &1.handle) |> Enum.sort() ==
               ["in-scope-mug", "out-of-scope-poster"]

      # Matched product's own field diff is untouched by the scope.
      assert product.uuid
    end

    test "mode: filtered offers only the in-scope product, counting the rest",
         %{item: item} do
      uuid = connect_shopify()
      CatalogueSource.get_product(item.uuid, [])

      Req.Test.stub(@stub, fn conn ->
        json_response(conn, 200, %{"products" => [shopify_payload(%{}) | unmatched_products()]})
      end)

      scope = %{mode: :filtered, tags: ["catalog-3d"], product_types: []}

      assert {:ok, %{new_products: [change], new_products_out_of_scope: 1}} =
               Sync.check(uuid, check_opts(scope: scope))

      assert change.handle == "in-scope-mug"
    end

    # An out-of-scope product at the REST payload's 100-variant cap is
    # never re-read (its prices are never used) and so comes back flagged
    # `:not_requested` — it must still be COUNTED as out of scope, not
    # silently dropped from the count.
    test "an out-of-scope product at the variant cap still counts as out of scope",
         %{item: item} do
      uuid = connect_shopify()
      CatalogueSource.get_product(item.uuid, [])
      capped = for n <- 1..100, do: %{"option1" => "V#{n}", "price" => "10.00"}

      [in_scope, out_of_scope] = unmatched_products()

      Req.Test.stub(@stub, fn conn ->
        refute conn.request_path =~ "/products/2/variants.json"

        json_response(conn, 200, %{
          "products" => [
            shopify_payload(%{}),
            in_scope,
            Map.put(out_of_scope, "variants", capped)
          ]
        })
      end)

      scope = %{mode: :filtered, tags: ["catalog-3d"], product_types: []}

      assert {:ok, %{new_products: [change], new_products_out_of_scope: 1}} =
               Sync.check(uuid, check_opts(scope: scope))

      assert change.handle == "in-scope-mug"
    end

    # Creating a newcomer writes its price, so an in-scope one at the cap
    # IS re-read in full under the catalogue source — and only it.
    test "re-reads a capped in-scope newcomer's full variant list", %{item: item} do
      uuid = connect_shopify()
      CatalogueSource.get_product(item.uuid, [])
      test_pid = self()
      capped = for n <- 1..100, do: %{"option1" => "V#{n}", "price" => "10.00"}

      [in_scope, out_of_scope] =
        Enum.map(unmatched_products(), &Map.put(&1, "variants", capped))

      Req.Test.stub(@stub, fn conn ->
        case Regex.run(~r{/products/(\d+)/variants\.json}, conn.request_path) do
          [_, id] ->
            send(test_pid, {:backfilled, id})
            json_response(conn, 200, %{"variants" => capped})

          nil ->
            json_response(conn, 200, %{
              "products" => [shopify_payload(%{}), in_scope, out_of_scope]
            })
        end
      end)

      scope = %{mode: :filtered, tags: ["catalog-3d"], product_types: []}

      assert {:ok, %{new_products: [change], new_products_out_of_scope: 1}} =
               Sync.check(uuid, check_opts(scope: scope))

      assert change.handle == "in-scope-mug"
      assert_received {:backfilled, "1"}
      refute_received {:backfilled, "2"}
    end

    test "defaults to SyncScope.get/0 when opts[:scope] is omitted", %{item: item} do
      assert {:ok, _} = SyncScope.put(%{"mode" => "filtered", "tags" => ["catalog-3d"]})

      uuid = connect_shopify()
      CatalogueSource.get_product(item.uuid, [])

      Req.Test.stub(@stub, fn conn ->
        json_response(conn, 200, %{"products" => [shopify_payload(%{}) | unmatched_products()]})
      end)

      assert {:ok, %{new_products: [change], new_products_out_of_scope: 1}} =
               Sync.check(uuid, check_opts())

      assert change.handle == "in-scope-mug"
    end
  end

  describe "ai_translatables/0" do
    test "is empty under the catalogue source" do
      assert Shop.ai_translatables() == []
    end
  end

  describe "imports LiveView" do
    test "shows the catalogue-source notice and hides the CSV upload wizard", %{conn: conn} do
      # The page needs shop.run_imports; `fake_scope/0` holds every shop key.
      {:ok, view, html} = live(put_test_scope(conn, fake_scope()), "/en/admin/shop/imports")

      assert html =~ "CSV import is disabled"
      assert html =~ "now live in the Catalogues module"
      assert has_element?(view, "#imports-catalogue-notice")
      refute has_element?(view, "#csv-upload-form")
    end
  end
end
