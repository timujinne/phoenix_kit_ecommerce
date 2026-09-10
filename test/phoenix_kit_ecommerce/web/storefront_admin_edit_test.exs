defmodule PhoenixKitEcommerce.Web.StorefrontAdminEditTest do
  @moduledoc """
  The storefront's shop index, category and product pages each show an
  "Edit" link into the matching admin page — but only for a visitor who
  can manage the catalog. `Web.Helpers.maybe_assign_admin_edit/3` checks
  `shop.manage_catalog` and then delegates to core's
  `PhoenixKitWeb.AdminEditHelper.assign_admin_edit/3`, which gates on
  admin-area access as well; these drive the three real LiveViews
  end-to-end (anonymous, admin-without-the-permission, admin) to prove the
  assign — and the render guard around it — actually withhold/show the
  link, not just that the helper function is correct in isolation.

  The link's target follows the product source: with the catalogue source
  on it opens the catalogue editor, since that is where the page's data
  now lives, and it carries `return_to` so the editor's exit lands back on
  the storefront page the visitor came from.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.ShopConfig
  alias PhoenixKitEcommerce.Test.Repo
  alias PhoenixKitEcommerce.Web.Helpers

  defp admin_edit_href(view) do
    view
    |> render()
    |> then(&Regex.run(~r/href="([^"]*(?:products|items|categories)\/[^"]*edit[^"]*)"/, &1))
    |> case do
      [_, href] -> href
      _ -> flunk("no admin edit link rendered")
    end
  end

  defp set_product_source(value) do
    case Repo.get(ShopConfig, "shop_product_source") do
      nil ->
        %ShopConfig{}
        |> ShopConfig.changeset(%{key: "shop_product_source", value: %{"value" => value}})
        |> Repo.insert!()

      config ->
        config
        |> ShopConfig.changeset(%{value: %{"value" => value}})
        |> Repo.update!()
    end
  end

  defp create_category_with_dialect_slug!(name) do
    {:ok, category} = Shop.create_category(%{"name" => %{"en" => name}})

    {:ok, category} =
      Shop.update_category(category, %{
        "name" => Map.put(category.name, "en-US", name),
        "slug" => Map.put(category.slug, "en-US", category.slug["en"])
      })

    category
  end

  defp lang do
    PhoenixKitEcommerce.SlugResolver.normalize_language_public(
      PhoenixKitEcommerce.Translations.default_language()
    )
  end

  describe "shop index (/shop)" do
    test "anonymous visitor gets no admin edit assign or link", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/shop")

      refute html =~ "admin_edit_url"
      refute html =~ "Manage Shop"
    end

    test "admin visitor sees a Manage Shop link to /admin/shop", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())

      {:ok, view, html} = live(conn, "/shop")

      assert html =~ "Manage Shop"
      assert view |> element(~s{a[href="/en/admin/shop"]}) |> has_element?()
    end

    test "an admin with base shop but not manage_catalog still gets it", %{conn: conn} do
      # `/admin/shop` is the shop dashboard, which asks for base `"shop"`.
      # The catalog gate belongs on the links that open a catalog editor;
      # applied here it would hide a link to a page this visitor can open
      # by typing the URL — the link and its target must not disagree.
      conn = put_test_scope(conn, fake_scope(permissions: ["shop"]))

      {:ok, view, html} = live(conn, "/shop")

      assert html =~ "Manage Shop"
      assert view |> element(~s{a[href="/en/admin/shop"]}) |> has_element?()
    end
  end

  describe "category page (/shop/category/:slug)" do
    setup do
      category = create_category_with_dialect_slug!("Ergonomic Mask")
      %{category: category, path: "/shop/category/#{category.slug["en-US"]}"}
    end

    test "anonymous visitor gets no admin edit assign or link", %{conn: conn, path: path} do
      {:ok, _view, html} = live(conn, path)

      refute html =~ "Edit Category"
    end

    test "an admin without shop.manage_catalog is shown no link", %{conn: conn, path: path} do
      # The product page has the same test. This one exists because the
      # gate is per call site now, so "the product page is covered" stops
      # being an argument about the category page.
      conn = put_test_scope(conn, fake_scope(permissions: ["shop"]))

      {:ok, _view, html} = live(conn, path)

      refute html =~ "Edit Category"
    end

    test "admin visitor sees an Edit Category link to the matching admin page", %{
      conn: conn,
      path: path,
      category: category
    } do
      conn = put_test_scope(conn, fake_scope())

      {:ok, view, html} = live(conn, path)

      assert html =~ "Edit Category"

      href = admin_edit_href(view)

      assert href =~ "/admin/shop/categories/#{category.uuid}/edit"
      assert href =~ "return_to="
      assert URI.decode(href) =~ "/shop/category/"
    end

    # Requires `PhoenixKitCatalogue.Paths` to be loaded:
    # `Helpers.admin_edit_path/3` falls back to the legacy path whenever
    # `Code.ensure_loaded?(PhoenixKitCatalogue.Paths)` is false, which it
    # always is on a checkout without the optional `phoenix_kit_catalogue`
    # dependency declared — same exclusion every other `:catalogue` test
    # in this fork relies on.
    @tag :catalogue
    test "with the catalogue source on, the link opens the catalogue category editor", %{
      category: category
    } do
      set_product_source("catalogue")
      on_exit(fn -> set_product_source("legacy") end)

      href = Helpers.admin_edit_path(:category, category.uuid, "/en/shop/category/x")

      assert href =~ "/admin/catalogue/categories/#{category.uuid}/edit"
      assert href =~ "return_to=%2Fen%2Fshop%2Fcategory%2Fx"
    end
  end

  describe "product page (/shop/product/:slug)" do
    setup do
      {:ok, product} =
        Shop.create_product(%{
          "title" => %{"en" => "Ergonomic Flower Pot"},
          "slug" => %{lang() => "ergonomic-flower-pot-#{System.unique_integer([:positive])}"},
          "price" => Decimal.new("10.00"),
          "status" => "active"
        })

      %{product: product, path: "/shop/product/#{product.slug[lang()]}"}
    end

    test "anonymous visitor gets no admin edit assign or link", %{conn: conn, path: path} do
      {:ok, _view, html} = live(conn, path)

      refute html =~ "Edit Product"
    end

    test "admin visitor sees an Edit Product link to the matching admin page", %{
      conn: conn,
      path: path,
      product: product
    } do
      conn = put_test_scope(conn, fake_scope())

      {:ok, view, html} = live(conn, path)

      assert html =~ "Edit Product"

      href = admin_edit_href(view)

      assert href =~ "/admin/shop/products/#{product.uuid}/edit"
      assert href =~ "return_to=", "the editor must know where to send the visitor back to"
      assert URI.decode(href) =~ "/shop/product/"
    end

    test "an admin without shop.manage_catalog is shown no link", %{conn: conn, path: path} do
      conn = put_test_scope(conn, fake_scope(permissions: ["shop"]))

      {:ok, _view, html} = live(conn, path)

      refute html =~ "Edit Product"
    end

    # See the tag note on the matching category-page test above.
    @tag :catalogue
    test "with the catalogue source on, the link opens the catalogue item editor", %{
      product: product
    } do
      # Driven through the helper rather than the page: an item created in
      # the legacy tables is not visible at all once the catalogue source
      # is on, so a LiveView mount would fail before reaching the link.
      set_product_source("catalogue")
      on_exit(fn -> set_product_source("legacy") end)

      href = Helpers.admin_edit_path(:item, product.uuid, "/en/shop/product/x")

      assert href =~ "/admin/catalogue/items/#{product.uuid}/edit"
      assert href =~ "return_to=%2Fen%2Fshop%2Fproduct%2Fx"
    end

    test "admin Edit survives shop_show_cart_bar being off", %{
      conn: conn,
      path: path,
      product: product
    } do
      PhoenixKit.Settings.update_setting("shop_show_cart_bar", "false")
      PhoenixKit.Cache.invalidate(:settings, "shop_show_cart_bar")

      on_exit(fn ->
        PhoenixKit.Settings.update_setting("shop_show_cart_bar", "true")
        PhoenixKit.Cache.invalidate(:settings, "shop_show_cart_bar")
      end)

      conn = put_test_scope(conn, fake_scope())
      {:ok, view, html} = live(conn, path)

      assert html =~ "Edit Product"
      refute html =~ ">Cart<"

      href = admin_edit_href(view)

      assert href =~ "/admin/shop/products/#{product.uuid}/edit"
      assert href =~ "return_to=", "the editor must know where to send the visitor back to"
    end
  end

  describe "admin list and detail pages" do
    # See the tag note on "with the catalogue source on..." above.
    @tag :catalogue
    test "the products list edits in the catalogue and returns to the list", %{conn: conn} do
      # Created first: with the catalogue source on, the legacy writer
      # refuses, and this fixture only needs a uuid to build a path from.
      {:ok, product} =
        Shop.create_product(%{
          "title" => %{"en" => "Admin Listed"},
          "slug" => %{"en" => "admin-listed-#{System.unique_integer([:positive])}"},
          "price" => Decimal.new("10.00"),
          "status" => "active"
        })

      set_product_source("catalogue")
      on_exit(fn -> set_product_source("legacy") end)

      href = Helpers.admin_edit_path(:item, product.uuid, "/en/admin/shop/products?page=2")

      # The admin's own list is the place to come back to, not the
      # catalogue's — an operator working through a shop list should not
      # be dropped into a different one after saving.
      assert href =~ "/admin/catalogue/items/#{product.uuid}/edit"
      assert href =~ "return_to=%2Fen%2Fadmin%2Fshop%2Fproducts%3Fpage%3D2"
    end

    @tag :catalogue
    test "the categories list edits the catalogue category", %{conn: _conn} do
      {:ok, category} = Shop.create_category(%{"name" => %{"en" => "Admin Cat"}})

      set_product_source("catalogue")
      on_exit(fn -> set_product_source("legacy") end)

      href = Helpers.admin_edit_path(:category, category.uuid, "/en/admin/shop/categories")

      assert href =~ "/admin/catalogue/categories/#{category.uuid}/edit"
      assert href =~ "return_to=%2Fen%2Fadmin%2Fshop%2Fcategories"
    end
  end
end
