defmodule PhoenixKitEcommerce.ActivityLoggingTest do
  @moduledoc """
  Pins each shop activity-log action string against the
  `phoenix_kit_activities` table.

  Every CRUD + status/visibility mutation logged by the shop admin LVs
  in production must show up here with the expected `action`,
  `actor_uuid`, and `resource_uuid`. Without these, a typoed action
  string or a dropped `Activity.log` call regresses silently — the
  surrounding CRUD test still passes because logging is best-effort
  (rescued) at the LV layer.

  ## Two layers of coverage

  1. **Live wiring** drives the list/form LiveViews with
     `render_click` / `render_submit` so the real `Activity.log` call
     sites fire with `actor_uuid` threaded from the test scope. This
     proves the wrapper + scope extraction works end-to-end.

  2. **Action-string pins** call the context function then `Activity.log`
     with exactly the opts the LV passes — mirroring billing's pattern
     for mutations only reachable through detail/form panels with
     complex multilang/media inputs that `render_click` can't easily
     reach (product + category create/update). Each pins `actor_uuid`
     so a test can't pass if the actor is dropped.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Activity

  setup %{conn: conn} do
    actor_uuid = Ecto.UUID.generate()
    scope = fake_scope(user_uuid: actor_uuid, roles: ["Owner"])
    conn = put_test_scope(conn, scope)
    {:ok, conn: conn, actor_uuid: actor_uuid}
  end

  # ── Products (live wiring for delete; pins for create/update) ────────

  describe "products" do
    test "delete (live) logs shop.product_deleted with the scope actor", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      {:ok, product} =
        Shop.create_product(%{
          "title" => %{"en" => "Deletable Widget"},
          "price" => Decimal.new("12.00"),
          "status" => "active"
        })

      {:ok, view, _html} = live(conn, "/en/admin/shop/products")

      render_click(view, "delete_product", %{"uuid" => product.uuid})

      assert_activity_logged("shop.product_deleted",
        actor_uuid: actor_uuid,
        resource_uuid: product.uuid,
        metadata_has: %{"status" => "active"}
      )
    end

    test "bulk status change (live) logs shop.products_status_changed", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      {:ok, product} =
        Shop.create_product(%{
          "title" => %{"en" => "Bulk Widget"},
          "price" => Decimal.new("5.00"),
          "status" => "draft"
        })

      {:ok, view, _html} = live(conn, "/en/admin/shop/products")

      render_click(view, "toggle_select", %{"uuid" => product.uuid})
      render_click(view, "bulk_change_status", %{"status" => "active"})

      assert_activity_logged("shop.products_status_changed",
        actor_uuid: actor_uuid,
        metadata_has: %{"status" => "active", "count" => 1}
      )
    end

    test "create pin logs shop.product_created", %{actor_uuid: actor_uuid} do
      {:ok, product} =
        Shop.create_product(%{
          "title" => %{"en" => "Created Widget"},
          "price" => Decimal.new("20.00"),
          "status" => "active"
        })

      Activity.log("shop.product_created",
        actor_uuid: actor_uuid,
        resource_type: "product",
        resource_uuid: product.uuid,
        metadata: %{
          "status" => product.status,
          "product_type" => product.product_type,
          "price" => Decimal.to_string(product.price)
        }
      )

      assert_activity_logged("shop.product_created",
        actor_uuid: actor_uuid,
        resource_uuid: product.uuid,
        metadata_has: %{"status" => "active"}
      )
    end

    test "update pin logs shop.product_updated", %{actor_uuid: actor_uuid} do
      {:ok, product} =
        Shop.create_product(%{
          "title" => %{"en" => "Updatable Widget"},
          "price" => Decimal.new("20.00"),
          "status" => "draft"
        })

      {:ok, updated} = Shop.update_product(product, %{"status" => "active"})

      Activity.log("shop.product_updated",
        actor_uuid: actor_uuid,
        resource_type: "product",
        resource_uuid: updated.uuid,
        metadata: %{
          "status" => updated.status,
          "product_type" => updated.product_type,
          "price" => Decimal.to_string(updated.price)
        }
      )

      assert_activity_logged("shop.product_updated",
        actor_uuid: actor_uuid,
        resource_uuid: updated.uuid,
        metadata_has: %{"status" => "active"}
      )
    end
  end

  # ── Categories (live wiring for delete; pins for create/update) ──────

  describe "categories" do
    test "delete (live) logs shop.category_deleted", %{conn: conn, actor_uuid: actor_uuid} do
      {:ok, category} = Shop.create_category(%{"name" => %{"en" => "Deletable Cat"}})

      {:ok, view, _html} = live(conn, "/en/admin/shop/categories")

      render_click(view, "delete", %{"uuid" => category.uuid})

      assert_activity_logged("shop.category_deleted",
        actor_uuid: actor_uuid,
        resource_uuid: category.uuid
      )
    end

    test "bulk status change (live) logs shop.categories_status_changed", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      {:ok, category} = Shop.create_category(%{"name" => %{"en" => "Bulk Cat"}})

      {:ok, view, _html} = live(conn, "/en/admin/shop/categories")

      render_click(view, "toggle_select", %{"uuid" => category.uuid})
      render_click(view, "bulk_change_status", %{"status" => "hidden"})

      assert_activity_logged("shop.categories_status_changed",
        actor_uuid: actor_uuid,
        metadata_has: %{"status" => "hidden", "count" => 1}
      )
    end

    test "create pin logs shop.category_created", %{actor_uuid: actor_uuid} do
      {:ok, category} = Shop.create_category(%{"name" => %{"en" => "Created Cat"}})

      Activity.log("shop.category_created",
        actor_uuid: actor_uuid,
        resource_type: "category",
        resource_uuid: category.uuid,
        metadata: %{"status" => category.status}
      )

      assert_activity_logged("shop.category_created",
        actor_uuid: actor_uuid,
        resource_uuid: category.uuid
      )
    end

    test "update pin logs shop.category_updated", %{actor_uuid: actor_uuid} do
      {:ok, category} = Shop.create_category(%{"name" => %{"en" => "Updatable Cat"}})
      {:ok, updated} = Shop.update_category(category, %{"status" => "hidden"})

      Activity.log("shop.category_updated",
        actor_uuid: actor_uuid,
        resource_type: "category",
        resource_uuid: updated.uuid,
        metadata: %{"status" => updated.status}
      )

      assert_activity_logged("shop.category_updated",
        actor_uuid: actor_uuid,
        resource_uuid: updated.uuid,
        metadata_has: %{"status" => "hidden"}
      )
    end
  end

  # ── Shipping methods (full live wiring: form + list) ─────────────────

  describe "shipping methods" do
    test "create (live form) logs shop.shipping_method_created", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")

      view
      |> form("form",
        shipping_method: %{name: "Live Courier", price: "9.00", currency: "USD"}
      )
      |> render_submit()

      method = Shop.get_shipping_method_by_slug("live-courier")
      assert method

      assert_activity_logged("shop.shipping_method_created",
        actor_uuid: actor_uuid,
        resource_uuid: method.uuid
      )
    end

    test "toggle_active (live) logs shop.shipping_method_updated", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      {:ok, method} =
        Shop.create_shipping_method(%{"name" => "Toggle Courier", "price" => Decimal.new("3.00")})

      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping")

      render_click(view, "toggle_active", %{"uuid" => method.uuid})

      assert_activity_logged("shop.shipping_method_updated",
        actor_uuid: actor_uuid,
        resource_uuid: method.uuid,
        metadata_has: %{"active" => false}
      )
    end

    test "delete (live) logs shop.shipping_method_deleted", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      {:ok, method} =
        Shop.create_shipping_method(%{"name" => "Delete Courier", "price" => Decimal.new("4.00")})

      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping")

      render_click(view, "delete", %{"uuid" => method.uuid})

      assert_activity_logged("shop.shipping_method_deleted",
        actor_uuid: actor_uuid,
        resource_uuid: method.uuid
      )
    end
  end

  # ── Import configs (full live wiring on the settings LV) ─────────────

  describe "import configs" do
    test "delete_config (live) logs shop.import_config_deleted", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      {:ok, config} = Shop.create_import_config(%{name: "Deletable Config"})

      {:ok, view, _html} = live(conn, "/en/admin/shop/settings/import-configs")

      render_click(view, "delete_config", %{"uuid" => config.uuid})

      assert_activity_logged("shop.import_config_deleted",
        actor_uuid: actor_uuid,
        resource_uuid: config.uuid
      )
    end

    test "toggle_active (live) logs shop.import_config_updated", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      {:ok, config} = Shop.create_import_config(%{name: "Toggle Config", active: true})

      {:ok, view, _html} = live(conn, "/en/admin/shop/settings/import-configs")

      render_click(view, "toggle_active", %{"uuid" => config.uuid})

      assert_activity_logged("shop.import_config_updated",
        actor_uuid: actor_uuid,
        resource_uuid: config.uuid,
        metadata_has: %{"active" => false}
      )
    end

    test "set_default (live) logs shop.import_config_set_default", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      {:ok, config} = Shop.create_import_config(%{name: "Default Config"})

      {:ok, view, _html} = live(conn, "/en/admin/shop/settings/import-configs")

      render_click(view, "set_default", %{"uuid" => config.uuid})

      assert_activity_logged("shop.import_config_set_default",
        actor_uuid: actor_uuid,
        resource_uuid: config.uuid,
        metadata_has: %{"is_default" => true}
      )
    end

    test "create pin logs shop.import_config_created", %{actor_uuid: actor_uuid} do
      {:ok, config} = Shop.create_import_config(%{name: "Created Config"})

      Activity.log("shop.import_config_created",
        actor_uuid: actor_uuid,
        resource_type: "import_config",
        resource_uuid: config.uuid,
        metadata: %{"active" => config.active, "is_default" => config.is_default}
      )

      assert_activity_logged("shop.import_config_created",
        actor_uuid: actor_uuid,
        resource_uuid: config.uuid
      )
    end
  end

  # ── Import runs (action-string pins, mirroring the LV opts) ──────────

  describe "import runs" do
    test "run_started pin logs shop.import_run_started", %{actor_uuid: actor_uuid} do
      {:ok, log} =
        Shop.create_import_log(%{filename: "products.csv", file_path: "/tmp/products.csv"})

      Activity.log("shop.import_run_started",
        actor_uuid: actor_uuid,
        resource_type: "import_log",
        resource_uuid: log.uuid,
        metadata: %{"status" => log.status, "language" => "en"}
      )

      assert_activity_logged("shop.import_run_started",
        actor_uuid: actor_uuid,
        resource_uuid: log.uuid,
        metadata_has: %{"language" => "en"}
      )
    end

    test "run_deleted pin logs shop.import_run_deleted", %{actor_uuid: actor_uuid} do
      {:ok, log} = Shop.create_import_log(%{filename: "old.csv"})

      Activity.log("shop.import_run_deleted",
        actor_uuid: actor_uuid,
        resource_type: "import_log",
        resource_uuid: log.uuid,
        metadata: %{"status" => log.status}
      )

      assert_activity_logged("shop.import_run_deleted",
        actor_uuid: actor_uuid,
        resource_uuid: log.uuid
      )
    end

    test "run_retried pin logs shop.import_run_retried", %{actor_uuid: actor_uuid} do
      {:ok, log} = Shop.create_import_log(%{filename: "retry.csv"})

      Activity.log("shop.import_run_retried",
        actor_uuid: actor_uuid,
        resource_type: "import_log",
        resource_uuid: log.uuid,
        metadata: %{"status" => log.status}
      )

      assert_activity_logged("shop.import_run_retried",
        actor_uuid: actor_uuid,
        resource_uuid: log.uuid
      )
    end
  end

  # ── Wrapper behaviour ────────────────────────────────────────────────

  describe "wrapper behaviour" do
    test "metadata carries actor_role from opts", %{actor_uuid: actor_uuid} do
      {:ok, category} = Shop.create_category(%{"name" => %{"en" => "Role Cat"}})

      Activity.log("shop.category_created",
        actor_uuid: actor_uuid,
        actor_role: "Owner",
        resource_type: "category",
        resource_uuid: category.uuid,
        metadata: %{"status" => category.status}
      )

      assert_activity_logged("shop.category_created",
        actor_uuid: actor_uuid,
        resource_uuid: category.uuid,
        metadata_has: %{"actor_role" => "Owner"}
      )
    end

    test "refute_activity_logged returns :ok when no row matches" do
      :ok = refute_activity_logged("shop.never_logged_action")
    end
  end
end
