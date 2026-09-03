defmodule PhoenixKitEcommerce.AITranslatable do
  @moduledoc """
  `PhoenixKitAI.Translatable` adapter for shop products.

  ## Resource identity

  `resource_type` is `"shop_product"`; `resource_uuid` is the product uuid.

  ## Fields

  `%{"title", "description", "body", "seo_title", "seo_description"}` from
  the source language (`Translations.get/3`), non-empty only. `"body"` maps
  to the schema's `body_html` (the shared prompt vocabulary uses `body`).
  The slug is NEVER sourced from or trusted to the AI — it is regenerated
  locally from the translated title, and only when the target language has
  no slug yet, so re-translations can't change published URLs (which is why
  no slug-history/redirect machinery is needed).

  ## Concurrency

  All languages share ONE product row's JSONB maps, so `put_translation/4`
  re-reads the row under `FOR UPDATE` and merges against the latest
  committed state (the publishing group-adapter pattern) — concurrent
  per-language jobs serialize on the row lock and never drop a sibling
  language. `update_product/2` / `update_product_translation/3` are
  deliberately NOT used here: they write a stale in-memory struct without a
  lock — the exact lost-update race this adapter must prevent.

  Slug uniqueness within the language is checked app-side (suffix on
  collision), not by asking the database to reject a collision: this
  comment used to say there was no DB constraint to ask (core migration
  v47 dropped it), which is no longer true. V171 added back a real one —
  a `phoenix_kit_shop_product_slugs` projection table (trigger-maintained)
  whose pkey is `unique_constraint(:slug, name:
  "phoenix_kit_shop_product_slugs_pkey")` in `Product.changeset/2`
  (mirrored for categories, design §4.2). This adapter still probes
  app-side rather than relying on that constraint and catching the error —
  changing that is out of scope here, but the probe is correctly described
  as best-effort now for a different reason: it checks by full language
  code (`"de-DE"`) while the projection buckets by base language (`"de"`),
  so it can race a sibling dialect it never queried, not because nothing
  in the database would catch the collision.

  ## Staleness / write-narrowing (design §4.1, §4.4)

  The SAME `FOR UPDATE` lock that makes concurrent languages safe is also
  what makes per-field write-narrowing correct: `put_translation/4`
  decides, field by field, whether a translation is worth writing by
  comparing `opts[:source_fields]` (the exact text this job read and
  translated — see `PhoenixKitEcommerce.TranslationFingerprint`) against
  the CURRENTLY stored translation and fingerprint of the freshly-locked
  row, never against the possibly-stale `resource` argument. A field whose
  fingerprint still matches is left untouched even though a fresh AI
  response for it is sitting right there — that's what stops a routine
  re-translation from clobbering a manual edit. Resetting a resource's
  fingerprints (`reset_reference/3`) is the only supported way to lift
  that protection ("перевести заново", design §4.4).

  ## Prompt

  The seo fields are not in the shared translation prompt's vocabulary, so
  this adapter ships its own prompt (`ensure_prompt/0`, slug
  `phoenixkit-shop-product-translation`). Host forms must pass its uuid
  per job — the global `ai_translation_prompt_uuid` setting stays untouched.

  The prompt template lives in `prompt_attrs/0` in code, but the row in
  `phoenix_kit_ai_prompts` is what's actually asked — a code change alone
  reaches nobody until `ensure_prompt/0` rolls it out. That rollout (create
  vs. update-in-place vs. leave-a-hand-edit-alone) is `PromptRollout.ensure/2`
  (design §5.2); see that module for the full invariant. The template itself
  is built on `{{SourceFields}}` (phoenix_kit_ai §9.1) — one marker section
  per field actually passed — rather than one hardcoded `{{fieldname}}` slot
  per field, which is what let a "skip literal placeholders" rule upstream
  mistake an unbound `{{title}}` for a real placeholder and skip translating
  the title outright (design §2). That rule is gone; there is nothing left
  for it to misfire on.

  Requires the optional `phoenix_kit_ai` plugin: `ensure_prompt/0` returns
  `{:error, :ai_not_installed}` when it is absent, and the whole adapter is
  only reached through duck-typed discovery, which never runs without it.
  """

  # Structurally implements the `PhoenixKitAI.Translatable` behaviour, but we
  # DON'T declare `@behaviour` — phoenix_kit_ai is an optional dependency and a
  # declared behaviour would force it at compile time. Discovery is duck-typed
  # (`ai_translatables/0` + `PhoenixKitAI.Translatables`), so this module is
  # only ever exercised when the plugin is present; the guarded PhoenixKitAI
  # calls in ensure_prompt/0 are quietened for the plugin-absent build.
  @compile {:no_warn_undefined, PhoenixKitAI}

  import Ecto.Query, only: [where: 3, lock: 2, from: 2]

  alias PhoenixKitEcommerce.Activity
  alias PhoenixKitEcommerce.Events
  alias PhoenixKitEcommerce.Product
  alias PhoenixKitEcommerce.PromptRollout
  alias PhoenixKitEcommerce.TranslationFingerprint

  @resource_type "shop_product"
  @prompt_name "PhoenixKit Shop Product Translation"
  # MUST equal slugify(@prompt_name): create_prompt derives the stored slug
  # from the NAME, so the idempotent get_prompt_by_slug re-read only finds
  # the row when the lookup slug matches that derived value. A mismatch makes
  # ensure_prompt/0 fail with :prompt_create_failed on every call after the
  # first (unique-name violation, then a slug miss).
  @prompt_slug "phoenixkit-shop-product-translation"

  # sha256(content) of every template this adapter has ever shipped BEFORE
  # PromptRollout's metadata scheme existed — consulted only to adopt a
  # stand's pre-existing unversioned row (design §5.2). This one entry is
  # the "literal placeholder" template §2 diagnoses: it hardcoded one
  # `{{fieldname}}` slot per field, which let the model see its own
  # unbound `{{title}}` and skip the title as if it were a placeholder.
  # Once a row is adopted it carries metadata and this list is never
  # consulted for it again — it never needs a second entry.
  @known_previous_shas [
    "751962e45dbea4bd36ef56c60558425c40aa8760767501211370d4363f42d232"
  ]

  # field name in the prompt/pipeline => schema field
  @field_map %{
    "title" => :title,
    "description" => :description,
    "body" => :body_html,
    "seo_title" => :seo_title,
    "seo_description" => :seo_description
  }

  # The reverse of @field_map — write-narrowing looks a field up by its
  # SCHEMA name (the key `translated`, the AI response after clean/1, is
  # keyed by) but needs the PROMPT name to find that field's source text
  # in opts[:source_fields] (which is keyed the way source_fields/2 built
  # it — prompt vocabulary).
  @schema_to_prompt Map.new(@field_map, fn {prompt_field, schema_field} ->
                      {schema_field, prompt_field}
                    end)

  # Fingerprints are keyed by SCHEMA field name (design §4.1's example
  # metadata uses "body_html", not the prompt vocabulary's "body") —
  # deliberately the same identifier as the JSONB column itself, so the
  # candidate SQL (TranslationFingerprint.select_candidates/2) can address
  # both with one `#{field}` interpolation.
  @schema_fields Map.values(@field_map) |> Enum.map(&Atom.to_string/1)

  @doc "The resource-type key this adapter registers under."
  def resource_type, do: @resource_type

  def fetch(@resource_type, product_uuid) when is_binary(product_uuid) do
    case repo().get(Product, product_uuid) do
      nil -> {:error, :resource_not_found}
      %Product{} = product -> {:ok, product}
    end
  end

  def fetch(_resource_type, _uuid), do: {:error, :resource_not_found}

  def source_fields(%Product{} = product, source_lang) do
    # Read the source language DIRECTLY, without Translations.get/3's
    # exact→default→first fallback: translating with the prompt saying
    # "from {{SourceLanguage}}" while feeding another language's text would
    # silently corrupt the result.
    @field_map
    |> Enum.map(fn {prompt_field, schema_field} ->
      {prompt_field, Map.get(Map.get(product, schema_field) || %{}, source_lang)}
    end)
    |> Enum.filter(fn {_k, v} -> is_binary(v) and String.trim(v) != "" end)
    |> Map.new()
  end

  def put_translation(%Product{uuid: uuid}, target_lang, fields, opts)
      when is_binary(target_lang) do
    translated =
      for {prompt_field, schema_field} <- @field_map,
          value = clean(fields[prompt_field]),
          value != nil,
          into: %{} do
        {schema_field, value}
      end

    if translated == %{} do
      # Nothing usable came back from the caller at all (blank/absent
      # response) — a real error, distinct from every field being
      # write-narrowed away below (which is a success, not this).
      {:error, :no_translated_fields}
    else
      source_fields = Keyword.get(opts, :source_fields) || %{}

      case merge_translation(uuid, target_lang, translated, source_fields) do
        {:ok, {:written, updated}} ->
          Events.broadcast_product_updated(updated)
          log_translated(updated, target_lang, opts)
          {:ok, updated}

        # Design §4.4: every field was write-narrowed away (each one's
        # fingerprint still matched its stored translation) — success,
        # but the row didn't change, so no update event and no
        # ai.translation_added activity entry (that log is about a
        # write that happened, not a call that happened).
        {:ok, {:skipped, current}} ->
          {:ok, current}

        {:error, _reason} = error ->
          error
      end
    end
  end

  @doc """
  "Перевести заново" (design §4.4): erases the stored fingerprints for
  `target_langs` × `fields` (schema field atoms; defaults to every
  fingerprinted field) under the same `FOR UPDATE` lock
  `put_translation/4` uses. The translated content itself is untouched —
  this only lifts write-narrowing's protection, so the next
  `put_translation/4` for that pair writes again even if the source
  hasn't changed. Until that next call lands, the reset field reads as
  `:unknown` (design §4.4: "пара со сброшенным эталоном до завершения
  задания числится unknown"), which is also why this never broadcasts a
  product-updated event — nothing visible changed, only bookkeeping.
  """
  @spec reset_reference(String.t(), [String.t()], [atom()]) ::
          {:ok, Product.t()} | {:error, term()}
  def reset_reference(uuid, target_langs, fields \\ Map.values(@field_map))
      when is_binary(uuid) and is_list(target_langs) and is_list(fields) do
    field_strings = Enum.map(fields, &Atom.to_string/1)

    repo().transaction(fn ->
      query = Product |> where([p], p.uuid == ^uuid) |> lock("FOR UPDATE")

      case repo().one(query) do
        nil -> repo().rollback(:resource_not_found)
        %Product{} = fresh -> apply_reset(fresh, target_langs, field_strings)
      end
    end)
  end

  defp apply_reset(%Product{} = fresh, target_langs, field_strings) do
    new_metadata = TranslationFingerprint.drop(fresh.metadata, target_langs, field_strings)

    case fresh |> Ecto.Changeset.change(%{metadata: new_metadata}) |> repo().update() do
      {:ok, updated} -> updated
      {:error, reason} -> repo().rollback(reason)
    end
  end

  @doc """
  "Проштамповать текущий источник как эталон" (design §4.1, §4.5): for
  every `{lang, field}` pair in `target_langs` × `fields` (schema field
  atoms; defaults to every fingerprinted field) that currently HAS a
  stored translation, writes the CURRENT source text's hash as its
  fingerprint — without calling the model and without touching the
  translation value. A field with no stored translation is left alone
  (nothing to certify — `:missing` stays `:missing`); a field whose
  source is blank is left alone too (mirrors `TranslationFingerprint`'s
  own "no source, no state" rule). Runs under the same `FOR UPDATE` lock
  `put_translation/4` / `reset_reference/3` use, and reads the source
  text itself off the freshly-locked row — never off a possibly-stale
  caller-supplied struct — so this can't race a concurrent write. Every
  stamped field reads as `:fresh` immediately afterward, by construction
  (the fingerprint IS `hash(current source)`).
  """
  @spec stamp_reference(String.t(), String.t(), [String.t()], [atom()]) ::
          {:ok, Product.t()} | {:error, term()}
  def stamp_reference(uuid, source_lang, target_langs, fields \\ Map.values(@field_map))
      when is_binary(uuid) and is_binary(source_lang) and is_list(target_langs) and
             is_list(fields) do
    repo().transaction(fn ->
      query = Product |> where([p], p.uuid == ^uuid) |> lock("FOR UPDATE")

      case repo().one(query) do
        nil -> repo().rollback(:resource_not_found)
        %Product{} = fresh -> apply_stamp(fresh, source_lang, target_langs, fields)
      end
    end)
  end

  defp apply_stamp(%Product{} = fresh, source_lang, target_langs, fields) do
    new_metadata =
      Enum.reduce(target_langs, fresh.metadata, fn lang, metadata ->
        field_hashes = stampable_field_hashes(fresh, source_lang, lang, fields)
        TranslationFingerprint.put_many(metadata, lang, field_hashes)
      end)

    case fresh |> Ecto.Changeset.change(%{metadata: new_metadata}) |> repo().update() do
      {:ok, updated} -> updated
      {:error, reason} -> repo().rollback(reason)
    end
  end

  # Only fields that have BOTH a non-empty source and an existing
  # translation for `lang` get stamped — see the moduledoc on
  # `stamp_reference/4`.
  defp stampable_field_hashes(%Product{} = fresh, source_lang, lang, fields) do
    for schema_field <- fields,
        source = fresh |> Map.get(schema_field, %{}) |> then(&(&1 || %{})) |> Map.get(source_lang),
        is_binary(source) and String.trim(source) != "",
        translation = fresh |> Map.get(schema_field, %{}) |> then(&(&1 || %{})) |> Map.get(lang),
        is_binary(translation) and String.trim(translation) != "",
        into: %{} do
      {Atom.to_string(schema_field), TranslationFingerprint.hash(source)}
    end
  end

  @doc """
  Design §4.3's candidate query: products with at least one field
  `:missing` or `:stale` (design §4.1) for a target language, hashed
  entirely in the database — see
  `PhoenixKitEcommerce.TranslationFingerprint.select_candidates/2`.

  `opts`:

    * `:statuses` — product-status filter (design §4.3 step 5); `nil`
      (default) applies none.
    * `:limit` — row cap (one row per `{uuid, language}` candidate
      pair, not per product).
  """
  @spec candidates(String.t(), [String.t()], keyword()) :: [
          %{uuid: String.t(), languages: [String.t()]}
        ]
  def candidates(source_lang, target_langs, opts \\ [])
      when is_binary(source_lang) and is_list(target_langs) do
    TranslationFingerprint.select_candidates(repo(),
      table: "phoenix_kit_shop_products",
      fields: @schema_fields,
      source_lang: source_lang,
      target_langs: target_langs,
      statuses: Keyword.get(opts, :statuses),
      limit: Keyword.get(opts, :limit)
    )
  end

  @doc """
  Idempotently rolls out this adapter's translation prompt and returns its
  uuid — host forms pass it per job instead of the shared default prompt.

  Beyond the first call this is not a pure no-op read: a code change to
  `prompt_attrs/0` reaches the database here, via `PromptRollout.ensure/2`
  (design §5.2) — see that module for exactly when it updates a row in
  place versus leaves it alone. The returned `sync_status` matters mainly
  to callers surfacing rollout state (e.g. a translations management
  page); `:diverged` still returns a perfectly usable uuid — an
  operator-edited prompt keeps working, it's just no longer code-managed
  until someone resolves the divergence by hand.
  """
  @spec ensure_prompt() ::
          {:ok, String.t(), PromptRollout.sync_status()} | {:error, term()}
  def ensure_prompt do
    if Code.ensure_loaded?(PhoenixKitAI) and function_exported?(PhoenixKitAI, :create_prompt, 1) do
      PromptRollout.ensure(prompt_attrs(), @known_previous_shas)
    else
      {:error, :ai_not_installed}
    end
  end

  # -- internals ---------------------------------------------------------

  defp merge_translation(uuid, target_lang, translated, source_fields) do
    repo().transaction(fn ->
      query = Product |> where([p], p.uuid == ^uuid) |> lock("FOR UPDATE")

      case repo().one(query) do
        nil -> repo().rollback(:resource_not_found)
        %Product{} = fresh -> write_merged(fresh, target_lang, translated, source_fields)
      end
    end)
  end

  defp write_merged(%Product{} = fresh, target_lang, translated, source_fields) do
    {field_changes, fingerprint_updates, written_fields} =
      narrow_writes(fresh, target_lang, translated, source_fields)

    if field_changes == %{} do
      {:skipped, fresh}
    else
      # Design §4.4's slug corner: the slug is derived from whichever
      # title text is actually about to be true after this write — the
      # just-written translation if :title was written this round,
      # otherwise the title translation already stored (covers both "the
      # model didn't return a title this time" and "title was
      # write-narrowed away") — never blank just because this call
      # didn't touch :title.
      title_for_slug =
        if :title in written_fields do
          translated[:title]
        else
          fresh.title |> then(&(&1 || %{})) |> Map.get(target_lang)
        end

      changes =
        field_changes
        |> maybe_put_slug(fresh, target_lang, title_for_slug)
        |> maybe_put_metadata(fresh, target_lang, fingerprint_updates)

      case fresh |> Ecto.Changeset.change(changes) |> repo().update() do
        {:ok, updated} -> {:written, updated}
        {:error, reason} -> repo().rollback(reason)
      end
    end
  end

  # Design §4.4's write-narrowing table, applied per field against the
  # FRESHLY-LOCKED row (never the possibly-stale `resource` the worker
  # loaded before the multi-second AI call) — returns the field changes
  # to write, the fingerprint updates to stamp, and which schema fields
  # were actually written (the slug step above needs to know that last
  # part specifically for :title).
  defp narrow_writes(fresh, target_lang, translated, source_fields) do
    Enum.reduce(translated, {%{}, %{}, []}, fn {schema_field, value}, acc ->
      apply_write_decision(fresh, target_lang, source_fields, schema_field, value, acc)
    end)
  end

  defp apply_write_decision(
         fresh,
         target_lang,
         source_fields,
         schema_field,
         value,
         {changes, fps, written}
       ) do
    prompt_field = Map.fetch!(@schema_to_prompt, schema_field)
    source = source_fields[prompt_field]

    existing_translation =
      fresh |> Map.get(schema_field) |> then(&(&1 || %{})) |> Map.get(target_lang)

    fp_field = Atom.to_string(schema_field)
    existing_fp = TranslationFingerprint.get(fresh.metadata, target_lang, fp_field)

    case TranslationFingerprint.write_decision(source, existing_translation, existing_fp) do
      :skip ->
        {changes, fps, written}

      {:write, new_fp} ->
        merged_field = Map.put(Map.get(fresh, schema_field) || %{}, target_lang, value)
        new_changes = Map.put(changes, schema_field, merged_field)
        new_fps = put_fingerprint(fps, fp_field, new_fp)
        {new_changes, new_fps, [schema_field | written]}
    end
  end

  defp put_fingerprint(fps, _fp_field, nil), do: fps
  defp put_fingerprint(fps, fp_field, new_fp), do: Map.put(fps, fp_field, new_fp)

  defp maybe_put_metadata(changes, _fresh, _target_lang, fingerprint_updates)
       when fingerprint_updates == %{},
       do: changes

  defp maybe_put_metadata(changes, fresh, target_lang, fingerprint_updates) do
    Map.put(
      changes,
      :metadata,
      TranslationFingerprint.put_many(fresh.metadata, target_lang, fingerprint_updates)
    )
  end

  # A locally-generated slug from the translated title, ONLY when the target
  # language has none yet — re-translations never rewrite an existing slug.
  defp maybe_put_slug(changes, %Product{} = fresh, target_lang, translated_title) do
    slug_map = fresh.slug || %{}

    cond do
      Map.get(slug_map, target_lang) not in [nil, ""] ->
        changes

      translated_title in [nil, ""] ->
        changes

      true ->
        base = slug_base(translated_title, slug_map, target_lang)
        slug = unique_slug(base, target_lang, fresh.uuid)
        Map.put(changes, :slug, Map.put(slug_map, target_lang, slug))
    end
  end

  @slug_max_len 80

  # A URL slug from the translated title, capped to a sane length. Scripts
  # with no romanizer (CJK, Arabic, emoji) still slugify to "" — Cyrillic
  # does not, now that transliteration is the default — and fall back to
  # the default-language slug + a language suffix so the language always
  # gets a non-empty per-language slug instead of silently serving the
  # default-language URL.
  defp slug_base(translated_title, slug_map, target_lang) do
    # target_lang is the language the TRANSLATED title is in, so the slug must be
    # generated in it — a German translation wants ö -> oe, an Estonian one ö -> o.
    case translated_title |> Product.slugify(target_lang) |> String.slice(0, @slug_max_len) do
      "" -> "#{default_lang_slug(slug_map)}-#{target_lang}"
      base -> base
    end
  end

  defp default_lang_slug(slug_map) do
    case slug_map |> Map.values() |> Enum.find(&(is_binary(&1) and &1 != "")) do
      nil -> "product"
      slug -> slug
    end
  end

  # Best-effort per-language uniqueness (no DB constraint on the JSONB map).
  defp unique_slug(base, lang, own_uuid), do: unique_slug(base, lang, own_uuid, 0)

  defp unique_slug(base, lang, own_uuid, attempt) when attempt < 10 do
    candidate = if attempt == 0, do: base, else: "#{base}-#{attempt + 1}"

    taken? =
      repo().exists?(
        from(p in Product,
          where: fragment("?->>? = ?", p.slug, ^lang, ^candidate) and p.uuid != ^own_uuid
        )
      )

    if taken?, do: unique_slug(base, lang, own_uuid, attempt + 1), else: candidate
  end

  defp unique_slug(base, _lang, _own_uuid, attempt), do: "#{base}-#{attempt + 1}"

  defp clean(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      _ -> value
    end
  end

  defp clean(_), do: nil

  defp log_translated(%Product{} = product, target_lang, opts) do
    Activity.log("shop.product.updated",
      mode: "auto",
      actor_uuid: opts[:actor_uuid],
      resource_type: "product",
      resource_uuid: product.uuid,
      metadata: %{"target_language" => target_lang, "source" => "ai_translation"}
    )
  end

  # §5.1/§9.1: built on the dynamic {{SourceFields}} block rather than one
  # hardcoded {{fieldname}} slot per field. The old per-slot template left a
  # slot like {{seo_title}} unbound whenever a product had no SEO text (only
  # non-empty fields are ever passed in, per source_fields/2), and the
  # "skip literal placeholders" rule that was patched in to handle that
  # matched the model's own unbound {{title}} slot too — the model read it
  # as "this is a placeholder, not real text" and silently skipped
  # translating the title (design §2). {{SourceFields}} only ever contains
  # markers for fields that were actually passed, so there is no unbound
  # slot left in the prose for a "skip placeholders" rule to misfire on —
  # and so that rule is gone, not tightened.
  defp prompt_attrs do
    %{
      slug: @prompt_slug,
      name: @prompt_name,
      description: "Translates shop product fields (incl. SEO) between languages.",
      content: """
      You are translating fields of an e-commerce product from {{SourceLanguage}} to {{TargetLanguage}}.

      RULES:
      - Preserve formatting exactly (line breaks, spacing, HTML if present).
      - Do NOT translate text inside code blocks, inline code, or URLs.
      - Translate naturally and idiomatically — commercial tone, natural for a shop.
      - Keep any HTML tags and attributes unchanged; translate only human-visible text.
      - Keep brand names, materials and measurements as-is unless they have a standard translation.
      - Output ONLY the structured markers below — no commentary, no preface, no closing remarks.

      The SOURCE section below has one marker per field of this product that
      needs translating — there is no fixed set of fields, so read whichever
      markers are actually present. For EACH marker in SOURCE, emit that
      SAME marker name back, followed by its translation:

          ---TITLE---
          [translated title]

      Emit a marker for every field in SOURCE and no others — never invent
      a marker that wasn't there, and never skip one that was.

      === SOURCE ===

      {{SourceFields}}
      """
    }
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
