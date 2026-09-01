defmodule PhoenixKitEcommerce.Web.ShopifySyncTest do
  @moduledoc """
  Covers render states, permission gating, and — via `Req.Test`'s stub
  registry — the full check → diff → render flow through a stubbed HTTP
  transport, reaching all the way into the `start_async` task this
  LiveView spawns for "check", and from there into the field-grouped
  sections, pagination, and the three apply scopes the page exposes.

  The scenario-level fetch → diff coverage (every field on the admin
  path, price-only on the storefront path, `fallback_reason` plumbing)
  stays in `PhoenixKitEcommerce.Shopify.SyncTest` — this file instead
  tests what only the wiring between `Sync.check/2`, `Sync.apply_change/2`
  /`apply_changes/2`, and this LiveView's template can get wrong: whether
  the storefront-fallback banner and the "shop matches Shopify" success
  alert are mutually exclusive (only wrong *in combination* — no unit
  test of `Sync.check/2` alone, or of the template in isolation, can see
  that); whether a section apply actually scopes itself to one field
  when the underlying `Change` carries more than one; whether pagination
  actually bounds what gets rendered instead of merely existing as
  markup nobody's DOM-size ever tests.

  `Sync.check/2` is called here with no `opts`, so there is no per-call
  hook to inject a stub `plug:`. Instead: `Req.default_options/1` sets a
  process-independent default merged into every `Req.new/1` call in the
  VM for the lifetime of one test (see the `setup` below, and its
  `on_exit` teardown). Stub lookup itself stays in `Req.Test`'s default
  PRIVATE mode — `$callers` (set by both `Phoenix.LiveViewTest`'s spawned
  LiveView process and, in turn, by `start_async`'s `Task.async`) lets
  `Req.Test` trace the request back to this test process as the stub's
  owner, so the LiveView process and the `Task` it spawns both resolve
  the same registered stub without any explicit `Req.Test.allow/3` call.
  This file is `async: false` NOT because of private mode (private mode
  is what makes per-test isolation safe to begin with) but because
  `Req.default_options/1` mutates a single VM-global default — two
  `async: true` tests in this file would race to overwrite each other's
  `plug:` default.
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

      Req.Test.set_req_test_to_private()
      Req.default_options(plug: {Req.Test, @stub})

      on_exit(fn ->
        Req.default_options([])
      end)

      {:ok, conn: put_test_scope(conn, fake_scope()), uuid: uuid}
    end

    defp json_response(conn, status, body) do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, JSON.encode!(body))
    end

    defp admin_request?(conn), do: String.starts_with?(conn.request_path, "/admin/")

    defp check_and_await(view, timeout \\ 100) do
      view |> element("#check-shopify-changes") |> render_click()
      render_async(view, timeout)
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

    test "a multi-field change is grouped into every matching section, price first",
         %{conn: conn} do
      {:ok, product} =
        Shop.create_product(%{
          "title" => %{"en" => "Old Widget"},
          "slug" => %{"en" => "widget"},
          "vendor" => "Old Co",
          "status" => "draft",
          "price" => "10.00"
        })

      Req.Test.stub(@stub, fn conn ->
        json_response(conn, 200, %{
          "products" => [
            %{
              "handle" => "widget",
              "title" => "New Widget",
              "vendor" => "New Co",
              "status" => "draft",
              "variants" => [%{"price" => "15.00"}]
            }
          ]
        })
      end)

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync")
      html = check_and_await(view)

      {price_at, _} = :binary.match(html, ~s(id="field-section-price"))
      {title_at, _} = :binary.match(html, ~s(id="field-section-title"))
      {vendor_at, _} = :binary.match(html, ~s(id="field-section-vendor"))
      assert price_at < title_at
      assert title_at < vendor_at

      view |> element("#toggle-section-price") |> render_click()
      view |> element("#toggle-section-title") |> render_click()
      html = view |> element("#toggle-section-vendor") |> render_click()

      assert html =~ "id=\"change-row-price-#{product.uuid}\""
      assert html =~ "id=\"change-row-title-#{product.uuid}\""
      assert html =~ "id=\"change-row-vendor-#{product.uuid}\""
    end

    test "applying a section only writes that field, leaving the product's other differing field",
         %{conn: conn} do
      {:ok, product} =
        Shop.create_product(%{
          "title" => %{"en" => "Old Widget"},
          "slug" => %{"en" => "widget"},
          "status" => "draft",
          "price" => "10.00"
        })

      Req.Test.stub(@stub, fn conn ->
        json_response(conn, 200, %{
          "products" => [
            %{
              "handle" => "widget",
              "title" => "New Widget",
              "status" => "draft",
              "variants" => [%{"price" => "15.00"}]
            }
          ]
        })
      end)

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync")
      check_and_await(view)

      view |> element("#toggle-section-price") |> render_click()
      view |> element("#toggle-section-title") |> render_click()

      html = view |> element("#apply-section-title") |> render_click()

      updated = Shop.get_product!(product.uuid)
      assert updated.title["en"] == "New Widget"
      assert Decimal.eq?(updated.price, Decimal.new("10.00"))

      # The Titles section is now empty and drops out entirely; the price
      # change on this same product is untouched and still shown.
      refute html =~ ~s(id="field-section-title")
      assert html =~ "id=\"change-row-price-#{product.uuid}\""

      assert_activity_logged("shop.shopify_sync_bulk_field_apply",
        metadata_has: %{"count" => 1, "field" => "title"}
      )
    end

    test "pagination bounds an expanded section to 25 rows and pages through the rest",
         %{conn: conn} do
      products =
        for i <- 1..30 do
          {:ok, product} =
            Shop.create_product(%{
              "title" => %{"en" => "Product #{i}"},
              "slug" => %{"en" => "product-#{i}"},
              "vendor" => "Old Co",
              "status" => "draft",
              "price" => "10.00"
            })

          product
        end

      shopify_products =
        for i <- 1..30 do
          %{
            "handle" => "product-#{i}",
            "title" => "Product #{i}",
            "vendor" => "New Co",
            "status" => "draft",
            "variants" => [%{"price" => "10.00"}]
          }
        end

      Req.Test.stub(@stub, fn conn ->
        json_response(conn, 200, %{"products" => shopify_products})
      end)

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync")
      check_and_await(view)

      html = view |> element("#toggle-section-vendor") |> render_click()

      page_1_rows = Regex.scan(~r/id="change-row-vendor-[a-f0-9-]+"/, html) |> length()

      assert page_1_rows == 25
      assert html =~ ~s(id="page-info-vendor")
      assert html =~ "1-25 of 30"

      html = view |> element("#page-next-vendor") |> render_click()

      page_2_rows = Regex.scan(~r/id="change-row-vendor-[a-f0-9-]+"/, html) |> length()

      assert page_2_rows == 5
      assert html =~ "26-30 of 30"

      last_product = List.last(products)
      assert html =~ "id=\"change-row-vendor-#{last_product.uuid}\""
    end

    test "expanding a text-field row reveals the word-level diff; collapsed hides it",
         %{conn: conn} do
      {:ok, product} =
        Shop.create_product(%{
          "title" => %{"en" => "Old Title Text"},
          "slug" => %{"en" => "widget"},
          "status" => "draft",
          "price" => "10.00"
        })

      Req.Test.stub(@stub, fn conn ->
        json_response(conn, 200, %{
          "products" => [
            %{
              "handle" => "widget",
              "title" => "New Title Text",
              "status" => "draft",
              "variants" => [%{"price" => "10.00"}]
            }
          ]
        })
      end)

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync")
      check_and_await(view)

      html = view |> element("#toggle-section-title") |> render_click()
      refute html =~ "diff-ins"
      refute html =~ "diff-del"
      assert html =~ ~s(id="toggle-diff-title-#{product.uuid}")

      html = view |> element("#toggle-diff-title-#{product.uuid}") |> render_click()
      assert html =~ "diff-ins"
      assert html =~ "diff-del"
    end

    test "applying one field of one product only writes that field", %{conn: conn} do
      {:ok, product} =
        Shop.create_product(%{
          "title" => %{"en" => "Old Title"},
          "slug" => %{"en" => "widget"},
          "status" => "draft",
          "price" => "10.00"
        })

      Req.Test.stub(@stub, fn conn ->
        json_response(conn, 200, %{
          "products" => [
            %{
              "handle" => "widget",
              "title" => "New Title",
              "status" => "draft",
              "variants" => [%{"price" => "15.00"}]
            }
          ]
        })
      end)

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync")
      check_and_await(view)

      view |> element("#toggle-section-title") |> render_click()
      html = view |> element("#apply-row-title-#{product.uuid}") |> render_click()

      updated = Shop.get_product!(product.uuid)
      assert updated.title["en"] == "New Title"
      assert Decimal.eq?(updated.price, Decimal.new("10.00"))

      refute html =~ "id=\"change-row-title-#{product.uuid}\""
      assert html =~ ~s(id="field-section-price")

      assert_activity_logged("shop.shopify_sync_apply",
        resource_uuid: product.uuid,
        metadata_has: %{"fields" => ["title"]}
      )
    end

    test "apply everything applies every pending field across all products", %{conn: conn} do
      {:ok, p1} =
        Shop.create_product(%{
          "title" => %{"en" => "P1"},
          "slug" => %{"en" => "p1"},
          "status" => "draft",
          "price" => "10.00"
        })

      {:ok, p2} =
        Shop.create_product(%{
          "title" => %{"en" => "P2"},
          "slug" => %{"en" => "p2"},
          "vendor" => "Old Co",
          "status" => "draft",
          "price" => "20.00"
        })

      Req.Test.stub(@stub, fn conn ->
        json_response(conn, 200, %{
          "products" => [
            %{
              "handle" => "p1",
              "title" => "P1 New",
              "status" => "draft",
              "variants" => [%{"price" => "10.00"}]
            },
            %{
              "handle" => "p2",
              "title" => "P2",
              "vendor" => "New Co",
              "status" => "draft",
              "variants" => [%{"price" => "20.00"}]
            }
          ]
        })
      end)

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync")
      check_and_await(view)

      html = view |> element("#apply-everything") |> render_click()

      assert Shop.get_product!(p1.uuid).title["en"] == "P1 New"
      assert Shop.get_product!(p2.uuid).vendor == "New Co"
      assert html =~ "the shop matches Shopify"

      assert_activity_logged("shop.shopify_sync_bulk_apply_all", metadata_has: %{"count" => 2})
    end

    # A storefront scenario with an actual (non-empty) price row was
    # deliberately NOT added here: `StorefrontClient` sleeps its default
    # 500ms `page_delay_ms` before requesting the page after any non-empty
    # one (there is no way to pass `page_delay_ms: 0` from this LiveView's
    # zero-opts `Sync.check/2` call — see `StorefrontClient`'s moduledoc),
    # and that combined with a real sleep across the `start_async` Task
    # boundary made `render_async/2` intermittently lose the private-mode
    # stub's ownership on the delayed second request even at generous
    # (1500ms) timeouts — exactly the "misleading 'cannot find mock'
    # cascade" this task's brief warned about. The "only Prices renders
    # for a storefront source" guarantee is proven two other ways instead:
    # the empty-price-diff scenario above (real end-to-end flow, just with
    # nothing to page past), and `visible_sections/2`'s direct unit tests
    # below — which is the only way to see the *filter* fire at all, since
    # (per that function's doc) no real storefront payload can ever carry
    # a non-price field for it to filter out.
  end

  describe "visible_sections/2 — storefront fallback stays honest" do
    alias PhoenixKitEcommerce.Shopify.ProductDiff.Change
    alias PhoenixKitEcommerce.Web.ShopifySync

    # `Source`/`StorefrontClient`/`ProductDiff` already make it structurally
    # impossible for a real `check/2` result to carry a non-price field
    # when `source == :storefront` (see `visible_sections/2`'s own doc for
    # the chain of guarantees) — so an end-to-end LiveView test can never
    # exercise this function's own filter, only the upstream ones. This
    # unit-tests the filter directly, with a synthetic multi-field change
    # no real storefront fetch could ever produce, so a mutation that
    # deletes the filter is still caught even though nothing "for real"
    # would ever trigger it.
    defp multi_field_change do
      %Change{
        product_uuid: Ecto.UUID.generate(),
        handle: "widget",
        title: "Widget",
        changes: %{
          price: %{current: Decimal.new("10.00"), incoming: Decimal.new("12.00")},
          title: %{current: "Old", incoming: "New"},
          vendor: %{current: "Old Co", incoming: "New Co"}
        }
      }
    end

    test "keeps only Prices when source is :storefront, even given other fields" do
      sections = ShopifySync.visible_sections([multi_field_change()], :storefront)
      assert Keyword.keys(sections) == [:price]
    end

    test "keeps every matching section, price first, for the :admin source" do
      sections = ShopifySync.visible_sections([multi_field_change()], :admin)
      assert Keyword.keys(sections) == [:price, :title, :vendor]
    end
  end
end
