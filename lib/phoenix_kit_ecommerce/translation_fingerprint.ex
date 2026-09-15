defmodule PhoenixKitEcommerce.TranslationFingerprint do
  @moduledoc """
  The staleness model shared by every AI-translation adapter (design doc
  §4.1/§4.3/§4.4): fingerprinting, the four-state computation, the
  per-field write-narrowing decision, and the hash-in-the-database
  candidate query. `AITranslatable` (products) and the category adapter
  both build on this rather than reimplementing it — the model has to
  stay identical across resource types or the sweep (design §4.3) can't
  treat them uniformly.

  ## Storage

  A fingerprint is `sha256(String.trim(source_text))`, hex-encoded, kept
  under `metadata["_translation_fingerprints"][target_lang][field]` —
  `metadata` being the JSONB column every adapted schema already has.
  `field` is the SAME name used for the schema's own JSONB column
  (`"title"`, `"body_html"`, ...), not the AI-prompt vocabulary name, so
  the candidate SQL below can address both with one identifier.

  No normalization beyond `trim/1` — no HTML/whitespace canonicalization.
  Treating "the text changed" as "unchanged" is worse than an occasional
  extra translation (design §4.1).

  ## The four states

  Defined **only** where the source is non-empty — a field whose source
  is blank or missing has no state at all (`nil`), not `stale`. Without
  that carve-out `stale` never resolves for a deleted source (nothing to
  re-translate against), so a sweep would queue the same empty field
  forever (design §4.1's convergence argument; the candidate SQL below
  encodes the same rule).

    * `:missing` — source non-empty, no translation yet
    * `:stale`   — translation exists, a fingerprint exists, and it
      no longer matches `hash(source)`
    * `:unknown` — translation exists, no fingerprint at all (pre-dates
      this scheme, or the reference was explicitly reset)
    * `:fresh`   — translation exists and its fingerprint matches

  Folding several field states into one resource-level state takes the
  worst: `missing > stale > unknown > fresh` (`fold/1`).

  ## Write-narrowing

  `write_decision/3` is the lock this doubles as (design §4.1's "не
  только датчик... но и замок записи"): a field whose fingerprint still
  matches its stored translation is left alone even when a fresh AI
  response is sitting right there, so a manual edit an operator made
  after the last translation is never silently overwritten by a routine
  re-run. "Перевести заново" (design §4.4) is `drop/3` — erasing the
  fingerprint is the only supported way to lift that protection.
  """

  use PhoenixKit.SchemaPrefix

  alias Ecto.Adapters.SQL

  @metadata_key "_translation_fingerprints"

  @type state :: :missing | :stale | :unknown | :fresh

  # ── Hashing ───────────────────────────────────────────────────────

  @doc """
  `sha256(trim(value))`, lowercase hex. The one hash function every
  fingerprint in this module is built from — source text, on both the
  write path and the read/candidate path, must go through exactly this
  so a value hashed at write time compares equal to itself hashed again
  at read time.
  """
  @spec hash(String.t()) :: String.t()
  def hash(value) when is_binary(value) do
    :crypto.hash(:sha256, String.trim(value)) |> Base.encode16(case: :lower)
  end

  # Every character `String.trim/1` strips — the Unicode `White_Space`
  # set. Postgres' one-argument `btrim(x)` strips ASCII SPACE and
  # nothing else, so a source text ending in a newline (which is what an
  # imported `body_html` normally ends in) hashes differently in SQL
  # than it does here. That divergence is not cosmetic: the candidate
  # query would call such a row `:stale` forever while
  # `write_decision/3` narrows every write away, so every sweep tick
  # would pay for a translation that changes nothing, and the management
  # page (which reads `field_state/3`, i.e. this trim) would show
  # `:fresh` for the row the sweep keeps re-queuing. Both SQL sites
  # therefore pass this set explicitly as `btrim(x, $n)`.
  @sql_trim_chars ([0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0xA0, 0x1680] ++
                     Enum.to_list(0x2000..0x200A) ++ [0x2028, 0x2029, 0x202F, 0x205F, 0x3000])
                  |> Enum.map_join(&<<&1::utf8>>)

  @doc """
  The character set to pass as `btrim`'s second argument so a hash
  computed in Postgres equals `hash/1` computed here — see the comment
  above its definition. Any SQL that recomputes a fingerprint MUST use
  it; `select_candidates/2` and the one-shot backfill mix task both do.
  """
  @spec sql_trim_chars() :: String.t()
  def sql_trim_chars, do: @sql_trim_chars

  # ── Metadata accessors ───────────────────────────────────────────

  @doc "Reads the stored fingerprint for `{lang, field}` out of a resource's `metadata` map, or `nil`."
  @spec get(map() | nil, String.t(), String.t()) :: String.t() | nil
  def get(metadata, lang, field) do
    metadata
    |> fingerprints_map()
    |> Map.get(lang, %{})
    |> then(&(&1 || %{}))
    |> Map.get(field)
  end

  @doc """
  Merges `field_hash_map` (`%{field => hash}`) into `metadata`'s stored
  fingerprints for `lang`, leaving every other language and every field
  not present in `field_hash_map` untouched. Returns the updated
  `metadata` map (the caller still owns writing it back under its own
  lock — this function is pure).
  """
  @spec put_many(map() | nil, String.t(), %{String.t() => String.t()}) :: map()
  def put_many(metadata, _lang, field_hash_map) when field_hash_map == %{},
    do: metadata || %{}

  def put_many(metadata, lang, field_hash_map) do
    metadata = metadata || %{}
    fingerprints = fingerprints_map(metadata)
    lang_map = Map.get(fingerprints, lang, %{}) || %{}
    updated_lang_map = Map.merge(lang_map, field_hash_map)
    Map.put(metadata, @metadata_key, Map.put(fingerprints, lang, updated_lang_map))
  end

  @doc """
  Applies ONE round of write-time fingerprint updates for `lang`, as
  `write_decision/3` produced them: a `{field, hash}` entry stamps that
  hash, a `{field, nil}` entry ERASES whatever fingerprint the field
  had.

  The `nil` case is not a no-op, and that matters. `write_decision/3`
  returns `{:write, nil}` when the caller supplied no source text for
  the field — the field is written from a source this module was never
  shown. Keeping the previous fingerprint would then have the metadata
  assert "this translation was made from source X" about a translation
  that replaced it, made from something else. Concretely, on a field
  that was `:stale`: the row keeps a fingerprint that still mismatches
  its source, so `select_candidates/2` keeps returning it, every sweep
  tick pays for another model call, and the write never moves the
  fingerprint — a non-convergent loop of exactly the kind design §4.1's
  empty-source carve-out exists to prevent. Erasing instead lands the
  field in `:unknown`, which design §4.1 names as the state for
  "переводы, записанные в обход отпечатков" and which the sweep never
  picks up on its own; the operator sees it and decides.

  Pure — the caller writes the result back under its own row lock.
  """
  @spec apply_writes(map() | nil, String.t(), %{String.t() => String.t() | nil}) :: map()
  def apply_writes(metadata, lang, updates) do
    {cleared, stamped} = Enum.split_with(updates, fn {_field, fp} -> is_nil(fp) end)

    metadata
    |> drop(cleared_langs(cleared, lang), Enum.map(cleared, &elem(&1, 0)))
    |> put_many(lang, Map.new(stamped))
  end

  defp cleared_langs([], _lang), do: []
  defp cleared_langs(_cleared, lang), do: [lang]

  @doc """
  Erases the fingerprints for every `{lang, field}` pair in `langs` ×
  `fields` — the "reset the reference" action (design §4.4). Pure; the
  caller applies it under the same locked merge `put_many/3` requires.
  An empty per-language map left behind is dropped, and an empty
  top-level key is dropped too, so a fully-reset resource's `metadata`
  never carries a dangling `{}`.
  """
  @spec drop(map() | nil, [String.t()], [String.t()]) :: map()
  def drop(metadata, langs, fields) do
    metadata = metadata || %{}
    fingerprints = fingerprints_map(metadata)

    updated = Enum.reduce(langs, fingerprints, fn lang, acc -> drop_lang(acc, lang, fields) end)

    if updated == %{} do
      Map.delete(metadata, @metadata_key)
    else
      Map.put(metadata, @metadata_key, updated)
    end
  end

  defp drop_lang(acc, lang, fields) do
    case Map.get(acc, lang) do
      nil -> acc
      lang_map -> put_or_delete_lang(acc, lang, Map.drop(lang_map, fields))
    end
  end

  defp put_or_delete_lang(acc, lang, new_lang_map) when new_lang_map == %{},
    do: Map.delete(acc, lang)

  defp put_or_delete_lang(acc, lang, new_lang_map), do: Map.put(acc, lang, new_lang_map)

  defp fingerprints_map(metadata) do
    (metadata || %{}) |> Map.get(@metadata_key, %{}) |> then(&(&1 || %{}))
  end

  # ── The four states ───────────────────────────────────────────────

  @doc """
  The state of one field: `source` is the CURRENT source text (`nil` or
  blank means no source — see the moduledoc), `translation` the stored
  translated value, `fingerprint` the stored hash for this field/lang.
  Returns `nil` when the source is blank — that field has no state and
  must be excluded from any fold, not counted as `:missing`.
  """
  @spec field_state(String.t() | nil, String.t() | nil, String.t() | nil) :: state() | nil
  def field_state(source, translation, fingerprint) do
    cond do
      blank?(source) -> nil
      blank?(translation) -> :missing
      is_nil(fingerprint) -> :unknown
      hash(source) != fingerprint -> :stale
      true -> :fresh
    end
  end

  @doc """
  Folds per-field states into one resource-level state:
  `missing > stale > unknown > fresh`. Fields with no state (`nil` —
  blank source) don't participate; if every field is `nil` the resource
  itself has no state (`nil`) — it never appears in a candidate set
  (design §4.1: "ресурс без единого непустого исходного поля состояния
  не имеет").
  """
  @spec fold([state() | nil]) :: state() | nil
  def fold(states) do
    states
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      list -> Enum.min_by(list, &rank/1)
    end
  end

  defp rank(:missing), do: 0
  defp rank(:stale), do: 1
  defp rank(:unknown), do: 2
  defp rank(:fresh), do: 3

  # ── Write-narrowing ──────────────────────────────────────────────

  @doc """
  Design §4.4's table, as a decision: given the source text this
  translation job actually read (`nil` when the caller didn't supply
  one — see below), the CURRENTLY stored translation, and the CURRENTLY
  stored fingerprint (both re-read under the adapter's row lock, not
  from a possibly-stale in-memory struct), decide whether to write.

    * no translation yet, no fingerprint yet, or the fingerprint no
      longer matches `hash(source)` → `{:write, hash(source)}`
    * fingerprint matches and a translation is already there → `:skip`
      (the manual-edit protection this whole model exists for)

  `source == nil` is the one case outside that table — a caller that
  doesn't participate in fingerprinting at all (no `:source_fields`
  opt; every production caller after design §9.3 always supplies one).
  Without source text there is nothing to hash, so this falls back to
  the pre-fingerprint behavior — always write — rather than either
  guessing or blocking a legitimate write. The `nil` in `{:write, nil}`
  means "erase this field's fingerprint", NOT "leave it as it was":
  applied through `apply_writes/3`, that leaves the field in
  `:unknown`, the honest state, since this module was never told what
  the value it just accepted was translated from. See `apply_writes/3`
  for why keeping the old fingerprint instead is not a harmless
  omission.
  """
  @spec write_decision(String.t() | nil, String.t() | nil, String.t() | nil) ::
          :skip | {:write, String.t() | nil}
  def write_decision(nil, _translation, _fingerprint), do: {:write, nil}

  def write_decision(source, translation, fingerprint) do
    case field_state(source, translation, fingerprint) do
      :fresh -> :skip
      _ -> {:write, hash(source)}
    end
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: true

  # ── Schema prefix (named-schema / `--prefix` installs) ─────────────

  @doc """
  Schema-qualifies a bare table name with the configured
  `config :phoenix_kit, :prefix` — the SAME compile-time value every
  Ecto-schema-backed query in this package already carries via
  `use PhoenixKit.SchemaPrefix` (see `Product`, `Category`, ...). Raw
  SQL text never goes through Ecto's query builder, so it doesn't pick
  that prefix up automatically; `select_candidates/2` below and the
  one-shot backfill mix task (`build_sql/2`) both call this on every
  table name they interpolate, so a named-schema install targets the
  schema the migrations actually installed into instead of raising
  "relation does not exist" against `public`.

  `nil` — the default, unprefixed `public` install — leaves `table`
  untouched, so behavior for every existing (unprefixed) install is
  unchanged.
  """
  @spec qualify_table(String.t(), String.t() | nil) :: String.t()
  def qualify_table(table, nil), do: table
  def qualify_table(table, prefix) when is_binary(prefix), do: "#{prefix}.#{table}"

  # ── Candidate query (design §4.3) ────────────────────────────────

  @doc """
  Runs the hash-in-the-database candidate query for one resource table
  and returns only `%{uuid:, languages: [...]}` — never resource text
  (design §4.3: "наружу приезжают только uuid и список языков").

  `opts`:

    * `:table` (required) — the table name, e.g.
      `"phoenix_kit_shop_products"`.
    * `:fields` (required) — JSONB column names to check, e.g.
      `["title", "description", ...]`. These come from this codebase's
      own fixed field maps, never external input, and are interpolated
      into the query text as identifiers — never pass user-controlled
      values here.
    * `:source_lang`, `:target_langs` (required).
    * `:statuses` — optional list to additionally require
      `status = ANY(statuses)`; `nil` (default) applies no status
      filter. Design §4.3: categories never pass this.
    * `:limit` — optional row cap (rows are one per `{uuid, lang}}`
      candidate pair, not per resource).

  A resource+language pair is a candidate the moment ANY field is
  `missing` or `stale` for it — matching design §4.4's decision that
  translation happens per-resource, not per-field (the field axis only
  narrows what gets *written*, never what gets *queued*).
  """
  @spec select_candidates(Ecto.Repo.t(), keyword()) :: [
          %{uuid: String.t(), languages: [String.t()]}
        ]
  def select_candidates(repo, opts) do
    table = Keyword.fetch!(opts, :table)
    fields = Keyword.fetch!(opts, :fields)
    source_lang = Keyword.fetch!(opts, :source_lang)
    target_langs = Keyword.fetch!(opts, :target_langs)
    statuses = Keyword.get(opts, :statuses)
    limit = Keyword.get(opts, :limit)

    sql = candidates_sql(qualify_table(table, @schema_prefix), fields)

    case SQL.query(repo, sql, [target_langs, source_lang, statuses, limit, @sql_trim_chars]) do
      {:ok, %{rows: rows}} ->
        rows
        |> Enum.group_by(fn [uuid, _lang] -> uuid end, fn [_uuid, lang] -> lang end)
        |> Enum.map(fn {uuid, langs} -> %{uuid: uuid, languages: Enum.sort(langs)} end)
        |> Enum.sort_by(& &1.uuid)

      {:error, error} ->
        raise "TranslationFingerprint.select_candidates/2 query failed: #{inspect(error)}"
    end
  end

  # $1 = target_langs (text[]), $2 = source_lang (text), $3 = statuses
  # (text[] or NULL — a NULL comparison short-circuits the whole clause
  # to "no filter" on the SQL side), $4 = limit (integer or NULL —
  # Postgres treats `LIMIT NULL` as no limit at all, so this is always
  # safe to include), $5 = the trim character set (see
  # `sql_trim_chars/0` — it is what makes this query's hash equal
  # `hash/1`'s). Fixed positions regardless of which optional clauses
  # fire, so no dynamic renumbering is needed.
  #
  # `table` arrives already schema-qualified (see `select_candidates/2`,
  # `qualify_table/2`) — this function just interpolates it into `FROM`.
  # `def`, not `defp`: exposed (doc false) so a test can pin the prefix
  # actually reaching this string without a live prefixed database.
  @doc false
  @spec candidates_sql(String.t(), [String.t()]) :: String.t()
  def candidates_sql(table, fields) do
    field_clauses = Enum.map_join(fields, "\n     OR ", &field_clause/1)

    """
    SELECT p.uuid::text, t.lang
    FROM #{table} AS p
    CROSS JOIN unnest($1::text[]) AS t(lang)
    WHERE (
      #{field_clauses}
    )
    AND ($3::text[] IS NULL OR p.status = ANY($3::text[]))
    ORDER BY p.uuid, t.lang
    LIMIT $4
    """
  end

  # One field's missing-OR-stale condition (design §4.3's SQL candidate,
  # verbatim: source non-empty AND (no translation yet OR (a fingerprint
  # exists AND it no longer matches)) — deliberately silent on `unknown`
  # (fingerprint absent, translation present): that state is excluded by
  # construction, not filtered out afterward.
  #
  # "Non-empty" is `blank?/1`'s definition, i.e. non-empty AFTER the same
  # trim `hash/1` applies — hence `btrim(..., $5)` inside every `nullif`,
  # not a bare `nullif(x,'')`. A whitespace-only source is blank here
  # (`field_state/3` returns `nil` for it) but would be non-empty to a
  # bare `nullif`, and that gap is not cosmetic: such a field would be a
  # candidate forever. `source_fields/2` drops it before the model ever
  # sees it, so nothing is written and no fingerprint is ever stamped,
  # while a sibling field on the same resource still makes the job a real
  # (paid) model call on every single sweep tick. Same rule on the
  # translation side, so a whitespace-only translation reads as `:missing`
  # here exactly as it does in `field_state/3`.
  defp field_clause(field) do
    """
    (
       nullif(btrim(p."#{field}"->>$2, $5),'') IS NOT NULL
       AND (
         nullif(btrim(p."#{field}"->>t.lang, $5),'') IS NULL
         OR (
           p.metadata->'#{@metadata_key}'->t.lang->>'#{field}' IS NOT NULL
           AND encode(sha256(convert_to(btrim(p."#{field}"->>$2, $5),'UTF8')),'hex')
               IS DISTINCT FROM p.metadata->'#{@metadata_key}'->t.lang->>'#{field}'
         )
       )
    )
    """
  end
end
