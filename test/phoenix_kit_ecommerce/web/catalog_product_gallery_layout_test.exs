defmodule PhoenixKitEcommerce.Web.CatalogProductGalleryLayoutTest do
  @moduledoc """
  A product with many pictures must not stretch the product page.

  The gallery sits in a two-column grid next to the buy box. A bare
  `65fr` column has an automatic minimum of its content, so the strip of
  64px thumbnails (one per picture, `flex-shrink-0`) made the column as wide
  as the whole strip: the buy box shrank to a sliver and the page scrolled
  sideways. A rendered test cannot measure pixels, so this pins the classes
  that keep the strip inside its column (the track definition and the
  strip's wrapping and height cap), and the two that let the narrower buy
  box cope (a breaking title and a wrapping price row).

  Needs `phoenix_kit_catalogue` loaded — excluded via `test_helper.exs`
  whenever the optional dependency isn't present. `async: false`: flips the
  process-wide `shop_product_source` config key.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  @moduletag :catalogue

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce.ShopConfig
  alias PhoenixKitEcommerce.Test.Repo

  @picture_count 18

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

  defp create_item_with_pictures(catalogue, slug, count) do
    {:ok, item} =
      Catalogue.create_item(%{
        catalogue_uuid: catalogue.uuid,
        name: "Gallery Item",
        base_price: Decimal.new("19.00"),
        status: "active",
        slug: %{"en-US" => slug},
        data: %{
          "ecommerce" => %{"shop_status" => "active"},
          "media_order" => for(_ <- 1..count, do: Ecto.UUID.generate())
        }
      })

    item
  end

  test "a product with many pictures keeps the strip inside the gallery column", %{
    conn: conn,
    catalogue: catalogue
  } do
    create_item_with_pictures(catalogue, "many-pictures", @picture_count)

    {:ok, view, _html} = live(conn, "/shop/product/many-pictures")

    # One thumbnail per picture: the layout below is meant for this many.
    assert has_element?(view, "#product-thumbnails button:nth-child(#{@picture_count})")
    refute has_element?(view, "#product-thumbnails button:nth-child(#{@picture_count + 1})")

    # The columns have no content-sized minimum, so the strip cannot widen them.
    assert has_element?(view, ~s{div[class*="minmax(0,65fr)"][class*="minmax(0,35fr)"]})

    # The gallery may shrink below the strip's width.
    assert has_element?(view, ~s{#product-gallery[class~="min-w-0"]})

    # Wide screens wrap the strip and cap its height, scrolling the rest;
    # narrow ones keep one row that scrolls sideways.
    assert has_element?(view, ~s{#product-thumbnails[class~="overflow-x-auto"]})
    assert has_element?(view, ~s{#product-thumbnails[class~="md:flex-wrap"]})
    assert has_element?(view, ~s{#product-thumbnails[class~="md:max-h-48"]})
    assert has_element?(view, ~s{#product-thumbnails[class~="md:overflow-y-auto"]})

    # The buy box column can be narrow: long title words break, the price row wraps.
    assert has_element?(view, ~s{h1[class~="break-words"]})
    assert has_element?(view, ~s{div[class~="flex-wrap"][class~="items-baseline"]})
  end
end
