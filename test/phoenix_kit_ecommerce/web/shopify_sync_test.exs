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

  Every apply affordance (row, section, selection, everything) is now
  request → confirm through `<.confirm_modal>` (see the LiveView's own
  moduledoc) — `confirm!/1` below drives that second step. A click on the
  request button alone is deliberately NOT enough to prove a write
  happened; the tests that care about the write always confirm.

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
  alias PhoenixKit.Integrations.Providers
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

  describe "shop_shopify_enabled = false (design §4.7)" do
    setup %{conn: conn} do
      connect_shopify()

      PhoenixKit.Settings.update_boolean_setting_with_module(
        "shop_shopify_enabled",
        false,
        "shop"
      )

      # The `Settings` cache (unlike the settings TABLE row) survives the
      # sandbox rollback, and `Integrations.Providers`' own
      # `:persistent_term` cache is process-global — left "false", either
      # would poison `connect_shopify()` in a LATER test (any file) with
      # `{:error, :unknown_provider}`, since `Providers.get/1` stops
      # seeing Shopify at all. Restore unconditionally.
      on_exit(fn ->
        PhoenixKit.Settings.update_boolean_setting_with_module(
          "shop_shopify_enabled",
          true,
          "shop"
        )

        Providers.clear_cache()
      end)

      {:ok, conn: put_test_scope(conn, fake_scope())}
    end

    test "redirects to the shop admin dashboard with an explanation", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: to, flash: flash}}} =
               live(conn, "/en/admin/shop/shopify-sync")

      assert to =~ "/admin/shop"
      assert flash["error"] =~ "Shopify sync is turned off"
    end

    test "a saved connection and its token are untouched — only reachability changed", %{
      conn: conn
    } do
      [before_toggle] = Integrations.list_connections("shopify", owner: :system)

      live(conn, "/en/admin/shop/shopify-sync")

      PhoenixKit.Settings.update_boolean_setting_with_module("shop_shopify_enabled", true, "shop")
      [after_toggle] = Integrations.list_connections("shopify", owner: :system)

      assert before_toggle.uuid == after_toggle.uuid
      assert before_toggle.data == after_toggle.data
    end
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

  describe "authz on the write path (confirm_apply is the only handler that writes)" do
    alias PhoenixKitEcommerce.Shopify.ProductDiff.Change
    alias PhoenixKitEcommerce.Web.ShopifySync

    # `request_apply_row`/`confirm_apply` can only be exercised for real
    # through a mounted, connected LiveView — but a real `check` event is
    # ITSELF `:run_imports`-gated (see the test above), so a
    # permission-less scope can never legitimately populate `@changes`
    # through the actual UI flow to begin with, making the two handlers'
    # own guards unreachable from a wire-level test. Calling
    # `handle_event/3` directly against a synthetic socket (same
    # rationale `visible_changes/2`'s tests below use) is the only way to
    # exercise a denied write with real pending state in play.
    test "a permission-less scope can neither open nor confirm an apply, and nothing is written" do
      {:ok, product} =
        Shop.create_product(%{
          "title" => %{"en" => "Widget"},
          "slug" => %{"en" => "widget"},
          "vendor" => "Old Co",
          "status" => "draft",
          "price" => "10.00"
        })

      change = %Change{
        product_uuid: product.uuid,
        handle: "widget",
        title: "Widget",
        base_locale: "en",
        changes: %{vendor: %{current: "Old Co", incoming: "New Co"}}
      }

      denied_socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          flash: %{},
          phoenix_kit_current_scope: fake_scope(permissions: ["shop"]),
          changes: [change],
          source: :admin,
          pending: nil
        }
      }

      # `request_apply_row` denied outright: it must never reach far
      # enough to open the confirm modal (`@pending` stays nil) — this is
      # the guard that goes missing if its own `Authz.authorize/3`
      # wrapper is deleted.
      {:noreply, after_request} =
        ShopifySync.handle_event(
          "request_apply_row",
          %{"field" => "vendor", "uuid" => product.uuid},
          denied_socket
        )

      assert after_request.assigns.pending == nil

      # `confirm_apply` has its OWN, independent guard — it must refuse
      # to write even when `@pending` is already set (e.g. permission was
      # revoked between a legitimately-opened confirmation and the
      # confirm click; `clear_pending/1`'s own moduledoc note is exactly
      # this kind of staleness). Constructing `@pending` directly, rather
      # than via `request_apply_row` above (which correctly refused to
      # set it), is what isolates this handler's guard from the other
      # one's.
      stale_pending_socket = %{
        denied_socket
        | assigns:
            Map.put(denied_socket.assigns, :pending, %{
              scope: :row,
              field: :vendor,
              uuid: product.uuid
            })
      }

      assert {:noreply, _socket} =
               ShopifySync.handle_event("confirm_apply", %{}, stale_pending_socket)

      assert Shop.get_product!(product.uuid).vendor == "Old Co"
      refute_activity_logged("shop.shopify_sync_apply", resource_uuid: product.uuid)
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

    # Pushes "confirm_apply" straight to the view rather than clicking a
    # DOM element: `<.confirm_modal>`'s own confirm button carries no id
    # (see `deps/phoenix_kit/.../core/modal.ex`), and going through the
    # view directly is exactly what the modal's `phx-click={@on_confirm}`
    # does client-side anyway.
    defp confirm!(view), do: render_click(view, "confirm_apply", %{})
    defp cancel!(view), do: render_click(view, "cancel_apply", %{})

    # Pulls the numeric value out of a `<.stat_card compact>` by its
    # wrapping id — the value sits in the first `.text-2xl` inside that
    # wrapper, several lines below the id in the compact markup, so a
    # plain `=~` substring check can't isolate WHICH card's number is
    # WHICH the way this needs to (`stat-total-changes` and
    # `stat-price-changes` can share the same digit by coincidence).
    defp stat_card_value(html, wrapper_id) do
      Regex.run(
        ~r/id="#{wrapper_id}".*?text-2xl font-bold mb-1">\s*(\S+)\s*</s,
        html
      )
      |> case do
        [_, value] -> value
        nil -> nil
      end
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

    # `Source.fetch/2` returns `{:error, {:fallback_failed, reason,
    # storefront_reason}}` when the credential failure that triggered the
    # storefront fallback is followed by the storefront ALSO failing — a
    # rejected token and an unpublished/unreachable storefront is an
    # ordinary pairing. The error banner must lead with the credential
    # failure (the actionable half), not just the storefront's own error.
    test "an error banner leads with the credential failure when the storefront fallback also fails",
         %{conn: conn} do
      Req.Test.stub(@stub, fn conn ->
        if admin_request?(conn) do
          json_response(conn, 401, %{"errors" => "Invalid API key"})
        else
          json_response(conn, 500, %{})
        end
      end)

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync")
      html = check_and_await(view)

      assert html =~ "Shopify rejected the access token"
      assert html =~ "storefront fallback also failed"
    end

    # Same path, but with the 403 the unified-sync work introduced.
    # `:forbidden` had a `format_fallback_reason/1` clause and no
    # `format_error/1` one, so the credential half of `{:fallback_failed,
    # ...}` — the half that whole tuple exists to put first — printed the
    # raw atom through the generic `inspect/1` clause. Asserting the
    # atom's ABSENCE is the load-bearing half: the sentence alone would
    # still pass if a later change reverted to inspecting it alongside
    # some other prose.
    test "a 403 credential failure names the missing scope instead of inspecting :forbidden",
         %{conn: conn} do
      Req.Test.stub(@stub, fn conn ->
        if admin_request?(conn) do
          json_response(conn, 403, %{"errors" => "This action requires merchant approval"})
        else
          json_response(conn, 500, %{})
        end
      end)

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync")
      html = check_and_await(view)

      assert html =~ "read_products"
      assert html =~ "storefront fallback also failed"
      refute html =~ "Could not reach Shopify: :forbidden"
    end

    # Discriminates the numerator from two wrong-but-plausible ones: the
    # local catalog's total size (overcounts — a local-only product was
    # never in this check's reach) and `length(@changes)` (undercounts —
    # a matched-but-identical product is matched with nothing to show).
    # Four distinct percentages (matched/shopify=50%, all-local/shopify=
    # 75%, changes/shopify=25%) mean any of the three wrong numerators
    # renders visibly differently, not just a different-but-plausible
    # number.
    test "the coverage stat's numerator is matched products, not the local total or the diff count",
         %{conn: conn} do
      {:ok, _matched_with_diff} =
        Shop.create_product(%{
          "title" => %{"en" => "Widget"},
          "slug" => %{"en" => "matched-with-diff"},
          "vendor" => "Old Co",
          "status" => "draft",
          "price" => "10.00"
        })

      {:ok, _matched_no_diff} =
        Shop.create_product(%{
          "title" => %{"en" => "Widget"},
          "slug" => %{"en" => "matched-no-diff"},
          "vendor" => "Acme",
          "status" => "draft",
          "price" => "10.00"
        })

      {:ok, _unmatched_local} =
        Shop.create_product(%{
          "title" => %{"en" => "Widget"},
          "slug" => %{"en" => "no-shopify-counterpart"},
          "status" => "draft",
          "price" => "10.00"
        })

      Req.Test.stub(@stub, fn conn ->
        json_response(conn, 200, %{
          "products" => [
            %{
              "handle" => "matched-with-diff",
              "title" => "Widget",
              "vendor" => "New Co",
              "status" => "draft",
              "variants" => [%{"price" => "10.00"}]
            },
            %{
              "handle" => "matched-no-diff",
              "title" => "Widget",
              "vendor" => "Acme",
              "status" => "draft",
              "variants" => [%{"price" => "10.00"}]
            },
            %{
              "handle" => "shopify-only-x",
              "title" => "Whatever",
              "status" => "draft",
              "variants" => [%{"price" => "10.00"}]
            },
            %{
              "handle" => "shopify-only-y",
              "title" => "Whatever",
              "status" => "draft",
              "variants" => [%{"price" => "10.00"}]
            }
          ]
        })
      end)

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync")
      html = check_and_await(view)

      assert html =~ ~s(id="stat-coverage")
      assert html =~ "2/4"
      assert html =~ "50% of the Shopify catalogue"
      refute html =~ "75% of the Shopify catalogue"
      refute html =~ "25% of the Shopify catalogue"
    end

    # Discriminates the field key from `:title`: P1 differs only in
    # price, P2 and P3 only in title. If the "Price changes" card counted
    # `:title` instead of `:price`, it would read 2, not 1.
    test "the price-changes stat card counts the :price field, not :title",
         %{conn: conn} do
      {:ok, _p1} =
        Shop.create_product(%{
          "title" => %{"en" => "Same Title"},
          "slug" => %{"en" => "p1"},
          "status" => "draft",
          "price" => "10.00"
        })

      {:ok, _p2} =
        Shop.create_product(%{
          "title" => %{"en" => "Old Title B"},
          "slug" => %{"en" => "p2"},
          "status" => "draft",
          "price" => "10.00"
        })

      {:ok, _p3} =
        Shop.create_product(%{
          "title" => %{"en" => "Old Title C"},
          "slug" => %{"en" => "p3"},
          "status" => "draft",
          "price" => "10.00"
        })

      Req.Test.stub(@stub, fn conn ->
        json_response(conn, 200, %{
          "products" => [
            %{
              "handle" => "p1",
              "title" => "Same Title",
              "status" => "draft",
              "variants" => [%{"price" => "15.00"}]
            },
            %{
              "handle" => "p2",
              "title" => "New Title B",
              "status" => "draft",
              "variants" => [%{"price" => "10.00"}]
            },
            %{
              "handle" => "p3",
              "title" => "New Title C",
              "status" => "draft",
              "variants" => [%{"price" => "10.00"}]
            }
          ]
        })
      end)

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync")
      html = check_and_await(view)

      assert stat_card_value(html, "stat-total-changes") == "3"
      assert stat_card_value(html, "stat-price-changes") == "1"
    end

    test "the coverage stat card does not render on the storefront fallback path",
         %{conn: conn} do
      {:ok, _product} =
        Shop.create_product(%{
          "title" => %{"en" => "Widget"},
          "slug" => %{"en" => "widget"},
          "price" => "10.00"
        })

      Req.Test.stub(@stub, fn conn ->
        if admin_request?(conn) do
          json_response(conn, 401, %{"errors" => "Invalid API key"})
        else
          case storefront_page(conn) do
            "1" ->
              json_response(conn, 200, %{
                "products" => [%{"handle" => "widget", "variants" => [%{"price" => "15.00"}]}]
              })

            _ ->
              json_response(conn, 200, %{"products" => []})
          end
        end
      end)

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync")
      html = check_and_await(view, 3000)

      assert html =~ ~s(id="stat-total-changes")
      assert html =~ ~s(id="stat-price-changes")
      refute html =~ ~s(id="stat-coverage")
      refute html =~ "of the Shopify catalogue"
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

      view |> element("#apply-section-title") |> render_click()
      html = confirm!(view)

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
      assert html =~ "Showing 1 to 25 of 30 results"

      # `data-bulk-total` drives the select-all checkbox's tri-state math
      # (checked only once selected count == total) — it must be the
      # CURRENT PAGE's row count (25), not the whole section's (30), or
      # select-all on page 1 could never show fully checked.
      assert html =~ ~s(data-bulk-total="25")
      refute html =~ ~s(data-bulk-total="30")

      html = view |> element("#page-next-vendor") |> render_click()

      page_2_rows = Regex.scan(~r/id="change-row-vendor-[a-f0-9-]+"/, html) |> length()

      assert page_2_rows == 5
      assert html =~ "Showing 26 to 30 of 30 results"
      assert html =~ ~s(data-bulk-total="5")

      last_product = List.last(products)
      assert html =~ "id=\"change-row-vendor-#{last_product.uuid}\""
    end

    # A pending confirmation belongs to the page it was opened on — a
    # row's uuid, or a selection's uuids, are only meaningful against
    # whatever the section was showing at request time. Paging away
    # must close it, not leave it able to confirm into a write for a
    # product that's no longer even on screen.
    test "paging a section clears a pending confirmation instead of letting it survive to be confirmed",
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

      view |> element("#toggle-section-vendor") |> render_click()

      first_on_page_1 = List.first(products)
      html = view |> element("#apply-row-vendor-#{first_on_page_1.uuid}") |> render_click()
      assert html =~ "Update #{first_on_page_1.title["en"]}: Vendor"

      html = view |> element("#page-next-vendor") |> render_click()
      refute html =~ "Update #{first_on_page_1.title["en"]}: Vendor"

      html = confirm!(view)
      refute html =~ "Update #{first_on_page_1.title["en"]}: Vendor"

      assert Shop.get_product!(first_on_page_1.uuid).vendor == "Old Co"
    end

    test "expanding a text-field row reveals the word-level diff; collapsed hides it",
         %{conn: conn} do
      # `:description` (not `:title` — see `@text_fields`'s moduledoc note
      # on why title deliberately doesn't get this treatment) is the
      # text field under test here.
      {:ok, product} =
        Shop.create_product(%{
          "title" => %{"en" => "Widget"},
          "slug" => %{"en" => "widget"},
          "description" => %{"en" => "Old description text"},
          "status" => "draft",
          "price" => "10.00"
        })

      Req.Test.stub(@stub, fn conn ->
        json_response(conn, 200, %{
          "products" => [
            %{
              "handle" => "widget",
              "title" => "Widget",
              "body_html" => "<p>New description text</p>",
              "status" => "draft",
              "variants" => [%{"price" => "10.00"}]
            }
          ]
        })
      end)

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync")
      check_and_await(view)

      html = view |> element("#toggle-section-description") |> render_click()
      refute html =~ "diff-ins"
      refute html =~ "diff-del"
      assert html =~ ~s(id="toggle-diff-description-#{product.uuid}")

      html = view |> element("#toggle-diff-description-#{product.uuid}") |> render_click()
      assert html =~ "diff-ins"
      assert html =~ "diff-del"
    end

    # `body_html`'s section header ("HTML texts") and its row/confirm
    # label used to disagree — the label read "Description (HTML)",
    # easily misread as belonging to the separate `:description` field's
    # own "Descriptions" section right next to it on the page. Pinned so
    # a future edit to one can't silently reintroduce the mismatch.
    test "the body_html section header and its row's confirm text use the same wording",
         %{conn: conn} do
      {:ok, product} =
        Shop.create_product(%{
          "title" => %{"en" => "Widget"},
          "slug" => %{"en" => "widget"},
          "status" => "draft",
          "price" => "10.00"
        })

      Req.Test.stub(@stub, fn conn ->
        json_response(conn, 200, %{
          "products" => [
            %{
              "handle" => "widget",
              "title" => "Widget",
              "body_html" => "<p>New body</p>",
              "status" => "draft",
              "variants" => [%{"price" => "10.00"}]
            }
          ]
        })
      end)

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync")
      html = check_and_await(view)

      assert html =~ ~s(id="field-section-body_html")
      assert html =~ "HTML texts"
      refute html =~ "Description (HTML)"

      view |> element("#toggle-section-body_html") |> render_click()
      view |> element("#apply-row-body_html-#{product.uuid}") |> render_click()
      html = confirm!(view)

      assert html =~ "Updated #{product.title["en"]}&#39;s HTML text."
      refute html =~ "Description (HTML)"
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
      view |> element("#apply-row-title-#{product.uuid}") |> render_click()
      html = confirm!(view)

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

    # `:title` used to be in `@text_fields`, so a title row rendered a
    # word-count summary ("N changed regions (+delta)") and its confirm
    # prompt read "Update X's Title from Shopify?" — an operator could
    # apply a title without ever seeing the incoming value, unless they
    # separately expanded the diff panel. Titles are most of what a real
    # sync's change set is made of, so this is where that mattered most.
    # `:title` now takes the same plain current → incoming treatment as
    # `:vendor`/`:tags`/etc.
    test "a title row shows its incoming value directly, not a word-diff summary",
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
              "variants" => [%{"price" => "10.00"}]
            }
          ]
        })
      end)

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync")
      check_and_await(view)

      html = view |> element("#toggle-section-title") |> render_click()

      assert html =~ "Old Widget"
      assert html =~ "New Widget"
      refute html =~ "changed region"
      refute html =~ ~s(id="toggle-diff-title-#{product.uuid}")

      html = view |> element("#apply-row-title-#{product.uuid}") |> render_click()
      assert html =~ "Update Old Widget: Title → New Widget?"
    end

    # `format_fallback_reason(:missing_credentials)` was believed
    # unreachable in an earlier round of this task and left unpinned —
    # wrongly: `Integrations.has_credentials?/1`'s FIRST clause
    # short-circuits on `status in ["connected", "configured"]` before it
    # ever looks at the token. `record_validation(uuid, :ok)` is what a
    # successful "Test Connection" click does to that status; once set,
    # `maybe_set_status/2` preserves it through later `save_setup/2`
    # calls. So: connect, validate, then the access token gets cleared —
    # token rotation gone wrong — and the SAME (still valid) shop_domain
    # is what `Source.shop_domain/1` re-reads for the fallback, so it
    # succeeds. Reproduced end to end, not just traced.
    test "storefront fallback due to a token cleared after a validated connection shows that specific wording",
         %{conn: conn, uuid: uuid} do
      :ok = Integrations.record_validation(uuid, :ok)
      {:ok, _} = Integrations.save_setup(uuid, %{"access_token" => ""})

      {:ok, _product} =
        Shop.create_product(%{
          "title" => %{"en" => "Widget"},
          "slug" => %{"en" => "widget"},
          "price" => "20.00"
        })

      Req.Test.stub(@stub, fn conn -> json_response(conn, 200, %{"products" => []}) end)

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync")
      html = check_and_await(view)

      assert html =~ ~s(id="storefront-fallback-notice")
      assert html =~ "the connection is missing its access token"
    end

    # A failed write must never disappear — the operator needs to see it
    # and retry, and the page must never claim things are settled while
    # one is still pending. Price is used here (matching
    # `PhoenixKitEcommerce.Shopify.SyncTest`'s own failing-write fixture:
    # a negative incoming price fails `Product`'s
    # `validate_number(:price, greater_than_or_equal_to: 0)`) — its ratio
    # (10.00 vs -5.00 computes to 0.5, well under the 3x extreme
    # threshold) keeps this failure orthogonal to the extreme-price
    # exclusion covered elsewhere in this file.
    test "a failed apply in a bulk scope leaves that row marked, with no false success alert",
         %{conn: conn} do
      {:ok, ok_product} =
        Shop.create_product(%{
          "title" => %{"en" => "OK Product"},
          "slug" => %{"en" => "ok-product"},
          "status" => "draft",
          "price" => "10.00"
        })

      {:ok, failing_product} =
        Shop.create_product(%{
          "title" => %{"en" => "Bad Product"},
          "slug" => %{"en" => "bad-product"},
          "status" => "draft",
          "price" => "10.00"
        })

      Req.Test.stub(@stub, fn conn ->
        json_response(conn, 200, %{
          "products" => [
            %{
              "handle" => "ok-product",
              "title" => "OK Product",
              "status" => "draft",
              "variants" => [%{"price" => "15.00"}]
            },
            %{
              "handle" => "bad-product",
              "title" => "Bad Product",
              "status" => "draft",
              "variants" => [%{"price" => "-5.00"}]
            }
          ]
        })
      end)

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync")
      check_and_await(view)

      view |> element("#toggle-section-price") |> render_click()
      view |> element("#apply-section-price") |> render_click()
      html = confirm!(view)

      assert Decimal.eq?(Shop.get_product!(ok_product.uuid).price, Decimal.new("15.00"))
      assert Decimal.eq?(Shop.get_product!(failing_product.uuid).price, Decimal.new("10.00"))

      refute html =~ "id=\"change-row-price-#{ok_product.uuid}\""
      assert html =~ "id=\"change-row-price-#{failing_product.uuid}\""
      refute html =~ "the shop matches Shopify"
      assert html =~ "Could not update"
    end

    # `data-confirm` (a bare browser `confirm()`) is gone from this page
    # entirely, replaced by `<.confirm_modal>` — pinned for all four apply
    # affordances (row, section, selection, everything): requesting opens
    # the modal with the right prompt and writes nothing; cancelling
    # clears it, still with nothing written. A grep for the literal
    # attribute proves the replacement is total, not just "the tests
    # I happened to update".
    test "every apply affordance opens the confirm modal (never data-confirm) and cancelling writes nothing",
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
      html = check_and_await(view)

      refute html =~ "data-confirm"

      html = view |> element("#apply-everything") |> render_click()
      assert html =~ "Apply pending changes for 1 product across all sections?"
      html = cancel!(view)
      refute html =~ "Apply pending changes for 1 product across all sections?"

      html = view |> element("#toggle-section-title") |> render_click()
      refute html =~ "data-confirm"
      assert html =~ ~s(id="apply-section-title")

      html = view |> element("#apply-section-title") |> render_click()
      assert html =~ "Apply 1 Title change from Shopify?"
      html = cancel!(view)
      refute html =~ "Apply 1 Title change from Shopify?"

      assert html =~ ~s(id="apply-row-title-#{product.uuid}")
      html = view |> element("#apply-row-title-#{product.uuid}") |> render_click()
      assert html =~ "Update #{product.title["en"]}: Title → New Widget?"
      html = cancel!(view)
      refute html =~ "Update #{product.title["en"]}: Title → New Widget?"

      # Nothing above ever confirmed — every one of those requests must
      # have written exactly nothing.
      assert Shop.get_product!(product.uuid).title["en"] == "Old Widget"
      assert Decimal.eq?(Shop.get_product!(product.uuid).price, Decimal.new("10.00"))
      refute_activity_logged("shop.shopify_sync_apply")
      refute_activity_logged("shop.shopify_sync_bulk_field_apply")
      refute_activity_logged("shop.shopify_sync_bulk_apply_all")
    end

    # The two performance contracts pagination exists for (see
    # `TextDiff`'s and `@per_page`'s moduledocs): summaries computed only
    # for the page being shown, and a word-level diff computed only for
    # the row actually expanded. Rendered HTML cannot see either — a
    # section slicing after mapping instead of before still LOOKS
    # identical once truncated to 25, and `words/2` computed regardless
    # of `expanded?` (gated only by the template's `:if`) still LOOKS
    # identical once the template hides it. Held by `TextDiff`'s own
    # telemetry instead (see its moduledoc for why `summary/2`'s internal
    # reuse of the same Myers pass does not also fire the `:words` event).
    test "pagination computes summaries for the current page only, and word-diffs only for the expanded row",
         %{conn: conn} do
      # `:description` (not `:title` — see `@text_fields`'s moduledoc note)
      # is the text field exercised here.
      products =
        for i <- 1..30 do
          {:ok, product} =
            Shop.create_product(%{
              "title" => %{"en" => "Widget #{i}"},
              "slug" => %{"en" => "product-#{i}"},
              "description" => %{"en" => "Old Desc #{i}"},
              "status" => "draft",
              "price" => "10.00"
            })

          product
        end

      shopify_products =
        for i <- 1..30 do
          %{
            "handle" => "product-#{i}",
            "title" => "Widget #{i}",
            "body_html" => "<p>New Desc #{i}</p>",
            "status" => "draft",
            "variants" => [%{"price" => "10.00"}]
          }
        end

      Req.Test.stub(@stub, fn conn ->
        json_response(conn, 200, %{"products" => shopify_products})
      end)

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync")
      check_and_await(view)

      test_pid = self()
      handler_id = "text-diff-calls-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        [
          [:phoenix_kit_ecommerce, :shopify, :text_diff, :summary],
          [:phoenix_kit_ecommerce, :shopify, :text_diff, :words]
        ],
        fn event, _measurements, _metadata, _config ->
          send(test_pid, {:text_diff_call, event})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      view |> element("#toggle-section-description") |> render_click()
      counts_after_section_expand = drain_text_diff_calls()

      assert Map.get(counts_after_section_expand, [
               :phoenix_kit_ecommerce,
               :shopify,
               :text_diff,
               :summary
             ]) == 25

      assert Map.get(
               counts_after_section_expand,
               [:phoenix_kit_ecommerce, :shopify, :text_diff, :words],
               0
             ) == 0

      first = List.first(products)
      view |> element("#toggle-diff-description-#{first.uuid}") |> render_click()
      counts_after_row_expand = drain_text_diff_calls()

      assert Map.get(counts_after_row_expand, [
               :phoenix_kit_ecommerce,
               :shopify,
               :text_diff,
               :words
             ]) == 1
    end

    defp drain_text_diff_calls(acc \\ %{}) do
      receive do
        {:text_diff_call, event} -> drain_text_diff_calls(Map.update(acc, event, 1, &(&1 + 1)))
      after
        200 -> acc
      end
    end

    # The reviewer's own reproduction: a genuinely non-empty first page
    # (so a real price row renders), an empty second page, and a real
    # `page_delay_ms` sleep in between. `render_async(view, 3000)` gives
    # the private-mode stub's ownership enough margin to survive the
    # delayed second request — this is the only end-to-end proof the
    # fallback path renders a *usable* page with a real row, not just an
    # empty-changes state.
    test "storefront fallback with an actual price change renders only the Prices section",
         %{conn: conn} do
      {:ok, product} =
        Shop.create_product(%{
          "title" => %{"en" => "Widget"},
          "slug" => %{"en" => "widget"},
          "price" => "10.00"
        })

      Req.Test.stub(@stub, fn conn ->
        if admin_request?(conn) do
          json_response(conn, 401, %{"errors" => "Invalid API key"})
        else
          case storefront_page(conn) do
            "1" ->
              json_response(conn, 200, %{
                "products" => [%{"handle" => "widget", "variants" => [%{"price" => "15.00"}]}]
              })

            _ ->
              json_response(conn, 200, %{"products" => []})
          end
        end
      end)

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync")
      html = check_and_await(view, 3000)

      assert html =~ ~s(id="field-section-price")
      refute html =~ ~s(id="field-section-title")
      refute html =~ ~s(id="field-section-vendor")
      refute html =~ ~s(id="field-section-status")

      html = view |> element("#toggle-section-price") |> render_click()
      assert html =~ "id=\"change-row-price-#{product.uuid}\""
    end

    defp storefront_page(conn) do
      conn |> Plug.Conn.fetch_query_params() |> Map.fetch!(:query_params) |> Map.get("page")
    end

    # `remove_field_for/3`'s trailing `Enum.reject(&(&1.changes == %{}))`
    # is what drops a change once its last field is applied — without it
    # an emptied change lingers in `@changes` and the "matches Shopify"
    # success state can never be reached again. A single-field product
    # (unlike the other apply tests in this file, which always leave a
    # second field behind) is what actually empties the change and
    # exercises this.
    test "applying the only field a product differs on removes it from the pending list entirely",
         %{conn: conn} do
      {:ok, _product} =
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
              "title" => "Old Widget",
              "vendor" => "New Co",
              "status" => "draft",
              "variants" => [%{"price" => "10.00"}]
            }
          ]
        })
      end)

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync")
      check_and_await(view)

      view |> element("#toggle-section-vendor") |> render_click()
      view |> element("#apply-section-vendor") |> render_click()
      html = confirm!(view)

      assert html =~ "the shop matches Shopify"
    end

    # `current_page/3`'s `min(total_pages(count))` clamp: without it, an
    # operator who pages to the last page and applies its only row is
    # left staring at a section whose badge still reads "(25)" but shows
    # zero rows — `total_pages` recomputes to 1 (hiding the pager
    # entirely, since it only shows for `total_pages > 1`) while the
    # STORED page assign is still 2, so the row slice starts past the
    # end of a now-25-item list.
    test "applying the last row on a trailing page snaps the section back to a page with rows",
         %{conn: conn} do
      products =
        for i <- 1..26 do
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
        for i <- 1..26 do
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

      view |> element("#toggle-section-vendor") |> render_click()
      view |> element("#page-next-vendor") |> render_click()

      last = List.last(products)
      view |> element("#apply-row-vendor-#{last.uuid}") |> render_click()
      html = confirm!(view)

      rows = Regex.scan(~r/id="change-row-vendor-[a-f0-9-]+"/, html) |> length()
      assert rows == 25

      # A single page (25 of 25 remaining) hides the pager entirely by
      # design (`section.total_pages > 1`) — the regression this guards
      # against is a STUCK page 2 with zero rows and no pager to escape
      # via, not a visible "1-25 of 25" — so what matters is that the
      # rows themselves are back, and there's no dangling prev/next.
      refute html =~ ~s(id="page-prev-vendor")
      refute html =~ ~s(id="page-next-vendor")
    end

    # `bump_page/3` must clamp against the CURRENT count, not read the raw
    # stored page: 51 rows (pages of 25/25/1), go to page 3 (its lone
    # row), apply it — 50 remain (pages of 25/25), the DISPLAY clamps
    # back to page 2, but the STORED page assign would stay 3 if it read
    # the raw value. A `Prev` click from there must land on page 1 — if
    # it instead computed "stored 3 minus 1 = 2", the operator (looking
    # at displayed page 2) would see no change at all.
    test "clicking Prev right after applying a trailing page's only row still moves back a page",
         %{conn: conn} do
      products =
        for i <- 1..51 do
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
        for i <- 1..51 do
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

      view |> element("#toggle-section-vendor") |> render_click()
      view |> element("#page-next-vendor") |> render_click()
      view |> element("#page-next-vendor") |> render_click()

      last = List.last(products)
      view |> element("#apply-row-vendor-#{last.uuid}") |> render_click()
      html = confirm!(view)

      assert html =~ "Showing 26 to 50 of 50 results"

      html = view |> element("#page-prev-vendor") |> render_click()
      assert html =~ "Showing 1 to 25 of 50 results"
    end

    # `apply_row`'s `Map.has_key?(&1.changes, field)` guard: without it, a
    # stale event (a slow double-click, or a client whose DOM is one
    # render behind) that names a field the change no longer carries
    # would still find the change BY PRODUCT alone, call
    # `Sync.apply_change/2` (which silently no-ops on a field not present
    # — see `resolve_fields/2`), and log an Activity entry claiming a
    # write that never happened. `assert_activity_logged/2` itself proves
    # this: it flunks if it finds more than one matching row, so a second,
    # bogus entry from the stale event is exactly what it would catch.
    test "a stale request_apply_row event for an already-applied field is a no-op, not a fake activity log",
         %{conn: conn} do
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

      view |> element("#toggle-section-price") |> render_click()
      view |> element("#apply-row-price-#{product.uuid}") |> render_click()
      confirm!(view)

      # The price row (and its button) is gone now — title still differs,
      # so the underlying change is still around. Push the SAME request
      # event directly (bypassing element lookup, which would correctly
      # fail since the button no longer exists) to simulate a stale
      # client, then try to confirm it too — `request_apply_row`'s own
      # `Enum.any?` guard must refuse to open the modal for a field the
      # change no longer carries, so this second confirm has nothing to
      # act on.
      render_click(view, "request_apply_row", %{"field" => "price", "uuid" => product.uuid})
      confirm!(view)

      assert_activity_logged("shop.shopify_sync_apply",
        resource_uuid: product.uuid,
        metadata_has: %{"fields" => ["price"]}
      )
    end

    # The "large change" badge is the only signal, other than the
    # extreme-price bulk exclusion pinned elsewhere in this file, that an
    # operator sees before applying a price swing this large.
    test "an extreme price change is badged 'large change' in its row", %{conn: conn} do
      {:ok, _product} =
        Shop.create_product(%{
          "title" => %{"en" => "Widget"},
          "slug" => %{"en" => "widget"},
          "status" => "draft",
          "price" => "10.00"
        })

      Req.Test.stub(@stub, fn conn ->
        json_response(conn, 200, %{
          "products" => [
            %{
              "handle" => "widget",
              "title" => "Widget",
              "status" => "draft",
              "variants" => [%{"price" => "50.00"}]
            }
          ]
        })
      end)

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync")
      check_and_await(view)

      html = view |> element("#toggle-section-price") |> render_click()

      assert html =~ "large change"
    end

    # The restored guard: a bulk scope must never write an extreme price
    # change (the old page's only bulk action — `price_only_safe?/1` —
    # never could, and this store has had a real price-corruption
    # incident). It stays reachable per-row, where the badge above is
    # visible on that specific product.
    test "section-apply skips an extreme price change, discloses the exclusion, and leaves it applicable per-row",
         %{conn: conn} do
      {:ok, extreme_product} =
        Shop.create_product(%{
          "title" => %{"en" => "Extreme Widget"},
          "slug" => %{"en" => "extreme-widget"},
          "status" => "draft",
          "price" => "10.00"
        })

      {:ok, normal_product} =
        Shop.create_product(%{
          "title" => %{"en" => "Normal Widget"},
          "slug" => %{"en" => "normal-widget"},
          "status" => "draft",
          "price" => "10.00"
        })

      Req.Test.stub(@stub, fn conn ->
        json_response(conn, 200, %{
          "products" => [
            %{
              "handle" => "extreme-widget",
              "title" => "Extreme Widget",
              "status" => "draft",
              "variants" => [%{"price" => "50.00"}]
            },
            %{
              "handle" => "normal-widget",
              "title" => "Normal Widget",
              "status" => "draft",
              "variants" => [%{"price" => "15.00"}]
            }
          ]
        })
      end)

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync")
      check_and_await(view)

      view |> element("#toggle-section-price") |> render_click()

      html = view |> element("#apply-section-price") |> render_click()

      # The base prompt and the exclusion notice are two separate
      # `<.confirm_modal>` messages now (a `{:warning, _}` message,
      # not text glued onto the browser-`confirm()` string the old
      # `data-confirm` carried) — see `exclusion_messages/1`.
      assert html =~ "Apply 1 Price change from Shopify?"
      assert html =~ "1 extreme price change is excluded and must be applied individually."

      html = confirm!(view)

      assert Decimal.eq?(Shop.get_product!(normal_product.uuid).price, Decimal.new("15.00"))
      assert Decimal.eq?(Shop.get_product!(extreme_product.uuid).price, Decimal.new("10.00"))

      refute html =~ "id=\"change-row-price-#{normal_product.uuid}\""
      assert html =~ "id=\"change-row-price-#{extreme_product.uuid}\""
      assert html =~ "large change"

      view |> element("#apply-row-price-#{extreme_product.uuid}") |> render_click()
      html = confirm!(view)
      assert Decimal.eq?(Shop.get_product!(extreme_product.uuid).price, Decimal.new("50.00"))
      refute html =~ "id=\"change-row-price-#{extreme_product.uuid}\""
    end

    # `apply_everything` touches every field on a change through `:all`,
    # so an extreme price component excludes the WHOLE change, not just
    # its price field — a per-field split isn't available through
    # `Sync.apply_changes/2`'s single `:all` sentinel. The excluded
    # product's non-price field stays reachable via its own row.
    test "apply-everything skips a product with an extreme price change entirely",
         %{conn: conn} do
      {:ok, extreme_product} =
        Shop.create_product(%{
          "title" => %{"en" => "Old Extreme Title"},
          "slug" => %{"en" => "extreme-widget"},
          "status" => "draft",
          "price" => "10.00"
        })

      {:ok, normal_product} =
        Shop.create_product(%{
          "title" => %{"en" => "Normal Widget"},
          "slug" => %{"en" => "normal-widget"},
          "status" => "draft",
          "price" => "10.00"
        })

      Req.Test.stub(@stub, fn conn ->
        json_response(conn, 200, %{
          "products" => [
            %{
              "handle" => "extreme-widget",
              "title" => "New Extreme Title",
              "status" => "draft",
              "variants" => [%{"price" => "50.00"}]
            },
            %{
              "handle" => "normal-widget",
              "title" => "Normal Widget",
              "status" => "draft",
              "variants" => [%{"price" => "15.00"}]
            }
          ]
        })
      end)

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync")
      check_and_await(view)

      view |> element("#apply-everything") |> render_click()
      html = confirm!(view)

      assert Decimal.eq?(Shop.get_product!(normal_product.uuid).price, Decimal.new("15.00"))
      assert Decimal.eq?(Shop.get_product!(extreme_product.uuid).price, Decimal.new("10.00"))
      assert Shop.get_product!(extreme_product.uuid).title["en"] == "Old Extreme Title"

      refute html =~ "the shop matches Shopify"
      assert html =~ ~s(id="field-section-price")
      assert html =~ ~s(id="field-section-title")
    end

    # The storefront empty-price-differences message must not claim
    # nothing was found when something WAS found and just got applied.
    test "the storefront empty-price message changes wording after a successful apply",
         %{conn: conn} do
      {:ok, product} =
        Shop.create_product(%{
          "title" => %{"en" => "Widget"},
          "slug" => %{"en" => "widget"},
          "price" => "10.00"
        })

      Req.Test.stub(@stub, fn conn ->
        if admin_request?(conn) do
          json_response(conn, 401, %{"errors" => "Invalid API key"})
        else
          case storefront_page(conn) do
            "1" ->
              json_response(conn, 200, %{
                "products" => [%{"handle" => "widget", "variants" => [%{"price" => "15.00"}]}]
              })

            _ ->
              json_response(conn, 200, %{"products" => []})
          end
        end
      end)

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync")
      check_and_await(view, 3000)

      view |> element("#toggle-section-price") |> render_click()
      view |> element("#apply-row-price-#{product.uuid}") |> render_click()
      html = confirm!(view)

      assert html =~ ~s(id="storefront-no-price-changes")
      assert html =~ "All price changes have been applied."
      refute html =~ "No price differences found"
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

      view |> element("#apply-everything") |> render_click()
      html = confirm!(view)

      assert Shop.get_product!(p1.uuid).title["en"] == "P1 New"
      assert Shop.get_product!(p2.uuid).vendor == "New Co"
      assert html =~ "the shop matches Shopify"

      assert_activity_logged("shop.shopify_sync_bulk_apply_all", metadata_has: %{"count" => 2})
    end

    # "Apply selection" is a bulk scope like "Apply section", but scoped
    # to an explicit, closed uuid set rather than "every row matching this
    # field" — this is the payload shape the `BulkSelectScope` JS hook
    # actually sends (`{uuids: [...]}`, see that hook's own moduledoc):
    # a faithful stand-in for a real checkbox click + "Apply selection"
    # click, since LiveViewTest cannot execute the hook's JS itself.
    test "checkboxes expose each row's uuid for the client-side selection hook, and 'apply selection' writes only the selected uuids' field",
         %{conn: conn} do
      # `selected` differs on TWO fields (price AND vendor), not price
      # alone — `Sync.apply_changes(eligible, [field])` at the call site
      # must write only `field` (:price here) even though the underlying
      # `Change` it's handed carries other differing fields too
      # (`visible_field_changes/3` returns untrimmed `Change` structs —
      # see that function's own doc). A fixture differing on price alone
      # can't tell "wrote only :price" apart from "wrote every field
      # (:all)" — both produce the same observable price update.
      {:ok, selected} =
        Shop.create_product(%{
          "title" => %{"en" => "Selected Widget"},
          "slug" => %{"en" => "selected-widget"},
          "vendor" => "Old Co",
          "status" => "draft",
          "price" => "10.00"
        })

      {:ok, unselected} =
        Shop.create_product(%{
          "title" => %{"en" => "Unselected Widget"},
          "slug" => %{"en" => "unselected-widget"},
          "status" => "draft",
          "price" => "10.00"
        })

      Req.Test.stub(@stub, fn conn ->
        json_response(conn, 200, %{
          "products" => [
            %{
              "handle" => "selected-widget",
              "title" => "Selected Widget",
              "vendor" => "New Co",
              "status" => "draft",
              "variants" => [%{"price" => "15.00"}]
            },
            %{
              "handle" => "unselected-widget",
              "title" => "Unselected Widget",
              "status" => "draft",
              "variants" => [%{"price" => "20.00"}]
            }
          ]
        })
      end)

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync")
      check_and_await(view)

      html = view |> element("#toggle-section-price") |> render_click()

      # Each row's checkbox carries the exact uuid `bulk_select_cell`
      # renders and the hook reads on click — proof the markup would
      # feed the hook the right identity, not just that the handler
      # below does the right thing with a uuid handed to it directly.
      assert html =~ ~s(data-uuid="#{selected.uuid}")
      assert html =~ ~s(data-uuid="#{unselected.uuid}")

      # The hook rewrites this element's textContent from the template
      # client-side (`el.dataset.bulkTextTemplate.replace("%{count}", ...)`
      # — see BulkSelectScope's own JS moduledoc) — if `%{count}` doesn't
      # survive gettext, the selection bar shows a bare word with no
      # number for every locale, silently.
      assert html =~ ~s(data-bulk-text-template="%{count} selected")

      html = render_click(view, "request_apply_selection:price", %{"uuids" => [selected.uuid]})

      assert html =~ "Apply the selected Price change from Shopify?"
      html = confirm!(view)

      assert Decimal.eq?(Shop.get_product!(selected.uuid).price, Decimal.new("15.00"))
      assert Decimal.eq?(Shop.get_product!(unselected.uuid).price, Decimal.new("10.00"))

      # The proof this pins: `selected` also has a pending vendor change
      # (Old Co -> New Co), and applying its PRICE selection must leave
      # that vendor field untouched — a regression that widened
      # `[field]` to `:all` at the call site would write it too.
      assert Shop.get_product!(selected.uuid).vendor == "Old Co"

      refute html =~ "id=\"change-row-price-#{selected.uuid}\""
      assert html =~ "id=\"change-row-price-#{unselected.uuid}\""

      # The vendor change on `selected` survives — its own (unexpanded)
      # section still lists it.
      assert html =~ ~s(id="field-section-vendor")

      assert_activity_logged("shop.shopify_sync_bulk_selection_apply",
        metadata_has: %{"count" => 1, "field" => "price"}
      )
    end

    # The extreme-price guard (`split_bulk_eligible/2`) applies to every
    # bulk scope, selection included — this store has had a real
    # price-corruption incident, and "I checked the boxes" is still a
    # bulk write.
    test "selection excludes an extreme price change, discloses it, and leaves it applicable per-row",
         %{conn: conn} do
      {:ok, extreme_product} =
        Shop.create_product(%{
          "title" => %{"en" => "Extreme Widget"},
          "slug" => %{"en" => "extreme-widget"},
          "status" => "draft",
          "price" => "10.00"
        })

      {:ok, normal_product} =
        Shop.create_product(%{
          "title" => %{"en" => "Normal Widget"},
          "slug" => %{"en" => "normal-widget"},
          "status" => "draft",
          "price" => "10.00"
        })

      Req.Test.stub(@stub, fn conn ->
        json_response(conn, 200, %{
          "products" => [
            %{
              "handle" => "extreme-widget",
              "title" => "Extreme Widget",
              "status" => "draft",
              "variants" => [%{"price" => "50.00"}]
            },
            %{
              "handle" => "normal-widget",
              "title" => "Normal Widget",
              "status" => "draft",
              "variants" => [%{"price" => "15.00"}]
            }
          ]
        })
      end)

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync")
      check_and_await(view)

      view |> element("#toggle-section-price") |> render_click()

      # Both rows "checked" (as a real select-all click would do) — the
      # extreme one must still be excluded from the bulk write.
      html =
        render_click(view, "request_apply_selection:price", %{
          "uuids" => [extreme_product.uuid, normal_product.uuid]
        })

      assert html =~ "Apply the selected Price change from Shopify?"
      assert html =~ "1 extreme price change is excluded and must be applied individually."

      html = confirm!(view)

      assert Decimal.eq?(Shop.get_product!(normal_product.uuid).price, Decimal.new("15.00"))
      assert Decimal.eq?(Shop.get_product!(extreme_product.uuid).price, Decimal.new("10.00"))
      assert html =~ "id=\"change-row-price-#{extreme_product.uuid}\""
    end

    test "a selection request with nothing eligible (all extreme, or nothing checked) opens no modal and writes nothing",
         %{conn: conn} do
      {:ok, extreme_product} =
        Shop.create_product(%{
          "title" => %{"en" => "Extreme Widget"},
          "slug" => %{"en" => "extreme-widget"},
          "status" => "draft",
          "price" => "10.00"
        })

      Req.Test.stub(@stub, fn conn ->
        json_response(conn, 200, %{
          "products" => [
            %{
              "handle" => "extreme-widget",
              "title" => "Extreme Widget",
              "status" => "draft",
              "variants" => [%{"price" => "50.00"}]
            }
          ]
        })
      end)

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync")
      check_and_await(view)

      view |> element("#toggle-section-price") |> render_click()

      html =
        render_click(view, "request_apply_selection:price", %{"uuids" => [extreme_product.uuid]})

      # Substring, not the full singular sentence: `ngettext`'s plural
      # form ("Apply 0 selected Price changes...") still contains
      # "selected Price change" — asserting only the singular string lets
      # a deleted `open_pending([], _)` guard slip through wearing the
      # plural form instead.
      refute html =~ "selected Price change"

      html = render_click(view, "request_apply_selection:price", %{"uuids" => []})
      refute html =~ "selected Price change"

      assert Decimal.eq?(Shop.get_product!(extreme_product.uuid).price, Decimal.new("10.00"))
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

  describe "no data-confirm anywhere in the page" do
    # The runtime assertions above prove `data-confirm` is gone from every
    # rendered state this suite exercises; this is the static counterpart
    # — a source grep, so the guarantee holds even for a render state no
    # test happens to reach, and a regression (someone adding a NEW apply
    # affordance with a bare `data-confirm` instead of the request/confirm
    # flow) fails here without needing its own scenario test first. Checks
    # for the ATTRIBUTE form (`data-confirm=`), not the bare word — the
    # moduledoc and code comments above legitimately mention `data-confirm`
    # in prose explaining what this file replaced it with.
    test "the LiveView source carries no data-confirm attribute" do
      source =
        [__DIR__, "..", "..", "..", "lib", "phoenix_kit_ecommerce", "web", "shopify_sync.ex"]
        |> Path.join()
        |> Path.expand()
        |> File.read!()

      refute source =~ "data-confirm="
    end
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
        base_locale: "en",
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

  describe "visible_changes/2 — apply_everything's :all must not reach a hidden field" do
    alias PhoenixKitEcommerce.Shopify.ProductDiff.Change
    alias PhoenixKitEcommerce.Web.ShopifySync

    defp price_title_vendor_change do
      %Change{
        product_uuid: Ecto.UUID.generate(),
        handle: "widget",
        title: "Widget",
        base_locale: "en",
        changes: %{
          price: %{current: Decimal.new("10.00"), incoming: Decimal.new("12.00")},
          title: %{current: "Old", incoming: "New"},
          vendor: %{current: "Old Co", incoming: "New Co"}
        }
      }
    end

    # The actual defect this pins: `confirm_everything_apply` hands the
    # result straight to `Sync.apply_changes(eligible, :all)`, and `:all`
    # writes every key in `change.changes` — so returning a change with
    # its ORIGINAL, untrimmed field map (merely having survived a
    # changes-level filter) would let :all write :title and :vendor on a
    # :storefront source, even though visible_sections/2 hides both.
    # Filtering which CHANGES survive is not the same guarantee as
    # trimming what EACH surviving change still carries — an earlier
    # version of this function only did the former and passed all 634
    # tests anyway, because no real check → render flow can produce a
    # :storefront change with a second field to catch it with.
    test "trims a change down to only the fields visible for :storefront, not just filters which changes survive" do
      assert [trimmed] = ShopifySync.visible_changes([price_title_vendor_change()], :storefront)
      assert Map.keys(trimmed.changes) == [:price]
    end

    test "keeps every field for the :admin source" do
      assert [kept] = ShopifySync.visible_changes([price_title_vendor_change()], :admin)
      assert Map.keys(kept.changes) |> Enum.sort() == [:price, :title, :vendor]
    end

    test "a change left with no visible fields at all is dropped entirely" do
      price_only =
        %Change{
          product_uuid: Ecto.UUID.generate(),
          handle: "widget2",
          title: "Widget 2",
          base_locale: "en",
          changes: %{vendor: %{current: "Old Co", incoming: "New Co"}}
        }

      assert ShopifySync.visible_changes([price_only], :storefront) == []
    end
  end

  describe "visible_field_changes/3 — the same honesty guarantee, scoped to one bulk write" do
    alias PhoenixKitEcommerce.Shopify.ProductDiff.Change
    alias PhoenixKitEcommerce.Web.ShopifySync

    # Same structural impossibility as `visible_sections/2` above: a real
    # storefront result can never carry a non-price field, so only a
    # direct call with synthetic data can prove "Apply section"/"Apply
    # selection" would refuse to write a field the page is hiding.
    defp price_and_vendor_change do
      %Change{
        product_uuid: Ecto.UUID.generate(),
        handle: "widget",
        title: "Widget",
        base_locale: "en",
        changes: %{
          price: %{current: Decimal.new("10.00"), incoming: Decimal.new("12.00")},
          vendor: %{current: "Old Co", incoming: "New Co"}
        }
      }
    end

    test "a hidden field (storefront source) returns no rows to write" do
      assert ShopifySync.visible_field_changes([price_and_vendor_change()], :storefront, :vendor) ==
               []
    end

    test "a visible field (storefront source, :price) returns the row" do
      assert [%Change{}] =
               ShopifySync.visible_field_changes([price_and_vendor_change()], :storefront, :price)
    end

    test "every field is visible for the :admin source" do
      assert [%Change{}] =
               ShopifySync.visible_field_changes([price_and_vendor_change()], :admin, :vendor)
    end
  end

  describe "coverage_percent/2" do
    alias PhoenixKitEcommerce.Web.ShopifySync

    test "clamps to 100 even if matched somehow exceeds the Shopify total" do
      assert ShopifySync.coverage_percent(5, 1) == 100
    end

    test "is 0, not a crash, when the Shopify total is 0" do
      assert ShopifySync.coverage_percent(5, 0) == 0
    end

    test "matched over shopify, not the other way around" do
      assert ShopifySync.coverage_percent(1, 4) == 25
      refute ShopifySync.coverage_percent(1, 4) == ShopifySync.coverage_percent(4, 1)
    end
  end
end
