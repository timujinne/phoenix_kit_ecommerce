defmodule PhoenixKitEcommerce.API.Public.CatalogTest do
  @moduledoc """
  get_products, list_categories and similar_products on the legacy source
  (`catalog_catalogue_test.exs` covers the catalogue item states).
  `async: false`: Billing's currency cache is node-global.
  """
  use PhoenixKitEcommerce.DataCase, async: false

  @compile {:no_warn_undefined, PhoenixKit.API.Validator}

  import PhoenixKitEcommerce.SearchFixtures

  alias PhoenixKit.API.Validator
  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.API.Public.Catalog
  alias PhoenixKitEcommerce.Category
  alias PhoenixKitEcommerce.Search.Indexer
  alias PhoenixKitEcommerce.Test.Repo

  setup do
    disable_languages!()
    currencies!()
    sample_shop!()
  end

  defp get!(input, overrides \\ []) do
    assert {:ok, out} = Catalog.get_products(input, public_ctx(overrides))
    out
  end

  describe "urls on a mapped domain" do
    setup do
      enable_languages!(["en-US", "de-DE"])
      {:ok, _} = Settings.update_boolean_setting("default_language_no_prefix", true)

      category = legacy_category!(%{"en-US" => "Lamps", "de-DE" => "Lampen"})

      product =
        legacy_product!(%{"en-US" => "Plain Vase", "de-DE" => "Rote Vasen"}, %{
          category_uuid: category.uuid,
          tags: ["mapped"]
        })

      sibling =
        legacy_product!(%{"en-US" => "Other Vase", "de-DE" => "Andere Vasen"}, %{
          category_uuid: category.uuid
        })

      {:ok, _} = Indexer.reindex_items([product.uuid, sibling.uuid])

      %{category: category, product: product, sibling: sibling}
    end

    test "get_products links to the language of the domain without a locale prefix", t do
      out = get!(%{"ids" => [t.product.uuid]}, language: "de")

      url = hd(out["results"])["product"]["url"]
      assert url =~ "https://shop.test/shop/product/"
      refute url =~ "/de/"
    end

    test "get_products links to an explicitly asked other language with its prefix", t do
      out = get!(%{"ids" => [t.product.uuid], "language" => "en"}, language: "de")

      assert hd(out["results"])["product"]["url"] =~ "https://shop.test/en/shop/product/"
    end

    test "list_categories links to the language of the domain without a locale prefix", t do
      node = list!(language: "de")["categories"] |> Enum.find(&(&1["id"] == t.category.uuid))

      assert node["name"] == "Lampen"
      assert node["url"] =~ "https://shop.test/shop/category/"
      refute node["url"] =~ "/de/"
    end

    test "list_categories links to an explicitly asked other language with its prefix", t do
      assert {:ok, out} =
               Catalog.list_categories(%{"language" => "en"}, public_ctx(language: "de"))

      node = Enum.find(out["categories"], &(&1["id"] == t.category.uuid))

      assert node["url"] =~ "https://shop.test/en/shop/category/"
    end

    test "similar_products links to the language of the domain without a locale prefix", t do
      out = similar!(%{"id" => t.product.uuid}, language: "de")

      assert [%{"id" => id, "url" => url}] = out["items"]
      assert id == t.sibling.uuid
      assert url =~ "https://shop.test/shop/product/"
      refute url =~ "/de/"
    end

    test "similar_products links to an explicitly asked other language with its prefix", t do
      out = similar!(%{"id" => t.product.uuid, "language" => "en"}, language: "de")

      assert [%{"url" => url}] = out["items"]
      assert url =~ "https://shop.test/en/shop/product/"
    end
  end

  describe "get_products/2" do
    test "a card for a listed product, a stub for a discontinued one, not_found for everything else",
         t do
      old = legacy_product!(%{"en" => "Old Lamp"}, %{status: "archived"})
      draft = legacy_product!(%{"en" => "Draft Lamp"}, %{status: "draft"})
      secret = legacy_category!(%{"en" => "Secret"}, %{status: "hidden"})
      hidden = legacy_product!(%{"en" => "Hidden Lamp"}, %{category_uuid: secret.uuid})
      unknown = Ecto.UUID.generate()

      ids = [t.a, old.uuid, draft.uuid, hidden.uuid, unknown, "garbage"]
      out = get!(%{"ids" => ids})

      assert [card, stub, gone_1, gone_2, gone_3, gone_4] = out["results"]

      assert card["ref"] == t.a
      assert card["product"]["title"] == "Red Ceramic Vase"
      assert card["product"]["status"] == "active"
      assert card["product"]["tags"] == ["gift"]
      assert card["product"]["price"] == %{"amount" => "20.00", "currency" => "USD"}

      assert stub == %{
               "ref" => old.uuid,
               "product" => %{"id" => old.uuid, "title" => "Old Lamp", "status" => "discontinued"}
             }

      not_found = %{"code" => "not_found", "message" => "No such product."}
      assert gone_1 == %{"ref" => draft.uuid, "error" => not_found}
      assert gone_2 == %{"ref" => hidden.uuid, "error" => not_found}
      assert gone_3 == %{"ref" => unknown, "error" => not_found}
      assert gone_4 == %{"ref" => "garbage", "error" => not_found}

      assert out["summary"] == %{"found" => 1, "discontinued" => 1, "not_found" => 4}
    end

    test "results follow the order and the duplicates of the input; an upper-case id is the same id",
         t do
      out = get!(%{"ids" => [t.b, t.a, t.b, String.upcase(t.a)]})

      assert Enum.map(out["results"], & &1["product"]["id"]) == [t.b, t.a, t.b, t.a]
      assert Enum.map(out["results"], & &1["ref"]) == [t.b, t.a, t.b, String.upcase(t.a)]
    end

    test "a 16-byte string is not an id, even when its bytes are those of a listed product", t do
      raw = Ecto.UUID.dump!(t.a)
      assert byte_size(raw) == 16

      out = get!(%{"ids" => [raw, t.a]})

      assert [%{"error" => %{"code" => "not_found"}}, %{"product" => %{"id" => id}}] =
               out["results"]

      assert id == t.a
    end

    test "a repeated id is loaded and built once: the cost does not grow with the repeats", t do
      # Warm the settings and currency caches so that both calls do the same work.
      get!(%{"ids" => [t.a]})

      once = count_queries(fn -> get!(%{"ids" => [t.a]}) end)
      many = count_queries(fn -> get!(%{"ids" => List.duplicate(t.a, 6)}) end)

      assert once > 0
      assert many == once

      out = get!(%{"ids" => List.duplicate(t.a, 3)})
      assert Enum.map(out["results"], & &1["product"]["id"]) == [t.a, t.a, t.a]
      assert out["summary"]["found"] == 3
    end

    test "format: markdown returns the description as Markdown" do
      product =
        legacy_product!(%{"en" => "Described"}, %{
          body_html: %{"en" => "<p>Hello <b>world</b></p>"}
        })

      text = get!(%{"ids" => [product.uuid]})
      markdown = get!(%{"ids" => [product.uuid], "format" => "markdown"})

      assert hd(text["results"])["product"]["description"] == "Hello world"
      assert hd(markdown["results"])["product"]["description"] =~ "**world**"
    end

    test "prices come in the requested currency", t do
      out = get!(%{"ids" => [t.a], "currency" => "EUR"})

      assert hd(out["results"])["product"]["price"] == %{"amount" => "18.18", "currency" => "EUR"}
    end

    test "an unknown language is a validation error", t do
      assert {:error, :validation_failed, _message, %{errors: [%{path: "language"}]}} =
               Catalog.get_products(%{"ids" => [t.a], "language" => "xx"}, public_ctx())
    end

    test "the answer is plain JSON", t do
      out = get!(%{"ids" => [t.a, Ecto.UUID.generate()]})

      assert out == out |> JSON.encode!() |> JSON.decode!()
    end

    @tag :requires_core_api
    test "the schemas accept the answer, a stub and a not_found row included, and refuse too many ids or a stray field",
         t do
      old = legacy_product!(%{"en" => "Old Lamp"}, %{status: "archived"})
      out = get!(%{"ids" => [t.a, old.uuid, Ecto.UUID.generate()]})
      assert out["summary"] == %{"found" => 1, "discontinued" => 1, "not_found" => 1}

      assert {:ok, _} =
               Validator.validate(Catalog.get_products_output_schema(), out)

      input = Catalog.get_products_input_schema()
      assert {:ok, _} = Validator.validate(input, %{"ids" => [t.a]})

      assert {:error, [%{path: "ids"}]} =
               Validator.validate(input, %{"ids" => List.duplicate(t.a, 51)})

      assert {:error, [%{path: "ids"}]} = Validator.validate(input, %{"ids" => []})
      assert {:error, [%{path: "ids"}]} = Validator.validate(input, %{})
    end
  end

  describe "list_categories/2" do
    defp list!(overrides \\ []) do
      assert {:ok, out} = Catalog.list_categories(%{}, public_ctx(overrides))
      out
    end

    test "the tree of active categories with direct and total product counts", t do
      out = list!()

      assert out["count"] == 3
      assert [home] = out["categories"]
      assert home["id"] == t.home
      assert home["name"] == "Home"
      assert home["product_count"] == 0
      assert home["total_count"] == 3

      assert home["url"] ==
               "https://shop.test" <> Shop.category_url(Shop.get_category(t.home), "en")

      assert Enum.map(home["children"], &{&1["name"], &1["product_count"], &1["total_count"]}) ==
               [{"Bowls", 1, 1}, {"Vases", 2, 2}]

      assert Enum.all?(home["children"], &(&1["children"] == []))
    end

    test "hidden and unlisted categories are not shown, and a child of a hidden parent becomes a root" do
      secret = legacy_category!(%{"en" => "Secret"}, %{status: "hidden"})
      _unlisted = legacy_category!(%{"en" => "Quiet"}, %{status: "unlisted"})
      orphan = legacy_category!(%{"en" => "Orphan"}, %{parent_uuid: secret.uuid})

      out = list!()

      names = out["categories"] |> Enum.map(& &1["name"]) |> Enum.sort()
      assert names == ["Home", "Orphan"]
      assert out["count"] == 4
      assert Enum.find(out["categories"], &(&1["name"] == "Orphan"))["id"] == orphan.uuid
    end

    test "a cycle of parents or a category that is its own parent is left out, and count matches the tree",
         t do
      loop_a = legacy_category!(%{"en" => "Loop A"})
      loop_b = legacy_category!(%{"en" => "Loop B"}, %{parent_uuid: loop_a.uuid})
      selfish = legacy_category!(%{"en" => "Selfish"})

      for {uuid, parent} <- [{loop_a.uuid, loop_b.uuid}, {selfish.uuid, selfish.uuid}] do
        {1, _} =
          Repo.update_all(from(c in Category, where: c.uuid == ^uuid), set: [parent_uuid: parent])
      end

      out = list!()

      assert [home] = out["categories"]
      assert home["id"] == t.home
      assert out["count"] == 3
    end

    test "roots and children are ordered by position, then by name, whatever the creation order",
         t do
      # Created out of order, so neither creation order nor name order alone is the answer.
      _zeta = legacy_category!(%{"en" => "Zeta"})
      _aardvark = legacy_category!(%{"en" => "Aardvark"})
      _last = legacy_category!(%{"en" => "Last"}, %{position: 5})
      _middle = legacy_category!(%{"en" => "Middle"}, %{position: 2})
      _attic = legacy_category!(%{"en" => "Attic"}, %{parent_uuid: t.home, position: 9})
      _cellar = legacy_category!(%{"en" => "Cellar"}, %{parent_uuid: t.home, position: 1})

      nodes = list!()["categories"]

      assert Enum.map(nodes, & &1["name"]) == ["Aardvark", "Home", "Zeta", "Middle", "Last"]

      home = Enum.find(nodes, &(&1["id"] == t.home))
      assert Enum.map(home["children"], & &1["name"]) == ["Bowls", "Vases", "Cellar", "Attic"]
    end

    test "a category with no slug has no page: slug and url are left out together" do
      bare = legacy_category!(%{"en" => "Bare"})
      {1, _} = Repo.update_all(from(c in Category, where: c.uuid == ^bare.uuid), set: [slug: %{}])

      nodes = list!()["categories"]
      node = Enum.find(nodes, &(&1["id"] == bare.uuid))
      listed = Enum.find(nodes, &(&1["name"] == "Home"))

      assert node["name"] == "Bare"
      refute Map.has_key?(node, "slug")
      refute Map.has_key?(node, "url")
      assert is_binary(listed["slug"]) and is_binary(listed["url"])
    end

    test "a product hidden since the index was written still counts until it is re-indexed", t do
      # The counts come from the index, not from live products: the aggregate lags
      # a hidden product by the re-index delay (items and cards are always live).
      {:ok, _} = Shop.update_product(Shop.get_product!(t.a), %{status: "draft"})
      assert vases_count() == 2

      {:ok, _} = Indexer.reindex_items([t.a])
      assert vases_count() == 1
    end

    defp vases_count do
      list!()["categories"]
      |> hd()
      |> Map.fetch!("children")
      |> Enum.find(&(&1["name"] == "Vases"))
      |> Map.fetch!("product_count")
    end

    @tag :requires_core_api
    test "the answer satisfies its schema and the input schema is closed" do
      assert {:ok, _} =
               Validator.validate(Catalog.list_categories_output_schema(), list!())

      input = Catalog.list_categories_input_schema()
      assert {:ok, _} = Validator.validate(input, %{"language" => "en"})
      assert {:error, [%{path: "q"}]} = Validator.validate(input, %{"q" => "x"})
    end
  end

  describe "similar_products/2" do
    defp similar!(input, overrides \\ []) do
      assert {:ok, out} = Catalog.similar_products(input, public_ctx(overrides))
      out
    end

    test "same category first, then shared tags; never the product itself", t do
      out = similar!(%{"id" => t.a})

      assert Enum.map(out["items"], & &1["id"]) == [t.c, t.d]
      assert out["count"] == 2
      assert hd(out["items"])["title"] == "Green Vase Small"
      refute Map.has_key?(out, "warnings")
    end

    test "a product with nothing in common has no similar products", t do
      assert similar!(%{"id" => t.b})["items"] == []
    end

    test "unknown, malformed and not-listed ids are all not_found", t do
      draft = legacy_product!(%{"en" => "Draft Lamp"}, %{status: "draft"})

      # A 16-byte string with the bytes of a listed product is no id either.
      for id <- [Ecto.UUID.generate(), "garbage", draft.uuid, Ecto.UUID.dump!(t.a)] do
        assert {:error, :not_found, "No such product.", _context} =
                 Catalog.similar_products(%{"id" => id}, public_ctx())
      end
    end

    test "a product hidden after the index was written is not_found and never a similar one", t do
      {:ok, _} = Shop.update_product(Shop.get_product!(t.c), %{status: "draft"})

      assert {:error, :not_found, _message, _context} =
               Catalog.similar_products(%{"id" => t.c}, public_ctx())

      assert Enum.map(similar!(%{"id" => t.a})["items"], & &1["id"]) == [t.d]
    end

    test "a limit above 20 is trimmed with a warning", t do
      out = similar!(%{"id" => t.a, "limit" => 100})

      assert [%{"code" => "limit_trimmed", "requested" => 100, "applied" => 20}] = out["warnings"]
      assert length(out["items"]) == 2
    end

    test "a limit of 1 returns the best one", t do
      assert Enum.map(similar!(%{"id" => t.a, "limit" => 1})["items"], & &1["id"]) == [t.c]
    end

    @tag :requires_core_api
    test "the answer satisfies its schema; the input needs an id and refuses a limit below 1",
         t do
      assert {:ok, _} =
               Validator.validate(
                 Catalog.similar_products_output_schema(),
                 similar!(%{"id" => t.a})
               )

      input = Catalog.similar_products_input_schema()
      assert {:ok, _} = Validator.validate(input, %{"id" => t.a, "limit" => 5})
      assert {:error, [%{path: "id"}]} = Validator.validate(input, %{})

      assert {:error, [%{path: "limit"}]} =
               Validator.validate(input, %{"id" => t.a, "limit" => 0})
    end
  end
end
