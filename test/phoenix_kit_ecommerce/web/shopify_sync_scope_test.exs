defmodule PhoenixKitEcommerce.Web.ShopifySyncScopeTest do
  @moduledoc """
  `PhoenixKitEcommerce.Web.ShopifySync`'s three sync-scope additions,
  catalogue source only:

    1. The "Sync scope" panel/form (`PhoenixKitEcommerce.Shopify.
       SyncScope`) — saves and re-renders its own summary line.
    2. The "Media & collections" panel's per-kind status block —
       `"skipped"` count and the "images"-only "nothing new" line, both
       read off `ShopifyMediaSyncWorker.get_progress/0`'s new per-kind
       shape.
    3. The "New in Shopify" panel (`Sync.check/2`'s own `:new_products`)
       — lists in-scope creates, hides out-of-scope ones with a count,
       and "Add" actually creates a catalogue item.

  Needs `phoenix_kit_catalogue` loaded — tagged `:catalogue` and
  excluded via `test_helper.exs` whenever the optional dependency isn't
  present, same as `shopify_sync_media_panel_test.exs`/
  `sync_catalogue_test.exs`. `async: false`: flips the process-wide
  `shop_product_source` key and mutates `Req.default_options/1`'s
  single VM-global default (same reason `shopify_sync_test.exs`'s own
  "check — stubbed transport" describe block is `async: false`).
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  @moduletag :catalogue

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}

  alias PhoenixKit.Integrations
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce.ProductSource.Catalogue.Query, as: CatalogueQuery
  alias PhoenixKitEcommerce.ShopConfig
  alias PhoenixKitEcommerce.Shopify.SyncScope
  alias PhoenixKitEcommerce.Test.Repo

  @stub __MODULE__

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

  defp json_response(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, JSON.encode!(body))
  end

  defp shop_json_request?(conn), do: String.ends_with?(conn.request_path, "/shop.json")

  # Same reasoning as `shopify_sync_test.exs`'s own `with_shop_lookup/1`:
  # `Sync.check/2`'s currency guard hits `/shop.json` incidentally on
  # every call in this file (a Shopify connection always exists here) —
  # answer it deterministically rather than let it fall through to a
  # scenario's own products-only stub.
  defp with_shop_lookup(stub_fun) do
    fn conn ->
      if shop_json_request?(conn) do
        json_response(conn, 404, %{"errors" => "Not Found"})
      else
        stub_fun.(conn)
      end
    end
  end

  defp check_and_await(view, timeout \\ 100) do
    view |> element("#check-shopify-changes") |> render_click()
    render_async(view, timeout)
  end

  setup %{conn: conn} do
    set_product_source("catalogue")
    on_exit(fn -> set_product_source("legacy") end)

    {:ok, catalogue} = Catalogue.create_catalogue(%{name: "decor3dprint"})

    {:ok, conn: put_test_scope(conn, fake_scope()), catalogue: catalogue}
  end

  describe "sync scope panel" do
    test "shows the default \"whole store\" summary when never configured", %{conn: conn} do
      connect_shopify()
      {:ok, _view, html} = live(conn, "/en/admin/shop/shopify-sync?tab=settings")

      assert html =~ ~s(id="sync-scope-panel")
      assert html =~ ~s(id="sync-scope-summary")
      assert html =~ "Scope: whole store"
    end

    test "saving a filtered scope re-renders the summary and round-trips through SyncScope",
         %{conn: conn} do
      connect_shopify()
      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync?tab=settings")

      html =
        view
        |> form("#sync-scope-form", %{
          "sync_scope" => %{
            "mode" => "filtered",
            "tags" => "catalog-3d, featured",
            "product_types" => "Mug"
          }
        })
        |> render_submit()

      assert html =~ "catalog-3d"
      assert html =~ "featured"
      assert html =~ "Mug"

      assert SyncScope.get() == %{
               mode: :filtered,
               tags: ["catalog-3d", "featured"],
               product_types: ["Mug"]
             }
    end

    test "denied without shop.run_imports — the scope is left untouched", %{conn: conn} do
      connect_shopify()
      conn = put_test_scope(conn, fake_scope(permissions: ["shop"]))
      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync?tab=settings")

      html =
        view
        |> form("#sync-scope-form", %{"sync_scope" => %{"mode" => "filtered", "tags" => "x"}})
        |> render_submit()

      assert html =~ "You don&#39;t have permission to do that"
      assert SyncScope.get() == SyncScope.all()
    end
  end

  describe "media panel — skipped count and the images \"nothing new\" line" do
    defp seed_progress(kind, attrs) do
      value =
        Map.merge(
          %{
            "kind" => kind,
            "total" => 5,
            "done" => 5,
            "skipped" => 0,
            "matched" => 5,
            "stats" => %{},
            "errors" => [],
            "started_at" => "2026-01-01T00:00:00Z",
            "finished_at" => "2026-01-01T00:05:00Z",
            "result" => nil
          },
          attrs
        )

      key = "shopify_media_sync:" <> kind

      %ShopConfig{}
      |> ShopConfig.changeset(%{key: key, value: value})
      |> Repo.insert!()
    end

    test "a finished run's skipped count is rendered", %{conn: conn} do
      connect_shopify()
      seed_progress("images", %{"total" => 10, "done" => 10, "matched" => 7, "skipped" => 3})

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync?tab=media")

      status = view |> element("#media-sync-status-images") |> render()
      assert status =~ "3 skipped"
    end

    test "\"images\" with nothing downloaded and no errors shows the explicit nothing-new line",
         %{conn: conn} do
      connect_shopify()

      seed_progress("images", %{
        "stats" => %{"downloaded" => 0, "reused" => 4, "attached" => 4}
      })

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync?tab=media")

      status = view |> element("#media-sync-status-images") |> render()
      assert status =~ "Nothing new"
    end

    test "\"images\" with a fresh download shows the downloaded/reused counts instead",
         %{conn: conn} do
      connect_shopify()

      seed_progress("images", %{
        "stats" => %{"downloaded" => 12, "reused" => 2, "attached" => 14}
      })

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync?tab=media")

      status = view |> element("#media-sync-status-images") |> render()
      refute status =~ "Nothing new"
      assert status =~ "Downloaded 12"
      assert status =~ "reused 2"
    end

    test "errors render inside a <details>, 25 at a time via load-more", %{conn: conn} do
      connect_shopify()

      errors = for n <- 1..55, do: %{"product" => "p#{n}", "reason" => "no_matching_item"}
      seed_progress("variants", %{"errors" => errors})

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync?tab=media")

      assert has_element?(view, "#media-sync-errors-variants")
      details = view |> element("#media-sync-errors-variants") |> render()
      assert details =~ "p1 — no_matching_item"
      refute details =~ "p26 — no_matching_item"
      assert details =~ "Showing 25 of 55 errors"

      details =
        view
        |> element("#media-sync-errors-load-more-variants button", "Load more")
        |> render_click()

      assert details =~ "p26 — no_matching_item"
      refute details =~ "p51 — no_matching_item"
      assert details =~ "Showing 50 of 55 errors"

      details =
        view
        |> element("#media-sync-errors-load-more-variants button", "Load more")
        |> render_click()

      assert details =~ "p51 — no_matching_item"
      assert details =~ "Showing 55 of 55 errors"
      refute has_element?(view, "#media-sync-errors-load-more-variants button", "Load more")
    end

    # A record written before this PR (or `get_progress/0`'s own
    # fallback to the legacy single `"shopify_media_sync"` key) carries
    # no `"matched"`/`"skipped"`/`"stats"` at all — the page must not
    # read that absence as "0 synced, 0 skipped", which would look like
    # a real, fully-measured run that happened to match nothing.
    test ~S{a legacy-shaped record (no matched/skipped/stats) shows a "not recorded" note, never "0 synced, 0 skipped"},
         %{conn: conn} do
      connect_shopify()

      legacy_value = %{
        "kind" => "collections",
        "total" => 1,
        "done" => 1,
        "errors" => [],
        "started_at" => "2026-01-01T00:00:00Z",
        "finished_at" => "2026-01-01T00:05:00Z",
        "result" => %{"categories_created" => 3}
      }

      %ShopConfig{}
      |> ShopConfig.changeset(%{key: "shopify_media_sync:collections", value: legacy_value})
      |> Repo.insert!()

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync?tab=media")

      status = view |> element("#media-sync-status-collections") |> render()
      refute status =~ "0 synced, 0 skipped"
      assert status =~ "Counts not recorded"
    end
  end

  describe "\"New in Shopify\" panel" do
    defp shopify_product(overrides) do
      Map.merge(
        %{
          "id" => System.unique_integer([:positive]),
          "handle" => "brand-new-mug",
          "title" => "Brand New Mug",
          "product_type" => "Mug",
          "status" => "active",
          "tags" => "catalog-3d",
          "variants" => [%{"price" => "12.50"}]
        },
        overrides
      )
    end

    setup %{conn: conn} do
      uuid = connect_shopify()
      Req.Test.set_req_test_to_private()
      Req.default_options(plug: {Req.Test, @stub})

      on_exit(fn -> Req.default_options([]) end)

      %{conn: conn, uuid: uuid}
    end

    test "lists an in-scope unmatched product and hides an out-of-scope one, with a count line",
         %{conn: conn} do
      assert {:ok, _} = SyncScope.put(%{"mode" => "filtered", "tags" => ["catalog-3d"]})

      Req.Test.stub(
        @stub,
        with_shop_lookup(fn conn ->
          json_response(conn, 200, %{
            "products" => [
              shopify_product(%{"handle" => "in-scope-mug", "tags" => "catalog-3d"}),
              shopify_product(%{"handle" => "out-of-scope-poster", "tags" => "wall-art"})
            ]
          })
        end)
      )

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync?tab=new")
      html = check_and_await(view)

      assert html =~ ~s(id="new-products-panel")
      assert html =~ "New in Shopify (1)"
      assert html =~ ~s(id="add-new-product-in-scope-mug")
      refute html =~ ~s(id="add-new-product-out-of-scope-poster")
      assert html =~ "1 product is outside the sync scope and hidden"
    end

    test "\"Add\" creates a catalogue item from the Shopify payload", %{conn: conn} do
      Req.Test.stub(
        @stub,
        with_shop_lookup(fn conn ->
          json_response(conn, 200, %{
            "products" => [shopify_product(%{"handle" => "brand-new-mug"})]
          })
        end)
      )

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync?tab=new")
      check_and_await(view)

      assert has_element?(view, "#add-new-product-brand-new-mug")
      render_click(view, "request_apply_new_row", %{"handle" => "brand-new-mug"})
      html = render_click(view, "confirm_apply", %{})

      assert html =~ "Added 1 product from Shopify."
      refute has_element?(view, "#add-new-product-brand-new-mug")

      assert Catalogue.list_items_for_catalogue(CatalogueQuery.catalogue_uuid())
             |> Enum.any?(&(&1.data["ecommerce"]["shopify"]["handle"] == "brand-new-mug"))
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

    # A create-`Change`'s currency guard is all-or-nothing per batch
    # (`Sync.create_change/2`'s own moduledoc) — on a mismatch the flash
    # must name the two currencies, the same wording a single-row field
    # apply already gives (`apply_error_flash/3`), not the generic
    # "try again individually" that fits every OTHER failure reason.
    test "\"Add\" surfaces the currency mismatch by name when the store's currency no longer matches",
         %{conn: conn} do
      set_base_currency("USD")

      Req.Test.stub(@stub, fn conn ->
        if String.ends_with?(conn.request_path, "/shop.json") do
          json_response(conn, 200, %{"shop" => %{"currency" => "EUR"}})
        else
          json_response(conn, 200, %{
            "products" => [shopify_product(%{"handle" => "brand-new-mug"})]
          })
        end
      end)

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync?tab=new")
      check_and_await(view)

      render_click(view, "request_apply_new_row", %{"handle" => "brand-new-mug"})
      html = render_click(view, "confirm_apply", %{})

      assert html =~ "EUR"
      assert html =~ "USD"
      refute html =~ "try again individually"
      assert has_element?(view, "#add-new-product-brand-new-mug")

      refute Catalogue.list_items_for_catalogue(CatalogueQuery.catalogue_uuid())
             |> Enum.any?(&(&1.data["ecommerce"]["shopify"]["handle"] == "brand-new-mug"))
    end

    test "empty state when the check finds no new products", %{conn: conn} do
      Req.Test.stub(
        @stub,
        with_shop_lookup(fn conn -> json_response(conn, 200, %{"products" => []}) end)
      )

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync?tab=new")
      html = check_and_await(view)

      assert html =~ ~s(id="new-products-panel")
      assert html =~ "No new products in scope."
    end

    test "load-more reveals more of a long new-products list", %{conn: conn} do
      products = for n <- 1..60, do: shopify_product(%{"handle" => "mug-#{n}"})

      Req.Test.stub(
        @stub,
        with_shop_lookup(fn conn -> json_response(conn, 200, %{"products" => products}) end)
      )

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync?tab=new")
      html = check_and_await(view)

      assert html =~ ~s(id="add-new-product-mug-1")
      refute html =~ ~s(id="add-new-product-mug-60")
      assert html =~ "Showing 50 of 60"

      html =
        view
        |> element("#new-products-load-more button", "Load more")
        |> render_click()

      assert html =~ ~s(id="add-new-product-mug-60")
      refute has_element?(view, "#new-products-load-more button", "Load more")
    end
  end
end
