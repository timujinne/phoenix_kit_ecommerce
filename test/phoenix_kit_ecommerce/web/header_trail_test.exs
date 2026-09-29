defmodule PhoenixKitEcommerce.Web.HeaderTrailTest do
  @moduledoc """
  Every admin page says where it is through the four header assigns core's
  admin layout reads (`page_section`, `page_section_path`, `page_crumbs`,
  `page_title`): the landing page is the module's title with no section,
  every page below it carries `E-Commerce` as the section, the list a record
  sits under as a crumb, and itself alone as the title.

  The test router renders a bare layout, so the trail is read off the
  socket rather than the HTML.
  """

  use PhoenixKitEcommerce.LiveCase

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitEcommerce, as: Shop

  setup %{conn: conn} do
    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  defp trail(conn, path) do
    {:ok, view, _html} = live(conn, path)
    assigns = :sys.get_state(view.pid).socket.assigns

    %{
      section: assigns[:page_section],
      section_path: assigns[:page_section_path],
      crumbs: Enum.map(assigns[:page_crumbs] || [], &{&1.label, &1[:path]}),
      title: assigns[:page_title]
    }
  end

  defp shop_path, do: Routes.path("/admin/shop")

  test "the landing page is the module with no section", %{conn: conn} do
    assert %{section: nil, crumbs: [], title: "E-Commerce"} = trail(conn, "/en/admin/shop")
  end

  test "list pages carry the module as their section", %{conn: conn} do
    shop = shop_path()

    for {path, title} <- [
          {"/en/admin/shop/products", "Products"},
          {"/en/admin/shop/categories", "Categories"},
          {"/en/admin/shop/shipping", "Shipping"},
          {"/en/admin/shop/carts", "Carts"},
          {"/en/admin/shop/imports", "CSV Import"},
          {"/en/admin/shop/settings", "Settings"}
        ] do
      assert %{section: "E-Commerce", section_path: ^shop, crumbs: [], title: ^title} =
               trail(conn, path),
             "#{path} should be E-Commerce / #{title}"
    end
  end

  test "a product's detail page sits under Products and its edit page under the product",
       %{conn: conn} do
    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Trail Widget"},
        "price" => Decimal.new("12.00"),
        "status" => "active"
      })

    products = Routes.path("/admin/shop/products")
    detail = Routes.path("/admin/shop/products/#{product.uuid}")

    assert %{section: "E-Commerce", crumbs: [{"Products", ^products}], title: "Trail Widget"} =
             trail(conn, "/en/admin/shop/products/#{product.uuid}")

    assert %{
             section: "E-Commerce",
             crumbs: [{"Products", ^products}, {"Trail Widget", ^detail}],
             title: "Edit"
           } = trail(conn, "/en/admin/shop/products/#{product.uuid}/edit")

    assert %{crumbs: [{"Products", ^products}], title: "New product"} =
             trail(conn, "/en/admin/shop/products/new")
  end

  test "a record whose list is its only page is a text crumb on its edit page", %{conn: conn} do
    {:ok, category} = Shop.create_category(%{"name" => %{"en" => "Trail Shelf"}})

    {:ok, method} =
      Shop.create_shipping_method(%{"name" => "Trail Courier", "price" => Decimal.new("9.00")})

    categories = Routes.path("/admin/shop/categories")
    shipping = Routes.path("/admin/shop/shipping")

    assert %{crumbs: [{"Categories", ^categories}, {"Trail Shelf", nil}], title: "Edit"} =
             trail(conn, "/en/admin/shop/categories/#{category.uuid}/edit")

    assert %{crumbs: [{"Categories", ^categories}], title: "New category"} =
             trail(conn, "/en/admin/shop/categories/new")

    assert %{crumbs: [{"Shipping", ^shipping}, {"Trail Courier", nil}], title: "Edit"} =
             trail(conn, "/en/admin/shop/shipping/#{method.uuid}/edit")

    assert %{crumbs: [{"Shipping", ^shipping}], title: "New shipping method"} =
             trail(conn, "/en/admin/shop/shipping/new")
  end

  test "the settings sub-pages sit under Settings", %{conn: conn} do
    settings = Routes.path("/admin/shop/settings")

    assert %{section: "E-Commerce", crumbs: [{"Settings", ^settings}], title: "Options"} =
             trail(conn, "/en/admin/shop/settings/options")

    assert %{section: "E-Commerce", crumbs: [{"Settings", ^settings}], title: "Import configs"} =
             trail(conn, "/en/admin/shop/settings/import-configs")
  end

  test "an import is titled by its file name under CSV Import", %{conn: conn} do
    {:ok, log} = Shop.create_import_log(%{filename: "trail.csv"})
    imports = Routes.path("/admin/shop/imports")

    assert %{section: "E-Commerce", crumbs: [{"CSV Import", ^imports}], title: "trail.csv"} =
             trail(conn, "/en/admin/shop/imports/#{log.uuid}")
  end
end
