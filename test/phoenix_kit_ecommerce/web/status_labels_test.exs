defmodule PhoenixKitEcommerce.Web.StatusLabelsTest do
  @moduledoc """
  A status is stored as its raw value and rendered as a translated label:
  the customer's order pages and the admin lists show "Pending", never
  `pending`, and the label follows the page's locale.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Web.StatusLabels

  # A status rendered raw sits alone between two tags.
  defp raw?(html, value), do: html =~ ~r/>\s*#{value}\s*</

  describe "customer order pages" do
    setup %{conn: conn} do
      PhoenixKit.Settings.update_boolean_setting_with_module("billing_enabled", true, "billing")

      session_id = "status-#{System.unique_integer([:positive])}"
      {:ok, cart} = Shop.create_cart(session_id: session_id)

      {:ok, cart} =
        Shop.add_to_cart(
          cart,
          product!("active", %{"product_type" => "digital", "requires_shipping" => false}),
          1
        )

      {:ok, order} =
        Shop.convert_cart_to_order(cart, billing_data: complete_billing("EE", "status"))

      assert order.status == "pending"

      %{conn: conn, order: order, session_id: session_id}
    end

    test "the order details page labels the status", %{conn: conn, order: order} do
      conn = put_test_scope(conn, fake_scope(user_uuid: order.user_uuid))
      {:ok, view, _html} = live(conn, "/dashboard/orders/#{order.uuid}")

      for id <- ["#order-status-badge", "#order-summary-status"] do
        badge = view |> element(id) |> render()
        assert badge =~ "Pending"
        refute raw?(badge, "pending")
        # the colour is still keyed on the stored value
        assert badge =~ "badge-warning"
      end
    end

    test "the order list labels the status", %{conn: conn, order: order} do
      conn = put_test_scope(conn, fake_scope(user_uuid: order.user_uuid))
      {:ok, view, _html} = live(conn, "/dashboard/orders")

      badge = view |> element("#order-status-#{order.uuid}") |> render()
      assert badge =~ "Pending"
      refute raw?(badge, "pending")
      assert badge =~ "badge-warning"
    end

    test "the confirmation page labels the status", ctx do
      %{conn: conn, order: order, session_id: session_id} = ctx

      conn =
        Plug.Test.init_test_session(conn, %{
          "shop_session_id" => session_id,
          "shop_session_trusted" => true
        })

      {:ok, view, _html} = live(conn, "/checkout/complete/#{order.uuid}")

      badge = view |> element("#order-status-badge") |> render()
      assert badge =~ "Pending"
      refute raw?(badge, "pending")
    end

    test "the label follows the page locale", %{conn: conn, order: order} do
      conn =
        conn
        |> put_test_scope(fake_scope(user_uuid: order.user_uuid))
        |> Plug.Test.init_test_session(%{"phoenix_kit_test_locale" => "ru"})

      {:ok, view, _html} = live(conn, "/dashboard/orders/#{order.uuid}")

      badge = view |> element("#order-status-badge") |> render()
      assert badge =~ "Ожидает"
      refute badge =~ "Pending"
    end
  end

  describe "admin lists" do
    setup %{conn: conn} do
      %{conn: put_test_scope(conn, fake_scope())}
    end

    test "the products list and its bulk flash label the status", %{conn: conn} do
      product = product!("draft")

      {:ok, view, html} = live(conn, "/en/admin/shop/products")
      assert raw?(html, "Draft")
      refute raw?(html, "draft")

      render_hook(view, "open_status_modal", %{"uuids" => [product.uuid]})
      html = render_click(view, "bulk_change_status", %{"status" => "archived"})

      assert html =~ "1 products updated to Archived"
      assert raw?(html, "Archived")
      refute raw?(html, "archived")
    end

    test "the product page labels the status", %{conn: conn} do
      product = product!("archived")

      {:ok, _view, html} = live(conn, "/en/admin/shop/products/#{product.uuid}")
      assert raw?(html, "Archived")
      refute raw?(html, "archived")
    end

    test "the categories list and its bulk flash label the status", %{conn: conn} do
      {:ok, category} =
        Shop.create_category(%{"name" => %{"en" => "Status Category"}, "status" => "unlisted"})

      {:ok, view, html} = live(conn, "/en/admin/shop/categories")
      assert raw?(html, "Unlisted")
      refute raw?(html, "unlisted")

      render_hook(view, "open_status_modal", %{"uuids" => [category.uuid]})
      html = render_click(view, "bulk_change_status", %{"status" => "hidden"})

      assert html =~ "1 categories updated to Hidden"
      refute raw?(html, "hidden")
    end

    test "the carts list labels the status", %{conn: conn} do
      {:ok, cart} = Shop.create_cart(session_id: "status-cart-#{System.unique_integer()}")
      {:ok, _cart} = Shop.add_to_cart(cart, product!("active"), 1)

      {:ok, _view, html} = live(conn, "/en/admin/shop/carts")
      assert html =~ ~r/badge badge-success[^>]*>\s*Active\s*</
      refute raw?(html, "active")
    end

    test "the import pages label the status", %{conn: conn} do
      {:ok, log} = Shop.create_import_log(%{filename: "status.csv"})
      assert log.status == "pending"

      {:ok, _view, html} = live(conn, "/en/admin/shop/imports/#{log.uuid}")
      assert raw?(html, "Pending")
      refute raw?(html, "pending")

      {:ok, _view, html} = live(conn, "/en/admin/shop/imports")
      assert raw?(html, "Pending")
      refute raw?(html, "pending")
    end
  end

  describe "labels" do
    test "every status a schema allows has its own clause" do
      families = [
        {&StatusLabels.product/1, ~w(draft active archived)},
        {&StatusLabels.category/1, Shop.Category.statuses()},
        {&StatusLabels.cart/1, Shop.Cart.statuses()},
        {&StatusLabels.import/1, ~w(pending processing completed failed)},
        {&StatusLabels.order/1, ~w(draft pending confirmed paid cancelled refunded)},
        {&StatusLabels.translation_entry/1, PhoenixKitAI.Request.valid_statuses()}
      ]

      Gettext.put_locale(PhoenixKitEcommerce.Gettext, "ru")

      for {label, statuses} <- families, status <- statuses do
        translated = label.(status)

        assert translated != String.capitalize(status),
               "#{status} fell through to the untranslated fallback"

        assert translated =~ ~r/\p{Cyrillic}/u
      end
    end

    test "an unknown value is humanized and a non-string renders empty" do
      assert StatusLabels.order("on_hold") == "On hold"
      assert StatusLabels.cart(nil) == ""
      assert StatusLabels.category(nil) == "Active"
    end
  end

  defp product!(status, extra \\ %{}) do
    {:ok, product} =
      Shop.create_product(
        Map.merge(
          %{
            "title" => %{"en" => "Status Widget #{System.unique_integer([:positive])}"},
            "price" => Decimal.new("12.00"),
            "currency" => "USD",
            "status" => status
          },
          extra
        )
      )

    product
  end
end
