defmodule PhoenixKitEcommerce.Search.Query do
  @moduledoc """
  Reads the public search index (`phoenix_kit_shop_search_index`).

  `run/2` answers one search: it filters the rows of one language, matches the
  query text, orders, pages, and folds facets over the matched set. It returns
  product ids only; the cards are built from live data by the tools, which also
  re-check visibility, so a stale row can never show a hidden product.

  ## Matching

    1. No query: `:browse`, ordered by the catalogue position, then the title.
    2. `websearch_to_tsquery(<language configuration>, q)` against `document`,
       ranked with `ts_rank_cd`: `:fulltext`. It accepts any text. Unbalanced
       quotes, operators and stop words only loosen or empty the query. A
       leading `-` excludes a word or a quoted phrase.
    3. Only when step 2 finds nothing, the query has no exclusion and the
       `pg_trgm` extension is installed: `title_trgm %> q` (word similarity of
       at least 0.45, set with `set_config` for the transaction the typo path
       runs in), best first: `:typo`. A query with an exclusion never takes
       the fallback: trigrams ignore the `-`, so the excluded words would
       count as evidence for the very products the buyer ruled out.

  Step 2 is probed inside the filters: `vase` with `price_max: 6` finds no
  full-text match even when `vase` products exist above that price, so the
  fallback (step 3) runs among the products the filters let through.

  If Postgres refuses a text outright (a NUL byte, a `tsquery` stack overflow;
  `clean_q/1` removes both) the answer is empty and `refused?` is `true`; any
  other database error is raised, never turned into "no products".

  ## Params and caller contract

  `run/2` takes a map; absent keys use the defaults. The caller has already
  validated every value (this module trusts it):

    * `q` - any term; `clean_q/1` decides (see there). Default `nil`.
    * `category_id` - a valid UUID string, or `nil`; an invalid one raises
      `Ecto.Query.CastError`. Matches the category and its whole subtree.
    * `price_min`, `price_max` - `Decimal` in the base currency, or `nil`.
    * `options` - `%{option_key => [option_value]}`, both in their slug form
      (`"size" => ["large"]`, not `"Large"`): OR within a key, AND across keys.
    * `vendor` - a string compared case-insensitively, or `nil`.
      Neither a vendor nor an option key or value may hold a NUL byte (Postgres
      refuses it and the call raises); `API.SearchParams` rejects it.
    * `on_sale`, `made_to_order` - `true`, `false` (the complement) or `nil`.
    * `sort` - one of `:relevance` (default), `:price_asc`, `:price_desc`,
      `:discount_desc`, `:newest`; anything else raises `FunctionClauseError`.
    * `limit` - a positive integer, `offset` - a non-negative integer (a
      negative offset raises `Postgrex.Error`).
    * `facets` - `false` skips the facets (their pass over up to 5000 rows
      is not run, `facets` is `nil` and `truncated?` is `false`). Default `true`.

  `language` is the code exactly as it is indexed (`"de"` finds no `"de-DE"`
  rows). It is not normalized here.

  ## Cursors

  A cursor is an opaque offset (`base64url("o:<n>")`, at most 10 000). The
  relevance rank is a float, which makes a keyset cursor fragile; the shop's
  catalogue is hundreds to low thousands of products, and `count` is exact
  either way.

  ## Size

  A search reads the rows of one language: the count, the page and the facets
  (up to 5000 rows) are three passes over the matched set. That is
  milliseconds for a few thousand rows per language. On an index of tens of
  thousands of rows a many-term query or a long misspelt one takes seconds, and
  a request is charged one rate-limit unit whatever the size of the index; such
  an install needs a database `statement_timeout` for these queries.
  """

  import Ecto.Query, warn: false

  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKitEcommerce.Search.Dictionary
  alias PhoenixKitEcommerce.Search.Entry
  alias PhoenixKitEcommerce.Search.Trigram

  @facet_cap 5_000
  @typo_threshold 0.45
  @max_offset 10_000
  @max_q_length 200

  @defaults %{
    q: nil,
    category_id: nil,
    price_min: nil,
    price_max: nil,
    options: %{},
    vendor: nil,
    on_sale: nil,
    made_to_order: nil,
    sort: :relevance,
    limit: 20,
    offset: 0,
    facets: true
  }

  @type params :: %{
          optional(:q) => term(),
          optional(:category_id) => String.t() | nil,
          optional(:price_min) => Decimal.t() | nil,
          optional(:price_max) => Decimal.t() | nil,
          optional(:options) => %{String.t() => [String.t()]},
          optional(:vendor) => String.t() | nil,
          optional(:on_sale) => boolean() | nil,
          optional(:made_to_order) => boolean() | nil,
          optional(:sort) => :relevance | :price_asc | :price_desc | :discount_desc | :newest,
          optional(:limit) => pos_integer(),
          optional(:offset) => non_neg_integer(),
          optional(:facets) => boolean()
        }

  @type result :: %{
          ids: [String.t()],
          count: non_neg_integer(),
          mode: :browse | :fulltext | :typo,
          facets: map() | nil,
          truncated?: boolean(),
          refused?: boolean()
        }

  @doc "Runs one search in `language`. See the moduledoc for `params` and what the caller guarantees."
  @spec run(params(), String.t()) :: result()
  def run(params, language) when is_map(params) and is_binary(language) do
    params = @defaults |> Map.merge(params) |> Map.update!(:q, &clean_q/1)
    {matched, mode} = language |> filtered(params) |> match(params, language)

    if mode == :typo,
      do: in_typo_transaction(fn -> read(matched, mode, params, language) end),
      else: read(matched, mode, params, language)
  end

  defp read(matched, mode, params, language) do
    count = RepoHelper.repo().aggregate(matched, :count)

    ids =
      matched
      |> ordered(mode, params, language)
      |> limit(^params.limit)
      |> offset(^params.offset)
      |> select([e], e.item_uuid)
      |> RepoHelper.repo().all()

    facets = if params.facets, do: facets(matched)

    %{
      ids: ids,
      count: count,
      mode: if(mode == :refused, do: :fulltext, else: mode),
      facets: facets,
      truncated?: params.facets and count > @facet_cap,
      refused?: mode == :refused
    }
  end

  # The `%>` operator reads the threshold from the session setting
  # `pg_trgm.word_similarity_threshold` (default 0.6). `SET LOCAL` needs one
  # transaction around the count, the page and the facets, so the typo path
  # runs in one and the setting dies with it.
  defp in_typo_transaction(fun) do
    repo = RepoHelper.repo()

    {:ok, result} =
      repo.transaction(fn ->
        repo.query!("SELECT set_config('pg_trgm.word_similarity_threshold', $1, true)", [
          Float.to_string(@typo_threshold)
        ])

        fun.()
      end)

    result
  end

  @doc """
  The query text as the index will see it: bytes that are not valid UTF-8 and
  NUL bytes removed (Postgres refuses both in text), at most #{@max_q_length}
  code points (not graphemes: one base letter with a hundred thousand
  combining marks is a single grapheme but a hundred thousand code points,
  and the typo path pays per code point), a `-` that is not directly followed
  by a letter, a digit or a double quote turned into a space (a run of 33 or
  more nested negations makes `websearch_to_tsquery` raise `tsquery stack too
  small`; `-vase`, `-"red ceramic"` and `co-op` keep their meaning), trimmed;
  blank or not a string is `nil` (no query).
  """
  @spec clean_q(term()) :: String.t() | nil
  def clean_q(q) when is_binary(q) do
    cleaned =
      q
      |> String.replace_invalid("")
      |> String.replace(<<0>>, "")
      |> String.codepoints()
      |> Enum.take(@max_q_length)
      |> Enum.join()
      |> then(&Regex.replace(~r/-(?![\p{L}\p{N}"])/u, &1, " "))
      |> String.trim()

    if cleaned == "", do: nil, else: cleaned
  end

  def clean_q(_other), do: nil

  @doc "The number of products listed directly in each category, in one language: `%{category_uuid => n}`."
  @spec category_counts(String.t()) :: %{String.t() => non_neg_integer()}
  def category_counts(language) when is_binary(language) do
    from(e in Entry,
      where: e.language == ^language and not is_nil(e.category_uuid),
      group_by: e.category_uuid,
      select: {e.category_uuid, count(e.uuid)}
    )
    |> RepoHelper.repo().all()
    |> Map.new()
  end

  @doc """
  The option keys and values the index holds in one language, sorted:
  `%{"size" => ["large", "small"]}`. What an `options` filter can match.
  """
  @spec option_vocabulary(String.t()) :: %{String.t() => [String.t()]}
  def option_vocabulary(language) when is_binary(language) do
    from(e in Entry,
      where: e.language == ^language,
      distinct: true,
      select: fragment("unnest(?)", e.option_pairs)
    )
    |> RepoHelper.repo().all()
    |> Enum.flat_map(fn pair ->
      case String.split(pair, ":", parts: 2) do
        [key, value] -> [{key, value}]
        _malformed -> []
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {key, values} -> {key, Enum.sort(values)} end)
  end

  @doc "The index row of one product in one language, or `nil`. `item_uuid` must be a valid UUID."
  @spec entry(String.t(), String.t()) :: Entry.t() | nil
  def entry(item_uuid, language) when is_binary(item_uuid) and is_binary(language) do
    RepoHelper.repo().one(
      from(e in Entry, where: e.item_uuid == ^item_uuid and e.language == ^language)
    )
  end

  @doc """
  Product ids similar to `base`, best first: the same category, then the most
  shared option values and tags, then a price within +-50%, then the newest. A
  product must share its category, an option value or a tag to qualify.
  """
  @spec similar(Entry.t(), pos_integer()) :: [String.t()]
  def similar(%Entry{} = base, limit) when is_integer(limit) and limit > 0 do
    pairs = base.option_pairs
    tags = base.tags
    category = base.category_uuid
    price = base.price

    from(e in Entry,
      where: e.language == ^base.language and e.item_uuid != ^base.item_uuid,
      where:
        fragment(
          "(? = ? OR ? && ?::text[] OR ? && ?::text[])",
          e.category_uuid,
          type(^category, Ecto.UUID),
          e.option_pairs,
          ^pairs,
          e.tags,
          ^tags
        ),
      order_by: [
        desc:
          fragment(
            "CASE WHEN ? = ? THEN 1 ELSE 0 END",
            e.category_uuid,
            type(^category, Ecto.UUID)
          ),
        desc:
          fragment(
            "cardinality(ARRAY(SELECT unnest(?) INTERSECT SELECT unnest(?::text[]))) + cardinality(ARRAY(SELECT unnest(?) INTERSECT SELECT unnest(?::text[])))",
            e.option_pairs,
            ^pairs,
            e.tags,
            ^tags
          ),
        desc:
          fragment(
            "CASE WHEN ?::numeric IS NOT NULL AND ? BETWEEN ?::numeric * 0.5 AND ?::numeric * 1.5 THEN 1 ELSE 0 END",
            ^price,
            e.price,
            ^price,
            ^price
          ),
        desc_nulls_last: e.item_inserted_at,
        asc: e.item_uuid
      ],
      limit: ^limit,
      select: e.item_uuid
    )
    |> RepoHelper.repo().all()
  end

  @doc "An opaque cursor for `offset`."
  @spec encode_cursor(non_neg_integer()) :: String.t()
  def encode_cursor(offset) when is_integer(offset) and offset >= 0 do
    Base.url_encode64("o:" <> Integer.to_string(offset), padding: false)
  end

  @doc "The offset a cursor stands for. `nil` and `\"\"` are the first page; anything else that is not a cursor of ours is `:error`."
  @spec decode_cursor(String.t() | nil) :: {:ok, non_neg_integer()} | :error
  def decode_cursor(nil), do: {:ok, 0}
  def decode_cursor(""), do: {:ok, 0}

  def decode_cursor(cursor) when is_binary(cursor) and byte_size(cursor) <= 64 do
    with {:ok, "o:" <> number} <- Base.url_decode64(cursor, padding: false),
         {offset, ""} when offset >= 0 and offset <= @max_offset <- Integer.parse(number),
         true <- Integer.to_string(offset) == number do
      {:ok, offset}
    else
      _other -> :error
    end
  end

  def decode_cursor(_other), do: :error

  @doc """
  The cursor of the page after `offset` + `limit`, or `nil` on the last page or
  beyond the #{@max_offset} products a cursor can reach.
  """
  @spec next_cursor(non_neg_integer(), pos_integer(), non_neg_integer()) :: String.t() | nil
  def next_cursor(offset, limit, count) do
    next = offset + limit
    if next < count and next <= @max_offset, do: encode_cursor(next)
  end

  # --- filters ---------------------------------------------------------------

  defp filtered(language, params) do
    from(e in Entry, where: e.language == ^language)
    |> by_category(params.category_id)
    |> by_price(params.price_min, params.price_max)
    |> by_options(params.options)
    |> by_vendor(params.vendor)
    |> by_flag(:on_sale, params.on_sale)
    |> by_flag(:made_to_order, params.made_to_order)
  end

  defp by_category(query, nil), do: query

  defp by_category(query, id) do
    where(
      query,
      [e],
      fragment("? @> ?", e.category_path_uuids, type(^[id], {:array, Ecto.UUID}))
    )
  end

  defp by_price(query, nil, nil), do: query
  defp by_price(query, min, nil), do: where(query, [e], e.price >= ^min)
  defp by_price(query, nil, max), do: where(query, [e], e.price <= ^max)
  defp by_price(query, min, max), do: where(query, [e], e.price >= ^min and e.price <= ^max)

  defp by_options(query, options) when map_size(options) == 0, do: query

  defp by_options(query, options) do
    Enum.reduce(options, query, fn {key, values}, acc ->
      pairs = Enum.map(values, &"#{key}:#{&1}")
      # `?::text[]`, not `type(^pairs, {:array, :string})`: Ecto would send
      # `$n::varchar[]` and Postgres has no operator `text[] && varchar[]`
      # (Postgrex.Error 42883 on every call).
      where(acc, [e], fragment("? && ?::text[]", e.option_pairs, ^pairs))
    end)
  end

  defp by_vendor(query, nil), do: query

  defp by_vendor(query, vendor),
    do: where(query, [e], fragment("lower(?) = lower(?)", e.vendor, ^vendor))

  defp by_flag(query, _field, nil), do: query
  defp by_flag(query, :on_sale, value), do: where(query, [e], e.on_sale == ^value)
  defp by_flag(query, :made_to_order, value), do: where(query, [e], e.made_to_order == ^value)

  # --- matching and order ----------------------------------------------------

  defp match(query, %{q: nil}, _language), do: {query, :browse}

  defp match(query, %{q: q}, language) do
    config = Dictionary.regconfig(language)

    fulltext =
      where(
        query,
        [e],
        fragment(
          "? @@ websearch_to_tsquery(?::text::regconfig, ?::text)",
          e.document,
          ^config,
          ^q
        )
      )

    case fulltext_probe(fulltext) do
      :refused ->
        # Defence in depth: `clean_q/1` already removes the inputs that make
        # websearch_to_tsquery raise. If Postgres still refuses a text, the
        # answer is "no match", flagged `refused?` (the internal mode
        # :refused keeps the order clause free of the tsquery), never a 500.
        {where(query, [e], false), :refused}

      true ->
        {fulltext, :fulltext}

      false ->
        typo_or_empty(query, q, fulltext)
    end
  end

  # Only the refusals of the text itself become an empty answer. A timeout, a
  # dropped connection or a missing table must fail the request: "no
  # products" during a database problem reads as "the shop has none". The log
  # carries the SQLSTATE only (a Postgres message or detail can echo the text).
  defp fulltext_probe(fulltext) do
    RepoHelper.repo().exists?(fulltext)
  rescue
    error in Postgrex.Error ->
      if text_refusal?(error) do
        Logger.warning("[Search] full-text probe refused (SQLSTATE #{sqlstate(error)})")
        :refused
      else
        reraise error, __STACKTRACE__
      end
  end

  # 22021: a NUL byte or invalid UTF-8; XX000 with "stack too small": the
  # tsquery parser ran out of stack on deeply nested operators.
  defp text_refusal?(%Postgrex.Error{postgres: %{code: :character_not_in_repertoire}}), do: true

  defp text_refusal?(%Postgrex.Error{postgres: %{code: :internal_error, message: message}})
       when is_binary(message),
       do: String.contains?(message, "stack too small")

  defp text_refusal?(_error), do: false

  defp sqlstate(%Postgrex.Error{postgres: %{pg_code: code}}) when is_binary(code), do: code
  defp sqlstate(_error), do: "unknown"

  # `title_trgm %> q` is `word_similarity(q, title_trgm) >= threshold` written
  # as an operator, which is the form the `gin_trgm_ops` index of V4 can serve
  # (a plain `word_similarity(...) >= x` call cannot use it). The threshold is
  # set per transaction in `in_typo_transaction/1`.
  defp typo_or_empty(query, q, fulltext) do
    if Trigram.available?() and not negation?(q) do
      typo = where(query, [e], fragment("? %> ?::text", e.title_trgm, ^String.downcase(q)))

      {typo, :typo}
    else
      {fulltext, :fulltext}
    end
  end

  # A `-` that starts a term (not the hyphen inside `co-op`) directly before a
  # word or a quote. `clean_q/1` has already removed every other `-`.
  defp negation?(q), do: Regex.match?(~r/(?<![\p{L}\p{N}])-[\p{L}\p{N}"]/u, q)

  defp ordered(query, :fulltext, %{sort: :relevance, q: q}, language) do
    config = Dictionary.regconfig(language)

    order_by(query, [e],
      desc:
        fragment(
          "ts_rank_cd(?, websearch_to_tsquery(?::text::regconfig, ?::text))",
          e.document,
          ^config,
          ^q
        ),
      asc: e.title,
      asc: e.item_uuid
    )
  end

  defp ordered(query, :typo, %{sort: :relevance, q: q}, _language) do
    order_by(query, [e],
      desc: fragment("word_similarity(?::text, ?)", ^String.downcase(q), e.title_trgm),
      asc: e.title,
      asc: e.item_uuid
    )
  end

  defp ordered(query, _mode, %{sort: :relevance}, _language),
    do: order_by(query, [e], asc: e.sort_position, asc: e.title, asc: e.item_uuid)

  defp ordered(query, _mode, %{sort: :price_asc}, _language),
    do: order_by(query, [e], asc_nulls_last: e.price, asc: e.title, asc: e.item_uuid)

  defp ordered(query, _mode, %{sort: :price_desc}, _language),
    do: order_by(query, [e], desc_nulls_last: e.price, asc: e.title, asc: e.item_uuid)

  defp ordered(query, _mode, %{sort: :discount_desc}, _language),
    do: order_by(query, [e], desc_nulls_last: e.discount_pct, asc: e.title, asc: e.item_uuid)

  defp ordered(query, _mode, %{sort: :newest}, _language),
    do: order_by(query, [e], desc_nulls_last: e.item_inserted_at, asc: e.title, asc: e.item_uuid)

  # --- facets ----------------------------------------------------------------

  defp facets(matched) do
    rows =
      matched
      |> select([e], %{
        category_uuid: e.category_uuid,
        vendor: e.vendor,
        option_pairs: e.option_pairs,
        option_labels: e.option_labels,
        on_sale: e.on_sale,
        made_to_order: e.made_to_order,
        price: e.price
      })
      |> order_by([e], asc: e.item_uuid)
      |> limit(^@facet_cap)
      |> RepoHelper.repo().all()

    %{
      categories: rows |> Enum.map(& &1.category_uuid) |> frequencies(),
      vendors: rows |> Enum.map(& &1.vendor) |> frequencies(),
      options: option_facets(rows),
      on_sale: Enum.count(rows, & &1.on_sale),
      made_to_order: Enum.count(rows, & &1.made_to_order),
      price: price_range(rows)
    }
  end

  defp frequencies(values), do: values |> Enum.reject(&is_nil/1) |> Enum.frequencies()

  defp option_facets(rows) do
    rows
    |> Enum.flat_map(fn row -> Enum.map(row.option_pairs, &{&1, row.option_labels}) end)
    |> Enum.reduce(%{}, fn {pair, labels}, acc ->
      Map.update(acc, pair, %{count: 1, labels: labels}, &%{&1 | count: &1.count + 1})
    end)
    |> Enum.flat_map(fn {pair, %{count: count, labels: labels}} ->
      case String.split(pair, ":", parts: 2) do
        [key, value] ->
          [
            %{
              pair: pair,
              key: key,
              value: value,
              label: Map.get(labels, pair, value),
              set_label: Map.get(labels, key, key),
              count: count
            }
          ]

        _malformed ->
          []
      end
    end)
    |> Enum.sort_by(&{&1.key, -&1.count, &1.value})
  end

  defp price_range(rows) do
    case rows |> Enum.map(& &1.price) |> Enum.reject(&is_nil/1) do
      [] -> nil
      prices -> {Enum.min(prices, Decimal), Enum.max(prices, Decimal)}
    end
  end
end
