defmodule PhoenixKitEcommerce.API.Public.SearchCatalogueTest do
  @moduledoc """
  `shop.search_products` on the Catalogue product source: the index is built
  from catalogue items, and the answer is built from live items.

  Needs a core with the shop API (`PhoenixKit.API.Actor`). `async: false`: the
  shop's catalogue is found by name across the database, and Billing's currency
  cache is node-global.
  """
  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :catalogue
  @moduletag :requires_core_api

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}

  import PhoenixKitEcommerce.SearchFixtures

  alias PhoenixKit.API.Actor
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce.API.Public.Search
  alias PhoenixKitEcommerce.Search.Indexer

  setup do
    disable_languages!()
    currencies!()
    catalogue = catalogue_source!()
    root = catalogue_category!(catalogue, "Home")
    leaf = catalogue_category!(catalogue, "Vases", %{parent_uuid: root.uuid})

    vase =
      catalogue_item!(catalogue, "Red Ceramic Vase", %{
        category_uuid: leaf.uuid,
        slug: %{"en" => "red-ceramic-vase"}
      })

    bowl = catalogue_item!(catalogue, "Blue Glass Bowl")
    _hidden = catalogue_item!(catalogue, "Hidden Vase", %{data: shop_data("draft")})
    {:ok, _} = Indexer.rebuild()

    %{catalogue: catalogue, vase: vase, bowl: bowl, leaf: leaf}
  end

  defp ctx(overrides) do
    ip = "10.1.#{rem(System.unique_integer([:positive]), 250)}.#{:rand.uniform(250)}"

    Map.merge(
      %{
        actor: struct(Actor, kind: :anonymous, ip: ip),
        scopes: [],
        audience: :public,
        language: "en",
        currency: nil,
        hosts: ["shop.test"],
        base_url: "https://shop.test",
        request_id: "req-1",
        dry_run?: false
      },
      Map.new(overrides)
    )
  end

  defp search!(input, overrides \\ []) do
    assert {:ok, out} = Search.search_products(input, ctx(overrides))
    out
  end

  defp item_ids(out), do: Enum.map(out["items"], & &1["id"])

  test "browsing lists the listed items and none that the shop status hides", t do
    out = search!(%{})

    assert out["count"] == 2
    assert Enum.sort(item_ids(out)) == Enum.sort([t.vase.uuid, t.bowl.uuid])
  end

  test "a text query finds an item, and its card has a title, slug, url and category path", t do
    out = search!(%{"q" => "vase"})

    assert item_ids(out) == [t.vase.uuid]
    assert out["match_mode"] == "fulltext"

    [item] = out["items"]
    assert item["title"] == "Red Ceramic Vase"
    assert item["slug"] == "red-ceramic-vase"
    assert String.starts_with?(item["url"], "https://shop.test/")
    assert String.ends_with?(item["url"], "/shop/product/red-ceramic-vase")
    assert Enum.map(item["category_path"], & &1["name"]) == ["Home", "Vases"]
    assert item["price"] == %{"amount" => "10.00", "currency" => "USD"}
  end

  test "an item changed after the index was written is not shown while it is hidden", t do
    {:ok, _} = Catalogue.update_item(t.vase, %{data: shop_data("draft")})

    # The index still holds the row; the live check drops it.
    out = search!(%{"q" => "vase"})
    assert item_ids(out) == []

    {:ok, _} = Indexer.reindex_items([t.vase.uuid])
    assert search!(%{"q" => "vase"})["count"] == 0
  end

  test "a host language 'de' finds an item indexed under the dialect 'de-DE'", t do
    enable_languages!(["en-US", "de-DE"])

    data =
      "active"
      |> shop_data()
      |> Map.merge(%{
        "_primary_language" => "en-US",
        "en-US" => %{"_name" => "Plain Lamp"},
        "de-DE" => %{"_name" => "Rote Lampen"}
      })

    lamp = catalogue_item!(t.catalogue, "Plain Lamp", %{data: data})
    {:ok, _} = Indexer.reindex_items([lamp.uuid])

    out = search!(%{"q" => "Lampen"}, language: "de")

    assert out["language"] == "de-DE"
    assert item_ids(out) == [lamp.uuid]
    assert hd(out["items"])["title"] == "Rote Lampen"
  end
end
