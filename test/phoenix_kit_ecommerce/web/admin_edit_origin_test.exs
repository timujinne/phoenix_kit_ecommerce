defmodule PhoenixKitEcommerce.Web.AdminEditOriginTest do
  @moduledoc """
  The admin "Edit" link opens the editor of WHERE THE RECORD COMES FROM, not
  of whichever product source the store happens to have switched on: a
  catalogue item opens `phoenix_kit_catalogue`'s editor, a legacy shop
  product opens the shop's own form. With the global switch deciding, a
  store that holds both — legacy rows an import left behind next to
  catalogue items, or a source flipped after products existed — sent the
  operator to an editor that has no such record.

  The catalogue half needs `phoenix_kit_catalogue` loaded and is tagged
  `:catalogue`; `async: false` because it flips the process-wide
  `shop_product_source` config key.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  @compile {:no_warn_undefined, [PhoenixKitCatalogue.Paths, PhoenixKitCatalogue.Catalogue]}

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Category
  alias PhoenixKitEcommerce.Product
  alias PhoenixKitEcommerce.ShopConfig
  alias PhoenixKitEcommerce.Test.Repo
  alias PhoenixKitEcommerce.Web.Helpers

  defp set_product_source(value) do
    case Repo.get(ShopConfig, "shop_product_source") do
      nil ->
        %ShopConfig{}
        |> ShopConfig.changeset(%{key: "shop_product_source", value: %{"value" => value}})
        |> Repo.insert!()

      config ->
        config |> ShopConfig.changeset(%{value: %{"value" => value}}) |> Repo.update!()
    end

    on_exit(fn -> set_product_source_quietly("legacy") end)
  end

  defp set_product_source_quietly(value) do
    Repo.get(ShopConfig, "shop_product_source")
    |> ShopConfig.changeset(%{value: %{"value" => value}})
    |> Repo.update!()
  end

  defp legacy_product! do
    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Origin Probe"},
        "slug" => %{"en" => "origin-probe-#{System.unique_integer([:positive])}"},
        "price" => Decimal.new("10.00"),
        "status" => "active"
      })

    product
  end

  defp legacy_category! do
    {:ok, category} = Shop.create_category(%{"name" => %{"en" => "Origin Cat"}})
    category
  end

  # `Scope.can?/2` also asks whether the key's module is switched on, so a
  # test that hands out the `"catalogue"` permission has to register the
  # catalogue module and enable it, as a host does.
  defp enable_catalogue_module do
    registered? = PhoenixKitCatalogue in PhoenixKit.ModuleRegistry.all_modules()
    :ok = PhoenixKit.ModuleRegistry.register(PhoenixKitCatalogue)
    PhoenixKit.Settings.update_setting("catalogue_enabled", "true")
    PhoenixKit.Settings.update_setting("entities_enabled", "true")

    on_exit(fn ->
      unless registered?, do: PhoenixKit.ModuleRegistry.unregister(PhoenixKitCatalogue)
    end)
  end

  defp catalogue_product, do: %Product{uuid: Ecto.UUID.generate(), origin: :catalogue}
  defp catalogue_category, do: %Category{uuid: Ecto.UUID.generate(), origin: :catalogue}

  describe "admin_edit_path/3 — legacy records" do
    test "a legacy product opens the shop form, keeping return_to" do
      product = legacy_product!()

      href = Helpers.admin_edit_path(:item, product, "/en/admin/shop/products?page=2")

      assert URI.parse(href).path == Routes.path("/admin/shop/products/#{product.uuid}/edit")
      assert href =~ "return_to=%2Fen%2Fadmin%2Fshop%2Fproducts%3Fpage%3D2"
    end

    test "a legacy category opens the shop category form" do
      category = legacy_category!()

      href = Helpers.admin_edit_path(:category, category, nil)

      assert href == Routes.path("/admin/shop/categories/#{category.uuid}/edit")
    end

    @tag :catalogue
    test "a legacy record still opens the shop form while the catalogue source is on" do
      product = legacy_product!()
      category = legacy_category!()
      set_product_source("catalogue")

      assert URI.parse(Helpers.admin_edit_path(:item, product, nil)).path ==
               Routes.path("/admin/shop/products/#{product.uuid}/edit")

      assert URI.parse(Helpers.admin_edit_path(:category, category, nil)).path ==
               Routes.path("/admin/shop/categories/#{category.uuid}/edit")
    end
  end

  describe "admin_edit_path/3 — catalogue records" do
    @describetag :catalogue

    test "a catalogue item opens the catalogue item editor, keeping return_to" do
      product = catalogue_product()

      href = Helpers.admin_edit_path(:item, product, "/en/shop/product/x")

      assert URI.parse(href).path ==
               URI.parse(PhoenixKitCatalogue.Paths.item_edit(product.uuid)).path

      assert href =~ "return_to=%2Fen%2Fshop%2Fproduct%2Fx"
    end

    test "a catalogue category opens the catalogue category editor" do
      category = catalogue_category()

      href = Helpers.admin_edit_path(:category, category, "/en/admin/shop/categories")

      assert URI.parse(href).path ==
               URI.parse(PhoenixKitCatalogue.Paths.category_edit(category.uuid)).path

      assert href =~ "return_to=%2Fen%2Fadmin%2Fshop%2Fcategories"
    end

    test "a catalogue item opens the catalogue editor while the legacy source is on" do
      assert Helpers.admin_edit_path(:item, catalogue_product(), nil) =~ "/catalogues/items/"
    end

    test "a store holding both origins routes each record to its own editor" do
      legacy = legacy_product!()
      catalogue = catalogue_product()
      set_product_source("catalogue")

      assert Helpers.admin_edit_path(:item, legacy, nil) =~ "/admin/shop/products/"
      assert Helpers.admin_edit_path(:item, catalogue, nil) =~ "/catalogues/items/"
    end
  end

  describe "admin_edit_path/3 with a bare uuid (deprecated)" do
    test "keeps the old behaviour: the legacy source opens the shop form" do
      uuid = Ecto.UUID.generate()

      assert Helpers.admin_edit_path(:item, uuid, nil) ==
               Routes.path("/admin/shop/products/#{uuid}/edit")

      assert Helpers.admin_edit_path(:category, uuid, nil) ==
               Routes.path("/admin/shop/categories/#{uuid}/edit")
    end

    @tag :catalogue
    test "keeps the old behaviour: the catalogue source opens the catalogue editor" do
      uuid = Ecto.UUID.generate()
      set_product_source("catalogue")

      assert Helpers.admin_edit_path(:item, uuid, "/en/shop/product/x") ==
               PhoenixKitCatalogue.Paths.item_edit(uuid) <>
                 "?return_to=%2Fen%2Fshop%2Fproduct%2Fx"

      assert Helpers.admin_edit_path(:category, uuid, nil) ==
               PhoenixKitCatalogue.Paths.category_edit(uuid)
    end
  end

  describe "admin_edit_permissions/1" do
    test "a legacy record needs only the catalog capability" do
      assert Helpers.admin_edit_permissions(%Product{}) == ["shop.manage_catalog"]
      assert Helpers.admin_edit_permissions(%Category{}) == ["shop.manage_catalog"]
    end

    test "a catalogue record also needs the catalogue module key" do
      assert Helpers.admin_edit_permissions(catalogue_product()) ==
               ["shop.manage_catalog", "catalogue"]

      assert Helpers.admin_edit_permissions(catalogue_category()) ==
               ["shop.manage_catalog", "catalogue"]
    end
  end

  describe "maybe_assign_admin_edit/4 with several permissions" do
    @describetag :catalogue

    setup do
      enable_catalogue_module()
      :ok
    end

    defp socket_with(scope),
      do: %Phoenix.LiveView.Socket{assigns: %{phoenix_kit_current_scope: scope, __changed__: %{}}}

    defp assigned?(socket), do: Map.has_key?(socket.assigns, :admin_edit_url)

    test "every named permission must be held" do
      both = socket_with(fake_scope(permissions: ["shop", "shop.manage_catalog", "catalogue"]))
      only_shop = socket_with(fake_scope(permissions: ["shop", "shop.manage_catalog"]))
      only_catalogue = socket_with(fake_scope(permissions: ["shop", "catalogue"]))
      perms = ["shop.manage_catalog", "catalogue"]

      assert assigned?(Helpers.maybe_assign_admin_edit(both, "/x", "Edit", permission: perms))

      refute assigned?(
               Helpers.maybe_assign_admin_edit(only_shop, "/x", "Edit", permission: perms)
             )

      refute assigned?(
               Helpers.maybe_assign_admin_edit(only_catalogue, "/x", "Edit", permission: perms)
             )
    end

    test "a single permission string still works" do
      allowed = socket_with(fake_scope(permissions: ["shop", "shop.manage_catalog"]))
      denied = socket_with(fake_scope(permissions: ["shop"]))

      assert assigned?(Helpers.maybe_assign_admin_edit(allowed, "/x", "Edit"))
      refute assigned?(Helpers.maybe_assign_admin_edit(denied, "/x", "Edit"))
    end

    test "no permission named, no link (fail closed)" do
      admin = socket_with(fake_scope(permissions: ["shop", "shop.manage_catalog"]))

      refute assigned?(Helpers.maybe_assign_admin_edit(admin, "/x", "Edit", permission: []))
      refute assigned?(Helpers.maybe_assign_admin_edit(admin, "/x", "Edit", permission: nil))
    end

    test "no scope, no link" do
      refute assigned?(Helpers.maybe_assign_admin_edit(socket_with(nil), "/x", "Edit"))
    end
  end

  describe "storefront product page for a catalogue item" do
    @describetag :catalogue

    setup do
      set_product_source("catalogue")
      enable_catalogue_module()

      {:ok, catalogue} = PhoenixKitCatalogue.Catalogue.create_catalogue(%{name: "decor3dprint"})
      slug = "origin-item-#{System.unique_integer([:positive])}"

      {:ok, item} =
        PhoenixKitCatalogue.Catalogue.create_item(%{
          catalogue_uuid: catalogue.uuid,
          name: "Origin Item",
          base_price: Decimal.new("19.00"),
          status: "active",
          slug: %{"en-US" => slug},
          data: %{"ecommerce" => %{"shop_status" => "active"}}
        })

      %{item: item, path: "/shop/product/#{slug}"}
    end

    test "an admin with the catalogue key is sent to the catalogue editor", %{
      conn: conn,
      item: item,
      path: path
    } do
      conn = put_test_scope(conn, fake_scope(permissions: shop_permissions() ++ ["catalogue"]))

      {:ok, _view, html} = live(conn, path)

      assert html =~ "Edit Product"
      assert html =~ PhoenixKitCatalogue.Paths.item_edit(item.uuid)
    end

    test "an admin without the catalogue key is shown no link", %{conn: conn, path: path} do
      conn = put_test_scope(conn, fake_scope())

      {:ok, _view, html} = live(conn, path)

      refute html =~ "Edit Product"
    end

    test "a visitor who is not an admin is shown no link", %{conn: conn, path: path} do
      {:ok, _view, html} = live(conn, path)

      refute html =~ "Edit Product"
    end
  end

  describe "storefront category page for a catalogue category" do
    @describetag :catalogue

    setup do
      set_product_source("catalogue")
      enable_catalogue_module()

      {:ok, catalogue} = PhoenixKitCatalogue.Catalogue.create_catalogue(%{name: "decor3dprint"})
      slug = "origin-category-#{System.unique_integer([:positive])}"

      {:ok, category} =
        PhoenixKitCatalogue.Catalogue.create_category(%{
          name: "Origin Category",
          catalogue_uuid: catalogue.uuid,
          slug: %{"en-US" => slug},
          data: %{"ecommerce" => %{"shop_status" => "active"}}
        })

      %{category: category, path: "/shop/category/#{slug}"}
    end

    test "an admin with the catalogue key is sent to the catalogue category editor", %{
      conn: conn,
      category: category,
      path: path
    } do
      conn = put_test_scope(conn, fake_scope(permissions: shop_permissions() ++ ["catalogue"]))

      {:ok, _view, html} = live(conn, path)

      assert html =~ "Edit Category"
      assert html =~ PhoenixKitCatalogue.Paths.category_edit(category.uuid)
      assert html =~ "return_to="
    end

    test "an admin without the catalogue key is shown no link", %{conn: conn, path: path} do
      conn = put_test_scope(conn, fake_scope())

      {:ok, _view, html} = live(conn, path)

      refute html =~ "Edit Category"
    end
  end
end
