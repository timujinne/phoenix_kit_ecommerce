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

  Every test drives the LiveView that owns the mutation — the real form
  submit or the real event — so the row is written by the production
  `Activity.log` call with `actor_uuid` threaded from the test scope. A test
  that logs the row itself would stay green with the call site removed.
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

  # ── Products ─────────────────────────────────────────────────────────

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

      render_click(view, "open_status_modal", %{"uuids" => [product.uuid]})
      render_click(view, "bulk_change_status", %{"status" => "active"})

      assert_activity_logged("shop.products_status_changed",
        actor_uuid: actor_uuid,
        metadata_has: %{"status" => "active", "count" => 1}
      )
    end

    test "create (live form) logs shop.product_created", %{conn: conn, actor_uuid: actor_uuid} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/products/new")

      view
      |> form(~s(form.space-y-6), %{
        "product" => %{"title" => "Created Widget", "price" => "20.00", "status" => "active"}
      })
      |> render_submit()

      assert [product] = Shop.list_products(search: "Created Widget")

      assert_activity_logged("shop.product_created",
        actor_uuid: actor_uuid,
        resource_uuid: product.uuid,
        metadata_has: %{"status" => "active"}
      )
    end

    test "update (live form) logs shop.product_updated", %{conn: conn, actor_uuid: actor_uuid} do
      {:ok, product} =
        Shop.create_product(%{
          "title" => %{"en" => "Updatable Widget"},
          "price" => Decimal.new("20.00"),
          "status" => "draft"
        })

      {:ok, view, _html} = live(conn, "/en/admin/shop/products/#{product.uuid}/edit")

      view
      |> form(~s(form.space-y-6), %{"product" => %{"status" => "active"}})
      |> render_submit()

      assert Shop.get_product!(product.uuid).status == "active"

      assert_activity_logged("shop.product_updated",
        actor_uuid: actor_uuid,
        resource_uuid: product.uuid,
        metadata_has: %{"status" => "active"}
      )
    end
  end

  # ── Categories ───────────────────────────────────────────────────────

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

      render_click(view, "open_status_modal", %{"uuids" => [category.uuid]})
      render_click(view, "bulk_change_status", %{"status" => "hidden"})

      assert_activity_logged("shop.categories_status_changed",
        actor_uuid: actor_uuid,
        metadata_has: %{"status" => "hidden", "count" => 1}
      )
    end

    test "create (live form) logs shop.category_created", %{conn: conn, actor_uuid: actor_uuid} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/categories/new")

      view
      |> form(~s(form.space-y-6), %{"category" => %{"name" => "Created Cat"}})
      |> render_submit()

      assert [category] = Shop.list_categories(search: "Created Cat")

      assert_activity_logged("shop.category_created",
        actor_uuid: actor_uuid,
        resource_uuid: category.uuid
      )
    end

    test "update (live form) logs shop.category_updated", %{conn: conn, actor_uuid: actor_uuid} do
      {:ok, category} = Shop.create_category(%{"name" => %{"en" => "Updatable Cat"}})

      {:ok, view, _html} = live(conn, "/en/admin/shop/categories/#{category.uuid}/edit")

      view
      |> form(~s(form.space-y-6), %{"category" => %{"status" => "hidden"}})
      |> render_submit()

      assert Shop.get_category!(category.uuid).status == "hidden"

      assert_activity_logged("shop.category_updated",
        actor_uuid: actor_uuid,
        resource_uuid: category.uuid,
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

    test "save_config (live form) logs shop.import_config_created", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      {:ok, view, _html} = live(conn, "/en/admin/shop/settings/import-configs")

      view |> element(~s(button[phx-click="show_add_modal"])) |> render_click()

      view
      |> form(~s(form[phx-submit="save_config"]), %{"config" => %{"name" => "Created Config"}})
      |> render_submit()

      assert config = Shop.get_import_config_by_name("Created Config")

      assert_activity_logged("shop.import_config_created",
        actor_uuid: actor_uuid,
        resource_uuid: config.uuid
      )
    end
  end

  # ── Import runs ──────────────────────────────────────────────────────

  describe "import runs" do
    test "starting a run (live) logs shop.import_run_started", %{conn: conn} do
      # The import log row references its user, so the actor must exist.
      actor_uuid = PhoenixKitEcommerce.DataCase.fixture_user().uuid
      conn = put_test_scope(conn, fake_scope(user_uuid: actor_uuid))

      {:ok, view, _html} = live(conn, "/en/admin/shop/imports")

      name = "audit-#{System.unique_integer([:positive])}.csv"
      csv = "Handle,Title,Variant Price\nwand,Wand,10.00\n"

      view
      |> file_input("#csv-upload-form", :csv_file, [%{name: name, content: csv, type: "text/csv"}])
      |> render_upload(name)

      view |> form("#csv-upload-form") |> render_submit()
      view |> element(~s([phx-click="run_import"])) |> render_click()

      assert [log] = Enum.filter(Shop.list_import_logs(limit: 20), &(&1.filename == name))
      on_exit(fn -> File.rm(log.file_path) end)

      assert_activity_logged("shop.import_run_started",
        actor_uuid: actor_uuid,
        resource_uuid: log.uuid,
        metadata_has: %{"status" => "pending"}
      )
    end

    test "delete_import (live) logs shop.import_run_deleted", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      {:ok, log} = Shop.create_import_log(%{filename: "old.csv"})

      {:ok, view, _html} = live(conn, "/en/admin/shop/imports")

      render_click(view, "delete_import", %{"id" => log.uuid})

      refute Shop.get_import_log(log.uuid)

      assert_activity_logged("shop.import_run_deleted",
        actor_uuid: actor_uuid,
        resource_uuid: log.uuid
      )
    end

    test "retry_import (live) logs shop.import_run_retried", %{
      conn: conn,
      actor_uuid: actor_uuid
    } do
      path = Path.join(System.tmp_dir!(), "retry-#{System.unique_integer([:positive])}.csv")
      File.write!(path, "Handle,Title,Variant Price\nwand,Wand,10.00\n")
      on_exit(fn -> File.rm(path) end)

      {:ok, log} = Shop.create_import_log(%{filename: "retry.csv", file_path: path})
      {:ok, log} = Shop.update_import_log(log, %{status: "failed"})

      {:ok, view, _html} = live(conn, "/en/admin/shop/imports")

      render_click(view, "retry_import", %{"id" => log.uuid})

      assert Shop.get_import_log(log.uuid).status == "pending"

      assert_activity_logged("shop.import_run_retried",
        actor_uuid: actor_uuid,
        resource_uuid: log.uuid,
        metadata_has: %{"status" => "pending"}
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

  describe "the wrapper" do
    test "log_failed records the attempt as pending, naming only the failing fields", %{
      actor_uuid: actor_uuid
    } do
      changeset =
        {%{}, %{email: :string}}
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.add_error(:email, "jane@example.com is taken")

      Activity.log_failed("shop.probe_failed", changeset,
        actor_uuid: actor_uuid,
        actor_role: "Owner",
        metadata: %{"status" => "active"}
      )

      row =
        assert_activity_logged("shop.probe_failed",
          actor_uuid: actor_uuid,
          metadata_has: %{
            "db_pending" => true,
            "failure_reason" => "email",
            "actor_role" => "Owner",
            "status" => "active"
          }
        )

      refute inspect(row.metadata) =~ "jane@example.com"
    end

    test "the actor and the role are read from the scope" do
      scope = fake_scope(roles: ["Admin", "Owner"])

      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, phoenix_kit_current_scope: scope}
      }

      assert Activity.actor_uuid(socket) == scope.user.uuid
      assert Activity.actor_role(socket) == "Admin"
    end
  end
end
