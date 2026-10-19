defmodule PhoenixKitEcommerce.API.Public.SearchTest do
  @moduledoc """
  The two search handlers, called the way the executor calls them:
  `apply(Search, :search_products, [input, ctx])`.

  Needs a core with the shop API (`PhoenixKit.API.Actor`, `Validator`).
  `async: false`: Billing's currency cache is node-global.
  """
  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :requires_core_api

  @compile {:no_warn_undefined, PhoenixKit.API.Validator}

  import ExUnit.CaptureLog
  import PhoenixKitEcommerce.SearchFixtures

  alias PhoenixKit.API.Actor
  alias PhoenixKit.API.Validator
  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.API.Cards
  alias PhoenixKitEcommerce.API.Public.Search
  alias PhoenixKitEcommerce.Search.Indexer

  setup do
    disable_languages!()
    currencies!()
    sample_shop!()
  end

  defp ctx(overrides \\ []) do
    ip = "10.0.#{rem(System.unique_integer([:positive]), 250)}.#{:rand.uniform(250)}"

    Map.merge(
      %{
        # struct/2, not a %Actor{} literal: a literal is expanded at compile time
        # and fails the whole test run on a core without PhoenixKit.API.Actor.
        actor: struct(Actor, kind: :anonymous, ip: ip, cart_token_hash: nil),
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

  defp batch!(input, overrides \\ []) do
    assert {:ok, out} = Search.search_products_batch(input, ctx(overrides))
    out
  end

  defp item_ids(out), do: Enum.map(out["items"], & &1["id"])

  test "answers with cards, facets, an exact count and the language and currency used", t do
    out = search!(%{"q" => "vase"})

    assert out["count"] == 3
    assert out["match_mode"] == "fulltext"
    assert out["language"] == "en"
    assert out["currency"] == "USD"
    assert item_ids(out) |> Enum.take(2) |> Enum.sort() == Enum.sort([t.a, t.c])
    assert List.last(item_ids(out)) == t.e
    refute Map.has_key?(out, "next_cursor")
    refute Map.has_key?(out, "warnings")

    item = Enum.find(out["items"], &(&1["id"] == t.a))
    assert item["title"] == "Red Ceramic Vase"
    assert item["price"] == %{"amount" => "20.00", "currency" => "USD"}
    assert item["url"] =~ "https://shop.test/"

    assert [%{"id" => vases, "name" => "Vases", "count" => 2}] =
             Enum.filter(out["facets"]["categories"], &(&1["name"] == "Vases"))

    assert vases == t.vases
    assert %{"value" => "Acme", "count" => 1} in out["facets"]["vendors"]
    assert out["facets"]["on_sale"] == 1
    assert out["facets"]["price"]["min"]["currency"] == "USD"
  end

  test "an unlisted category is not named in the facets, though its product is listed" do
    unlisted = legacy_category!(%{"en" => "Hush"}, %{status: "unlisted"})
    lamp = legacy_product!(%{"en" => "Hush Lamp"}, %{category_uuid: unlisted.uuid, price: "9.00"})
    {:ok, _} = Indexer.reindex_items([lamp.uuid])

    out = search!(%{"q" => "lamp"})

    assert lamp.uuid in item_ids(out)
    refute Enum.any?(out["facets"]["categories"], &(&1["id"] == unlisted.uuid))
  end

  test "a category hidden after the index was written is not named in the facets either", t do
    {:ok, _} = Shop.update_category(Shop.get_category(t.vases), %{status: "hidden"})

    out = search!(%{})

    # The index still holds the rows (the count is the index's), the facet does not name the category.
    assert out["count"] == 5
    names = Enum.map(out["facets"]["categories"], & &1["name"])
    assert names == ["Bowls"]
    # And the products in the hidden category are dropped from the items.
    assert Enum.sort(item_ids(out)) == Enum.sort([t.b, t.d, t.e])
  end

  test "the name of a hidden ancestor category cannot be found through q" do
    hidden = legacy_category!(%{"en" => "Zorblax"}, %{status: "hidden"})
    child = legacy_category!(%{"en" => "Plinth"}, %{parent_uuid: hidden.uuid})
    item = legacy_product!(%{"en" => "Quiet Lamp"}, %{category_uuid: child.uuid, price: "9.00"})
    {:ok, _} = Indexer.reindex_items([item.uuid])

    assert search!(%{"q" => "lamp"})["count"] == 1
    assert search!(%{"q" => "Zorblax"})["count"] == 0
  end

  test "no query browses the shop", t do
    out = search!(%{})

    assert out["match_mode"] == "browse"
    assert out["count"] == 5
    assert item_ids(out) == [t.b, t.c, t.e, t.a, t.d]

    options = out["facets"]["options"]
    assert Enum.map(options, & &1["key"]) == ["colour", "size"]
    assert Enum.map(options, & &1["label"]) == ["Colour", "Size"]
    size = Enum.find(options, &(&1["key"] == "size"))

    assert size["values"] == [
             %{"key" => "large", "label" => "Large", "count" => 1},
             %{"key" => "small", "label" => "Small", "count" => 1}
           ]
  end

  test "pages follow next_cursor to the end without repeating or skipping", t do
    first = search!(%{"limit" => 2})
    assert item_ids(first) == [t.b, t.c]
    assert first["count"] == 5

    second = search!(%{"limit" => 2, "cursor" => first["next_cursor"]})
    assert item_ids(second) == [t.e, t.a]

    third = search!(%{"limit" => 2, "cursor" => second["next_cursor"]})
    assert item_ids(third) == [t.d]
    refute Map.has_key?(third, "next_cursor")
  end

  test "fields limits the keys of an item, and always keeps the id" do
    out = search!(%{"fields" => ["title", "price"]})

    for item <- out["items"] do
      assert item |> Map.keys() |> Enum.sort() == ["id", "price", "title"]
    end
  end

  test "currency override: prices and the price filter are in the response currency", t do
    out = search!(%{"currency" => "EUR", "sort" => "price_asc"})
    assert item_ids(out) == [t.d, t.c, t.e, t.a, t.b]
    a = Enum.find(out["items"], &(&1["id"] == t.a))
    assert a["price"] == %{"amount" => "18.18", "currency" => "EUR"}
    assert out["currency"] == "EUR"

    # 20.00 USD is shown as 18.18 EUR: a maximum of 18.18 includes it, 18.17 does not.
    at_edge = search!(%{"currency" => "EUR", "price_max" => "18.18"})
    assert t.a in item_ids(at_edge)
    refute t.b in item_ids(at_edge)

    below = search!(%{"currency" => "EUR", "price_max" => "18.17"})
    refute t.a in item_ids(below)
    assert below["count"] == 3
  end

  test "a bad filter is a validation error with the path of every problem" do
    assert {:error, :validation_failed, _message, %{errors: errors}} =
             Search.search_products(
               %{"category_id" => "nope", "price_min" => "5", "price_max" => "1"},
               ctx()
             )

    assert Enum.map(errors, & &1.path) |> Enum.sort() == ["category_id", "price_min"]
  end

  describe "every filter of a query reaches the search" do
    # Each filter is asserted against the unfiltered answer (5 products), so a
    # filter that is parsed but dropped on the way to the query shows as 5.
    defp filtered(input) do
      out = search!(input)
      {Enum.sort(item_ids(out)), out["count"]}
    end

    test "category_id: a parent finds its whole subtree, a leaf only itself", t do
      assert search!(%{})["count"] == 5

      assert {ids, 3} = filtered(%{"category_id" => t.home})
      assert ids == Enum.sort([t.a, t.b, t.c])

      assert {ids, 2} = filtered(%{"category_id" => t.vases})
      assert ids == Enum.sort([t.a, t.c])

      assert {[id], 1} = filtered(%{"category_id" => t.bowls})
      assert id == t.b
    end

    test "options: values of one key are alternatives, different keys must all match", t do
      assert {ids, 2} = filtered(%{"options" => %{"size" => ["large", "small"]}})
      assert ids == Enum.sort([t.a, t.c])

      assert {[id], 1} = filtered(%{"options" => %{"size" => ["small"]}})
      assert id == t.c

      assert {[id], 1} =
               filtered(%{"options" => %{"size" => ["large", "small"], "colour" => ["red"]}})

      assert id == t.a

      assert {[], 0} =
               filtered(%{"options" => %{"size" => ["small"], "colour" => ["red"]}})
    end

    test "options: an unknown key or value is named in a warning with the valid ones", t do
      out = search!(%{"options" => %{"sise" => ["large"], "size" => ["large", "huge"]}})

      assert out["count"] == 0
      assert item_ids(out) == []

      assert [
               %{
                 "code" => "unknown_option_key",
                 "key" => "sise",
                 "valid_keys" => ["colour", "size"]
               },
               %{
                 "code" => "unknown_option_value",
                 "key" => "size",
                 "values" => ["huge"],
                 "valid_values" => ["large", "small"]
               }
             ] = warnings = out["warnings"]

      assert Enum.all?(warnings, &is_binary(&1["message"]))
      assert {:ok, _} = Validator.validate(Search.search_output_schema(), out)

      # A typo among alternatives still finds the rest.
      out = search!(%{"options" => %{"size" => ["large", "huge"]}})
      assert item_ids(out) == [t.a]
      assert [%{"code" => "unknown_option_value", "values" => ["huge"]}] = out["warnings"]
    end

    test "options: known keys and values, an empty result among them included, add no warning" do
      assert {[], 0} = filtered(%{"options" => %{"size" => ["small"], "colour" => ["red"]}})
      refute Map.has_key?(search!(%{"options" => %{"size" => ["small"]}}), "warnings")
      refute Map.has_key?(search!(%{}), "warnings")
    end

    test "options: the valid keys are those of the answer's language, and the batch warns per query" do
      out =
        batch!(%{
          "queries" => [
            %{"options" => %{"nope" => ["x"]}},
            %{"options" => %{"size" => ["small"]}}
          ]
        })

      assert [first, second] = out["results"]
      assert [%{"code" => "unknown_option_key", "key" => "nope"}] = first["warnings"]
      refute Map.has_key?(second, "warnings")
    end

    test "vendor matches whatever the case", t do
      assert {[id], 1} = filtered(%{"vendor" => "acme"})
      assert id == t.a

      assert {[id], 1} = filtered(%{"vendor" => "BETA"})
      assert id == t.b
    end

    test "on_sale true keeps the products with a sale price, false the others", t do
      assert {[id], 1} = filtered(%{"on_sale" => true})
      assert id == t.a

      assert {ids, 4} = filtered(%{"on_sale" => false})
      assert ids == Enum.sort([t.b, t.c, t.d, t.e])
    end

    test "made_to_order keeps the products made to order", t do
      assert {[id], 1} = filtered(%{"made_to_order" => true})
      assert id == t.c

      assert {ids, 4} = filtered(%{"made_to_order" => false})
      assert ids == Enum.sort([t.a, t.b, t.d, t.e])
    end

    test "price_min and price_max bound the price from both sides", t do
      assert {ids, 3} = filtered(%{"price_min" => "15"})
      assert ids == Enum.sort([t.a, t.b, t.e])

      assert {ids, 2} = filtered(%{"price_min" => 15, "price_max" => "20"})
      assert ids == Enum.sort([t.a, t.e])
    end

    test "a filter combines with q", t do
      assert {[id], 1} = filtered(%{"q" => "vase", "vendor" => "acme"})
      assert id == t.a
    end

    test "search_products_batch applies the filters of a query and leaves the others alone", t do
      out =
        batch!(%{
          "queries" => [
            %{"category_id" => t.vases, "on_sale" => true, "price_min" => 5},
            %{"vendor" => "beta"},
            %{}
          ]
        })

      assert [filtered_block, vendor_block, plain] = out["results"]

      assert item_ids(filtered_block) == [t.a]
      assert filtered_block["count"] == 1
      assert item_ids(vendor_block) == [t.b]
      assert plain["count"] == 5
    end

    test "a price above the ceiling is a validation error, not a Decimal" do
      assert {:error, :validation_failed, _, %{errors: errors}} =
               Search.search_products(%{"price_max" => 10 ** 40, "price_min" => "1e400"}, ctx())

      assert errors |> Enum.map(& &1.path) |> Enum.sort() == ["price_max", "price_min"]
    end
  end

  test "a host language 'de' finds products indexed under the dialect 'de-DE'" do
    enable_languages!(["en-US", "de-DE"])
    g = legacy_product!(%{"en-US" => "Plain Vase", "de-DE" => "Rote Vasen"})
    {:ok, _} = Indexer.reindex_items([g.uuid])

    out = search!(%{"q" => "Vase"}, language: "de")

    assert out["language"] == "de-DE"
    assert item_ids(out) == [g.uuid]
    assert hd(out["items"])["title"] == "Rote Vasen"
  end

  describe "item urls on a mapped domain" do
    setup do
      enable_languages!(["en-US", "de-DE"])
      {:ok, _} = Settings.update_boolean_setting("default_language_no_prefix", true)

      product = legacy_product!(%{"en-US" => "Plain Vase", "de-DE" => "Rote Vasen"})
      {:ok, _} = Indexer.reindex_items([product.uuid])

      %{product: product}
    end

    defp item_url(out, product) do
      Enum.find(out["items"], &(&1["id"] == product.uuid))["url"]
    end

    test "search_products links to the language of the domain without a locale prefix", t do
      url = %{"q" => "Vase"} |> search!(language: "de") |> item_url(t.product)

      assert url =~ "https://shop.test/shop/product/"
      refute url =~ "/de/"
    end

    test "search_products links to an explicitly asked other language with its prefix", t do
      url =
        %{"q" => "Vase", "language" => "en"} |> search!(language: "de") |> item_url(t.product)

      assert url =~ "https://shop.test/en/shop/product/"
    end

    test "search_products_batch links to the language of the domain without a prefix", t do
      assert %{"results" => [block]} =
               batch!(%{"queries" => [%{"q" => "Vase"}]}, language: "de")

      url = item_url(block, t.product)
      assert url =~ "https://shop.test/shop/product/"
      refute url =~ "/de/"
    end

    test "search_products_batch links to an explicitly asked other language with its prefix",
         t do
      assert %{"results" => [block]} =
               batch!(%{"language" => "en", "queries" => [%{"q" => "Vase"}]}, language: "de")

      assert item_url(block, t.product) =~ "https://shop.test/en/shop/product/"
    end

    @tag :requires_core_canonical_urls
    test "search_products links to a language that has a domain on that domain, whoever asks",
         t do
      put_canonical_host_resolver!()

      from_the_other_domain = search!(%{"q" => "Vase", "language" => "de"}, language: "en")
      from_its_own_domain = search!(%{"q" => "Vase"}, language: "de")

      for out <- [from_the_other_domain, from_its_own_domain] do
        url = item_url(out, t.product)
        assert url =~ "https://shop.example.de/shop/product/"
        refute url =~ "/de/"
      end
    end

    @tag :requires_core_canonical_urls
    test "search_products_batch links to a language that has a domain on that domain", t do
      put_canonical_host_resolver!()

      assert %{"results" => [from_the_other_domain]} =
               batch!(%{"language" => "de", "queries" => [%{"q" => "Vase"}]}, language: "en")

      assert %{"results" => [from_its_own_domain]} =
               batch!(%{"queries" => [%{"q" => "Vase"}]}, language: "de")

      for block <- [from_the_other_domain, from_its_own_domain] do
        url = item_url(block, t.product)
        assert url =~ "https://shop.example.de/shop/product/"
        refute url =~ "/de/"
      end
    end
  end

  test "fields takes at most as many names as an item has fields" do
    all = Cards.list_fields()
    too_many = ["title" | all]

    assert {:ok, _} = Validator.validate(Search.search_input_schema(), %{"fields" => all})

    assert {:error, [%{path: "fields"}]} =
             Validator.validate(Search.search_input_schema(), %{"fields" => too_many})

    assert {:error, [%{path: "queries[0].fields"}]} =
             Validator.validate(Search.batch_input_schema(), %{
               "queries" => [%{"fields" => too_many}]
             })
  end

  test "a limit above 100 is trimmed with a warning, not refused" do
    out = search!(%{"limit" => 500})

    assert [%{"code" => "limit_trimmed", "requested" => 500}] = out["warnings"]
    assert length(out["items"]) == 5
  end

  test "a tampered cursor, an unknown language and an unknown currency are validation errors" do
    assert {:error, :validation_failed, _, %{errors: [%{path: "cursor"}]}} =
             Search.search_products(%{"cursor" => "@@"}, ctx())

    assert {:error, :validation_failed, _, %{errors: [%{path: "language", allowed: ["en"]}]}} =
             Search.search_products(%{"language" => "xx"}, ctx())

    assert {:error, :validation_failed, _, %{errors: [%{path: "currency"}]}} =
             Search.search_products(%{"currency" => "XXX"}, ctx())
  end

  test "a product hidden after the index was written is never shown", t do
    {:ok, _} = Shop.update_product(Shop.get_product!(t.a), %{status: "draft"})

    # The index still holds the row (it is a few seconds behind); the card build does not.
    out = search!(%{"q" => "vase"})

    refute t.a in item_ids(out)
    assert Enum.sort(item_ids(out)) == Enum.sort([t.c, t.e])

    {:ok, _} = Indexer.reindex_items([t.a])
    assert search!(%{"q" => "vase"})["count"] == 2
  end

  test "hostile text is answered, never raised" do
    hostile =
      ["\"", "\"open", "-", "or", "the", "!!!", "a\0b", "'; DROP TABLE x; --", "😀", "%"] ++
        [String.duplicate("-", 40), String.duplicate("- ", 40) <> "a", String.duplicate("-(", 20)]

    for q <- hostile do
      assert {:ok, %{"count" => count}} = Search.search_products(%{"q" => q}, ctx())
      assert is_integer(count), inspect(q)
    end
  end

  describe "facets: false" do
    test "leaves the facet block out and keeps the rest of the answer", t do
      full = search!(%{"q" => "vase"})
      lean = search!(%{"q" => "vase", "facets" => false})

      assert Map.has_key?(full, "facets")
      refute Map.has_key?(lean, "facets")
      assert Map.delete(full, "facets") == lean
      assert item_ids(lean) |> Enum.sort() == Enum.sort([t.a, t.c, t.e])
    end

    test "true is the default" do
      assert search!(%{"facets" => true}) == search!(%{})
    end

    test "does not read the matched rows for the facets" do
      search!(%{})
      with_facets = count_queries(fn -> search!(%{"limit" => 1}) end)
      without = count_queries(fn -> search!(%{"limit" => 1, "facets" => false}) end)

      assert without == with_facets - 1
    end

    test "limit 1 without facets is a small answer" do
      full = search!(%{"limit" => 1}) |> JSON.encode!() |> byte_size()
      lean = search!(%{"limit" => 1, "facets" => false}) |> JSON.encode!() |> byte_size()

      assert lean < full
      assert lean < 3_000
    end

    test "the answer satisfies the output schema" do
      assert {:ok, _} =
               Validator.validate(
                 Search.search_output_schema(),
                 search!(%{"limit" => 1, "facets" => false})
               )
    end

    test "is refused when it is not a boolean" do
      assert {:error, :validation_failed, _, %{errors: [%{path: "facets"}]}} =
               Search.search_products(%{"facets" => "no"}, ctx())

      assert {:error, [%{path: "facets"}]} =
               Validator.validate(Search.search_input_schema(), %{"facets" => "no"})
    end

    test "the batch honours it per query", t do
      out =
        batch!(%{
          "queries" => [
            %{"q" => "vase", "facets" => false},
            %{"q" => "vase"},
            %{"category_id" => t.bowls, "facets" => false}
          ]
        })

      assert [lean, full, bowls] = out["results"]
      refute Map.has_key?(lean, "facets")
      assert Map.has_key?(full, "facets")
      refute Map.has_key?(bowls, "facets")
      assert lean["count"] == 3 and bowls["count"] == 1

      assert {:ok, _} = Validator.validate(Search.batch_output_schema(), out)

      assert {:ok, _} =
               Validator.validate(Search.batch_input_schema(), %{
                 "queries" => [%{"facets" => false}]
               })
    end
  end

  test "the answer is plain JSON and satisfies its own output schema" do
    out = search!(%{"q" => "vase", "limit" => 2})

    assert out == out |> JSON.encode!() |> JSON.decode!()
    assert {:ok, _} = Validator.validate(Search.search_output_schema(), out)
  end

  describe "search_products_batch/2" do
    test "answers every query in order and echoes the ref", t do
      out =
        batch!(%{
          "queries" => [%{"ref" => "q1", "q" => "vase"}, %{"q" => "bowl"}, %{"q" => "zzzzqqqq"}]
        })

      assert out["count"] == 3
      assert [first, second, third] = out["results"]

      assert first["index"] == 0 and first["ref"] == "q1" and first["count"] == 3
      assert second["index"] == 1 and not Map.has_key?(second, "ref")
      assert item_ids(second) == [t.b]
      assert third["index"] == 2 and third["count"] == 0 and third["items"] == []
    end

    test "a batch builds at most its card budget: later queries are trimmed with a warning" do
      assert {:ok, out} =
               Search.search_products_batch(
                 %{"queries" => List.duplicate(%{"limit" => 5}, 3)},
                 ctx(),
                 6
               )

      assert [first, second, third] = out["results"]

      assert length(first["items"]) == 5
      refute Map.has_key?(first, "warnings")

      for block <- [second, third] do
        assert length(block["items"]) == 1
        assert [%{"code" => "batch_limit_trimmed", "applied" => 1}] = block["warnings"]
      end
    end

    test "a query without a limit gets 10 products, one with a limit gets what it asks" do
      for n <- 1..12 do
        product = legacy_product!(%{"en" => "Bulk Item #{n}"}, %{vendor: "Bulk"})
        {:ok, _} = Indexer.reindex_items([product.uuid])
      end

      out =
        batch!(%{
          "queries" => [
            %{"vendor" => "Bulk"},
            %{"vendor" => "Bulk", "limit" => 12},
            %{"vendor" => "Bulk", "limit" => 3}
          ]
        })

      assert [default, twelve, three] = out["results"]
      assert {length(default["items"]), default["count"]} == {10, 12}
      assert is_binary(default["next_cursor"])
      assert {length(twelve["items"]), twelve["count"]} == {12, 12}
      assert length(three["items"]) == 3

      # A single search keeps its own default of 20.
      assert length(search!(%{"vendor" => "Bulk"})["items"]) == 12
    end

    test "a query that raises is an internal_error block; the others run, and the log names only the exception" do
      stage_tsquery_failure!("57014", "canceling statement due to statement timeout")

      log =
        capture_log(fn ->
          out =
            batch!(%{
              "queries" => [
                %{"ref" => "ok-1"},
                %{"ref" => "boom", "q" => "vase"},
                %{"ref" => "ok-2"}
              ]
            })

          assert [first, second, third] = out["results"]
          assert first["count"] == 5 and third["count"] == 5
          assert second["ref"] == "boom"

          assert second["error"] == %{
                   "code" => "internal_error",
                   "message" => "This query failed unexpectedly.",
                   "context" => %{}
                 }

          refute Map.has_key?(second, "items")
          assert [%{"index" => 0}, %{"index" => 1}, %{"index" => 2}] = out["results"]
        end)

      assert log =~ "a batch query failed: ** (Postgrex.Error)"
      refute log =~ "vase"
      refute log =~ "statement timeout"
    end

    test "trim_to_budget/3 trims a limit to what is left of the batch budget, never below 1" do
      assert {%{limit: 100}, []} = Search.trim_to_budget(%{limit: 100}, [], nil)
      assert {%{limit: 10}, []} = Search.trim_to_budget(%{limit: 10}, [], 30)

      assert {%{limit: 30}, [warning]} = Search.trim_to_budget(%{limit: 100}, [], 30)
      assert warning["code"] == "batch_limit_trimmed"
      assert warning["requested"] == 100 and warning["applied"] == 30

      assert {%{limit: 1}, [%{"applied" => 1}]} = Search.trim_to_budget(%{limit: 20}, [], 0)
    end

    test "one bad query is an error block and does not spoil the others" do
      out =
        batch!(%{
          "queries" => [
            %{"q" => "vase"},
            %{"ref" => "bad", "category_id" => "nope"},
            %{"q" => "bowl"}
          ]
        })

      assert [ok_a, bad, ok_b] = out["results"]
      assert ok_a["count"] == 3 and ok_b["count"] == 1

      assert %{"ref" => "bad", "error" => error} = bad
      assert error["code"] == "validation_failed"
      assert [%{"path" => "queries[1].category_id"}] = error["context"]["errors"]
      refute Map.has_key?(bad, "items")
    end

    test "currency and language apply to every query" do
      out = batch!(%{"currency" => "EUR", "queries" => [%{"q" => "spoon"}]})

      assert [%{"items" => [item], "currency" => "EUR"}] = out["results"]
      assert item["price"]["currency"] == "EUR"
    end

    test "batch_cost/1 prices a raw, unvalidated batch by its number of queries" do
      # The executor calls it BEFORE validation: it must
      # answer a positive integer for any term and never raise.
      assert Search.batch_cost(%{"queries" => List.duplicate(%{}, 7)}) == 7
      assert Search.batch_cost(%{"queries" => List.duplicate(%{}, 20)}) == 20
      assert Search.batch_cost(%{"queries" => [%{}]}) == 1
      assert Search.batch_cost(%{"queries" => []}) == 1
      # Over the cap the call is refused with 422; it is charged the cap, not 500.
      assert Search.batch_cost(%{"queries" => List.duplicate(%{}, 500)}) == 20

      for junk <- [
            %{},
            %{"queries" => "junk"},
            %{"queries" => %{"a" => 1}},
            %{"queries" => nil},
            nil,
            42,
            "x",
            []
          ] do
        assert Search.batch_cost(junk) == 1, inspect(junk)
      end
    end

    test "the batch answer is plain JSON and satisfies its output schema" do
      out = batch!(%{"queries" => [%{"q" => "vase"}, %{"category_id" => "nope"}]})

      assert out == out |> JSON.encode!() |> JSON.decode!()
      assert {:ok, _} = Validator.validate(Search.batch_output_schema(), out)
    end
  end

  test "a q over 200 characters is refused by the input schema; the handler alone truncates it" do
    long = String.duplicate("vase ", 2_000)

    assert {:error, [%{path: "q"}]} =
             Validator.validate(Search.search_input_schema(), %{"q" => long})

    assert {:ok, %{"count" => count}} = Search.search_products(%{"q" => long}, ctx())
    assert is_integer(count)
  end

  test "the input schemas accept what the handlers read and close the object" do
    assert {:ok, _} =
             Validator.validate(Search.search_input_schema(), %{
               "q" => "vase",
               "limit" => 5,
               "options" => %{"size" => ["large"]},
               "price_min" => 1,
               "price_max" => "20.50",
               "fields" => ["title"],
               "language" => "en",
               "currency" => "USD"
             })

    assert {:error, [%{path: "limit"}]} =
             Validator.validate(Search.search_input_schema(), %{"limit" => 0})

    assert {:error, [%{path: "fields[0]"}]} =
             Validator.validate(Search.search_input_schema(), %{
               "fields" => ["cost_per_item"]
             })

    queries = List.duplicate(%{}, 21)

    assert {:error, [%{path: "queries"}]} =
             Validator.validate(Search.batch_input_schema(), %{
               "queries" => queries
             })
  end
end
