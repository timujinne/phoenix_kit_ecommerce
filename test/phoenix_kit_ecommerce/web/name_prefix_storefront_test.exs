defmodule PhoenixKitEcommerce.Web.NamePrefixStorefrontTest do
  @moduledoc """
  `shop_name_prefixes` end-to-end through the storefront chokepoint
  (`Translations.get_display/3`): every public shop page a shopper can
  reach must show the stripped name once the setting names a prefix, and
  every admin page must keep showing the raw stored name regardless — an
  operator editing a category has to see what is actually stored, or an
  edit that "doesn't match the storefront" becomes unexplainable.

  Covers the chokepoint's real callers: `ShopCatalog` (catalog root
  category grid + product cards via `ShopCards`), `CatalogCategory`
  (heading/page_title + breadcrumbs + sidebar), `CatalogProduct`
  (title + category breadcrumb chip). Admin coverage: `Categories`,
  `CategoryForm`, `Products`, `ProductForm`, `ProductDetail`.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.NamePrefix

  defp lang do
    PhoenixKitEcommerce.SlugResolver.normalize_language_public(
      PhoenixKitEcommerce.Translations.default_language()
    )
  end

  defp set_prefix(value), do: Settings.update_setting(NamePrefix.setting_key(), value)

  defp unique(base), do: "#{base}-#{System.unique_integer([:positive])}"

  defp create_category!(name, attrs \\ %{}) do
    {:ok, category} =
      Shop.create_category(
        Map.merge(
          %{"name" => %{"en" => name, lang() => name}, "slug" => %{lang() => unique("cat")}},
          attrs
        )
      )

    category
  end

  defp create_product!(name, category_uuid) do
    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => name, lang() => name},
        "slug" => %{lang() => unique("prod")},
        "price" => Decimal.new("10.00"),
        "status" => "active",
        "category_uuid" => category_uuid
      })

    product
  end

  describe "storefront: prefix configured" do
    setup do
      set_prefix("3D Printed")
      :ok
    end

    test "category page: heading/page_title and breadcrumbs show the stripped name, parent included",
         %{conn: conn} do
      parent = create_category!("3D Printed Home Decor")
      child = create_category!("3D Printed Costume Masks", %{"parent_uuid" => parent.uuid})
      _product = create_product!("3D Printed Skeleton Mask", child.uuid)

      {:ok, _view, html} = live(conn, "/shop/category/#{child.slug[lang()]}")

      assert html =~ "Costume Masks"
      assert html =~ "Home Decor"
      refute html =~ "3D Printed"
    end

    test "product page: title and category breadcrumb chip show the stripped name", %{
      conn: conn
    } do
      category = create_category!("3D Printed Wall Art")
      product = create_product!("3D Printed Coral Wall Planter Shelf", category.uuid)

      {:ok, _view, html} = live(conn, "/shop/product/#{product.slug[lang()]}")

      assert html =~ "Coral Wall Planter Shelf"
      assert html =~ "Wall Art"
      refute html =~ "3D Printed"
    end

    test "shop root: category grid and product cards show the stripped name", %{conn: conn} do
      category = create_category!("3D Printed Dollhouse Miniatures")
      _product = create_product!("3D Printed Tiny Armchair", category.uuid)

      {:ok, _view, html} = live(conn, "/shop")

      assert html =~ "Dollhouse Miniatures"
      assert html =~ "Tiny Armchair"
      refute html =~ "3D Printed"
    end
  end

  describe "storefront: default (empty) setting changes nothing" do
    test "category and product pages render the name exactly as stored", %{conn: conn} do
      category = create_category!("3D Printed Costume Masks")
      product = create_product!("3D Printed Skeleton Mask", category.uuid)

      {:ok, _view, cat_html} = live(conn, "/shop/category/#{category.slug[lang()]}")
      assert cat_html =~ "3D Printed Costume Masks"

      {:ok, _view, prod_html} = live(conn, "/shop/product/#{product.slug[lang()]}")
      assert prod_html =~ "3D Printed Skeleton Mask"
    end
  end

  describe "admin surfaces always show the raw name, even with the prefix configured" do
    setup %{conn: conn} do
      set_prefix("3D Printed")
      {:ok, conn: put_test_scope(conn, fake_scope())}
    end

    test "Categories (index) and CategoryForm (edit)", %{conn: conn} do
      category = create_category!("3D Printed Costume Masks")

      {:ok, _view, index_html} = live(conn, "/en/admin/shop/categories")
      assert index_html =~ "3D Printed Costume Masks"

      {:ok, _view, edit_html} = live(conn, "/en/admin/shop/categories/#{category.uuid}/edit")
      assert edit_html =~ "3D Printed Costume Masks"
    end

    test "Products (index), ProductForm (edit) and ProductDetail", %{conn: conn} do
      category = create_category!("3D Printed Wall Art")
      product = create_product!("3D Printed Coral Wall Planter Shelf", category.uuid)

      {:ok, _view, index_html} = live(conn, "/en/admin/shop/products")
      assert index_html =~ "3D Printed Coral Wall Planter Shelf"

      {:ok, _view, edit_html} = live(conn, "/en/admin/shop/products/#{product.uuid}/edit")
      assert edit_html =~ "3D Printed Coral Wall Planter Shelf"

      {:ok, _view, detail_html} = live(conn, "/en/admin/shop/products/#{product.uuid}")
      assert detail_html =~ "3D Printed Coral Wall Planter Shelf"
    end
  end
end
