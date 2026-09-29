defmodule PhoenixKitEcommerce.Web.CatalogProductCatalogueOptionsTest do
  @moduledoc """
  The live defect end to end through the catalogue source: an item whose
  options come from two attached attribute sets — "Liquid Color" with
  +32.00 on every value, "Cup Color" with 0.00 on every value, base
  35.52 (the 2026-09-24 "Coffee Splash Illusion Sculpture" after a
  `never_cheaper` variant sync). Every real combination costs 67.52, and
  the product page headlined, and the cart charged, 35.52 with no colour
  chosen.

  The metadata-only twin that runs without the bridge is
  `catalog_product_required_options_test.exs`.

  Needs `phoenix_kit_catalogue` loaded — excluded via `test_helper.exs`
  otherwise, like every `:catalogue` test. `async: false`: flips the
  process-wide `shop_product_source` config key.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  @moduletag :catalogue

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}
  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue.AttributeSets}

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.AttributeSets
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.ProductSource.Catalogue, as: CatalogueSource
  alias PhoenixKitEcommerce.ShopConfig
  alias PhoenixKitEcommerce.Test.Repo

  @slug "coffee-splash-sculpture"

  setup %{conn: conn} do
    set_product_source("catalogue")
    on_exit(fn -> set_product_source("legacy") end)

    AttributeSets.register_deletion_guard()
    PhoenixKit.Settings.update_setting("entities_enabled", "true")
    on_exit(fn -> PhoenixKit.Settings.update_setting("entities_enabled", "false") end)

    {:ok, catalogue} = Catalogue.create_catalogue(%{name: "decor3dprint"})

    {:ok, item} =
      Catalogue.create_item(%{
        catalogue_uuid: catalogue.uuid,
        name: "Coffee Splash Illusion Sculpture",
        base_price: Decimal.new("35.52"),
        status: "active",
        slug: %{"en-US" => @slug},
        data: %{
          "ecommerce" => %{
            "shop_status" => "active",
            "price_modifiers" => %{
              "liquid_color" => %{"black" => "32.00", "blue" => "32.00"},
              "cup_color" => %{"white" => "0.00", "gold" => "0.00"}
            }
          }
        }
      })

    attach_set(item, "Liquid Color", "liquid_color", [{"Black", "black"}, {"Blue", "blue"}])
    attach_set(item, "Cup Color", "cup_color", [{"White", "white"}, {"Gold", "gold"}])

    session_id = "catalogue-options-#{System.unique_integer([:positive])}"
    conn = Plug.Test.init_test_session(conn, %{"shop_session_id" => session_id})

    %{conn: conn, item: item, session_id: session_id}
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

  defp attach_set(item, name, slug, values) do
    actor = [actor_uuid: Ecto.UUID.generate()]
    {:ok, set} = AttributeSets.create_set(%{name: name, slug: slug}, actor)

    for {label, value_slug} <- values do
      {:ok, _} = AttributeSets.create_value(set, %{label: label, slug: value_slug}, actor)
    end

    {:ok, _} = AttributeSets.attach_set(item.uuid, set.uuid)

    :ok =
      AttributeSets.set_attachment_selection(item.uuid, set.uuid, Enum.map(values, &elem(&1, 1)))
  end

  defp cart_lines(session_id) do
    case Shop.find_active_cart(session_id: session_id) do
      %{items: items} -> items
      nil -> []
    end
  end

  test "the page headlines a real combination and Add to Cart charges it with every colour", %{
    conn: conn,
    session_id: session_id
  } do
    {:ok, view, _html} = live(conn, "/shop/product/#{@slug}")

    assert view |> element("span.text-3xl.text-primary") |> render() =~ "67.52"
    refute render(view) =~ "35.52"

    view |> element("button[phx-click=add_to_cart]") |> render_click()

    assert [line] = cart_lines(session_id)
    assert line.selected_specs == %{"liquid_color" => "Black", "cup_color" => "White"}
    assert Decimal.equal?(line.base_unit_price, Decimal.new("67.52"))
  end

  test "the context refuses the item with a colour left unchosen", %{item: item} do
    product = CatalogueSource.get_product(item.uuid, [])
    {:ok, cart} = Shop.create_cart(session_id: "catalogue-options-ctx")

    assert {:error, :missing_required_option, key} = Shop.add_to_cart(cart, product, 1)
    assert key in ["liquid_color", "cup_color"]

    assert {:error, :missing_required_option, "liquid_color"} =
             Shop.add_to_cart(cart, product, 1, selected_specs: %{"cup_color" => "Gold"})

    assert Shop.get_cart(cart.uuid).items == []
  end
end
