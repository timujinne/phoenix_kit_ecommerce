defmodule PhoenixKitEcommerce.Search.QueryTypoTest do
  @moduledoc """
  The typo fallback (`title_trgm %> q`, word similarity 0.45) and its absence. `async: false`: the
  tests pin the global `pg_trgm` availability cache.
  """
  use PhoenixKitEcommerce.DataCase, async: false

  import PhoenixKitEcommerce.SearchFixtures

  alias PhoenixKitEcommerce.Search.Indexer
  alias PhoenixKitEcommerce.Search.Query
  alias PhoenixKitEcommerce.Search.Trigram

  setup do
    disable_languages!()
    Trigram.reset_cache()
    on_exit(&Trigram.reset_cache/0)

    category = legacy_category!(%{"en" => "Vases"})
    vase = legacy_product!(%{"en" => "Ceramic Vase"}, %{category_uuid: category.uuid})
    bowl = legacy_product!(%{"en" => "Glass Bowl"})
    {:ok, _} = Indexer.reindex_items([vase.uuid, bowl.uuid])

    %{vase: vase.uuid, bowl: bowl.uuid, category: category.uuid}
  end

  @tag :requires_pg_trgm
  test "a misspelt word is found by word similarity when full text finds nothing", t do
    result = Query.run(%{q: "ceramik"}, "en")

    assert result.mode == :typo
    assert result.ids == [t.vase]
    assert result.count == 1
  end

  @tag :requires_pg_trgm
  test "the threshold is 0.45, not the extension default of 0.6", t do
    # word_similarity('cerumic', 'ceramic vase') = 0.4545: below the default
    # 0.6, above ours.
    result = Query.run(%{q: "cerumic"}, "en")

    assert result.mode == :typo
    assert result.ids == [t.vase]
  end

  @tag :requires_pg_trgm
  test "the fallback is not used when full text already found something", t do
    result = Query.run(%{q: "ceramic"}, "en")

    assert result.mode == :fulltext
    assert result.ids == [t.vase]
  end

  @tag :requires_pg_trgm
  test "nonsense finds nothing even with the fallback, and filters still apply", t do
    assert %{ids: [], count: 0} = Query.run(%{q: "zzzzqqqq"}, "en")

    assert %{ids: [], count: 0} =
             Query.run(%{q: "ceramik", category_id: Ecto.UUID.generate()}, "en")

    assert %{ids: [vase]} = Query.run(%{q: "ceramik", category_id: t.category}, "en")
    assert vase == t.vase
  end

  @tag :requires_pg_trgm
  test "the best match comes first, ahead of an alphabetically earlier weaker one", t do
    # word_similarity('ceramik', ...): 'ceramic vase' 0.75, 'aaa cerumik' 0.4545
    weaker = legacy_product!(%{"en" => "Aaa Cerumik"})
    {:ok, _} = Indexer.reindex_items([weaker.uuid])

    result = Query.run(%{q: "ceramik"}, "en")

    assert result.mode == :typo
    assert result.ids == [t.vase, weaker.uuid]
  end

  @tag :requires_pg_trgm
  test "a query that excludes a word never takes the fallback", t do
    # Without the exclusion rule the trigrams of "vase -ceramic" (which ignore
    # the dash) match "Ceramic Vase", the very product the buyer ruled out.
    for q <- ["vase -ceramic", "ceramic -ceramic", ~s|ceramik -"glass bowl"|, "-ceramic ceramik"] do
      assert %{mode: :fulltext, ids: [], count: 0} = Query.run(%{q: q}, "en"), "q=#{q}"
    end

    # a hyphen inside a word is not an exclusion
    assert %{mode: :typo} = Query.run(%{q: "ceramik-vase"}, "en")
    assert %{mode: :typo, ids: [vase]} = Query.run(%{q: "ceramik"}, "en")
    assert vase == t.vase
  end

  test "without pg_trgm search still works and simply skips the typo fallback", t do
    Trigram.put_cache(false)

    assert %{mode: :fulltext, ids: [], count: 0} = Query.run(%{q: "ceramik"}, "en")
    assert %{mode: :fulltext, ids: [vase]} = Query.run(%{q: "ceramic"}, "en")
    assert vase == t.vase
  end

  test "stop words only: no result and no error, with or without the fallback" do
    Trigram.put_cache(false)
    assert %{ids: [], count: 0, mode: :fulltext} = Query.run(%{q: "the"}, "en")

    Trigram.reset_cache()
    assert %{ids: ids} = Query.run(%{q: "the"}, "en")
    assert is_list(ids)
  end
end
