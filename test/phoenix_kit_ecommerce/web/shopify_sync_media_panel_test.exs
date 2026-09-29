defmodule PhoenixKitEcommerce.Web.ShopifySyncMediaPanelTest do
  @moduledoc """
  The "Media & collections" panel on `PhoenixKitEcommerce.Web.ShopifySync`
  (Block 7 Task 5, `docs/superpowers/plans/2026-09-06-block7-shopify-
  media-collections.md`): three buttons that enqueue `ShopifyMediaSyncWorker`
  jobs, gated on the catalogue product source and the `shop.run_imports`
  permission, live progress via PubSub, and a button staying disabled
  while a job of ITS kind is in flight.

  Needs `phoenix_kit_catalogue` loaded — the panel is gated on
  `ProductSource.current/0 == Catalogue`, which is unconditionally
  `Legacy` without that optional dependency (see its own moduledoc) —
  tagged `:catalogue` and excluded via `test_helper.exs`, same as the
  rest of Block 7's suite.

  Uses the suite-wide `Oban` instance `test_helper.exs` starts (named
  `Oban`, matching the bare `Oban.insert/1` the LiveView's
  `handle_event("run_media_sync", ...)` calls). `testing: :manual` — jobs
  land in `oban_jobs` through the test's sandboxed connection, so they roll
  back with it, but are never auto-processed. Starting a second instance
  here under the same VM-global name fails every test in this module.
  `async: false`: flips the process-wide `shop_product_source` key.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  @moduletag :catalogue

  use Oban.Testing, repo: PhoenixKitEcommerce.Test.Repo

  alias PhoenixKit.Integrations
  alias PhoenixKit.PubSub.Manager
  alias PhoenixKitEcommerce.ShopConfig
  alias PhoenixKitEcommerce.Test.Repo
  alias PhoenixKitEcommerce.Workers.ShopifyMediaSyncWorker

  setup %{conn: conn} do
    on_exit(fn -> set_product_source("legacy") end)
    set_product_source("catalogue")

    connect_shopify()

    {:ok, conn: put_test_scope(conn, fake_scope())}
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

  defp seed_progress(kind, finished_at) do
    value = %{
      "kind" => kind,
      "total" => 5,
      "done" => 2,
      "errors" => [],
      "started_at" => "2026-01-01T00:00:00Z",
      "finished_at" => finished_at,
      "result" => nil
    }

    case Repo.get(ShopConfig, "shopify_media_sync") do
      nil ->
        %ShopConfig{}
        |> ShopConfig.changeset(%{key: "shopify_media_sync", value: value})
        |> Repo.insert!()

      config ->
        config
        |> ShopConfig.changeset(%{value: value})
        |> Repo.update!()
    end
  end

  # Per-kind progress key, unlike `seed_progress/2`'s legacy single key —
  # lets a test set `"warnings"`/`"stats"["approximated"]` directly, the
  # way a real `ShopifyMediaSyncWorker` run would write them.
  defp seed_kind_progress(kind, extra) do
    value =
      Map.merge(
        %{
          "kind" => kind,
          "total" => 3,
          "done" => 3,
          "matched" => 3,
          "skipped" => 0,
          "stats" => %{},
          "errors" => [],
          "started_at" => "2026-01-01T00:00:00Z",
          "finished_at" => "2026-01-01T00:05:00Z",
          "result" => nil
        },
        extra
      )

    key = "shopify_media_sync:" <> kind

    %ShopConfig{}
    |> ShopConfig.changeset(%{key: key, value: value})
    |> Repo.insert!()
  end

  defp count_li(html), do: Regex.scan(~r/<li>/, html) |> length()

  test "the panel is absent under the legacy source", %{conn: conn} do
    set_product_source("legacy")
    {:ok, _view, html} = live(conn, "/en/admin/shop/shopify-sync?tab=media")

    refute html =~ ~s(id="media-sync-panel")
  end

  describe "catalogue source" do
    test "shows all three buttons, none disabled", %{conn: conn} do
      {:ok, view, html} = live(conn, "/en/admin/shop/shopify-sync?tab=media")

      assert html =~ ~s(id="media-sync-panel")

      for kind <- ~w(images variants collections) do
        refute has_element?(view, "#sync-media-#{kind}[disabled]")
      end
    end

    test "shows the active collections filter — \"none\" when never configured", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/shop/shopify-sync?tab=settings")

      assert html =~ ~s(id="media-sync-collections-filter")
      assert html =~ "Collections filter: none"
    end

    test "shows the configured collections filter's prefix and exclude list", %{conn: conn} do
      %ShopConfig{}
      |> ShopConfig.changeset(%{
        key: "shopify_collections_filter",
        value: %{"value" => %{"prefix" => "3d-printed-", "exclude" => ["3d-printed-items"]}}
      })
      |> Repo.insert!()

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync?tab=settings")

      filter_html = view |> element("#media-sync-collections-filter") |> render()

      assert filter_html =~ "prefix 3d-printed-,"
      assert filter_html =~ "excluding 3d-printed-items"
    end

    test "clicking a button enqueues a job with that kind and the current user", %{conn: conn} do
      user_uuid = Ecto.UUID.generate()
      conn = put_test_scope(conn, fake_scope(user_uuid: user_uuid))
      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync?tab=media")

      render_click(element(view, "#sync-media-images"))

      assert_enqueued(
        worker: ShopifyMediaSyncWorker,
        args: %{"kind" => "images", "actor_uuid" => user_uuid}
      )
    end

    test "a second click before the first job starts hits Oban's own uniqueness — no second job, an info flash instead of the success wording",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync?tab=media")

      html1 = render_click(element(view, "#sync-media-images"))
      assert html1 =~ "Sync queued"

      # `media_sync_in_flight?/2` reads the PROGRESS record, which the
      # worker only writes once it actually starts running — nothing
      # updates it just from enqueueing, so the button itself stays
      # enabled and a second click reaches `Oban.insert/1` for real. It
      # is Oban's own `unique:` (still `:available`, per Global
      # Constraints — no job is ever processed here) that must catch it.
      html2 = render_click(element(view, "#sync-media-images"))
      refute html2 =~ "Sync queued"
      assert html2 =~ "already running"

      assert [_one_job] =
               all_enqueued(worker: ShopifyMediaSyncWorker, args: %{"kind" => "images"})
    end

    test "denied without shop.run_imports — no flash success, nothing enqueued", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope(permissions: ["shop"]))
      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync?tab=media")

      html = render_click(element(view, "#sync-media-variants"))

      assert html =~ "You don&#39;t have permission to do that"
      refute_enqueued(worker: ShopifyMediaSyncWorker, args: %{"kind" => "variants"})
    end

    test "a kind already in flight (per the progress record) renders disabled and refuses a second enqueue",
         %{conn: conn} do
      seed_progress("images", nil)

      {:ok, view, html} = live(conn, "/en/admin/shop/shopify-sync?tab=media")

      assert has_element?(view, "#sync-media-images[disabled]")
      refute has_element?(view, "#sync-media-variants[disabled]")
      assert html =~ "images"

      # Not `render_click(element(view, "#sync-media-images"))` —
      # `Phoenix.LiveViewTest` refuses to click a disabled element, which
      # would never reach `handle_event("run_media_sync", ...)` at all
      # and leave its own in-flight guard (`media_sync_in_flight?/2`)
      # completely untested. Drive the event directly, the way a
      # tampered/stale client request would.
      render_click(view, "run_media_sync", %{"kind" => "images"})
      refute_enqueued(worker: ShopifyMediaSyncWorker, args: %{"kind" => "images"})
    end

    test "a finished progress record does not disable the button", %{conn: conn} do
      seed_progress("collections", "2026-01-01T00:05:00Z")

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync?tab=media")

      refute has_element?(view, "#sync-media-collections[disabled]")
    end

    test "a PubSub progress broadcast updates the panel live, without a page reload", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync?tab=media")

      Manager.broadcast(
        ShopifyMediaSyncWorker.topic(),
        {:media_sync_progress,
         %{
           "kind" => "variants",
           "total" => 10,
           "done" => 4,
           "errors" => [],
           "started_at" => "2026-01-01T00:00:00Z",
           "finished_at" => nil,
           "result" => nil
         }}
      )

      html = render(view)
      assert html =~ "4 / 10"
      assert has_element?(view, "#sync-media-variants[disabled]")
    end

    test "a broadcast while on another tab doesn't crash, and is visible after switching to media",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync")

      Manager.broadcast(
        ShopifyMediaSyncWorker.topic(),
        {:media_sync_progress,
         %{
           "kind" => "variants",
           "total" => 10,
           "done" => 4,
           "errors" => [],
           "started_at" => "2026-01-01T00:00:00Z",
           "finished_at" => nil,
           "result" => nil
         }}
      )

      html = render(view)
      refute html =~ ~s(id="media-sync-panel")

      html =
        view
        |> element(~s(a[href$="?tab=media"]))
        |> render_click()

      assert html =~ "4 / 10"
      assert has_element?(view, "#sync-media-variants[disabled]")
    end

    test "approximated prices are listed apart from errors", %{conn: conn} do
      seed_kind_progress("variants", %{
        "stats" => %{"values_created" => 0, "approximated" => 1},
        "warnings" => [
          %{
            "product" => "sculpture",
            "reason" => "prices approximated (cheapest): 21 of 256 variants differ"
          }
        ]
      })

      {:ok, view, html} = live(conn, "/en/admin/shop/shopify-sync?tab=media")

      assert html =~ "1 with approximated prices"
      assert has_element?(view, "#media-sync-warnings-variants")
      refute has_element?(view, "#media-sync-errors-variants")
      assert html =~ "sculpture"
    end

    test "a record from before warnings existed renders without them", %{conn: conn} do
      seed_kind_progress("variants", %{"stats" => %{"values_created" => 0}})

      {:ok, view, html} = live(conn, "/en/admin/shop/shopify-sync?tab=media")

      refute has_element?(view, "#media-sync-warnings-variants")
      refute html =~ "approximated"
    end

    test "warnings and errors load-more counters are independent", %{conn: conn} do
      warnings =
        for n <- 1..30,
            do: %{"product" => "wp#{n}", "reason" => "prices approximated: reason #{n}"}

      errors = for n <- 1..30, do: %{"product" => "ep#{n}", "reason" => "boom #{n}"}

      seed_kind_progress("variants", %{
        "stats" => %{"values_created" => 0, "approximated" => 30},
        "warnings" => warnings,
        "errors" => errors
      })

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync?tab=media")

      assert view |> element("#media-sync-warnings-variants") |> render() |> count_li() == 25
      assert view |> element("#media-sync-errors-variants") |> render() |> count_li() == 25

      view
      |> element("#media-sync-warnings-load-more-variants button", "Load more")
      |> render_click()

      assert view |> element("#media-sync-warnings-variants") |> render() |> count_li() == 30
      assert view |> element("#media-sync-errors-variants") |> render() |> count_li() == 25
    end
  end
end
