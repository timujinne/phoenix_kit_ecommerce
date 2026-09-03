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
  collision); there is no DB unique constraint on the JSONB slug map (core
  migration v47 dropped it), so the check is best-effort across rows.

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
      {:error, :no_translated_fields}
    else
      case merge_translation(uuid, target_lang, translated) do
        {:ok, updated} = ok ->
          Events.broadcast_product_updated(updated)
          log_translated(updated, target_lang, opts)
          ok

        error ->
          error
      end
    end
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

  defp merge_translation(uuid, target_lang, translated) do
    repo().transaction(fn ->
      query = Product |> where([p], p.uuid == ^uuid) |> lock("FOR UPDATE")

      case repo().one(query) do
        nil -> repo().rollback(:resource_not_found)
        %Product{} = fresh -> write_merged(fresh, target_lang, translated)
      end
    end)
  end

  defp write_merged(%Product{} = fresh, target_lang, translated) do
    changes =
      translated
      |> Enum.reduce(%{}, fn {schema_field, value}, acc ->
        merged = Map.put(Map.get(fresh, schema_field) || %{}, target_lang, value)
        Map.put(acc, schema_field, merged)
      end)
      |> maybe_put_slug(fresh, target_lang, translated[:title])

    case fresh |> Ecto.Changeset.change(changes) |> repo().update() do
      {:ok, updated} -> updated
      {:error, reason} -> repo().rollback(reason)
    end
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
