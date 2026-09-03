defmodule Mix.Tasks.PhoenixKitEcommerce.BackfillTranslationFingerprints do
  # Ignore Mix.Task behaviour callback info (unavailable in PLT)
  @dialyzer :no_undefined_callbacks

  @moduledoc """
  ONE-SHOT backfill (design §4.1, owner's decision 2026-09-03): stamps the
  CURRENT source text as the reference fingerprint for every existing shop
  translation. Every product/category that already has a translation for a
  language moves to `:fresh` the moment this runs, so the staleness sweep
  (design §4.3) starts from an empty queue instead of re-translating the
  entire catalog on its first tick — 634 resources (627 products + 7
  categories, per the design doc's §2 measurement) is the concrete number
  this was written against.

  Deliberately blunt: it does not check whether a stored translation is
  ACTUALLY faithful to its source — it declares "whatever is live today is
  the reference," which is the accepted cost (design §4.1: "если
  какой-то из существующих переводов уже разошёлся с источником, это
  расхождение замораживается"). **Never run this a second time against a
  catalog that has been live under the sweep** — it would re-freeze any
  drift the sweep had since correctly caught as `:stale`, silently
  un-flagging it. It IS safe to re-run against a catalog that has
  acquired brand-new translations no reference exists for yet (a fresh
  import, a manual translation done outside this pipeline) — for those,
  stamping a reference is exactly the intended, idempotent behavior.

  A field with no source, or no translation, is left alone — nothing to
  stamp; per design §4.1 it still resolves as `:missing` or has no state
  at all, never `:stale`.

  ## Usage

      mix phoenix_kit_ecommerce.backfill_translation_fingerprints
      mix phoenix_kit_ecommerce.backfill_translation_fingerprints --dry-run
      mix phoenix_kit_ecommerce.backfill_translation_fingerprints --source-lang en-US --languages de-DE,fr-FR

  ## Options

    * `--dry-run` — report how many rows per table WOULD be touched,
      without writing.
    * `--source-lang` — defaults to
      `PhoenixKitEcommerce.Translations.default_language/0`.
    * `--languages` — comma-separated target languages; defaults to
      every enabled language except the source (mirrors design §4.6's
      default for the `shop_translation_languages` setting).

  ## Safety

  This task touches ONLY the `metadata` column (the
  `_translation_fingerprints` key within it) — it never writes
  translated content, slugs, or any other field. Each table gets exactly
  one `UPDATE`, matching the cost design §2 measured for a full-catalog
  hash pass (tens of milliseconds, not a per-row loop). Run it against
  the shared stand only as the project's own separate, explicitly
  announced live-verification step (see the project's worktree
  instructions) — never as a byproduct of running this package's tests,
  and never against the dev database from a throwaway checkout.
  """

  use Mix.Task
  use PhoenixKit.SchemaPrefix

  @dialyzer {:nowarn_function, run: 1}
  @dialyzer {:nowarn_function, build_sql: 2}

  alias Ecto.Adapters.SQL
  alias PhoenixKitEcommerce.TranslationFingerprint
  alias PhoenixKitEcommerce.Translations

  @shortdoc "One-shot: stamp existing shop translations' sources as the fingerprint reference"

  @switches [
    dry_run: :boolean,
    source_lang: :string,
    languages: :string
  ]

  # Field name == the schema/JSONB column name == the fingerprint key
  # (design §4.1's example metadata uses "body_html", not the AI-prompt
  # vocabulary's "body") — kept in lockstep with `AITranslatable`'s
  # `@schema_fields` and, once it exists, the category adapter's field
  # list (design §4.2: `name`, `description` — `slug` is excluded there
  # exactly as it is for products).
  @product_fields ~w(title description body_html seo_title seo_description)
  @category_fields ~w(name description)

  @impl Mix.Task
  def run(args) do
    {opts, _args} = OptionParser.parse!(args, strict: @switches)
    dry_run = Keyword.get(opts, :dry_run, false)

    Mix.Task.run("app.start")

    repo = PhoenixKit.RepoHelper.repo()
    source_lang = Keyword.get(opts, :source_lang) || Translations.default_language()
    target_langs = resolve_target_langs(opts, source_lang)

    run_with_targets(repo, source_lang, target_langs, dry_run)
  end

  defp run_with_targets(_repo, source_lang, [], _dry_run) do
    Mix.shell().error("No target languages resolved (source: #{source_lang}) — nothing to do.")
  end

  defp run_with_targets(repo, source_lang, target_langs, dry_run) do
    label = if dry_run, do: " (DRY RUN — no writes)", else: ""

    Mix.shell().info(
      "Backfilling translation fingerprints — source: #{source_lang}, " <>
        "targets: #{Enum.join(target_langs, ", ")}#{label}"
    )

    repo
    |> backfill(source_lang, target_langs, dry_run: dry_run)
    |> Enum.each(&report_result(&1, dry_run))
  end

  defp report_result({table, count}, dry_run) do
    verb = if dry_run, do: "would touch", else: "touched"
    Mix.shell().info("  #{table}: #{verb} #{count} row(s)")
  end

  defp resolve_target_langs(opts, source_lang) do
    case Keyword.get(opts, :languages) do
      nil ->
        Translations.enabled_languages() -- [source_lang]

      raw ->
        raw
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end
  end

  @doc """
  The backfill itself, factored out of `run/1` so it can be exercised
  directly against a test database without going through
  `Mix.Task.run("app.start")`. One `UPDATE` (or, with `dry_run: true`,
  one `SELECT count(*)`) per table — see the moduledoc for exactly what
  it touches. Returns `[{table_name, affected_row_count}]`.
  """
  @spec backfill(Ecto.Repo.t(), String.t(), [String.t()], keyword()) ::
          [{String.t(), non_neg_integer()}]
  def backfill(repo, source_lang, target_langs, opts \\ [])
      when is_binary(source_lang) and is_list(target_langs) do
    dry_run = Keyword.get(opts, :dry_run, false)

    for {table, fields} <- [
          {"phoenix_kit_shop_products", @product_fields},
          {"phoenix_kit_shop_categories", @category_fields}
        ] do
      {table, run_table(repo, table, fields, source_lang, target_langs, dry_run)}
    end
  end

  defp run_table(repo, table, fields, source_lang, target_langs, dry_run) do
    qualified_table = TranslationFingerprint.qualify_table(table, @schema_prefix)
    {count_sql, update_sql} = build_sql(qualified_table, fields)
    sql = if dry_run, do: count_sql, else: update_sql

    # $3 (the trim character set) only appears in the UPDATE — the
    # count query has no hash expression, and Postgres rejects a bind
    # carrying more parameters than the statement uses.
    params =
      if dry_run do
        [target_langs, source_lang]
      else
        [target_langs, source_lang, TranslationFingerprint.sql_trim_chars()]
      end

    case SQL.query(repo, sql, params) do
      {:ok, %{rows: [[count]]}} when dry_run ->
        count

      {:ok, %{num_rows: count}} ->
        count

      {:error, error} ->
        raise "backfill_translation_fingerprints failed on #{table}: #{inspect(error)}"
    end
  end

  # $1 = target_langs (text[]), $2 = source_lang (text), $3 = the trim
  # character set (UPDATE only — see run_table/6). A row is touched
  # only when AT LEAST ONE field, for AT LEAST ONE target language, has
  # both a non-empty source and a non-empty translation already — the
  # exact same "has something to stamp" predicate for both the dry-run
  # count and the real UPDATE's WHERE, so the two never disagree.
  #
  # `table` arrives already schema-qualified (see `run_table/6`,
  # `TranslationFingerprint.qualify_table/2`) — this function just
  # interpolates it into `UPDATE`/`FROM`. `def`, not `defp`: exposed
  # (doc false) so a test can pin the prefix actually reaching this
  # string without a live prefixed database.
  @doc false
  @spec build_sql(String.t(), [String.t()]) :: {String.t(), String.t()}
  def build_sql(table, fields) do
    touch_predicate = Enum.map_join(fields, "\n           OR ", &field_present_clause/1)

    exists_clause = """
    EXISTS (
      SELECT 1 FROM unnest($1::text[]) AS t(lang)
      WHERE #{touch_predicate}
    )
    """

    field_pairs = Enum.map_join(fields, ",\n              ", &field_pair/1)

    # For each target language, merge freshly-computed hashes (nulls
    # stripped, so a field with no source/translation leaves whatever was
    # already there untouched) on top of that language's existing
    # fingerprints; then merge those per-language results on top of the
    # FULL existing fingerprints object, so a language not in
    # target_langs is carried through unchanged rather than dropped.
    update_sql = """
    UPDATE #{table} AS p
    SET metadata = jsonb_set(
      coalesce(p.metadata, '{}'::jsonb),
      '{_translation_fingerprints}',
      coalesce(p.metadata->'_translation_fingerprints', '{}'::jsonb)
        || coalesce((
          SELECT jsonb_object_agg(t.lang, per_lang.merged)
          FROM unnest($1::text[]) AS t(lang)
          CROSS JOIN LATERAL (
            SELECT coalesce(p.metadata->'_translation_fingerprints'->t.lang, '{}'::jsonb)
                   || jsonb_strip_nulls(jsonb_build_object(
              #{field_pairs}
                   )) AS merged
          ) AS per_lang
        ), '{}'::jsonb),
      true
    )
    WHERE #{exists_clause}
    """

    count_sql = """
    SELECT count(*)
    FROM #{table} AS p
    WHERE #{exists_clause}
    """

    {count_sql, update_sql}
  end

  defp field_pair(field), do: "'#{field}', #{field_hash_expr(field)}"

  defp field_hash_expr(field) do
    """
    CASE
                WHEN nullif(p."#{field}"->>$2,'') IS NOT NULL
                     AND nullif(p."#{field}"->>t.lang,'') IS NOT NULL
                THEN encode(sha256(convert_to(btrim(p."#{field}"->>$2, $3),'UTF8')),'hex')
              END
    """
  end

  defp field_present_clause(field) do
    "(nullif(p.\"#{field}\"->>$2,'') IS NOT NULL AND nullif(p.\"#{field}\"->>t.lang,'') IS NOT NULL)"
  end
end
