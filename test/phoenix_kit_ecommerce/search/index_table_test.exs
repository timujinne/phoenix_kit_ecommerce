defmodule PhoenixKitEcommerce.Search.IndexTableTest do
  use PhoenixKitEcommerce.DataCase, async: true

  alias PhoenixKitEcommerce.Search.Dictionary
  alias PhoenixKitEcommerce.Search.Entry
  alias PhoenixKitEcommerce.Test.Repo

  @columns ~w(
    uuid item_uuid language title title_trgm document category_uuid category_path
    category_path_uuids vendor tags option_pairs option_labels made_to_order on_sale
    price compare_at_price discount_pct sort_position item_inserted_at indexed_at
  )

  test "the table has exactly the columns the indexer writes" do
    %{rows: rows} =
      Repo.query!("""
      SELECT column_name FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = 'phoenix_kit_shop_search_index'
      ORDER BY column_name
      """)

    assert List.flatten(rows) == Enum.sort(@columns)
  end

  test "every field of the schema is a column" do
    fields = Entry.__schema__(:fields) |> Enum.map(&Atom.to_string/1)
    assert fields -- @columns == []
  end

  test "the unique index and the three GIN indexes exist" do
    %{rows: rows} =
      Repo.query!(
        "SELECT indexname FROM pg_indexes WHERE tablename = 'phoenix_kit_shop_search_index'"
      )

    names = List.flatten(rows)

    for name <- ~w(
          phoenix_kit_shop_search_index_pkey
          phoenix_kit_shop_search_index_item_lang_idx
          phoenix_kit_shop_search_index_document_idx
          phoenix_kit_shop_search_index_category_idx
          phoenix_kit_shop_search_index_options_idx
        ) do
      assert name in names, "missing index #{name}"
    end
  end

  test "the trigram index exists exactly when pg_trgm is installed" do
    %{rows: [[installed]]} =
      Repo.query!("SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm')")

    %{rows: [[indexed]]} =
      Repo.query!("""
      SELECT EXISTS (SELECT 1 FROM pg_indexes
                     WHERE indexname = 'phoenix_kit_shop_search_index_title_trgm_idx')
      """)

    assert indexed == installed
  end

  test "a product appears once per language: (item_uuid, language) is unique" do
    sql = """
    INSERT INTO phoenix_kit_shop_search_index (item_uuid, language, title, title_trgm, document)
    VALUES ($1, 'en', 'A', 'a', to_tsvector('simple', 'a'))
    """

    id = Ecto.UUID.bingenerate()
    Repo.query!(sql, [id])

    assert_raise Postgrex.Error, ~r/phoenix_kit_shop_search_index_item_lang_idx/, fn ->
      Repo.query!(sql, [id])
    end
  end

  test "every text search configuration the dictionary can return exists in this server" do
    %{rows: rows} = Repo.query!("SELECT cfgname FROM pg_ts_config")
    available = List.flatten(rows)

    for config <- ["simple" | Dictionary.configs()] do
      assert config in available, "Postgres has no text search configuration #{config}"
    end
  end
end
