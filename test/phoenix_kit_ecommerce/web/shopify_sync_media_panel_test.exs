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

  Starts its OWN local `Oban` instance, NAMED `Oban` (matching the
  bare `Oban.insert/1` the LiveView's `handle_event("run_media_sync", ...)`
  calls — there is no application-wide Oban config in this fork's own
  test env; Oban is the HOST app's concern, see `config/test.exs`'s own
  comment). `testing: :manual` — jobs land in `oban_jobs` (already
  present in the shared test database; the host app owns that
  migration) but are never auto-processed. `start_supervised!` ties its
  lifetime to each test, so no state or registered name leaks between
  tests. `async: false`: flips the process-wide `shop_product_source`
  key and registers a process under a fixed, VM-global name (`Oban`).
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

    start_supervised!({Oban, name: Oban, repo: Repo, testing: :manual, queues: [shop_imports: 1]})

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

  test "the panel is absent under the legacy source", %{conn: conn} do
    set_product_source("legacy")
    {:ok, _view, html} = live(conn, "/en/admin/shop/shopify-sync")

    refute html =~ ~s(id="media-sync-panel")
  end

  describe "catalogue source" do
    test "shows all three buttons, none disabled", %{conn: conn} do
      {:ok, view, html} = live(conn, "/en/admin/shop/shopify-sync")

      assert html =~ ~s(id="media-sync-panel")

      for kind <- ~w(images variants collections) do
        refute has_element?(view, "#sync-media-#{kind}[disabled]")
      end
    end

    test "clicking a button enqueues a job with that kind and the current user", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync")

      render_click(element(view, "#sync-media-images"))

      assert_enqueued(worker: ShopifyMediaSyncWorker, args: %{"kind" => "images"})
    end

    test "a second click before the first job starts hits Oban's own uniqueness — no second job, an info flash instead of the success wording",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync")

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
      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync")

      html = render_click(element(view, "#sync-media-variants"))

      assert html =~ "You don&#39;t have permission to do that"
      refute_enqueued(worker: ShopifyMediaSyncWorker, args: %{"kind" => "variants"})
    end

    test "a kind already in flight (per the progress record) renders disabled and refuses a second enqueue",
         %{conn: conn} do
      seed_progress("images", nil)

      {:ok, view, html} = live(conn, "/en/admin/shop/shopify-sync")

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

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync")

      refute has_element?(view, "#sync-media-collections[disabled]")
    end

    test "a PubSub progress broadcast updates the panel live, without a page reload", %{
      conn: conn
    } do
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
      assert html =~ "4/10"
      assert has_element?(view, "#sync-media-variants[disabled]")
    end
  end
end
