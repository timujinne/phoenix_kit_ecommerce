defmodule PhoenixKitEcommerce.Workers.ShopifyMediaSyncWorkerTest do
  @moduledoc """
  `PhoenixKitEcommerce.Workers.ShopifyMediaSyncWorker` (Block 7 Task 5,
  `docs/superpowers/plans/2026-09-06-block7-shopify-media-collections.md`):
  the worker's own `run/3` — matching Shopify products to catalogue
  items (by `product_id`, falling back to `handle`), continuing past a
  per-product failure, delegating `"collections"` wholesale to
  `CollectionSync.run/1`, and the `phoenix_kit_shop_config["shopify_media_sync"]`
  progress record (persisted AND broadcast on `Worker.topic/0`).

  Calls `Worker.run/3` directly — the same function `perform/1` calls —
  never through `Oban.insert/1`: this fork's own test env has no Oban
  supervisor running (see the sync-page LiveView test file for where
  enqueueing itself gets covered, with its own local Oban instance).
  `opts[:client]`/`opts[:downloader]` are stub modules/functions — no
  real HTTP, per Global Constraints.

  Needs `phoenix_kit_catalogue` (AND `phoenix_kit_entities` for the
  `"variants"` kind) loaded — tagged `:catalogue` and excluded via
  `test_helper.exs` whenever the optional dependency isn't present, same
  as `collection_sync_test.exs`/`writer_variants_test.exs`. `async:
  false`: flips the process-wide `shop_product_source` config key and
  writes the shared `shopify_media_sync` progress row.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :catalogue

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}
  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue.AttributeSets}
  @compile {:no_warn_undefined, PhoenixKitEntities}

  alias PhoenixKit.Integrations
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.PubSub.Manager
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.AttributeSets
  alias PhoenixKitEcommerce.ShopConfig
  alias PhoenixKitEcommerce.Test.Repo
  alias PhoenixKitEcommerce.Workers.ShopifyMediaSyncWorker, as: Worker

  @stub __MODULE__

  setup do
    on_exit(fn -> set_product_source("legacy") end)

    # Named "decor3dprint" (the adapter's own default, `Query.
    # catalogue_uuid/0`'s `@default_catalogue_name`) — not a unique
    # per-test name: the worker resolves ITS catalogue by looking up the
    # catalogue named `get_config("shop_catalogue") || "decor3dprint"`,
    # so a differently-named catalogue here is invisible to it (each test
    # still runs in its own rolled-back sandbox transaction, so reusing
    # this name across tests in this file is safe).
    {:ok, catalogue} = Catalogue.create_catalogue(%{name: "decor3dprint"})

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

  defp create_item(catalogue_uuid, name, shopify, attrs \\ %{}) do
    {:ok, item} =
      Catalogue.create_item(
        Map.merge(
          %{
            catalogue_uuid: catalogue_uuid,
            name: name,
            base_price: Decimal.new("10.00"),
            status: "active",
            data: %{"ecommerce" => %{"shop_status" => "active", "shopify" => shopify}}
          },
          attrs
        )
      )

    item
  end

  defp reload(item), do: Catalogue.get_item!(item.uuid)

  # ============================================================
  # Currency guard (per-domain-currency design §7.5) — real Shopify
  # connection + Req.Test stub, since `Sync.currency_verdict/1` always
  # calls the REAL `AdminClient.fetch_shop/2`, independent of whatever
  # fake `client:` module a test passes for `fetch_products/2`.
  # ============================================================

  defp connect_shopify do
    {:ok, %{uuid: uuid}} =
      Integrations.add_connection("shopify", "Test Shop #{System.unique_integer([:positive])}")

    {:ok, _} =
      Integrations.save_setup(uuid, %{
        "shop_domain" => "test-shop.myshopify.com",
        "access_token" => "shpat_test_token"
      })

    uuid
  end

  defp set_base_currency(code) do
    PhoenixKit.Cache.clear(:billing_currencies)
    Repo.delete_all(PhoenixKitBilling.Currency)

    {:ok, _} =
      PhoenixKitBilling.create_currency(%{
        code: code,
        name: code,
        symbol: code,
        is_default: true,
        exchange_rate: "1.0"
      })

    :ok
  end

  defp json_response(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, JSON.encode!(body))
  end

  # ============================================================
  # "images" — client/downloader stubs
  # ============================================================

  defmodule ImagesStub do
    @moduledoc false

    def fetch_products(_integration_uuid, _opts) do
      {:ok,
       [
         %{
           "id" => 111,
           "handle" => "matched-by-id",
           "images" => [
             %{"id" => 501, "src" => "https://cdn.example/a.jpg", "position" => 1},
             %{"id" => 502, "src" => "https://cdn.example/broken.jpg", "position" => 2}
           ]
         },
         %{
           "id" => 222,
           "handle" => "matched-by-handle",
           "images" => [%{"id" => 601, "src" => "https://cdn.example/b.jpg", "position" => 1}]
         },
         %{"id" => 333, "handle" => "unknown-product", "images" => []}
       ]}
    end
  end

  # A real `Storage.File` row per call (so `Attachments.attach_files/3`'s
  # own existence check passes), except for the one URL deliberately
  # made to fail — a stand-in for a real download error, not a mock of
  # the writer's own behaviour.
  defp stub_downloader(user_uuid) do
    fn
      "https://cdn.example/broken.jpg", _downloader_user_uuid, _opts ->
        {:error, :not_found}

      url, downloader_user_uuid, _opts ->
        store_fixture_file(url, downloader_user_uuid || user_uuid)
    end
  end

  defp store_fixture_file(url, user_uuid) do
    body = "fixture-bytes-#{url}"
    tmp = Path.join(System.tmp_dir!(), "media_sync_worker_#{System.unique_integer([:positive])}")
    File.write!(tmp, body)

    result =
      Storage.store_file(tmp,
        filename: Path.basename(url),
        content_type: "image/jpeg",
        size_bytes: byte_size(body),
        user_uuid: user_uuid
      )

    File.rm(tmp)

    case result do
      {:ok, file} -> {:ok, file.uuid}
      {:error, reason} -> {:error, reason}
    end
  end

  # ============================================================
  # "variants" — client stub
  # ============================================================

  defmodule VariantsStub do
    @moduledoc false

    def fetch_products(_integration_uuid, _opts) do
      {:ok,
       [
         %{
           "id" => 777,
           "handle" => "two-option-mug",
           "options" => [%{"name" => "Size", "position" => 1, "values" => ["Small", "Large"]}],
           "variants" => [
             %{"option1" => "Small", "price" => "10.00"},
             %{"option1" => "Large", "price" => "15.00"}
           ]
         }
       ]}
    end
  end

  # ============================================================
  # "collections" — same shape as `CollectionSyncTest`'s own stub
  # ============================================================

  defmodule CollectionsStub do
    @moduledoc false

    def fetch_collections(_opts) do
      {:ok, [%{"id" => 1, "handle" => "gifts", "title" => "Gifts", "position" => 0}]}
    end

    def fetch_collection_product_ids(1, _opts), do: {:ok, [444]}
  end

  describe "run/3 — legacy source" do
    test "every kind is a no-op returning :catalogue_source_inactive" do
      assert Worker.run("images", nil, integration_uuid: "irrelevant") ==
               {:error, :catalogue_source_inactive}

      assert Worker.run("variants", nil, integration_uuid: "irrelevant") ==
               {:error, :catalogue_source_inactive}

      assert Worker.run("collections", nil, integration_uuid: "irrelevant") ==
               {:error, :catalogue_source_inactive}
    end
  end

  describe "run/3 — catalogue source" do
    setup do
      set_product_source("catalogue")
      :ok
    end

    test "fails and records a run-level error when no Shopify connection is configured" do
      assert Worker.run("images", nil) == {:error, :missing_shopify_connection}

      progress = Worker.get_progress()
      assert progress["kind"] == "images"
      assert progress["finished_at"] != nil

      assert [%{"product" => "_run", "reason" => ":missing_shopify_connection"}] =
               progress["errors"]
    end

    test "images: matches by product_id then by handle, skips an unknown product, and reports a failed download without halting",
         %{catalogue: catalogue} do
      user = fixture_user()
      by_id = create_item(catalogue.uuid, "By id", %{"product_id" => "111"})
      by_handle = create_item(catalogue.uuid, "By handle", %{"handle" => "matched-by-handle"})

      Manager.subscribe(Worker.topic())

      assert {:ok, %{total: 3, done: 3, errors: errors}} =
               Worker.run("images", user.uuid,
                 client: ImagesStub,
                 downloader: stub_downloader(user.uuid),
                 integration_uuid: "test-integration"
               )

      assert length(errors) == 2

      assert Enum.any?(errors, fn %{"product" => p, "reason" => r} ->
               p == "unknown-product" and r == "no_matching_item"
             end)

      assert Enum.any?(errors, fn %{"product" => p, "reason" => r} ->
               p == "matched-by-id" and r =~ "image 502" and r =~ "not_found"
             end)

      by_id = reload(by_id)
      by_handle = reload(by_handle)

      assert by_id.data["media_order"] == [by_id.data["ecommerce"]["shopify"]["image_ids"]["501"]]

      assert by_handle.data["media_order"] == [
               by_handle.data["ecommerce"]["shopify"]["image_ids"]["601"]
             ]

      assert_receive {:media_sync_progress, %{"finished_at" => finished_at, "done" => 3}}
                     when not is_nil(finished_at)

      progress = Worker.get_progress()
      assert progress["kind"] == "images"
      assert progress["total"] == 3
      assert progress["done"] == 3
      assert length(progress["errors"]) == 2
      assert progress["result"] == nil
    end

    test "variants: attaches an attribute set to the matched item", %{catalogue: catalogue} do
      AttributeSets.register_deletion_guard()
      PhoenixKit.Settings.update_setting("entities_enabled", "true")
      on_exit(fn -> PhoenixKit.Settings.update_setting("entities_enabled", "false") end)

      item =
        create_item(catalogue.uuid, "Two-Option Mug", %{"handle" => "two-option-mug"}, %{
          data: %{
            "_primary_language" => "en",
            "ecommerce" => %{
              "shop_status" => "active",
              "shopify" => %{"handle" => "two-option-mug"}
            }
          }
        })

      assert {:ok, %{total: 1, done: 1, errors: []}} =
               Worker.run("variants", nil,
                 client: VariantsStub,
                 integration_uuid: "test-integration"
               )

      assert length(AttributeSets.list_attachments(item.uuid)) == 1

      progress = Worker.get_progress()
      assert progress["kind"] == "variants"
      assert progress["finished_at"] != nil
      assert progress["errors"] == []
    end

    test "variants: a shop-currency mismatch skips every product, writes no price_modifiers, and reports the refusal",
         %{catalogue: catalogue} do
      set_base_currency("USD")
      integration_uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn ->
        json_response(conn, 200, %{"shop" => %{"currency" => "EUR"}})
      end)

      item =
        create_item(catalogue.uuid, "Two-Option Mug", %{"handle" => "two-option-mug"}, %{
          data: %{
            "_primary_language" => "en",
            "ecommerce" => %{
              "shop_status" => "active",
              "shopify" => %{"handle" => "two-option-mug"}
            }
          }
        })

      assert {:ok, %{total: 1, done: 1, errors: [error]}} =
               Worker.run("variants", nil,
                 client: VariantsStub,
                 integration_uuid: integration_uuid,
                 req_options: [plug: {Req.Test, @stub}]
               )

      assert %{"product" => "two-option-mug", "reason" => reason} = error
      assert reason =~ "currency_mismatch"
      assert reason =~ "EUR"
      assert reason =~ "USD"

      # `Writer.sync_variants/2` was never called: no attribute set, no
      # price_modifiers — the whole write is refused, not half-done.
      assert AttributeSets.list_attachments(item.uuid) == []
      reloaded = reload(item)
      assert get_in(reloaded.data, ["ecommerce", "price_modifiers"]) in [nil, %{}]

      progress = Worker.get_progress()
      assert progress["kind"] == "variants"
      assert progress["finished_at"] != nil
      assert length(progress["errors"]) == 1
    end

    test "collections: delegates to CollectionSync.run/1 and keeps its result on the progress record",
         %{catalogue: catalogue} do
      create_item(catalogue.uuid, "Gift A", %{"product_id" => "444"})

      assert {:ok, result} =
               Worker.run("collections", nil,
                 client: CollectionsStub,
                 integration_uuid: "test-integration"
               )

      assert result.categories_created == 1
      assert result.items_assigned == 1

      progress = Worker.get_progress()
      assert progress["kind"] == "collections"
      assert progress["total"] == 1
      assert progress["done"] == 1
      assert progress["finished_at"] != nil
      assert progress["result"]["categories_created"] == 1
    end
  end
end
