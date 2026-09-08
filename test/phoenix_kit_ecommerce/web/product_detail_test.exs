defmodule PhoenixKitEcommerce.Web.ProductDetailTest do
  @moduledoc """
  Covers the admin product detail page's rendering of `body_html`
  through the shared `<.markdown>` component: Shopify-synced Markdown
  formats, legacy raw-HTML descriptions still render, and the default
  sanitize policy keeps a `<script>` out of the output. Round 2 review
  found no LiveView-level test for this page existed — only the
  Shopify-sync page's field labels were covered.
  """

  use PhoenixKitEcommerce.LiveCase

  alias PhoenixKitEcommerce, as: Shop

  setup %{conn: conn} do
    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  defp create_product(body_html) do
    Shop.create_product(%{
      "title" => %{"en" => "Widget"},
      "slug" => %{"en" => "widget"},
      "status" => "draft",
      "price" => "10.00",
      "body_html" => %{"en" => body_html}
    })
  end

  test "Shopify-synced Markdown body_html renders as formatted HTML", %{conn: conn} do
    {:ok, product} = create_product("**bold** intro\n\n- item")

    {:ok, _view, html} = live(conn, "/en/admin/shop/products/#{product.uuid}")

    assert html =~ "<strong>bold</strong>"
    assert html =~ "<li>item</li>"
  end

  test "legacy raw-HTML body_html still renders through the same component", %{conn: conn} do
    {:ok, product} = create_product("<p>Hello <em>there</em></p>")

    {:ok, _view, html} = live(conn, "/en/admin/shop/products/#{product.uuid}")

    assert html =~ "<em>there</em>"
  end

  test "a <script> in body_html does not reach the output under the default sanitize policy",
       %{conn: conn} do
    {:ok, product} = create_product("<p>Safe</p><script>alert(1)</script>")

    {:ok, _view, html} = live(conn, "/en/admin/shop/products/#{product.uuid}")

    assert html =~ "Safe"
    refute html =~ "<script"
    refute html =~ "alert(1)"
  end
end
