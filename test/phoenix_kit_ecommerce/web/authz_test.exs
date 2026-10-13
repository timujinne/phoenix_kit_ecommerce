defmodule PhoenixKitEcommerce.Web.AuthzTest do
  @moduledoc """
  Sub-permission enforcement in the bundled admin LiveViews.

  Until now the harness could not express a denied scope at all: every
  fixture handed out `["shop"]` with `roles: ["Owner"]`, so an authorization
  regression could not fail a test. These drive the real LiveViews with
  narrowed scopes and assert the mutation does NOT happen.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Web.Authz

  defp scope_with(permissions) do
    fake_scope(roles: ["Employee"], permissions: permissions)
  end

  defp product_fixture do
    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Authz Widget #{System.unique_integer([:positive])}"},
        "price" => Decimal.new("10.00"),
        "status" => "active"
      })

    product
  end

  defp category_fixture do
    {:ok, category} =
      Shop.create_category(%{
        "name" => %{"en" => "Authz Cat #{System.unique_integer([:positive])}"},
        "status" => "active"
      })

    category
  end

  describe "Authz.can?/2" do
    test "fails closed on a missing scope" do
      refute Authz.can?(%{assigns: %{}}, :manage_catalog)
      refute Authz.can?(%{assigns: %{phoenix_kit_current_scope: nil}}, :manage_catalog)
    end

    test "honours the specific capability, not the base key" do
      base_only = %{assigns: %{phoenix_kit_current_scope: scope_with(["shop"])}}

      catalog = %{
        assigns: %{phoenix_kit_current_scope: scope_with(["shop", "shop.manage_catalog"])}
      }

      refute Authz.can?(base_only, :manage_catalog)
      assert Authz.can?(catalog, :manage_catalog)
      # A capability the scope does not hold stays denied even for a holder
      # of a sibling one.
      refute Authz.can?(catalog, :manage_settings)
    end
  end

  describe "denied mutations do not happen" do
    @tag :integration
    test "a scope without manage_catalog cannot delete a product", %{conn: conn} do
      product = product_fixture()
      conn = put_test_scope(conn, scope_with(["shop"]))

      {:ok, view, _html} = live(conn, "/en/admin/shop/products")

      html =
        view
        |> render_hook("delete_product", %{"uuid" => product.uuid})

      assert html =~ "permission"
      # The product is still there.
      assert Shop.get_product(product.uuid)
    end

    @tag :integration
    test "a scope without manage_catalog cannot delete a category", %{conn: conn} do
      category = category_fixture()
      conn = put_test_scope(conn, scope_with(["shop"]))

      {:ok, view, _html} = live(conn, "/en/admin/shop/categories")

      view |> render_hook("delete", %{"uuid" => category.uuid})

      assert Shop.get_category(category.uuid)
    end

    @tag :integration
    test "manage_catalog does not unlock the settings page's mutations", %{conn: conn} do
      PhoenixKit.Settings.update_setting("shop_allow_raw_html_descriptions", "false")

      conn = put_test_scope(conn, scope_with(["shop", "shop.manage_catalog"]))

      {:ok, view, _html} = live(conn, "/en/admin/shop/settings")

      view |> render_hook("toggle_allow_raw_html", %{})

      # The security policy is unchanged.
      refute PhoenixKitEcommerce.Policy.allow_raw_html_descriptions?()
    end
  end

  describe "stock tracking switch" do
    alias PhoenixKitEcommerce.Test.FakeWarehouse

    setup do
      on_exit(fn ->
        PhoenixKit.Settings.update_boolean_setting_with_module(
          "shop_stock_tracking_enabled",
          false,
          "shop"
        )

        FakeWarehouse.reset()
      end)

      # Warehouse is ready, so the only thing that can refuse the toggle is
      # the permission check.
      FakeWarehouse.put_state(enabled: true, default_location: "loc-1")
    end

    @tag :integration
    test "manage_catalog does not unlock turning stock tracking on", %{conn: conn} do
      conn = put_test_scope(conn, scope_with(["shop", "shop.manage_catalog"]))

      {:ok, view, _html} = live(conn, "/en/admin/shop/settings")

      html = render_hook(view, "toggle_shop_stock_tracking", %{})

      assert html =~ "permission"
      refute PhoenixKitEcommerce.StockTracking.setting_enabled?()
      refute_activity_logged("shop.stock_tracking_changed")
    end
  end

  describe "granted mutations still work" do
    @tag :integration
    test "manage_catalog can delete a product", %{conn: conn} do
      product = product_fixture()
      conn = put_test_scope(conn, scope_with(["shop", "shop.manage_catalog"]))

      {:ok, view, _html} = live(conn, "/en/admin/shop/products")

      view |> render_hook("delete_product", %{"uuid" => product.uuid})

      refute Shop.get_product(product.uuid)
    end
  end

  describe "every import-starting event is gated" do
    test "no import-starting handler reaches the worker without run_imports" do
      # skip_mapping was a verbatim un-gated duplicate of confirm_import:
      # both call run_import_with_mappings/2, but only one was wrapped, so
      # the "Skip Mapping" button started a full import for a holder of
      # base "shop" alone. Pin the whole family, not just the one that got
      # missed.
      source = File.read!("lib/phoenix_kit_ecommerce/web/imports.ex")

      starters = ~w(start_import confirm_import skip_mapping run_import retry_import
                    start_image_migration cancel_image_migration delete_import)

      for event <- starters do
        assert source =~
                 ~s|def handle_event("#{event}", params, socket) do\n    Authz.authorize(socket, :run_imports|,
               "#{event} does not go through the run_imports gate"
      end
    end
  end

  describe "privileged pages guard their content" do
    @tag :integration
    test "the carts page is not readable without manage_carts", %{conn: conn} do
      conn = put_test_scope(conn, scope_with(["shop", "shop.manage_catalog"]))

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, "/en/admin/shop/carts")
      assert to =~ "/admin/shop"
    end

    @tag :integration
    test "a denied carts request does not run the customer query at all", %{conn: conn} do
      # push_navigate from mount does NOT halt the lifecycle - handle_params
      # still runs for the request, and the cart query preloads :user (i.e.
      # customer emails). The guard must be in handle_params too, not just
      # mount.
      conn = put_test_scope(conn, scope_with(["shop", "shop.manage_catalog"]))

      # The redirect is the visible outcome; the point of the test is that
      # getting here no longer executes an unauthorized PII read, which the
      # source-level guard below pins.
      assert {:error, {:live_redirect, _}} = live(conn, "/en/admin/shop/carts")

      source = File.read!("lib/phoenix_kit_ecommerce/web/carts.ex")
      assert source =~ "if Authz.can?(socket, :manage_carts) do"
    end

    @tag :integration
    test "the carts page opens with manage_carts", %{conn: conn} do
      conn = put_test_scope(conn, scope_with(["shop", "shop.manage_carts"]))

      assert {:ok, _view, html} = live(conn, "/en/admin/shop/carts")
      assert html =~ "Carts" or html =~ "carts"
    end
  end
end
