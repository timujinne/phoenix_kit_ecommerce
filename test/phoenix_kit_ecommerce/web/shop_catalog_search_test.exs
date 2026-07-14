defmodule PhoenixKitEcommerce.Web.ShopCatalogSearchTest do
  @moduledoc """
  Storefront search flow on the public catalog LiveView: the sidebar
  search form patches the URL with the search param and narrows the
  product grid; ?search= in the URL filters the initial mount too.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitEcommerce, as: Shop

  defp create_product!(title, extra \\ %{}) do
    {:ok, product} =
      Shop.create_product(
        Map.merge(
          %{
            "title" => %{"en" => title},
            "price" => Decimal.new("10.00"),
            "status" => "active"
          },
          extra
        )
      )

    product
  end

  describe "public catalog search" do
    test "search form submit patches the URL and narrows the grid", %{conn: conn} do
      create_product!("Skeleton Wall Mask")
      create_product!("Plain Flower Pot")

      {:ok, view, html} = live(conn, "/shop")
      assert html =~ "Skeleton Wall Mask"
      assert html =~ "Plain Flower Pot"

      html =
        view
        |> element(~s{form[phx-submit="filter_search"]})
        |> render_submit(%{"filter_key" => "search", "search" => "skeleton"})

      assert_patch(view)
      assert html =~ "Skeleton Wall Mask"
      refute html =~ "Plain Flower Pot"
    end

    test "?search= URL param filters the initial mount", %{conn: conn} do
      create_product!("Skeleton Wall Mask")
      create_product!("Plain Flower Pot")

      {:ok, _view, html} = live(conn, "/shop?search=skeleton")
      assert html =~ "Skeleton Wall Mask"
      refute html =~ "Plain Flower Pot"
    end

    test "search by sku finds the product", %{conn: conn} do
      create_product!("Skeleton Wall Mask", %{"metadata" => %{"sku" => "MASK-042"}})
      create_product!("Plain Flower Pot")

      {:ok, _view, html} = live(conn, "/shop?search=MASK-042")
      assert html =~ "Skeleton Wall Mask"
      refute html =~ "Plain Flower Pot"
    end

    test "clearing the search restores the full grid", %{conn: conn} do
      create_product!("Skeleton Wall Mask")
      create_product!("Plain Flower Pot")

      {:ok, view, _html} = live(conn, "/shop?search=skeleton")

      html =
        view
        |> element(~s{form[phx-submit="filter_search"]})
        |> render_submit(%{"filter_key" => "search", "search" => ""})

      assert_patch(view)
      assert html =~ "Skeleton Wall Mask"
      assert html =~ "Plain Flower Pot"
    end
  end
end
