defmodule PhoenixKitEcommerce.Web.CatalogCategorySearchTest do
  @moduledoc """
  Storefront search on the public category page: zero-result states must
  tell the customer their filters matched nothing (with a clear-filters
  affordance), not pretend the category is empty.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitEcommerce, as: Shop

  setup do
    %{category: category} = create_category_with_dialect_slug!("Masks")

    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Skeleton Wall Mask"},
        "price" => Decimal.new("10.00"),
        "status" => "active",
        "category_uuid" => category.uuid
      })

    %{category: category, product: product, path: "/shop/category/#{category.slug["en-US"]}"}
  end

  # The public category route resolves slugs under the normalized dialect
  # code ("en" -> "en-US"), so the fixture must carry the slug under the
  # dialect key the router will actually query.
  defp create_category_with_dialect_slug!(name) do
    {:ok, category} = Shop.create_category(%{"name" => %{"en" => name}})

    {:ok, category} =
      Shop.update_category(category, %{
        "name" => Map.put(category.name, "en-US", name),
        "slug" => Map.put(category.slug, "en-US", category.slug["en"])
      })

    %{category: category}
  end

  describe "category page search" do
    test "search narrows the category grid", %{conn: conn, path: path} do
      {:ok, _view, html} = live(conn, path <> "?search=skeleton")
      assert html =~ "Skeleton Wall Mask"
    end

    test "zero-result search shows a filters-aware empty state", %{conn: conn, path: path} do
      {:ok, _view, html} = live(conn, path <> "?search=no-such-thing")

      assert html =~ "No products match your filters"
      assert html =~ "Clear filters"
      refute html =~ "No products in this category"
    end

    test "a genuinely empty category keeps the original empty state", %{conn: conn} do
      %{category: empty_cat} = create_category_with_dialect_slug!("Empty Shelf")

      {:ok, _view, html} = live(conn, "/shop/category/#{empty_cat.slug["en-US"]}")

      assert html =~ "No products in this category"
    end
  end
end
