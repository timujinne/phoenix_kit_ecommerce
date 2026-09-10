defmodule PhoenixKitEcommerce.Web.CatalogCategoryCatalogueStatusTest do
  @moduledoc """
  Storefront-render regression for the category-side twin of the #53 live
  defect: a catalogue category soft-deleted at the catalogue level
  (`c.status == "deleted"`) stayed reachable — and its products listed —
  at its category page URL whenever a left-over
  `data["ecommerce"]["shop_status"]` was not literally `"hidden"`.
  `CatalogCategory.do_mount/3`'s gate tests the DERIVED status
  (`View.category_view/2`), so the defect lived in the derivation, not
  the gate — this pins the gate's observable behavior end to end, through
  a real `phoenix_kit_cat_categories` row soft-deleted via
  `Catalogue.trash_category/2`.

  Needs `phoenix_kit_catalogue` loaded — excluded via `test_helper.exs`
  whenever the optional dependency isn't present, same as every other
  `:catalogue` test. `async: false`: flips the process-wide
  `shop_product_source` config key.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  @moduletag :catalogue

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce.ShopConfig
  alias PhoenixKitEcommerce.Test.Repo

  setup do
    set_product_source("catalogue")
    on_exit(fn -> set_product_source("legacy") end)

    {:ok, catalogue} = Catalogue.create_catalogue(%{name: "decor3dprint"})

    %{catalogue: catalogue}
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

  for shop_status <- ~w(active unlisted) do
    test "a deleted catalogue category with shop_status left #{shop_status} is not served at its URL",
         %{conn: conn, catalogue: catalogue} do
      slug = "retired-category-#{unquote(shop_status)}"

      {:ok, category} =
        Catalogue.create_category(%{
          name: "Retired Category (#{unquote(shop_status)})",
          catalogue_uuid: catalogue.uuid,
          slug: %{"en-US" => slug},
          data: %{"ecommerce" => %{"shop_status" => unquote(shop_status)}}
        })

      {:ok, _trashed} = Catalogue.trash_category(category)

      assert {:error, {kind, %{to: to}}} = live(conn, "/shop/category/#{slug}")
      assert kind in [:redirect, :live_redirect]
      assert to =~ "/shop"
    end
  end

  test "a deleted catalogue category with no shop_status set (unconditional-active default) is not served",
       %{conn: conn, catalogue: catalogue} do
    slug = "retired-category-default"

    {:ok, category} =
      Catalogue.create_category(%{
        name: "Retired Category (default)",
        catalogue_uuid: catalogue.uuid,
        slug: %{"en-US" => slug}
      })

    {:ok, _trashed} = Catalogue.trash_category(category)

    assert {:error, {kind, %{to: to}}} = live(conn, "/shop/category/#{slug}")
    assert kind in [:redirect, :live_redirect]
    assert to =~ "/shop"
  end

  test "an active catalogue category with shop_status active is still served", %{
    conn: conn,
    catalogue: catalogue
  } do
    slug = "still-active-category"

    {:ok, _category} =
      Catalogue.create_category(%{
        name: "Still Active Category",
        catalogue_uuid: catalogue.uuid,
        slug: %{"en-US" => slug},
        data: %{"ecommerce" => %{"shop_status" => "active"}}
      })

    {:ok, _view, html} = live(conn, "/shop/category/#{slug}")

    assert html =~ "Still Active Category"
  end
end
