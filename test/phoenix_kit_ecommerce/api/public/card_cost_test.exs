defmodule PhoenixKitEcommerce.API.Public.CardCostTest do
  @moduledoc """
  What a card costs in queries: the work shared by the cards of one answer (the
  option schema, the categories, the stored pictures) is read once for the
  answer, so the number of queries does not grow with the number of products.
  `async: false`: Billing's currency cache is node-global.
  """
  use PhoenixKitEcommerce.DataCase, async: false

  import PhoenixKitEcommerce.SearchFixtures

  alias PhoenixKit.Modules.Storage
  alias PhoenixKitEcommerce.API.Public.Catalog
  alias PhoenixKitEcommerce.API.Public.Search
  alias PhoenixKitEcommerce.Search.Indexer

  setup do
    disable_languages!()
    currencies!()
    :ok
  end

  defp stored_image do
    user = PhoenixKitEcommerce.DataCase.fixture_user()

    {:ok, file} =
      Storage.create_file(%{
        original_file_name: "probe.png",
        file_name: "probe.png",
        mime_type: "image/png",
        file_type: "image",
        ext: "png",
        file_checksum: "c#{System.unique_integer([:positive])}",
        user_file_checksum: "u#{System.unique_integer([:positive])}",
        size: 100,
        status: "active",
        user_uuid: user.uuid
      })

    for variant <- ["small", "medium"] do
      {:ok, _} =
        Storage.create_file_instance(%{
          file_uuid: file.uuid,
          variant_name: variant,
          file_name: "probe-#{variant}.png",
          mime_type: "image/png",
          ext: "png",
          checksum: "i#{System.unique_integer([:positive])}",
          size: 100
        })
    end

    file.uuid
  end

  # `count` products spread over `count` categories, each with three stored pictures.
  defp shop_of(count) do
    batch = System.unique_integer([:positive])

    for n <- 1..count do
      category = legacy_category!(%{"en" => "Shelf #{batch} #{n}"})
      images = for _ <- 1..3, do: stored_image()

      legacy_product!(%{"en" => "Cost Vase #{batch} #{n}"}, %{
        category_uuid: category.uuid,
        featured_image_uuid: hd(images),
        image_uuids: images
      })
    end
  end

  defp get!(ids) do
    assert {:ok, out} = Catalog.get_products(%{"ids" => ids}, public_ctx())
    out
  end

  defp search!(input) do
    assert {:ok, out} = Search.search_products(input, public_ctx())
    out
  end

  test "the queries of get_products do not grow with the number of products" do
    few = shop_of(2) |> Enum.map(& &1.uuid)
    many = shop_of(12) |> Enum.map(& &1.uuid)

    # Warm the settings and currency caches so that both calls do the same work.
    get!(few)

    few_queries = count_queries(fn -> get!(few) end)
    many_queries = count_queries(fn -> get!(many) end)

    assert few_queries > 0
    assert many_queries == few_queries
  end

  test "every card carries its own stored pictures and none of another card's" do
    products = shop_of(4)
    own = Map.new(products, &{&1.uuid, Enum.uniq([&1.featured_image_uuid | &1.image_uuids])})
    cards = get!(Map.keys(own))["results"] |> Enum.map(& &1["product"])

    assert length(cards) == 4
    assert cards |> Enum.map(& &1["id"]) |> Enum.sort() == own |> Map.keys() |> Enum.sort()

    for card <- cards do
      files = Map.fetch!(own, card["id"])
      foreign = own |> Map.delete(card["id"]) |> Map.values() |> List.flatten()

      assert "https://shop.test/" <> _ = card["image"]
      assert [_, _, _] = card["images"]
      assert String.contains?(card["image"], hd(files))

      for file <- files, do: assert(Enum.count(card["images"], &String.contains?(&1, file)) == 1)

      for url <- [card["image"] | card["images"]], file <- foreign do
        refute String.contains?(url, file)
      end
    end
  end

  test "the price range is read against the schema of each product's own category" do
    size = %{
      "key" => "size",
      "label" => "Size",
      "type" => "select",
      "options" => ["S", "L"],
      "affects_price" => true,
      "modifier_type" => "fixed",
      "price_modifiers" => %{"S" => "0", "L" => "5"}
    }

    sized = legacy_category!(%{"en" => "Sized"}, %{option_schema: [size]})
    plain = legacy_category!(%{"en" => "Plain"})
    cheap = legacy_product!(%{"en" => "Sized Vase"}, %{category_uuid: sized.uuid, price: "20.00"})
    flat = legacy_product!(%{"en" => "Plain Vase"}, %{category_uuid: plain.uuid, price: "20.00"})

    results = get!([cheap.uuid, flat.uuid])["results"]

    assert [%{"product" => sized_card}, %{"product" => plain_card}] = results
    assert sized_card["price_from"] == %{"amount" => "20.00", "currency" => "USD"}
    refute Map.has_key?(plain_card, "price_from")
  end

  test "a search page builds its cards from a fixed number of queries" do
    few = shop_of(2) |> Enum.map(& &1.uuid)
    {:ok, _} = Indexer.reindex_items(few)
    search!(%{"q" => "cost"})
    few_queries = count_queries(fn -> search!(%{"q" => "cost"}) end)

    many = shop_of(12) |> Enum.map(& &1.uuid)
    {:ok, _} = Indexer.reindex_items(many)
    many_queries = count_queries(fn -> search!(%{"q" => "cost"}) end)

    assert length(search!(%{"q" => "cost"})["items"]) == 14
    assert many_queries == few_queries
  end

  test "fields limits the work: the pictures and the price range are not read for an id and a title" do
    ids = shop_of(4) |> Enum.map(& &1.uuid)
    {:ok, _} = Indexer.reindex_items(ids)
    search!(%{"q" => "cost"})

    full = count_queries(fn -> search!(%{"q" => "cost"}) end)

    narrow =
      count_queries(fn -> search!(%{"q" => "cost", "fields" => ["title"]}) end)

    assert narrow < full

    assert [%{"id" => _, "title" => _} = item | _] =
             search!(%{"q" => "cost", "fields" => ["title"]})["items"]

    assert Map.keys(item) |> Enum.sort() == ["id", "title"]
  end

  test "get_products is priced by its ids: one unit per ten, at least one, at most the cap" do
    assert Catalog.get_products_cost(%{"ids" => ["a"]}) == 1
    assert Catalog.get_products_cost(%{"ids" => List.duplicate("a", 10)}) == 1
    assert Catalog.get_products_cost(%{"ids" => List.duplicate("a", 11)}) == 2
    assert Catalog.get_products_cost(%{"ids" => List.duplicate("a", 50)}) == 5
    assert Catalog.get_products_cost(%{"ids" => List.duplicate("a", 500)}) == 5
    assert Catalog.get_products_cost(%{"ids" => []}) == 1

    for junk <- [%{}, %{"ids" => "junk"}, %{"ids" => nil}, nil, 42, "x", []] do
      assert Catalog.get_products_cost(junk) == 1, inspect(junk)
    end
  end
end
