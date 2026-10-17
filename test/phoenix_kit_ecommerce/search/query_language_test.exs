defmodule PhoenixKitEcommerce.Search.QueryLanguageTest do
  @moduledoc """
  The language's own stemming on the query side, with the typo fallback
  switched off so that only full text can answer: a query parsed with the wrong
  configuration finds nothing here. `async: false`: the tests pin the global
  `pg_trgm` availability cache.
  """
  use PhoenixKitEcommerce.DataCase, async: false

  import PhoenixKitEcommerce.SearchFixtures

  alias PhoenixKitEcommerce.Search.Indexer
  alias PhoenixKitEcommerce.Search.Query
  alias PhoenixKitEcommerce.Search.Trigram

  setup do
    enable_languages!(["en", "de", "fr"])
    Trigram.put_cache(false)
    on_exit(&Trigram.reset_cache/0)
    :ok
  end

  defp run(q, language), do: Query.run(%{q: q}, language)

  # The query must be reduced to its stem by the language's own configuration:
  # the inflected spelling is searched, the stem is in the index (and the other
  # way round), and neither English nor `simple` reduces these words.
  test "German inflection: Häuser finds Haus, and Haus finds Häuser" do
    house = legacy_product!(%{"en" => "Wooden Toy", "de" => "Haus am See"})
    houses = legacy_product!(%{"en" => "Plastic Toy", "de" => "Häuser aus Holz"})
    {:ok, _} = Indexer.reindex_items([house.uuid, houses.uuid])

    assert %{mode: :fulltext, ids: ids} = run("Häuser", "de")
    assert Enum.sort(ids) == Enum.sort([house.uuid, houses.uuid])
    assert %{mode: :fulltext, ids: ids} = run("Haus", "de")
    assert Enum.sort(ids) == Enum.sort([house.uuid, houses.uuid])

    # the English row says neither
    assert %{ids: [], count: 0} = run("Haus", "en")
  end

  test "French inflection: chevaux finds cheval, and cheval finds chevaux" do
    one = legacy_product!(%{"en" => "Wooden Toy", "fr" => "Cheval de bois"})
    many = legacy_product!(%{"en" => "Plastic Toy", "fr" => "Chevaux de bois"})
    {:ok, _} = Indexer.reindex_items([one.uuid, many.uuid])

    assert %{mode: :fulltext, ids: ids} = run("chevaux", "fr")
    assert Enum.sort(ids) == Enum.sort([one.uuid, many.uuid])
    assert %{mode: :fulltext, ids: ids} = run("cheval", "fr")
    assert Enum.sort(ids) == Enum.sort([one.uuid, many.uuid])
  end

  test "English inflection still holds, with the fallback off" do
    toy = legacy_product!(%{"en" => "Red Vases"})
    {:ok, _} = Indexer.reindex_items([toy.uuid])

    assert %{mode: :fulltext, ids: [id]} = run("vase", "en")
    assert id == toy.uuid
  end

  test "German: a title match ranks above a description match" do
    by_description =
      legacy_product!(%{"en" => "Chair", "de" => "Gartenstuhl"}, %{
        description: %{"de" => "Dazu passt unser Haus"}
      })

    by_title = legacy_product!(%{"en" => "Toy", "de" => "Haus aus Holz"})
    {:ok, _} = Indexer.reindex_items([by_description.uuid, by_title.uuid])

    assert %{mode: :fulltext, ids: ids} = run("Häuser", "de")
    assert ids == [by_title.uuid, by_description.uuid]
  end

  test "French: a title match ranks above a description match" do
    by_description =
      legacy_product!(%{"en" => "Chair", "fr" => "Chaise de jardin"}, %{
        description: %{"fr" => "Va bien avec notre cheval de bois"}
      })

    by_title = legacy_product!(%{"en" => "Toy", "fr" => "Cheval de bois"})
    {:ok, _} = Indexer.reindex_items([by_description.uuid, by_title.uuid])

    assert %{mode: :fulltext, ids: ids} = run("chevaux", "fr")
    assert ids == [by_title.uuid, by_description.uuid]
  end
end
