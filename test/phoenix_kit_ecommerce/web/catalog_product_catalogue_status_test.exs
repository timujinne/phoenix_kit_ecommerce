defmodule PhoenixKitEcommerce.Web.CatalogProductCatalogueStatusTest do
  @moduledoc """
  Storefront-render regression for the live defect: a catalogue item
  retired via its own `status` (`"inactive"`, `"discontinued"`, …) stayed
  reachable — and purchasable — at its product page URL whenever a
  left-over `data["ecommerce"]["shop_status"]` was still `"active"`.
  `mount/3`'s gate (`web/catalog_product.ex`) tests the DERIVED status
  (`View.product_status/2`), so the defect lived in the derivation, not
  the gate — this pins the gate's observable behavior end to end, through
  a real `phoenix_kit_cat_items` row.

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

  defp create_item(catalogue, attrs) do
    {:ok, item} =
      Catalogue.create_item(Map.merge(%{catalogue_uuid: catalogue.uuid}, attrs))

    item
  end

  for catalogue_status <- ~w(inactive discontinued deleted) do
    test "a #{catalogue_status} catalogue item with shop_status left active is not served at its URL",
         %{conn: conn, catalogue: catalogue} do
      slug = "retired-item-#{unquote(catalogue_status)}"

      create_item(catalogue, %{
        name: "Retired Item (#{unquote(catalogue_status)})",
        base_price: Decimal.new("19.00"),
        status: unquote(catalogue_status),
        slug: %{"en-US" => slug},
        data: %{"ecommerce" => %{"shop_status" => "active"}}
      })

      assert {:error, {kind, %{to: to}}} = live(conn, "/shop/product/#{slug}")
      assert kind in [:redirect, :live_redirect]
      assert to =~ "/shop"
    end
  end

  test "an active catalogue item with shop_status active is still served and purchasable", %{
    conn: conn,
    catalogue: catalogue
  } do
    slug = "still-active-item"

    create_item(catalogue, %{
      name: "Still Active Item",
      base_price: Decimal.new("19.00"),
      status: "active",
      slug: %{"en-US" => slug},
      data: %{"ecommerce" => %{"shop_status" => "active"}}
    })

    {:ok, _view, html} = live(conn, "/shop/product/#{slug}")

    assert html =~ "Still Active Item"
    assert html =~ "phx-click=\"add_to_cart\""
  end
end
