defmodule PhoenixKitEcommerce.Search.Indexer do
  @moduledoc """
  Writes the public search index (`phoenix_kit_shop_search_index`).

  Every run stamps the rows it writes with one `indexed_at` (the moment the
  run started), **upserts first**, and then deletes the rows of its scope
  that carry an older stamp. A product that stopped being listed, a deleted
  product and a language that was switched off are all "rows nobody touched
  in this run", so one rule removes them. Because the primary key of a row
  survives an upsert, a search that runs during a rebuild still finds every
  product that stays listed.

  Runs may overlap (the queue has more than one slot and reindex jobs are not
  unique), so a run never overwrites a row that carries a newer stamp than its
  own: a slower, older run can neither bring back stale content nor make a
  newer run's row look stale to that run's own sweep. The rows of two runs
  that touch the same product therefore end with the content and the stamp of
  the run that started last. Ties (equal stamps) are written, so the newest
  stamp always wins and a repeated run with one stamp is idempotent.

  One case is not covered: a row is only skipped when it exists. If a newer run
  removed the row of a product that has just become unlisted, an older and
  slower run that still saw the product as listed can insert that row again,
  because there is nothing left to compare its stamp with. The card builder
  re-checks the product's visibility when it reads the results, so such a
  leftover row never reaches a shopper; it stays in the index until the next
  reindex of the product or the nightly rebuild removes it.

    * `reindex_items/1` - the given product ids (an item edit, a bulk change).
    * `rebuild/0` - the whole shop (the nightly safety net). If the shop's
      catalogue cannot be resolved it returns `{:error, :no_catalogue}` and
      deletes nothing: an unresolvable catalogue is not an empty shop.

  Every enabled language gets a row. If the Languages module is on and none
  is enabled, the shop's default language is indexed instead, so that a
  language-less configuration cannot make the sweep empty the index.

  Rows are written with raw SQL because the `document` column is a
  `tsvector` that Postgres builds with the language's configuration
  (`PhoenixKitEcommerce.Search.Dictionary`) from the weighted parts of
  `PhoenixKitEcommerce.Search.Document`.
  """

  import Ecto.Query, warn: false

  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKitEcommerce.API.Loader
  alias PhoenixKitEcommerce.API.Record
  alias PhoenixKitEcommerce.Search.Document
  alias PhoenixKitEcommerce.Search.Entry
  alias PhoenixKitEcommerce.Translations

  @chunk 100
  @delete_chunk 500

  @typedoc """
  Run options. `:started_at` is the stamp of the run (default: now); rows
  stamped later are never overwritten. `:chunk_size` is the number of products
  per write batch and per delete statement (default 100 and 500).
  """
  @type opts :: [started_at: DateTime.t(), chunk_size: pos_integer()]

  @doc """
  Re-indexes `uuids`: listed products are upserted in every enabled language,
  every other row of these products is removed. Entries that are not product
  uuids are ignored.

  Like `rebuild/0` it changes nothing while the Catalogue source is on and the
  shop's catalogue cannot be resolved: the loader would answer an empty map and
  `delete_stale/2` would then remove the rows of every id it was given.
  """
  @spec reindex_items([term()], opts()) ::
          {:ok, %{indexed: non_neg_integer(), removed: non_neg_integer()}}
  def reindex_items(uuids, opts \\ []) when is_list(uuids) do
    if Loader.source_resolvable?() do
      uuids =
        uuids
        |> Enum.map(&Loader.canonical_uuid/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      started = started_at(opts)
      indexed = index_all(uuids, started, opts)
      removed = delete_stale(uuids, started, opts)
      {:ok, %{indexed: indexed, removed: removed}}
    else
      Logger.warning("[Search] reindex skipped: the shop catalogue cannot be resolved")
      {:ok, %{indexed: 0, removed: 0}}
    end
  end

  @doc "Rebuilds the whole index from the product source."
  @spec rebuild(opts()) ::
          {:ok,
           %{products: non_neg_integer(), indexed: non_neg_integer(), removed: non_neg_integer()}}
          | {:error, :no_catalogue}
  def rebuild(opts \\ []) do
    # The stamp is taken before the ids are read: a product that appears after
    # this point is stamped later than `started` and is safe from the sweep.
    started = started_at(opts)

    case Loader.all_ids() do
      {:error, :no_catalogue} = error ->
        Logger.warning("[Search] rebuild skipped: the shop catalogue cannot be resolved")
        error

      {:ok, ids} ->
        indexed = index_all(ids, started, opts)

        {removed, _} =
          RepoHelper.repo().delete_all(from(e in Entry, where: e.indexed_at < ^started))

        Logger.info(
          "[Search] rebuild: #{length(ids)} products, #{indexed} rows written, #{removed} removed"
        )

        {:ok, %{products: length(ids), indexed: indexed, removed: removed}}
    end
  end

  @doc "True when the index has no row at all."
  @spec empty?() :: boolean()
  def empty?, do: not RepoHelper.repo().exists?(Entry)

  # --- writing ---------------------------------------------------------------

  defp started_at(opts), do: Keyword.get_lazy(opts, :started_at, &DateTime.utc_now/0)

  # With the Languages module on and no language enabled, the enabled list is
  # empty: indexing nothing would let the sweep delete every row, so the
  # shop's default language stands in.
  defp index_languages do
    case Translations.enabled_languages() do
      [] -> [Translations.default_language()]
      languages -> languages
    end
  end

  defp index_all([], _started, _opts), do: 0

  defp index_all(ids, started, opts) do
    languages = index_languages()
    categories = Loader.categories()

    ids
    |> Enum.chunk_every(Keyword.get(opts, :chunk_size, @chunk))
    |> Enum.reduce(0, fn chunk, total ->
      total + index_chunk(chunk, started, languages, categories)
    end)
  end

  # The loading, the row building and the writing are separate functions to
  # keep each body shallow (Credo `--strict` allows two levels of nesting).
  # Rows are written in a fixed order so that two overlapping runs lock the
  # same rows in the same order.
  defp index_chunk(chunk, started, languages, categories) do
    chunk
    |> chunk_rows(languages, categories)
    |> write_rows(started)
  end

  defp chunk_rows(chunk, languages, categories) do
    languages
    |> Enum.flat_map(&language_rows(chunk, &1, categories))
    |> Enum.sort_by(&{&1.language, &1.item_uuid})
  end

  defp write_rows([], _started), do: 0

  defp write_rows(rows, started) do
    repo = RepoHelper.repo()

    {:ok, written} =
      repo.transaction(
        fn -> rows |> Enum.map(&upsert(repo, &1, started)) |> Enum.sum() end,
        timeout: :infinity
      )

    written
  end

  defp language_rows(chunk, language, categories) do
    chunk
    |> Loader.load(language: language, categories: categories)
    |> Map.values()
    |> Enum.filter(&(&1.state == :listed))
    |> Enum.flat_map(&document_rows(&1, language))
  end

  defp document_rows(%Record{} = record, language) do
    case Document.build(record, language) do
      nil -> []
      row -> [row]
    end
  end

  defp delete_stale(uuids, started, opts) do
    uuids
    |> Enum.chunk_every(Keyword.get(opts, :chunk_size, @delete_chunk))
    |> Enum.reduce(0, fn chunk, total ->
      {count, _} =
        RepoHelper.repo().delete_all(
          from(e in Entry, where: e.item_uuid in ^chunk and e.indexed_at < ^started)
        )

      total + count
    end)
  end

  # The number of rows written: 0 when the row already carries a newer stamp.
  defp upsert(repo, row, started) do
    repo.query!(upsert_sql(), params(row, started)).num_rows
  end

  defp params(row, started) do
    [
      dump_uuid(row.item_uuid),
      row.language,
      row.title,
      row.regconfig,
      row.text_b,
      row.text_c,
      row.text_d,
      dump_uuid(row.category_uuid),
      row.category_path,
      Enum.map(row.category_path_uuids, &dump_uuid/1),
      row.vendor,
      row.tags,
      row.option_pairs,
      row.option_labels,
      row.made_to_order,
      row.on_sale,
      row.price,
      row.compare_at_price,
      row.discount_pct,
      row.sort_position,
      row.item_inserted_at,
      started
    ]
  end

  defp dump_uuid(nil), do: nil
  defp dump_uuid(uuid), do: Ecto.UUID.dump!(uuid)

  defp upsert_sql do
    """
    INSERT INTO #{Entry.table()} AS idx
      (item_uuid, language, title, title_trgm, document, category_uuid, category_path,
       category_path_uuids, vendor, tags, option_pairs, option_labels, made_to_order, on_sale,
       price, compare_at_price, discount_pct, sort_position, item_inserted_at, indexed_at)
    VALUES
      ($1::uuid, $2::text, $3::text, lower($3::text),
       setweight(to_tsvector($4::text::regconfig, $3::text), 'A') ||
       setweight(to_tsvector($4::text::regconfig, $5::text), 'B') ||
       setweight(to_tsvector($4::text::regconfig, $6::text), 'C') ||
       setweight(to_tsvector($4::text::regconfig, $7::text), 'D'),
       $8::uuid, $9::text[], $10::uuid[], $11::text, $12::text[], $13::text[], $14::jsonb,
       $15::boolean, $16::boolean, $17::numeric, $18::numeric, $19::numeric, $20::integer,
       $21::timestamptz, $22::timestamptz)
    ON CONFLICT (item_uuid, language) DO UPDATE SET
      title = EXCLUDED.title,
      title_trgm = EXCLUDED.title_trgm,
      document = EXCLUDED.document,
      category_uuid = EXCLUDED.category_uuid,
      category_path = EXCLUDED.category_path,
      category_path_uuids = EXCLUDED.category_path_uuids,
      vendor = EXCLUDED.vendor,
      tags = EXCLUDED.tags,
      option_pairs = EXCLUDED.option_pairs,
      option_labels = EXCLUDED.option_labels,
      made_to_order = EXCLUDED.made_to_order,
      on_sale = EXCLUDED.on_sale,
      price = EXCLUDED.price,
      compare_at_price = EXCLUDED.compare_at_price,
      discount_pct = EXCLUDED.discount_pct,
      sort_position = EXCLUDED.sort_position,
      item_inserted_at = EXCLUDED.item_inserted_at,
      indexed_at = EXCLUDED.indexed_at
    WHERE idx.indexed_at <= EXCLUDED.indexed_at
    """
  end
end
