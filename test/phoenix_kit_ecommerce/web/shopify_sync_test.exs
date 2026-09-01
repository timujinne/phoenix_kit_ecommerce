defmodule PhoenixKitEcommerce.Web.ShopifySyncTest do
  @moduledoc """
  Covers render states, permission gating, and — via `Req.Test`'s shared
  mode — the full check → diff → render flow through a stubbed HTTP
  transport, reaching all the way into the `start_async` task this
  LiveView spawns for "check".

  The scenario-level fetch → diff coverage (every field on the admin
  path, price-only on the storefront path, `fallback_reason` plumbing)
  stays in `PhoenixKitEcommerce.Shopify.SyncTest` — this file instead
  tests what only the wiring between `Sync.check/2` and this LiveView's
  template can get wrong: whether the storefront-fallback banner and the
  "shop matches Shopify" success alert are mutually exclusive. They are
  only wrong *in combination* — no unit test of `Sync.check/2` alone, or
  of the template in isolation, can see that.

  `Sync.check/2` is called here with no `opts`, so there is no per-call
  hook to inject a stub `plug:`. Instead: `Req.default_options/1` sets a
  process-independent default merged into every `Req.new/1` call in the
  VM for the lifetime of one test (see the `setup` below, and its
  `on_exit` teardown), and `Req.Test.set_req_test_to_shared/1` makes the
  registered stub available regardless of which process — the LiveView,
  or the `Task` its `start_async` spawns — ends up making the request.
  This file is `async: false`, which is the shared mode's own
  documented prerequisite (its stubs "cannot be used concurrently").
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKit.Integrations
  alias PhoenixKitEcommerce, as: Shop

  @stub __MODULE__

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

  describe "not connected" do
    setup %{conn: conn} do
      {:ok, conn: put_test_scope(conn, fake_scope())}
    end

    test "shows a connect prompt and no check button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/shop/shopify-sync")

      assert html =~ "Shopify isn&#39;t connected yet"
      refute html =~ ~s(id="check-shopify-changes")
    end
  end

  describe "connected" do
    setup %{conn: conn} do
      connect_shopify()
      {:ok, conn: put_test_scope(conn, fake_scope())}
    end

    test "shows the connection name and a check button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/shop/shopify-sync")

      assert html =~ "Connected:"
      assert html =~ ~s(id="check-shopify-changes")
    end
  end

  describe "permission gating" do
    setup %{conn: conn} do
      connect_shopify()
      {:ok, conn: put_test_scope(conn, fake_scope(permissions: ["shop"]))}
    end

    test "check is denied without shop.run_imports", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync")

      html = render_click(element(view, "#check-shopify-changes"))

      assert html =~ "You don&#39;t have permission to do that"
    end
  end

  describe "check — stubbed transport, full flow" do
    setup %{conn: conn} do
      uuid = connect_shopify()

      Req.Test.set_req_test_to_shared()
      Req.default_options(plug: {Req.Test, @stub})

      on_exit(fn ->
        Req.default_options([])
        Req.Test.set_req_test_to_private()
      end)

      {:ok, conn: put_test_scope(conn, fake_scope()), uuid: uuid}
    end

    defp json_response(conn, status, body) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, JSON.encode!(body))
    end

    defp admin_request?(conn), do: String.starts_with?(conn.request_path, "/admin/")

    defp check_and_await(view) do
      view |> element("#check-shopify-changes") |> render_click()
      render_async(view)
    end

    test "storefront fallback with no price differences shows the fallback banner, never the success alert",
         %{conn: conn} do
      {:ok, _product} =
        Shop.create_product(%{
          "title" => %{"en" => "Widget"},
          "slug" => %{"en" => "widget"},
          "price" => "20.00"
        })

      # An empty first page short-circuits StorefrontClient's pagination
      # immediately (no second request, no real page_delay_ms sleep —
      # this LiveView calls Sync.check/2 with no opts, so there is no
      # way to pass page_delay_ms: 0 from here). All that matters for
      # this scenario is that the storefront path returns zero changes.
      Req.Test.stub(@stub, fn conn ->
        if admin_request?(conn) do
          json_response(conn, 401, %{"errors" => "Invalid API key"})
        else
          json_response(conn, 200, %{"products" => []})
        end
      end)

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync")
      html = check_and_await(view)

      assert html =~ ~s(id="storefront-fallback-notice")
      assert html =~ "the access token was rejected"
      assert html =~ ~s(id="storefront-no-price-changes")
      refute html =~ "the shop matches Shopify"
    end

    test "admin path with no differences shows the success alert, never the fallback banner",
         %{conn: conn} do
      {:ok, _product} =
        Shop.create_product(%{
          "title" => %{"en" => "Gadget"},
          "slug" => %{"en" => "gadget"},
          "vendor" => "Acme",
          "price" => "30.00"
        })

      Req.Test.stub(@stub, fn conn ->
        json_response(conn, 200, %{
          "products" => [
            %{
              "handle" => "gadget",
              "title" => "Gadget",
              "vendor" => "Acme",
              "status" => "draft",
              "variants" => [%{"price" => "30.00"}]
            }
          ]
        })
      end)

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync")
      html = check_and_await(view)

      assert html =~ "the shop matches Shopify"
      refute html =~ ~s(id="storefront-fallback-notice")
      refute html =~ ~s(id="storefront-no-price-changes")
    end
  end
end
