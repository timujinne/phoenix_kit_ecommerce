defmodule PhoenixKitEcommerce.Search.QueryTest do
  @moduledoc """
  `Search.Query` over a small shop indexed through the real indexer.

      Home
      |- Vases:  Red Ceramic Vase (Acme, gift, 20.00, was 25.00, size Large + colour Red)
      |          Green Vase Small (10.00, made to order, size Small)
      |- Bowls:  Blue Glass Bowl (Beta, 35.00)
      (none):    Wooden Spoon (gift, 5.00, description "handmade from oak")
                 Plant Stand (15.00, description "A stand for a vase")

  The typo fallback has its own module (it flips a global cache).
  """
  use PhoenixKitEcommerce.DataCase, async: true

  import ExUnit.CaptureLog
  import PhoenixKitEcommerce.SearchFixtures

  alias PhoenixKitEcommerce.Search.Indexer
  alias PhoenixKitEcommerce.Search.Query
  alias PhoenixKitEcommerce.Test.Repo

  setup do
    disable_languages!()
    sample_shop!()
  end

  defp run(params, language \\ "en"), do: Query.run(params, language)
  defp ids(params, language \\ "en"), do: params |> run(language) |> Map.fetch!(:ids)

  test "browse lists every product, by position then title, with an exact count", t do
    result = run(%{})

    assert result.mode == :browse
    assert result.count == 5
    assert result.ids == [t.b, t.c, t.e, t.a, t.d]
    refute result.truncated?
    refute result.refused?
  end

  test "browse puts the catalogue position before the title", t do
    # Blue Glass Bowl is first by title; position 5 sends it last, and a
    # negative position goes before everything.
    set_position!(t.b, 5)
    set_position!(t.d, -1)

    assert ids(%{}) == [t.d, t.c, t.e, t.a, t.b]
  end

  defp set_position!(item_uuid, position) do
    Repo.query!(
      "UPDATE phoenix_kit_shop_search_index SET sort_position = $2 WHERE item_uuid = $1",
      [Ecto.UUID.dump!(item_uuid), position]
    )
  end

  test "full text finds a title match, and ranks it above a description match", t do
    result = run(%{q: "vase"})

    assert result.mode == :fulltext
    assert result.count == 3
    assert result.ids |> Enum.take(2) |> Enum.sort() == Enum.sort([t.a, t.c])
    assert List.last(result.ids) == t.e
  end

  test "full text reads vendor, tags, category names, option labels and descriptions", t do
    assert ids(%{q: "acme"}) == [t.a]
    assert ids(%{q: "gift"}) |> Enum.sort() == Enum.sort([t.a, t.d])
    assert ids(%{q: "bowls"}) == [t.b]
    assert ids(%{q: "large"}) == [t.a]
    assert ids(%{q: "colour"}) == [t.a]
    assert ids(%{q: "oak"}) == [t.d]
  end

  test "the language's stemming applies: a plural finds the singular", t do
    # :fulltext, not :typo: the pg_trgm fallback would find these rows too.
    result = run(%{q: "vases"})
    assert result.mode == :fulltext
    assert Enum.sort(result.ids) == Enum.sort([t.a, t.c, t.e])
  end

  test "a query uses the configuration of the requested language (en, de, fr)" do
    enable_languages!(["en", "de", "fr"])

    g =
      legacy_product!(%{
        "en" => "Plain Vase",
        "de" => "Rote Vasen",
        "fr" => "Grandes assiettes"
      })

    {:ok, _} = Indexer.reindex_items([g.uuid])

    # Each answer must be :fulltext, not :typo: the pg_trgm fallback finds a
    # near spelling with any configuration, so only the mode tells that the
    # query was parsed with the language's own one.
    assert %{mode: :fulltext, ids: [id]} = run(%{q: "Vase"}, "de")
    assert id == g.uuid
    assert %{mode: :fulltext, ids: ids_en} = run(%{q: "Vase"}, "en")
    assert g.uuid in ids_en
    assert %{mode: :fulltext, ids: [id]} = run(%{q: "assiette"}, "fr")
    assert id == g.uuid
    refute g.uuid in ids(%{q: "assiette"}, "en")
  end

  test "hostile text never raises: quotes, operators, stop words, SQL, NUL, emoji, huge input" do
    hostile = [
      "\"",
      "\"unbalanced",
      "-",
      "or",
      "the",
      "!!!",
      "'; DROP TABLE phoenix_kit_shop_search_index; --",
      "%",
      "_",
      "\\",
      "((((",
      "a & | b",
      "a\0b",
      "😀",
      String.duplicate("a", 10_000),
      # 33 or more nested negations: `tsquery stack too small` (XX000) in
      # websearch_to_tsquery unless clean_q/1 neutralises the dashes
      String.duplicate("-", 40),
      String.duplicate("- ", 40) <> "a",
      String.duplicate("-(", 20),
      # a dash before a quote is a real negation and survives clean_q/1
      String.duplicate(~s|-"|, 100),
      String.duplicate(~s|-"vase |, 25),
      String.duplicate(~s|-"vase -|, 25),
      # invalid UTF-8 and one grapheme made of 100 000 code points
      <<"va", 0xFF, "se">>,
      "a" <> String.duplicate(<<0xCC, 0x81>>, 100_000)
    ]

    for q <- hostile do
      assert %{count: count, ids: ids} = run(%{q: q}), "q=#{inspect(q, limit: 20)}"
      assert is_integer(count) and is_list(ids)
    end

    assert run(%{}).count == 5
  end

  test "the cleaning happens before Postgres sees the text, not by rescuing its refusal" do
    # Without clean_q/1 both texts make Postgres raise; the rescue in the probe
    # would turn that into an empty, `refused?` answer, which these assertions
    # tell apart from the real ones.
    assert %{mode: :browse, count: 5, refused?: false} = run(%{q: String.duplicate("-", 40)})
    assert %{mode: :fulltext, count: 3, refused?: false} = run(%{q: "va\0se"})

    assert %{mode: :fulltext, count: 3, refused?: false} =
             run(%{q: String.duplicate("- ", 40) <> "vase"})
  end

  test "clean_q/1 removes NUL bytes, trims, caps the length and turns blank into no query" do
    assert Query.clean_q("  vase ") == "vase"
    assert Query.clean_q("va\0se") == "vase"
    assert Query.clean_q("") == nil
    assert Query.clean_q("   ") == nil
    assert Query.clean_q("\0") == nil
    assert Query.clean_q(nil) == nil
    assert Query.clean_q(42) == nil
    assert String.length(Query.clean_q(String.duplicate("a", 300))) == 200
  end

  test "clean_q/1 caps code points, not graphemes, and scrubs invalid UTF-8" do
    # one base letter plus combining acute accents is ONE grapheme
    zalgo = "a" <> String.duplicate("\u0301", 100_000)

    assert String.length(zalgo) == 1
    assert zalgo |> Query.clean_q() |> String.codepoints() |> length() == 200

    assert Query.clean_q(<<"va", 0xFF, "se">>) == "vase"
    assert Query.clean_q(<<0xFF, 0xFE>>) == nil
  end

  test "an exclusion of a quoted phrase is kept by clean_q/1 and excludes the phrase", t do
    assert Query.clean_q(~s|vase -"red ceramic"|) == ~s|vase -"red ceramic"|
    assert Query.clean_q(~s|-"|) == ~s|-"|

    # `vase "red ceramic"` is the positive twin: it finds the product to exclude
    assert ids(%{q: ~s|vase "red ceramic"|}) == [t.a]

    result = run(%{q: ~s|vase -"red ceramic"|})
    assert result.mode == :fulltext
    assert Enum.sort(result.ids) == Enum.sort([t.c, t.e])
    refute t.a in result.ids
  end

  test "clean_q/1 keeps a dash that negates or joins a word and drops the others" do
    assert Query.clean_q("-vase") == "-vase"
    assert Query.clean_q("red -vase") == "red -vase"
    assert Query.clean_q("co-op") == "co-op"
    assert Query.clean_q("-") == nil
    assert Query.clean_q(String.duplicate("-", 40)) == nil
    assert Query.clean_q("a - b") == "a   b"
    assert Query.clean_q("-(") == "("
    refute Query.clean_q(String.duplicate("-(", 20)) =~ "-"
  end

  describe "when Postgres refuses the text" do
    # Nothing a caller can send reaches this branch (clean_q/1 sees to that),
    # so the refusal is staged (see `stage_tsquery_failure!/2`).
    test "a tsquery stack overflow answers empty and flagged, logging the SQLSTATE only" do
      stage_tsquery_failure!("XX000", "tsquery stack too small")

      log =
        capture_log(fn ->
          assert %{ids: [], count: 0, mode: :fulltext, refused?: true} = run(%{q: "vase"})
        end)

      assert log =~ "SQLSTATE XX000"
      refute log =~ "secret detail"
      refute log =~ "stack too small"

      # the connection is still usable afterwards
      assert %{count: 5, refused?: false} = run(%{})
    end

    test "invalid bytes (22021) are a refusal too" do
      stage_tsquery_failure!("22021", "invalid byte sequence for encoding")

      capture_log(fn -> assert %{count: 0, refused?: true} = run(%{q: "vase"}) end)
    end

    test "every other database error is raised, not turned into an empty answer" do
      stage_tsquery_failure!("57014", "canceling statement due to statement timeout")
      assert_raise Postgrex.Error, fn -> run(%{q: "vase"}) end

      # XX000 alone is not enough: only the tsquery stack message is a refusal
      Repo.query!("DROP FUNCTION search_refusal_stub.websearch_to_tsquery(regconfig, text)")
      Repo.query!("DROP SCHEMA search_refusal_stub")
      stage_tsquery_failure!("XX000", "something else broke")
      assert_raise Postgrex.Error, fn -> run(%{q: "vase"}) end
    end

    test "a filter with no search text does not run the probe at all" do
      stage_tsquery_failure!("57014", "never called")
      assert %{count: 5, mode: :browse, refused?: false} = run(%{})
    end
  end

  test "the category filter takes the whole branch", t do
    assert ids(%{category_id: t.home}) == [t.b, t.c, t.a]
    assert ids(%{category_id: t.vases}) == [t.c, t.a]
    assert ids(%{category_id: t.bowls}) == [t.b]
    assert ids(%{category_id: Ecto.UUID.generate()}) == []
  end

  test "price bounds are inclusive; vendor ignores case; flags can be true or false", t do
    assert ids(%{price_min: Decimal.new("10"), price_max: Decimal.new("20")}) == [t.c, t.e, t.a]
    assert ids(%{price_min: Decimal.new("20")}) == [t.b, t.a]
    assert ids(%{price_max: Decimal.new("5")}) == [t.d]
    assert ids(%{vendor: "acme"}) == [t.a]
    assert ids(%{on_sale: true}) == [t.a]
    assert ids(%{on_sale: false}) == [t.b, t.c, t.e, t.d]
    assert ids(%{made_to_order: true}) == [t.c]
    assert ids(%{made_to_order: false}) == [t.b, t.e, t.a, t.d]
  end

  test "a price-on-request product leaks no price through filters, sorts or the price facet", t do
    secret =
      legacy_product!(%{"en" => "Secret Vase"}, %{
        price: "777.00",
        compare_at_price: "900.00",
        metadata: %{"_price_display" => %{"on_request" => true}}
      })

    {:ok, _} = Indexer.reindex_items([secret.uuid])

    row = Query.entry(secret.uuid, "en")
    assert row.price == nil and row.compare_at_price == nil and row.discount_pct == nil
    assert row.on_sale == false

    # still listed ...
    assert secret.uuid in ids(%{})
    assert secret.uuid in ids(%{q: "secret"})

    # ... but invisible to every price device
    refute secret.uuid in ids(%{price_min: Decimal.new("700")})
    refute secret.uuid in ids(%{price_max: Decimal.new("800")})
    assert {_min, max} = run(%{}).facets.price
    assert Decimal.equal?(max, Decimal.new("35.00"))
    assert List.last(ids(%{sort: :price_desc})) == secret.uuid
    assert List.last(ids(%{sort: :price_asc})) == secret.uuid
    assert hd(ids(%{sort: :price_desc})) == t.b
  end

  test "options are OR within a key and AND across keys", t do
    assert ids(%{options: %{"size" => ["large", "small"]}}) == [t.c, t.a]
    assert ids(%{options: %{"size" => ["large"], "colour" => ["red"]}}) == [t.a]
    assert ids(%{options: %{"size" => ["large"], "colour" => ["blue"]}}) == []
    assert ids(%{options: %{"nonsense" => ["x"]}}) == []
  end

  test "filters combine with each other and with a query", t do
    assert ids(%{category_id: t.vases, price_max: Decimal.new("15")}) == [t.c]
    assert ids(%{q: "vase", category_id: t.vases}) |> Enum.sort() == Enum.sort([t.a, t.c])
    assert ids(%{q: "vase", vendor: "nobody"}) == []
  end

  test "sorts", t do
    assert ids(%{sort: :price_asc}) == [t.d, t.c, t.e, t.a, t.b]
    assert ids(%{sort: :price_desc}) == [t.b, t.a, t.e, t.c, t.d]
    assert ids(%{sort: :discount_desc}) == [t.a, t.b, t.c, t.e, t.d]
  end

  test "discount_desc puts the larger discount first, whichever product was created first", t do
    small = legacy_product!(%{"en" => "Small Sale"}, %{price: "9.00", compare_at_price: "10.00"})
    big = legacy_product!(%{"en" => "Big Sale"}, %{price: "5.00", compare_at_price: "10.00"})
    {:ok, _} = Indexer.reindex_items([small.uuid, big.uuid])

    assert ids(%{sort: :discount_desc}) == [big.uuid, t.a, small.uuid, t.b, t.c, t.e, t.d]
  end

  describe "field weights" do
    # One word, `zephyr`, in one field of each product. The titles run against
    # the expected order (Bravo, Charlie, Delta, Zephyr), so a tie in rank
    # would put the products in the opposite order.
    test "the same word ranks by the field it is in: title, vendor, option label, description" do
      description = legacy_product!(%{"en" => "Bravo Lamp"}, %{description: %{"en" => "zephyr"}})

      option =
        legacy_product!(%{"en" => "Charlie Lamp"}, %{
          metadata: %{"_option_values" => %{"size" => ["Zephyr"]}}
        })

      vendor = legacy_product!(%{"en" => "Delta Lamp"}, %{vendor: "Zephyr"})
      title = legacy_product!(%{"en" => "Zephyr Lamp"})

      {:ok, _} =
        [description, option, vendor, title] |> Enum.map(& &1.uuid) |> Indexer.reindex_items()

      assert %{mode: :fulltext, count: 4} = run(%{q: "zephyr"})
      assert ids(%{q: "zephyr"}) == Enum.map([title, vendor, option, description], & &1.uuid)
    end
  end

  test "newest sorts by the product's creation time", t do
    for {id, days} <- [{t.a, 0}, {t.b, 1}, {t.c, 2}, {t.d, 3}, {t.e, 4}] do
      Repo.query!(
        """
        UPDATE phoenix_kit_shop_search_index
        SET item_inserted_at = now() - ($2::int * interval '1 day') WHERE item_uuid = $1
        """,
        [Ecto.UUID.dump!(id), days]
      )
    end

    assert ids(%{sort: :newest}) == [t.a, t.b, t.c, t.d, t.e]
  end

  test "pages keep their order and the count stays exact", t do
    assert run(%{limit: 2, offset: 0}) |> Map.take([:ids, :count]) == %{ids: [t.b, t.c], count: 5}
    assert run(%{limit: 2, offset: 2}) |> Map.take([:ids, :count]) == %{ids: [t.e, t.a], count: 5}
    assert run(%{limit: 2, offset: 4}) |> Map.take([:ids, :count]) == %{ids: [t.d], count: 5}
    assert run(%{limit: 2, offset: 6}) |> Map.take([:ids, :count]) == %{ids: [], count: 5}
  end

  test "facets describe the matched set", t do
    facets = run(%{}).facets

    assert facets.categories == %{t.vases => 2, t.bowls => 1}
    assert facets.vendors == %{"Acme" => 1, "Beta" => 1}
    assert facets.on_sale == 1
    assert facets.made_to_order == 1
    assert {min, max} = facets.price
    assert Decimal.equal?(min, Decimal.new("5.00"))
    assert Decimal.equal?(max, Decimal.new("35.00"))

    assert Enum.map(facets.options, &{&1.pair, &1.label, &1.set_label, &1.count}) == [
             {"colour:red", "Red", "Colour", 1},
             {"size:large", "Large", "Size", 1},
             {"size:small", "Small", "Size", 1}
           ]
  end

  test "facets: false skips the facets and changes nothing else", t do
    lean = run(%{facets: false})
    full = run(%{})

    assert lean.facets == nil
    refute lean.truncated?
    assert Map.drop(lean, [:facets]) == Map.drop(full, [:facets])
    assert run(%{}).facets == run(%{facets: true}).facets
    assert t.vases in Map.keys(full.facets.categories)
  end

  test "option_vocabulary lists the option keys and values the index holds in a language" do
    assert Query.option_vocabulary("en") == %{
             "colour" => ["red"],
             "size" => ["large", "small"]
           }

    assert Query.option_vocabulary("de") == %{}
  end

  test "option facets are ordered by key, then by count (highest first), then by value" do
    cup =
      legacy_product!(%{"en" => "Small Cup"}, %{
        metadata: %{"_option_values" => %{"size" => ["Small"]}}
      })

    {:ok, _} = Indexer.reindex_items([cup.uuid])

    # Two "small" against one "large": the more common value goes first, which
    # is the opposite of the order the map of counts happens to iterate in.
    assert run(%{}).facets.options |> Enum.map(&{&1.pair, &1.count}) == [
             {"colour:red", 1},
             {"size:small", 2},
             {"size:large", 1}
           ]
  end

  test "the facets read at most 5 000 rows and the result says when it cut them" do
    insert_rows!(1, 5_000)

    at_cap = run(%{limit: 1}, "xx")
    assert at_cap.count == 5_000
    refute at_cap.truncated?
    assert at_cap.facets.on_sale == 5_000

    insert_rows!(5_001, 5_001)

    over = run(%{limit: 1}, "xx")
    assert over.count == 5_001
    assert over.truncated?
    assert length(over.ids) == 1
    # counted over the capped 5 000 rows, not over all 5 001
    assert over.facets.on_sale == 5_000
  end

  defp insert_rows!(from, to) do
    Repo.query!(
      """
      INSERT INTO phoenix_kit_shop_search_index
        (item_uuid, language, title, title_trgm, document, on_sale)
      SELECT gen_random_uuid(), 'xx', 'Row ' || n, 'row ' || n, to_tsvector('simple', 'row'), true
      FROM generate_series($1::int, $2::int) AS n
      """,
      [from, to]
    )
  end

  test "facets follow the filters", t do
    facets = run(%{category_id: t.vases}).facets

    assert facets.categories == %{t.vases => 2}
    assert facets.vendors == %{"Acme" => 1}
    assert facets.on_sale == 1
    assert {min, max} = facets.price
    assert Decimal.equal?(min, Decimal.new("10.00"))
    assert Decimal.equal?(max, Decimal.new("20.00"))

    empty = run(%{category_id: Ecto.UUID.generate()}).facets
    assert empty.categories == %{}
    assert empty.price == nil
    assert empty.options == []
  end

  test "cursors are opaque offsets, and anything else is refused" do
    assert Query.decode_cursor(Query.encode_cursor(40)) == {:ok, 40}
    assert Query.decode_cursor(nil) == {:ok, 0}
    assert Query.decode_cursor("") == {:ok, 0}

    for bad <- [
          "!!!",
          "x",
          Base.url_encode64("o:-1", padding: false),
          Base.url_encode64("o:10001", padding: false),
          Base.url_encode64("x:5", padding: false),
          Base.url_encode64("o:5x", padding: false),
          # the same number written another way is not a cursor we issued
          Base.url_encode64("o:+5", padding: false),
          Base.url_encode64("o:005", padding: false),
          String.duplicate("A", 5_000)
        ] do
      assert Query.decode_cursor(bad) == :error, "cursor #{inspect(bad, limit: 20)}"
    end

    assert Query.decode_cursor(Query.encode_cursor(10_000)) == {:ok, 10_000}
  end

  test "next_cursor/3 exists only while there is a next page the cursor can reach" do
    assert Query.next_cursor(0, 20, 45) == Query.encode_cursor(20)
    assert Query.next_cursor(40, 20, 45) == nil
    assert Query.next_cursor(0, 20, 20) == nil
    assert Query.next_cursor(9_990, 20, 50_000) == nil
  end

  test "category_counts/1 counts the products directly in each category", t do
    assert Query.category_counts("en") == %{t.vases => 2, t.bowls => 1}
    assert Query.category_counts("de") == %{}
  end

  test "similar/2 ranks the same category first, then shared options and tags, and never the product itself",
       t do
    base = Query.entry(t.a, "en")

    assert base.item_uuid == t.a
    assert Query.similar(base, 10) == [t.c, t.d]
    assert Query.similar(base, 1) == [t.c]

    assert Query.entry(Ecto.UUID.generate(), "en") == nil
    assert Query.entry(t.a, "de") == nil

    # A product with nothing in common with anything has no similar products.
    assert Query.similar(Query.entry(t.b, "en"), 10) == []
  end

  describe "similar/2 ordering inside one category rank" do
    # The index rows are aged by hand: products created in one test share a
    # second, and then the newest tie-break would not depend on creation order.
    # Each test gives the age that would put the right answer LAST if the
    # criterion under test were missing (the newest product wins the final
    # tie-break), and keeps every other criterion equal.

    defp age!(hours_ago_by_uuid) do
      now = DateTime.utc_now()

      for {uuid, hours} <- hours_ago_by_uuid do
        Repo.query!(
          "UPDATE phoenix_kit_shop_search_index SET item_inserted_at = $2 WHERE item_uuid = $1",
          [Ecto.UUID.dump!(uuid), DateTime.add(now, -hours * 3600)]
        )
      end

      :ok
    end

    defp similar_to(base_uuid), do: Query.similar(Query.entry(base_uuid, "en"), 10)

    defp options(values), do: %{metadata: %{"_option_values" => values}}

    test "more shared tags first" do
      more = legacy_product!(%{"en" => "Two Shared"}, %{tags: ["sim-x", "sim-y"]})
      fewer = legacy_product!(%{"en" => "One Shared"}, %{tags: ["sim-x"]})
      base = legacy_product!(%{"en" => "Tag Base"}, %{tags: ["sim-x", "sim-y"]})
      {:ok, _} = Indexer.reindex_items([more.uuid, fewer.uuid, base.uuid])
      age!([{more.uuid, 5}, {fewer.uuid, 1}])

      assert similar_to(base.uuid) == [more.uuid, fewer.uuid]
    end

    test "more shared option values first" do
      more =
        legacy_product!(
          %{"en" => "Two Options"},
          options(%{"finish" => ["Matte"], "bulk" => ["Big"]})
        )

      fewer = legacy_product!(%{"en" => "One Option"}, options(%{"finish" => ["Matte"]}))

      base =
        legacy_product!(
          %{"en" => "Option Base"},
          options(%{"finish" => ["Matte"], "bulk" => ["Big"]})
        )

      {:ok, _} = Indexer.reindex_items([more.uuid, fewer.uuid, base.uuid])
      age!([{more.uuid, 5}, {fewer.uuid, 1}])

      assert similar_to(base.uuid) == [more.uuid, fewer.uuid]
    end

    test "tags and option values count together" do
      # both = 1 tag + 1 option (2); tag_only and option_only = 1 each. A count
      # of tags alone or of options alone ties `both` with one of the others,
      # and the newer one then wins.
      both =
        legacy_product!(
          %{"en" => "Both"},
          Map.put(options(%{"finish" => ["Matte"]}), :tags, ["sim-t"])
        )

      option_only = legacy_product!(%{"en" => "Option Only"}, options(%{"finish" => ["Matte"]}))
      tag_only = legacy_product!(%{"en" => "Tag Only"}, %{tags: ["sim-t"]})

      base =
        legacy_product!(
          %{"en" => "Sum Base"},
          Map.put(options(%{"finish" => ["Matte"]}), :tags, ["sim-t"])
        )

      {:ok, _} = Indexer.reindex_items([both.uuid, option_only.uuid, tag_only.uuid, base.uuid])
      age!([{both.uuid, 6}, {option_only.uuid, 2}, {tag_only.uuid, 1}])

      assert similar_to(base.uuid) == [both.uuid, tag_only.uuid, option_only.uuid]
    end

    test "a price within 50 percent of the product's own comes before a distant one" do
      near = legacy_product!(%{"en" => "Near Price"}, %{tags: ["sim-p"], price: "25.00"})
      far = legacy_product!(%{"en" => "Far Price"}, %{tags: ["sim-p"], price: "100.00"})
      base = legacy_product!(%{"en" => "Price Base"}, %{tags: ["sim-p"], price: "20.00"})
      {:ok, _} = Indexer.reindex_items([near.uuid, far.uuid, base.uuid])
      age!([{near.uuid, 5}, {far.uuid, 1}])

      assert similar_to(base.uuid) == [near.uuid, far.uuid]
    end

    test "the price band is 50 to 150 percent, both ends included" do
      product = fn title, price ->
        legacy_product!(%{"en" => title}, %{tags: ["sim-b"], price: price})
      end

      in_high = product.("High Edge In", "30.00")
      in_low = product.("Low Edge In", "10.00")
      out_high = product.("High Edge Out", "30.01")
      out_low = product.("Low Edge Out", "9.99")
      base = product.("Band Base", "20.00")
      uuids = Enum.map([in_high, in_low, out_high, out_low, base], & &1.uuid)
      {:ok, _} = Indexer.reindex_items(uuids)
      age!([{in_high.uuid, 8}, {in_low.uuid, 6}, {out_high.uuid, 4}, {out_low.uuid, 2}])

      # inside the band first, each group newest first
      assert similar_to(base.uuid) == [in_low.uuid, in_high.uuid, out_low.uuid, out_high.uuid]
    end

    test "otherwise equal, the newest product comes first, then the lower id" do
      first = legacy_product!(%{"en" => "Tie First"}, %{tags: ["sim-n"]})
      second = legacy_product!(%{"en" => "Tie Second"}, %{tags: ["sim-n"]})
      third = legacy_product!(%{"en" => "Tie Third"}, %{tags: ["sim-n"]})
      base = legacy_product!(%{"en" => "Tie Base"}, %{tags: ["sim-n"]})
      {:ok, _} = Indexer.reindex_items([first.uuid, second.uuid, third.uuid, base.uuid])

      # created first, second, third: the age order is second, first, third
      age!([{second.uuid, 1}, {first.uuid, 2}, {third.uuid, 3}])
      assert similar_to(base.uuid) == [second.uuid, first.uuid, third.uuid]

      # One instant: the lower id first. The rows are rewritten from the highest
      # id down and read by a sequential scan (the unique index on the id would
      # hand them over in id order by itself), so the order the scan produces
      # is the reverse of the expected one and only the id tie-break fixes it.
      Repo.query!("SET LOCAL enable_indexscan = off")
      Repo.query!("SET LOCAL enable_bitmapscan = off")
      same = DateTime.utc_now()

      for p <- Enum.sort_by([first, second, third], & &1.uuid, :desc) do
        Repo.query!(
          "UPDATE phoenix_kit_shop_search_index SET item_inserted_at = $2 WHERE item_uuid = $1",
          [Ecto.UUID.dump!(p.uuid), same]
        )
      end

      assert similar_to(base.uuid) == Enum.sort([first.uuid, second.uuid, third.uuid])
    end
  end
end
