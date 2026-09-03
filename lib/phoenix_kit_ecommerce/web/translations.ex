defmodule PhoenixKitEcommerce.Web.Translations do
  @moduledoc """
  `/admin/shop/translations` — the management page design §4.5 calls the
  core of this whole initiative: "интерфейс — ядро задачи." Everything
  built in tasks 3–5 (fingerprints/staleness, the category adapter, the
  reconciliation sweep) is reachable ONLY from here — design §1's
  requirement that no capability exist the interface can't reach.

  ## Why this page does NOT use `phoenix_kit_ai`'s `AITranslate` components

  `FormGlue` / `Embed` / `AITranslate` (design §4.5) are hard-wired to ONE
  resource: one `ai_resource_uuid`, one subscription, scalar
  `ai_in_flight?` / `ai_progress` / `ai_modal_open`, one
  `<dialog id="ai-translation-modal">`. A coverage table with many rows
  would collide on every one of those. This page is built directly on
  `PhoenixKitAI.Translations.enqueue/1` / `enqueue_all_missing/2` — both
  stateless, both taking identifiers as plain arguments — plus this
  package's own `AITranslatable` / `CategoryAITranslatable` adapters.

  ## Data model: rows and columns

  A row is a resource (product or category, per `@type_filter` — the two
  types are never mixed in one table because their field vocabularies
  differ). A column is a target language from
  `TranslationSweepSettings.languages/0`. A cell holds that resource's
  FOLDED state for that language (design §4.1's `missing > stale >
  unknown > fresh`), computed from `TranslationFingerprint.field_state/3`
  over every translatable field.

  States are computed in this process, not via
  `TranslationFingerprint.select_candidates/2`'s hash-in-the-database
  query — that query deliberately returns ONLY `missing`/`stale`
  candidates (design §4.3: "наружу приезжают только uuid и список
  языков"), which is exactly wrong for a table that must also show
  `fresh` and `unknown`. At this catalog's measured size (665 products, 7
  categories — design §2) loading the filtered set and folding states in
  Elixir is milliseconds, matching the design doc's own full-catalog hash
  measurements; this is an admin page, not a hot path.

  ## Bulk verbs and the field/lang scope

  Design §4.5: field/lang axes are smuggled into the `data-bulk-action`
  event NAME (`"request_translate:de-DE:seo_title"`), the same technique
  `PhoenixKitEcommerce.Web.ShopifySync` uses for its per-section actions —
  `BulkSelectScope`'s `data-bulk-action` has no way to attach an extra
  `phx-value-*`. `"all"` in either segment means "every configured target
  language" / "every field of this resource type" — see `bulk_event/3`
  and `parse_scope/3`.

  Three verbs (design §4.4, §4.5):

    * **translate** — `missing ∪ stale` only, computed fresh per resource
      at confirm time (never trusts the request-time snapshot — see
      `PhoenixKitEcommerce.Web.ShopifySync`'s moduledoc on why). The
      field scope narrows nothing here (design §4.4: "На состав задания
      он не влияет") — only the already-filtered row selection does that.
    * **retranslate** ("перевести заново") — resets the fingerprints for
      the selected langs × fields (`reset_reference/3`) and THEN enqueues
      for exactly that lang list, unconditionally: a freshly-reset field
      reads `:unknown`, which the ordinary missing∪stale computation
      would never pick up on its own.
    * **stamp** ("проштамповать") — `stamp_reference/4`, no model call.

  ## What is deliberately NOT here

  Per-field JOB scoping (design §12.2 rejected `resource_scope` for
  exactly this reason) — the field axis only narrows what gets WRITTEN
  (`put_translation/4`'s write-narrowing) and, for retranslate/stamp,
  what gets touched in `metadata`. A "translate" job always asks the
  model for every non-empty field.
  """

  use PhoenixKitEcommerce.Web, :live_view

  use PhoenixKitWeb.Live.UrlState,
    params: [
      type_filter: [default: "product", url_key: "type", in: ~w(product category)],
      category_filter: [default: nil, url_key: "category"],
      lang_filter: [default: nil, url_key: "lang"],
      state_filter: [default: nil, url_key: "state", in: ~w(missing stale unknown fresh)],
      field_filter: [default: nil, url_key: "field"],
      search: [default: "", url_key: "search"],
      page: [default: 1, cast: :integer, min: 1, url_key: "page"]
    ]

  import Ecto.Query, only: [from: 2]

  import PhoenixKitWeb.Components.Core.BulkSelect
  import PhoenixKitWeb.Components.Core.EmptyState

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Activity
  alias PhoenixKitEcommerce.AITranslatable
  alias PhoenixKitEcommerce.CategoryAITranslatable
  alias PhoenixKitEcommerce.TranslationFingerprint, as: Fingerprint
  alias PhoenixKitEcommerce.Translations
  alias PhoenixKitEcommerce.TranslationSweepSettings, as: SweepSettings
  alias PhoenixKitEcommerce.Web.Authz
  alias PhoenixKitEcommerce.Workers.TranslationSweepWorker, as: SweepWorker

  # phoenix_kit_ai is an OPTIONAL dependency (see mix.exs) — this whole
  # page is unreachable without it (mount refuses to render unless
  # `ai_translations_available?/0`), but the compiler still needs
  # convincing: every direct `PhoenixKitAI.Translations.*` call below is
  # otherwise an undefined-function warning under `--warnings-as-errors`.
  @compile {:no_warn_undefined, PhoenixKitAI.Translations}

  @per_page 25

  # Job states that mean "already in flight" — the same four
  # `PhoenixKitAI.Translations` and `TranslationSweepWorker` dedup
  # against (deliberately excludes `:suspended`, absent from some hosts'
  # `oban_job_state` enum — see those modules' docs).
  @incomplete_states ~w(available scheduled executing retryable)
  @translate_worker "PhoenixKitAI.TranslateWorker"

  # Design §8's own measured throughput: 44.6s average per call, ten
  # parallel `TranslateWorker` jobs. Used only for the confirm modal's
  # "≈N calls, about M minutes" estimate — never for anything that gates
  # a write.
  @avg_call_seconds 45
  @parallel_jobs 10

  # `Product` has no public `statuses/0` (unlike `Category`) — mirrors the
  # closed set `Product.changeset/2` validates against and
  # `TranslationSweepSettings`'s own `@default_statuses` module attribute.
  @product_statuses ~w(draft active archived)

  # ============================================================
  # Mount
  # ============================================================

  @impl true
  def mount(_params, _session, socket) do
    Authz.authorize_mount(socket, :manage_catalog, fn -> do_mount(socket) end)
  end

  defp do_mount(socket) do
    cond do
      not SweepSettings.translations_enabled?() ->
        unavailable(
          socket,
          gettext("Shop translations aren't enabled. Turn them on in E-Commerce settings first.")
        )

      not ai_translations_available?() ->
        unavailable(
          socket,
          gettext(
            "AI translation isn't available — configure an enabled AI endpoint in the AI section first."
          )
        )

      true ->
        if connected?(socket), do: PhoenixKitAI.Translations.subscribe()

        # Design §4.3: reached on every page mount so a broken chain
        # (server restart, Oban pruning) self-heals on the operator's
        # very next visit, without waiting for a settings save.
        SweepWorker.ensure_scheduled()

        {:ok,
         socket
         |> assign(:page_title, gettext("Shop Translations"))
         |> assign(:categories, Shop.list_categories())
         |> assign(:enabled_languages, Translations.enabled_languages())
         |> assign(:pending, nil)
         |> assign(:per_page, @per_page)}
    end
  end

  defp unavailable(socket, message) do
    {:ok,
     socket
     |> put_flash(:error, message)
     |> push_navigate(to: Routes.path("/admin/shop"))}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # ============================================================
  # UrlState -> load
  # ============================================================

  # `category_filter`, `lang_filter`, `field_filter` can't be validated by
  # `UrlState`'s own `in:` (their valid sets are runtime data: which
  # categories exist, which languages the sweep targets, which fields the
  # CURRENT `type_filter` has) — re-parsed here instead, the same pattern
  # `Web.Products` uses for its own `category_filter`. Assigning the
  # cleaned value back is the sanctioned way to make a bad URL value drop
  # out of the query string rather than resurrect itself on every patch.
  @impl true
  def handle_url_state(_state, socket) do
    target_langs = SweepSettings.languages()
    fields = fields_for_type(socket.assigns.type_filter)

    socket
    |> assign(:category_filter, parse_category_uuid(socket.assigns.category_filter))
    |> assign(:lang_filter, valid_member(socket.assigns.lang_filter, target_langs))
    |> assign(:field_filter, valid_field(socket.assigns.field_filter, fields))
    |> load_data()
  end

  defp load_data(socket) do
    source_lang = Translations.default_language()
    target_langs = SweepSettings.languages()
    type = socket.assigns.type_filter
    fields = fields_for_type(type)

    {rows, total} =
      type
      |> fetch_resources(socket.assigns.category_filter, socket.assigns.search)
      |> Enum.map(&build_row(&1, type, source_lang, target_langs, fields))
      |> Enum.filter(
        &row_matches?(
          &1,
          socket.assigns.lang_filter,
          socket.assigns.state_filter,
          socket.assigns.field_filter
        )
      )
      |> Enum.sort_by(& &1.title)
      |> paginate(socket.assigns.page)

    socket
    |> assign(:source_lang, source_lang)
    |> assign(:target_langs, target_langs)
    |> assign(:fields, fields)
    |> assign(:rows, rows)
    |> assign(:total, total)
    |> assign(:coverage, load_coverage(source_lang, target_langs))
    |> assign(:in_flight, count_in_flight())
    |> assign(:sweep_status, SweepWorker.status())
    |> assign(:sweep_settings, load_sweep_settings())
    |> assign(:prompt_sync, load_prompt_sync())
    |> assign(:diagnostics, recent_shop_requests(20))
  end

  defp fields_for_type("category"), do: Translations.category_fields() -- [:slug]
  defp fields_for_type(_product), do: Translations.product_fields() -- [:slug]

  defp adapter_for("category"), do: CategoryAITranslatable
  defp adapter_for(_product), do: AITranslatable

  defp fetch_resources("category", _category_filter, search) do
    Shop.list_categories(search: search)
  end

  defp fetch_resources(_product, category_filter, search) do
    Shop.list_products(category_uuid: category_filter, search: search, preload: [:category])
  end

  defp build_row(resource, type, source_lang, target_langs, fields) do
    states = resource_states(resource, source_lang, target_langs, fields)

    overall =
      states |> Map.values() |> Enum.flat_map(&Map.values/1) |> Fingerprint.fold()

    %{
      uuid: resource.uuid,
      type: type,
      title: display_title(resource, type, source_lang),
      category: (type == "product" && Map.get(resource, :category)) || nil,
      states: states,
      overall_state: overall
    }
  end

  defp display_title(resource, "category", source_lang),
    do: get_lang(Map.get(resource, :name), source_lang) || "—"

  defp display_title(resource, _product, source_lang),
    do: get_lang(Map.get(resource, :title), source_lang) || "—"

  # `%{lang => %{field => state}}` for one resource — the single
  # computation the table cells, the row filter, and the bulk-scope
  # estimate all read from (design §4.1's four states, folded per lang in
  # `row.overall_state` when needed, never folded here).
  defp resource_states(resource, source_lang, target_langs, fields) do
    for lang <- target_langs, into: %{} do
      field_states =
        for field <- fields, into: %{} do
          source = get_lang(Map.get(resource, field), source_lang)
          translation = get_lang(Map.get(resource, field), lang)
          fp = Fingerprint.get(resource.metadata, lang, Atom.to_string(field))
          {field, Fingerprint.field_state(source, translation, fp)}
        end

      {lang, field_states}
    end
  end

  defp get_lang(nil, _lang), do: nil
  defp get_lang(map, lang) when is_map(map), do: Map.get(map, lang)

  # A row is included when it has AT LEAST ONE (lang, field) matching the
  # active filters — with no filters at all this is "has any state", i.e.
  # every resource that has some translatable source text, which is what
  # a coverage table should default to.
  defp row_matches?(row, lang_filter, state_filter, field_filter) do
    langs = if lang_filter, do: [lang_filter], else: Map.keys(row.states)
    Enum.any?(langs, &lang_matches?(row, &1, state_filter, field_filter))
  end

  defp lang_matches?(row, lang, state_filter, field_filter) do
    field_states = Map.get(row.states, lang, %{})
    fields = if field_filter, do: [field_filter], else: Map.keys(field_states)
    Enum.any?(fields, &field_matches?(field_states, &1, state_filter))
  end

  defp field_matches?(field_states, field, state_filter) do
    case Map.get(field_states, field) do
      nil -> false
      state -> is_nil(state_filter) or Atom.to_string(state) == state_filter
    end
  end

  defp paginate(rows, page) do
    total = length(rows)
    offset = (max(page, 1) - 1) * @per_page
    {Enum.slice(rows, offset, @per_page), total}
  end

  # Design §4.5's `<.stat_card>` row: per-language fresh/stale/missing/unknown
  # counts across the WHOLE catalog (both resource types, no filters) —
  # deliberately independent of the table's current filters, which answer
  # a different question ("what am I looking at right now" vs. "what's
  # the overall state of the catalog").
  defp load_coverage(source_lang, target_langs) do
    product_fields = fields_for_type("product")
    category_fields = fields_for_type("category")

    all_rows =
      Enum.map(
        Shop.list_products(),
        &build_row(&1, "product", source_lang, target_langs, product_fields)
      ) ++
        Enum.map(
          Shop.list_categories(),
          &build_row(&1, "category", source_lang, target_langs, category_fields)
        )

    for lang <- target_langs, into: %{} do
      counts =
        all_rows
        |> Enum.map(fn row ->
          row.states |> Map.get(lang, %{}) |> Map.values() |> Fingerprint.fold()
        end)
        |> Enum.reject(&is_nil/1)
        |> Enum.frequencies()

      {lang,
       %{
         fresh: Map.get(counts, :fresh, 0),
         stale: Map.get(counts, :stale, 0),
         missing: Map.get(counts, :missing, 0),
         unknown: Map.get(counts, :unknown, 0)
       }}
    end
  end

  defp load_sweep_settings do
    %{
      sweep_enabled: SweepSettings.sweep_enabled?(),
      interval_minutes: SweepSettings.interval_minutes(),
      batch_size: SweepSettings.batch_size(),
      max_in_flight: SweepSettings.max_in_flight(),
      languages: SweepSettings.languages(),
      statuses: SweepSettings.statuses()
    }
  end

  # Design §4.5's "промпт расходится с версией модуля" banner —
  # `ensure_prompt/0` both rolls the prompt out AND reports whether an
  # operator's hand edit has diverged from what the module ships (design
  # §5.2). Calling it here (rather than only on first install) is what
  # lets the banner appear the moment a divergence happens, not only
  # after the next code deploy touches the prompt.
  defp load_prompt_sync do
    %{
      product: prompt_sync_status(AITranslatable),
      category: prompt_sync_status(CategoryAITranslatable)
    }
  end

  defp prompt_sync_status(adapter) do
    case adapter.ensure_prompt() do
      {:ok, _uuid, sync_status} -> sync_status
      {:error, _reason} -> :error
    end
  end

  defp count_in_flight do
    repo = PhoenixKit.RepoHelper.repo()
    shop_types = [AITranslatable.resource_type(), CategoryAITranslatable.resource_type()]

    from(j in "oban_jobs",
      where: j.worker == ^@translate_worker,
      where: j.state in ^@incomplete_states,
      where: fragment("?->>'resource_type' = ANY(?)", j.args, ^shop_types)
    )
    |> select_count()
    |> repo.one()
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  defp select_count(query), do: from(j in query, select: count(j.id))

  # Design §4.5's diagnostics panel. Reads the RAW `phoenix_kit_ai_requests`
  # table (schemaless — never `PhoenixKitAI.Request` directly, which would
  # tie this optional-dependency page's compilation to that module always
  # being present; `TranslationSweepWorker.count_in_flight/0` uses the same
  # schemaless-table technique for `oban_jobs`). Only SUCCESSFUL requests
  # carry `attribution` (design §4.5's honesty note: `log_failed_request/7`
  # never merges it) — a transport failure never shows up here, only a
  # request that reached the model and may still have parsed badly.
  defp recent_shop_requests(limit) do
    repo = PhoenixKit.RepoHelper.repo()
    shop_types = [AITranslatable.resource_type(), CategoryAITranslatable.resource_type()]

    from(r in "phoenix_kit_ai_requests",
      where: fragment("?->'attribution'->>'resource_type' = ANY(?)", r.metadata, ^shop_types),
      order_by: [desc: r.inserted_at],
      limit: ^limit,
      select: %{
        uuid: r.uuid,
        resource_type: fragment("?->'attribution'->>'resource_type'", r.metadata),
        resource_uuid: fragment("?->'attribution'->>'resource_uuid'", r.metadata),
        status: r.status,
        error_message: r.error_message,
        response: fragment("?->>'response'", r.metadata),
        # Design §4.5 asks this panel for BOTH halves — "сырой ответ модели
        # и отправленный промпт". The sent half is the load-bearing one:
        # design §2 diagnosed this initiative's root defect (`{{title}}`
        # substituted into the prompt's own prose) by reading the RENDERED
        # prompt off these rows, not the response. `metadata->'messages'`
        # is what the AI request log stores, subject to the same
        # `:capture_request_content` gate as `response` (default `true`).
        messages: fragment("?->'messages'", r.metadata),
        inserted_at: r.inserted_at
      }
    )
    |> repo.all()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  # ============================================================
  # Filters
  # ============================================================

  @impl true
  def handle_event("filter_type", %{"type" => type}, socket) do
    {:noreply,
     push_url_state(socket,
       type_filter: type,
       category_filter: nil,
       field_filter: nil,
       page: 1
     )}
  end

  def handle_event("filter_category", %{"category" => category}, socket) do
    {:noreply, push_url_state(socket, category_filter: parse_category_uuid(category), page: 1)}
  end

  def handle_event("filter_lang", %{"lang" => lang}, socket) do
    {:noreply, push_url_state(socket, lang_filter: blank_to_nil(lang), page: 1)}
  end

  def handle_event("filter_state", %{"state" => state}, socket) do
    {:noreply, push_url_state(socket, state_filter: blank_to_nil(state), page: 1)}
  end

  def handle_event("filter_field", %{"field" => field}, socket) do
    {:noreply, push_url_state(socket, field_filter: blank_to_nil(field), page: 1)}
  end

  def handle_event("search", %{"search" => search}, socket) do
    {:noreply, push_url_state(socket, [search: search, page: 1], replace: true)}
  end

  def handle_event("change_page", %{"page" => page}, socket) do
    {:noreply, push_url_state(socket, page: parse_page(page))}
  end

  # "Проверить сейчас" — read-only recompute (design §4.5). Every state
  # this page shows is already computed fresh on every render trigger, so
  # this is a plain reload — it exists for the operator, not the code
  # (another admin's edit, or a resource added since the last patch).
  def handle_event("recheck", _params, socket) do
    {:noreply, load_data(socket)}
  end

  # "Запустить сверку" — calls the tick body DIRECTLY, no Oban (design
  # §4.5): an immediate `Oban.insert/1` would collide with the very
  # uniqueness that keeps the chain single-instance (design §4.3), and a
  # direct call gives instant feedback without touching the scheduled tick.
  def handle_event("run_sweep_now", _params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      {reason, info} = SweepWorker.run_tick()

      {:noreply,
       socket
       |> put_flash(sweep_flash_kind(reason, info), sweep_result_message(reason, info))
       |> load_data()}
    end)
  end

  # ============================================================
  # Operational settings panel (design §4.6 — moved here from the
  # settings page: the operator changes the sweep's pace where they see
  # its effect)
  # ============================================================

  def handle_event("save_sweep_settings", params, socket) do
    Authz.authorize(socket, :manage_settings, fn -> do_save_sweep_settings(params, socket) end)
  end

  # ============================================================
  # Bulk verbs — request phase (design §4.5's two-phase request/confirm,
  # same shape as `Web.ShopifySync`)
  # ============================================================

  def handle_event("request_translate:" <> scope, %{"uuids" => uuids}, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      open_pending(socket, :translate, scope, uuids)
    end)
  end

  def handle_event("request_retranslate:" <> scope, %{"uuids" => uuids}, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      open_pending(socket, :retranslate, scope, uuids)
    end)
  end

  def handle_event("request_stamp:" <> scope, %{"uuids" => uuids}, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      open_pending(socket, :stamp, scope, uuids)
    end)
  end

  # "Остановить переводы" (design §4.5): cancels every incomplete
  # `TranslateWorker` job for this shop's resource types, INCLUDING
  # `executing` — `Oban.cancel_all_jobs/1` signals a running job to stop;
  # nothing it had written survives, so the translation just doesn't
  # appear and can be started again.
  def handle_event("request_stop", _params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      {:noreply, assign(socket, :pending, %{verb: :stop})}
    end)
  end

  # ============================================================
  # Bulk verbs — confirm phase
  # ============================================================

  def handle_event("confirm_bulk_action", _params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      case socket.assigns.pending do
        nil -> {:noreply, socket}
        pending -> do_confirm(socket, pending)
      end
    end)
  end

  # No Authz guard on cancel — matches `Web.ShopifySync`: an operator
  # whose permission was revoked mid-session must still be able to
  # dismiss the modal.
  def handle_event("cancel_bulk_action", _params, socket) do
    {:noreply, assign(socket, :pending, nil)}
  end

  # ============================================================
  # Private helpers — grouped here (after every `handle_event`/`handle_info`
  # clause, matching this module's `def`-then-`defp` layout, and required
  # for the compiler's "clauses ... should be grouped together" rule: a
  # `defp` of a different name sitting BETWEEN two `handle_event` clauses
  # breaks that grouping)
  # ============================================================

  defp do_save_sweep_settings(params, socket) do
    enabled = Map.has_key?(params, "sweep_enabled")
    interval = parse_positive_int(params["interval_minutes"], SweepSettings.interval_minutes())
    batch = parse_non_negative_int(params["batch_size"], SweepSettings.batch_size())

    max_in_flight =
      parse_non_negative_int(params["max_in_flight"], SweepSettings.max_in_flight())

    # Design §4.6: target languages are "все включённые, кроме основного".
    # The source language is excluded from the WHITELIST, not just from the
    # rendered checkbox list — `SweepSettings.languages/0` only intersects
    # with the enabled set, so a stale or hand-crafted submit naming the
    # primary language would otherwise persist it as a translation target.
    allowed_languages = socket.assigns.enabled_languages -- [socket.assigns.source_lang]
    languages = checked_list(params["languages"], allowed_languages)
    statuses = checked_list(params["statuses"], @product_statuses)

    Settings.update_boolean_setting_with_module("shop_translation_sweep_enabled", enabled, "shop")

    Settings.update_setting_with_module(
      "shop_translation_interval_minutes",
      Integer.to_string(interval),
      "shop"
    )

    Settings.update_setting_with_module(
      "shop_translation_batch",
      Integer.to_string(batch),
      "shop"
    )

    Settings.update_setting_with_module(
      "shop_translation_max_in_flight",
      Integer.to_string(max_in_flight),
      "shop"
    )

    Settings.update_json_setting_with_module(
      "shop_translation_languages",
      %{"codes" => languages},
      "shop"
    )

    Settings.update_json_setting_with_module(
      "shop_translation_statuses",
      %{"statuses" => statuses},
      "shop"
    )

    Activity.log("shop.translation_sweep_settings_changed",
      actor_uuid: Activity.actor_uuid(socket),
      actor_role: Activity.actor_role(socket),
      resource_type: "setting",
      metadata: %{
        "sweep_enabled" => enabled,
        "interval_minutes" => interval,
        "batch_size" => batch,
        "max_in_flight" => max_in_flight,
        "languages" => languages,
        "statuses" => statuses
      }
    )

    # Design §4.3: a shortened interval must take effect immediately, not
    # after the stale interval finishes — always reschedule, whether or
    # not the interval itself changed (idempotent either way).
    SweepWorker.reschedule()

    {:noreply,
     socket
     |> put_flash(:info, gettext("Sweep settings updated"))
     |> load_data()}
  end

  # `@` inside `~H` reads from `assigns`, not this module's attributes —
  # the template calls this function rather than `@product_statuses`.
  defp product_statuses, do: @product_statuses

  defp checked_list(nil, _allowed), do: []

  defp checked_list(raw, allowed) do
    allowed_set = MapSet.new(allowed)

    raw
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and MapSet.member?(allowed_set, &1)))
  end

  defp parse_positive_int(str, default) do
    case Integer.parse(to_string(str || "")) do
      {n, _rest} when n > 0 -> n
      _ -> default
    end
  end

  defp parse_non_negative_int(str, default) do
    case Integer.parse(to_string(str || "")) do
      {n, _rest} when n >= 0 -> n
      _ -> default
    end
  end

  # Empty selection is a no-op — matches the toolbar buttons' own
  # `disabled` state and stops a stale/tampered client event from opening
  # a confirmation for zero actual resources.
  defp open_pending(socket, _verb, _scope, []), do: {:noreply, socket}

  defp open_pending(socket, verb, scope, uuids) do
    {lang, field} = parse_scope(scope, socket.assigns.target_langs, socket.assigns.fields)
    calls = estimate_calls(socket, uuids, lang, field, verb)

    pending = %{verb: verb, uuids: uuids, lang: lang, field: field, calls: calls}
    {:noreply, assign(socket, :pending, pending)}
  end

  # `"all"` (or any value that fails the whitelist) collapses to `nil`,
  # meaning "every configured target language" / "every field of this
  # resource type" — never `String.to_existing_atom/1` on the raw field
  # segment without checking membership first, since it is client input.
  defp parse_scope(scope, target_langs, fields) do
    case String.split(scope, ":", parts: 2) do
      [lang_str, field_str] ->
        {valid_member(lang_str, target_langs), valid_field(field_str, fields)}

      _other ->
        {nil, nil}
    end
  end

  defp valid_member(value, allowed) when is_binary(value) do
    if value in allowed, do: value, else: nil
  end

  defp valid_member(_value, _allowed), do: nil

  defp valid_field("all", _fields), do: nil

  defp valid_field(str, fields) when is_binary(str) do
    atom = safe_to_existing_atom(str)
    if atom in fields, do: atom, else: nil
  end

  defp valid_field(_str, _fields), do: nil

  defp safe_to_existing_atom(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> nil
  end

  # Estimate only — read from the ALREADY-LOADED `@rows` (design: cheap,
  # request-time preview). The real write always re-derives from a fresh
  # `FOR UPDATE`-locked read at confirm time; this number only drives the
  # confirm modal's "≈N calls" line and is never trusted for a write.
  defp estimate_calls(socket, uuids, lang, field, verb) do
    rows_by_uuid = Map.new(socket.assigns.rows, &{&1.uuid, &1})

    Enum.reduce(uuids, 0, fn uuid, acc ->
      case Map.get(rows_by_uuid, uuid) do
        nil -> acc
        row -> acc + langs_needing_work(row, lang, field, verb)
      end
    end)
  end

  defp langs_needing_work(_row, _lang, _field, :stamp), do: 0

  defp langs_needing_work(row, lang, _field, :retranslate) do
    langs = if lang, do: [lang], else: Map.keys(row.states)
    length(langs)
  end

  defp langs_needing_work(row, lang, field, :translate) do
    langs = if lang, do: [lang], else: Map.keys(row.states)

    Enum.count(langs, fn l ->
      field_states = Map.get(row.states, l, %{})
      fields = if field, do: [field], else: Map.keys(field_states)
      Enum.any?(fields, fn f -> Map.get(field_states, f) in [:missing, :stale] end)
    end)
  end

  defp do_confirm(socket, %{verb: :stop}) do
    {:ok, count} = cancel_pending_translation_jobs()

    {:noreply,
     socket
     |> assign(:pending, nil)
     |> put_flash(
       :info,
       ngettext(
         "Cancelled %{count} pending translation job.",
         "Cancelled %{count} pending translation jobs.",
         count,
         count: count
       )
     )
     |> load_data()}
  end

  defp do_confirm(socket, %{verb: :translate, uuids: uuids, lang: lang}) do
    {enqueued, conflicts, errors} = bulk_translate(socket, uuids, lang)

    {:noreply,
     socket
     |> assign(:pending, nil)
     |> put_flash(:info, translate_result_message(enqueued, conflicts, errors))
     |> load_data()}
  end

  defp do_confirm(socket, %{verb: :retranslate, uuids: uuids, lang: lang, field: field}) do
    {enqueued, conflicts, errors} = bulk_retranslate(socket, uuids, lang, field)

    {:noreply,
     socket
     |> assign(:pending, nil)
     |> put_flash(:info, translate_result_message(enqueued, conflicts, errors))
     |> load_data()}
  end

  defp do_confirm(socket, %{verb: :stamp, uuids: uuids, lang: lang, field: field}) do
    count = bulk_stamp(socket, uuids, lang, field)

    {:noreply,
     socket
     |> assign(:pending, nil)
     |> put_flash(
       :info,
       ngettext(
         "Stamped %{count} resource as reference.",
         "Stamped %{count} resources as reference.",
         count,
         count: count
       )
     )
     |> load_data()}
  end

  defp bulk_translate(socket, uuids, lang_filter) do
    adapter = adapter_for(socket.assigns.type_filter)

    with {:ok, endpoint_uuid} <- fetch_endpoint_uuid(),
         {:ok, prompt_uuid, _sync} <- adapter.ensure_prompt() do
      ctx = %{
        adapter: adapter,
        source_lang: socket.assigns.source_lang,
        target_langs: socket.assigns.target_langs,
        fields: socket.assigns.fields,
        lang_filter: lang_filter,
        endpoint_uuid: endpoint_uuid,
        prompt_uuid: prompt_uuid,
        actor_uuid: Activity.actor_uuid(socket)
      }

      Enum.reduce(uuids, {0, 0, []}, &translate_one(ctx, &1, &2))
    else
      {:error, reason} -> {0, 0, [{:setup, reason}]}
    end
  end

  defp translate_one(ctx, uuid, acc) do
    case ctx.adapter.fetch(ctx.adapter.resource_type(), uuid) do
      {:ok, resource} ->
        langs =
          candidate_langs(
            resource,
            ctx.source_lang,
            ctx.target_langs,
            ctx.fields,
            ctx.lang_filter
          )

        enqueue_reduce(
          langs,
          ctx.adapter,
          uuid,
          ctx.endpoint_uuid,
          ctx.prompt_uuid,
          ctx.source_lang,
          ctx.actor_uuid,
          acc
        )

      {:error, reason} ->
        add_error(acc, uuid, reason)
    end
  end

  defp bulk_retranslate(socket, uuids, lang_filter, field_filter) do
    adapter = adapter_for(socket.assigns.type_filter)
    target_langs = if lang_filter, do: [lang_filter], else: socket.assigns.target_langs
    fields = if field_filter, do: [field_filter], else: socket.assigns.fields

    with {:ok, endpoint_uuid} <- fetch_endpoint_uuid(),
         {:ok, prompt_uuid, _sync} <- adapter.ensure_prompt() do
      ctx = %{
        adapter: adapter,
        source_lang: socket.assigns.source_lang,
        target_langs: target_langs,
        fields: fields,
        endpoint_uuid: endpoint_uuid,
        prompt_uuid: prompt_uuid,
        actor_uuid: Activity.actor_uuid(socket)
      }

      Enum.reduce(uuids, {0, 0, []}, &retranslate_one(ctx, &1, &2))
    else
      {:error, reason} -> {0, 0, [{:setup, reason}]}
    end
  end

  defp retranslate_one(ctx, uuid, acc) do
    case ctx.adapter.reset_reference(uuid, ctx.target_langs, ctx.fields) do
      {:ok, _resource} ->
        enqueue_reduce(
          ctx.target_langs,
          ctx.adapter,
          uuid,
          ctx.endpoint_uuid,
          ctx.prompt_uuid,
          ctx.source_lang,
          ctx.actor_uuid,
          acc
        )

      {:error, reason} ->
        add_error(acc, uuid, reason)
    end
  end

  defp add_error({enq, conf, errs}, uuid, reason), do: {enq, conf, [{uuid, reason} | errs]}

  defp bulk_stamp(socket, uuids, lang_filter, field_filter) do
    type = socket.assigns.type_filter
    adapter = adapter_for(type)
    source_lang = socket.assigns.source_lang
    target_langs = if lang_filter, do: [lang_filter], else: socket.assigns.target_langs
    fields = if field_filter, do: [field_filter], else: socket.assigns.fields

    Enum.count(uuids, fn uuid ->
      match?({:ok, _}, adapter.stamp_reference(uuid, source_lang, target_langs, fields))
    end)
  end

  defp enqueue_reduce([], _adapter, _uuid, _endpoint, _prompt, _source, _actor, acc), do: acc

  defp enqueue_reduce(langs, adapter, uuid, endpoint_uuid, prompt_uuid, source_lang, actor_uuid, {
         enq,
         conf,
         errs
       }) do
    base = %{
      resource_type: adapter.resource_type(),
      resource_uuid: uuid,
      endpoint_uuid: endpoint_uuid,
      prompt_uuid: prompt_uuid,
      source_lang: source_lang,
      actor_uuid: actor_uuid
    }

    case PhoenixKitAI.Translations.enqueue_all_missing(base, langs) do
      {:ok, %{enqueued: n, conflicts: c}} -> {enq + n, conf + c, errs}
      {:error, reason} -> {enq, conf, [{uuid, reason} | errs]}
    end
  end

  defp candidate_langs(resource, source_lang, target_langs, fields, lang_filter) do
    langs = if lang_filter, do: [lang_filter], else: target_langs

    Enum.filter(langs, fn lang ->
      Enum.any?(fields, fn field ->
        source = get_lang(Map.get(resource, field), source_lang)
        translation = get_lang(Map.get(resource, field), lang)
        fp = Fingerprint.get(resource.metadata, lang, Atom.to_string(field))
        Fingerprint.field_state(source, translation, fp) in [:missing, :stale]
      end)
    end)
  end

  defp fetch_endpoint_uuid do
    case PhoenixKitAI.Translations.default_endpoint_uuid() do
      nil -> {:error, :no_endpoint}
      uuid -> {:ok, uuid}
    end
  end

  defp cancel_pending_translation_jobs do
    shop_types = [AITranslatable.resource_type(), CategoryAITranslatable.resource_type()]

    query =
      from(j in Oban.Job,
        where: j.worker == ^@translate_worker,
        where: j.state in ^@incomplete_states,
        where: fragment("?->>'resource_type' = ANY(?)", j.args, ^shop_types)
      )

    Oban.cancel_all_jobs(query)
  rescue
    _ -> {:ok, 0}
  catch
    :exit, _ -> {:ok, 0}
  end

  # ============================================================
  # PubSub — global translation status topic (design §4.5)
  # ============================================================

  @impl true
  def handle_info({:ai_translation, _event, _payload}, socket) do
    {:noreply, load_data(socket)}
  end

  # Catch-all is load-bearing, not decorative — see `Web.Products`' own
  # identical note: any message shape not explicitly matched above must
  # not crash a mounted admin session.
  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  # ============================================================
  # Helpers
  # ============================================================

  defp parse_category_uuid(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp parse_category_uuid(_id), do: nil

  defp parse_page(nil), do: 1

  defp parse_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {n, _rest} when n > 0 -> n
      _ -> 1
    end
  end

  defp parse_page(_page), do: 1

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp ai_translations_available? do
    Code.ensure_loaded?(PhoenixKitAI.Translations) and
      function_exported?(PhoenixKitAI.Translations, :available?, 0) and
      PhoenixKitAI.Translations.available?() and
      not is_nil(PhoenixKitAI.Translations.default_endpoint_uuid())
  end

  # `:ok` with per-language enqueue failures (design §1 — the run-now
  # button's own version of the `last_run_summary/1` gap above: a tick
  # that failed to enqueue anything is not the same as one that had
  # nothing to do, and the flash color must say so too).
  defp sweep_flash_kind(:ok, %{errors: n}) when n > 0, do: :warning
  defp sweep_flash_kind(:ok, _info), do: :info
  defp sweep_flash_kind(_reason, _info), do: :warning

  defp sweep_result_message(:ok, %{enqueued: n} = info) do
    base =
      ngettext("Sweep ran — %{count} job queued.", "Sweep ran — %{count} jobs queued.", n,
        count: n
      )

    errors = Map.get(info, :errors, 0)

    if errors > 0 do
      base <>
        " " <>
        ngettext("%{count} enqueue error.", "%{count} enqueue errors.", errors, count: errors)
    else
      base
    end
  end

  defp sweep_result_message(:translations_disabled, _info),
    do: gettext("Sweep did not run — shop translations are disabled.")

  defp sweep_result_message(:sweep_disabled, _info),
    do: gettext("Sweep did not run — automatic sweeping is turned off.")

  defp sweep_result_message(:ai_unavailable, _info),
    do: gettext("Sweep did not run — AI translation isn't available right now.")

  defp sweep_result_message(:ceiling_reached, %{in_flight: n}),
    do: gettext("Sweep did not run — %{count} jobs already in flight (at the ceiling).", count: n)

  defp sweep_result_message(:no_target_languages, _info),
    do: gettext("Sweep did not run — no target languages are configured.")

  defp sweep_result_message(_reason, _info), do: gettext("Sweep finished.")

  defp translate_result_message(enqueued, conflicts, errors) do
    parts = [
      ngettext("%{count} job queued", "%{count} jobs queued", enqueued, count: enqueued)
    ]

    parts =
      if conflicts > 0,
        do: parts ++ [gettext("%{count} already in flight", count: conflicts)],
        else: parts

    parts =
      if errors != [],
        do: parts ++ [gettext("%{count} failed", count: length(errors))],
        else: parts

    Enum.join(parts, ", ")
  end

  defp field_label(:title), do: gettext("Title")
  defp field_label(:description), do: gettext("Description")
  defp field_label(:body_html), do: gettext("Body")
  defp field_label(:seo_title), do: gettext("SEO title")
  defp field_label(:seo_description), do: gettext("SEO description")
  defp field_label(:name), do: gettext("Name")
  defp field_label(field), do: field |> Atom.to_string() |> String.capitalize()

  defp state_label(:missing), do: gettext("Missing")
  defp state_label(:stale), do: gettext("Stale")
  defp state_label(:unknown), do: gettext("Unknown")
  defp state_label(:fresh), do: gettext("Fresh")
  defp state_label(nil), do: gettext("No source")

  defp state_badge_class(:fresh), do: "badge badge-success"
  defp state_badge_class(:stale), do: "badge badge-warning"
  defp state_badge_class(:missing), do: "badge badge-error"
  defp state_badge_class(:unknown), do: "badge badge-ghost"
  defp state_badge_class(nil), do: "badge badge-ghost opacity-40"

  defp bulk_event(verb, lang_filter, field_filter) do
    "request_#{verb}:#{lang_filter || "all"}:#{field_filter || "all"}"
  end

  defp stale_fields_tooltip(field_states) do
    field_states
    |> Enum.filter(fn {_field, state} -> state in [:missing, :stale] end)
    |> Enum.map_join(", ", fn {field, _state} -> field_label(field) end)
  end

  # The prompt as the provider actually received it, flattened out of the
  # request log's `messages` array (design §4.5's "отправленный промпт").
  # `nil` when content capture is off (`:capture_request_content false`) or
  # the row predates it — the panel then simply omits the block rather
  # than claiming an empty prompt was sent.
  defp prompt_text(messages) when is_list(messages) do
    text =
      messages
      |> Enum.map(fn
        %{"role" => role, "content" => content} when is_binary(content) ->
          "[#{role}]\n#{content}"

        %{"content" => content} when is_binary(content) ->
          content

        _other ->
          nil
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    if text == "", do: nil, else: text
  end

  defp prompt_text(_messages), do: nil

  defp format_tick_time(nil), do: gettext("not scheduled")

  defp format_tick_time(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M UTC")
  end

  defp call_estimate(0), do: nil

  defp call_estimate(calls) do
    minutes = max(1, ceil(calls * @avg_call_seconds / 60 / @parallel_jobs))

    ngettext(
      "≈%{calls} model call, about %{minutes} minute.",
      "≈%{calls} model calls, about %{minutes} minutes.",
      calls,
      calls: calls,
      minutes: minutes
    )
  end

  # ============================================================
  # Confirm modal content — derives entirely from `@pending`, matching
  # `Web.ShopifySync`'s `pending_modal/1`.
  # ============================================================

  defp pending_modal(%{pending: nil}), do: nil

  defp pending_modal(%{pending: %{verb: :stop}}) do
    %{
      title: gettext("Stop translations?"),
      prompt:
        gettext(
          "Cancels every pending and in-progress translation job for this shop. Nothing already written is undone — a stopped translation just doesn't appear yet and can be started again."
        ),
      danger: true
    }
  end

  defp pending_modal(%{pending: %{verb: :translate, uuids: uuids, calls: calls}} = assigns) do
    %{
      title: gettext("Translate?"),
      prompt:
        ngettext(
          "Queue translation for %{count} selected resource's missing and outdated languages?",
          "Queue translation for %{count} selected resources' missing and outdated languages?",
          length(uuids),
          count: length(uuids)
        ),
      messages: scope_messages(assigns) ++ estimate_messages(calls),
      danger: false
    }
  end

  defp pending_modal(%{pending: %{verb: :retranslate, uuids: uuids, calls: calls}} = assigns) do
    %{
      title: gettext("Translate again?"),
      prompt:
        ngettext(
          "Reset the reference and re-queue translation for %{count} selected resource, for the current language/field scope?",
          "Reset the reference and re-queue translation for %{count} selected resources, for the current language/field scope?",
          length(uuids),
          count: length(uuids)
        ),
      messages:
        [
          {:warning,
           gettext(
             "Any manual edit to the selected fields, for the selected languages, will be overwritten by the new translation."
           )}
        ] ++ scope_messages(assigns) ++ estimate_messages(calls),
      danger: true
    }
  end

  defp pending_modal(%{pending: %{verb: :stamp, uuids: uuids}} = assigns) do
    %{
      title: gettext("Stamp as reference?"),
      prompt:
        ngettext(
          "Mark the current source text as the reference translation for %{count} selected resource, for the current language/field scope — no model call, existing translations are kept as-is.",
          "Mark the current source text as the reference translation for %{count} selected resources, for the current language/field scope — no model call, existing translations are kept as-is.",
          length(uuids),
          count: length(uuids)
        ),
      messages:
        [
          # Design §4.1 aims this verb at the 634 `unknown` rows, but the
          # page can't stop the operator pointing it at a `stale` one, and
          # there the effect is the freeze §4.1 books as a conscious cost:
          # the divergence stops being visible to the sweep. Say so.
          {:warning,
           gettext(
             "A translation whose source has changed since (\"stale\") is accepted as up to date — the sweep will stop picking it up until its reference is reset."
           )}
        ] ++ scope_messages(assigns),
      danger: false
    }
  end

  # Design §4.5 wants the confirmation to name "число ресурсов, языков и
  # оценку" — the resource count is in the prompt above, the estimate in
  # `estimate_messages/1`; this spells out WHICH languages (and which
  # field, when the filter narrows one) the verb is about to act on, so
  # "the current language/field scope" is never something the operator has
  # to reconstruct from the toolbar.
  defp scope_messages(%{pending: pending} = assigns) do
    langs =
      case pending[:lang] do
        nil -> assigns.target_langs
        lang -> [lang]
      end

    field_part =
      case pending[:field] do
        nil -> gettext("all fields")
        field -> field_label(field)
      end

    [
      {:info,
       gettext("Scope: %{langs} · %{fields}",
         langs: Enum.join(langs, ", "),
         fields: field_part
       )}
    ]
  end

  defp estimate_messages(calls) do
    case call_estimate(calls) do
      nil -> []
      text -> [{:info, text}]
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :modal, pending_modal(assigns))

    ~H"""
    <div class="container flex-col mx-auto px-4 py-6 max-w-7xl">
      <.admin_page_header back={Routes.path("/admin/shop")} title={gettext("Shop Translations")}>
        <:actions>
          <button type="button" id="recheck-translations" class="btn btn-ghost btn-sm" phx-click="recheck">
            <.icon name="hero-arrow-path" class="w-4 h-4 mr-1" /> {gettext("Check now")}
          </button>
          <button type="button" id="run-sweep-now" class="btn btn-primary btn-sm" phx-click="run_sweep_now">
            {gettext("Run sweep")}
          </button>
        </:actions>
      </.admin_page_header>

      <%!-- Always-visible sweep block + operational panel (design §4.5/§4.6) --%>
      <div class="card bg-base-100 shadow-xl mb-6" id="sweep-block">
        <div class="card-body">
          <h2 class="card-title text-xl mb-2">
            <.icon name="hero-clock" class="w-6 h-6" /> {gettext("Reconciliation sweep")}
          </h2>

          <div class="flex flex-wrap items-center gap-4 text-sm mb-4">
            <span id="sweep-enabled-status" class={
              if(@sweep_settings.sweep_enabled, do: "badge badge-success", else: "badge badge-ghost")
            }>
              {if @sweep_settings.sweep_enabled, do: gettext("Automatic sweep: on"), else: gettext("Automatic sweep: off (manual only)")}
            </span>
            <span id="sweep-next-tick">
              {gettext("Next tick: %{time}", time: format_tick_time(@sweep_status.next_tick_at))}
            </span>
            <span id="sweep-last-run">
              {gettext("Last tick: %{outcome}", outcome: last_run_summary(@sweep_status.last_run))}
            </span>
            <span id="sweep-in-flight" class="badge badge-outline">
              {gettext("%{count} in queue now", count: @in_flight)}
            </span>
          </div>

          <form id="sweep-settings-form" phx-submit="save_sweep_settings" class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <label class="label cursor-pointer justify-start gap-3">
              <input type="checkbox" name="sweep_enabled" value="true" class="toggle toggle-primary" checked={@sweep_settings.sweep_enabled} />
              <span class="fieldset-legend">{gettext("Enable automatic sweep")}</span>
            </label>

            <div></div>

            <div class="fieldset">
              <label class="label"><span class="fieldset-legend">{gettext("Interval (minutes)")}</span></label>
              <input type="number" min="1" name="interval_minutes" value={@sweep_settings.interval_minutes} class="input w-full" />
            </div>

            <div class="fieldset">
              <label class="label"><span class="fieldset-legend">{gettext("Batch size (resources per tick)")}</span></label>
              <input type="number" min="0" name="batch_size" value={@sweep_settings.batch_size} class="input w-full" />
            </div>

            <div class="fieldset">
              <label class="label"><span class="fieldset-legend">{gettext("Max in-flight jobs")}</span></label>
              <input type="number" min="0" name="max_in_flight" value={@sweep_settings.max_in_flight} class="input w-full" />
            </div>

            <div></div>

            <div class="fieldset">
              <label class="label"><span class="fieldset-legend">{gettext("Target languages")}</span></label>
              <div class="flex flex-wrap gap-3">
                <%= for lang <- @enabled_languages, lang != @source_lang do %>
                  <label class="label cursor-pointer gap-2">
                    <input type="checkbox" name="languages[]" value={lang} checked={lang in @sweep_settings.languages} class="checkbox checkbox-sm" />
                    <span>{lang}</span>
                  </label>
                <% end %>
              </div>
            </div>

            <div class="fieldset">
              <label class="label"><span class="fieldset-legend">{gettext("Product statuses swept")}</span></label>
              <div class="flex flex-wrap gap-3">
                <%= for status <- product_statuses() do %>
                  <label class="label cursor-pointer gap-2">
                    <input type="checkbox" name="statuses[]" value={status} checked={status in @sweep_settings.statuses} class="checkbox checkbox-sm" />
                    <span>{status}</span>
                  </label>
                <% end %>
              </div>
            </div>

            <div class="md:col-span-2">
              <button type="submit" id="save-sweep-settings" class="btn btn-primary btn-sm">
                {gettext("Save sweep settings")}
              </button>
            </div>
          </form>
        </div>
      </div>

      <%!-- Prompt-divergence warnings (design §4.5/§5.2) --%>
      <div :if={@prompt_sync.product == :diverged} class="alert alert-warning mb-4" id="prompt-diverged-product">
        <span>{gettext("The product translation prompt has been hand-edited and no longer matches the module's shipped version. Restore it in AI › Prompts, or leave the edit — this warning stays until it's resolved.")}</span>
      </div>
      <div :if={@prompt_sync.category == :diverged} class="alert alert-warning mb-4" id="prompt-diverged-category">
        <span>{gettext("The category translation prompt has been hand-edited and no longer matches the module's shipped version. Restore it in AI › Prompts, or leave the edit — this warning stays until it's resolved.")}</span>
      </div>

      <%!-- Coverage stat row (design §4.5) --%>
      <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4 mb-6" id="coverage-stats">
        <%= for lang <- @target_langs do %>
          <% c = Map.get(@coverage, lang, %{fresh: 0, stale: 0, missing: 0, unknown: 0}) %>
          <div id={"coverage-#{lang}"}>
            <.stat_card
              value={"#{c.fresh}/#{c.fresh + c.stale + c.missing + c.unknown}"}
              title={lang}
              subtitle={gettext("fresh / stale %{s} / missing %{m} / unknown %{u}", s: c.stale, m: c.missing, u: c.unknown)}
              color="info"
              compact
            >
              <:icon><.icon name="hero-language" class="w-6 h-6" /></:icon>
            </.stat_card>
          </div>
        <% end %>
        <div id="coverage-in-flight">
          <.stat_card value={@in_flight} title={gettext("In queue now")} subtitle={gettext("Incomplete translation jobs")} color="warning" compact>
            <:icon><.icon name="hero-queue-list" class="w-6 h-6" /></:icon>
          </.stat_card>
        </div>
      </div>

      <%!-- Filters (design §4.5's four axes + search) --%>
      <div class="bg-base-200 rounded-lg p-6 mb-6">
        <div class="grid grid-cols-1 md:grid-cols-3 lg:grid-cols-6 gap-4 items-end">
          <div>
            <label class="label"><span class="fieldset-legend">{gettext("Type")}</span></label>
            <form id="filter-type-form" phx-change="filter_type">
              <select class="select w-full" name="type">
                <option value="product" selected={@type_filter == "product"}>{gettext("Products")}</option>
                <option value="category" selected={@type_filter == "category"}>{gettext("Categories")}</option>
              </select>
            </form>
          </div>

          <div>
            <label class="label"><span class="fieldset-legend">{gettext("Category")}</span></label>
            <form id="filter-category-form" phx-change="filter_category">
              <select class="select w-full" name="category" disabled={@type_filter != "product"}>
                <option value="" selected={is_nil(@category_filter)}>{gettext("All categories")}</option>
                <%= for category <- @categories do %>
                  <option value={category.uuid} selected={@category_filter == category.uuid}>
                    {Translations.get(category, :name, @source_lang)}
                  </option>
                <% end %>
              </select>
            </form>
          </div>

          <div>
            <label class="label"><span class="fieldset-legend">{gettext("Language")}</span></label>
            <form id="filter-lang-form" phx-change="filter_lang">
              <select class="select w-full" name="lang">
                <option value="" selected={is_nil(@lang_filter)}>{gettext("All target languages")}</option>
                <%= for lang <- @target_langs do %>
                  <option value={lang} selected={@lang_filter == lang}>{lang}</option>
                <% end %>
              </select>
            </form>
          </div>

          <div>
            <label class="label"><span class="fieldset-legend">{gettext("State")}</span></label>
            <form id="filter-state-form" phx-change="filter_state">
              <select class="select w-full" name="state">
                <option value="" selected={is_nil(@state_filter)}>{gettext("Any state")}</option>
                <option value="missing" selected={@state_filter == "missing"}>{gettext("Missing")}</option>
                <option value="stale" selected={@state_filter == "stale"}>{gettext("Stale")}</option>
                <option value="unknown" selected={@state_filter == "unknown"}>{gettext("Unknown")}</option>
                <option value="fresh" selected={@state_filter == "fresh"}>{gettext("Fresh")}</option>
              </select>
            </form>
          </div>

          <div>
            <label class="label"><span class="fieldset-legend">{gettext("Field")}</span></label>
            <form id="filter-field-form" phx-change="filter_field">
              <select class="select w-full" name="field">
                <option value="" selected={is_nil(@field_filter)}>{gettext("Any field")}</option>
                <%= for field <- @fields do %>
                  <option value={field} selected={@field_filter == field}>{field_label(field)}</option>
                <% end %>
              </select>
            </form>
          </div>

          <div>
            <label class="label"><span class="fieldset-legend">{gettext("Search")}</span></label>
            <form id="filter-search-form" phx-submit="search" phx-change="search">
              <input type="text" name="search" value={@search} placeholder={gettext("Search...")} class="input w-full" phx-debounce="300" />
            </form>
          </div>
        </div>
      </div>

      <div class="flex justify-end mb-4">
        <button type="button" id="stop-translations" class="btn btn-error btn-outline btn-sm" phx-click="request_stop">
          <.icon name="hero-stop-circle" class="w-4 h-4 mr-1" /> {gettext("Stop translations")}
        </button>
      </div>

      <.bulk_select_scope id="translations-bulk" total_count={length(@rows)}>
        <div class="bg-primary/10 border border-primary/30 rounded-lg p-4 mb-6" data-bulk-show="has-selection" style="display: none;">
          <div class="flex flex-wrap items-center justify-between gap-4">
            <div class="flex items-center gap-2">
              <span class="badge badge-primary badge-lg" data-bulk-text-template={gettext("%{count} selected", count: "%{count}")}>
                {gettext("%{count} selected", count: 0)}
              </span>
              <button type="button" data-bulk-clear="true" class="btn btn-ghost btn-sm">{gettext("Clear selection")}</button>
            </div>
            <div class="flex flex-wrap gap-2">
              <button type="button" id="bulk-translate" class="btn btn-sm btn-primary" data-bulk-action={bulk_event("translate", @lang_filter, @field_filter)}>
                {gettext("Translate")}
              </button>
              <button type="button" id="bulk-retranslate" class="btn btn-sm btn-outline btn-warning" data-bulk-action={bulk_event("retranslate", @lang_filter, @field_filter)}>
                {gettext("Translate again")}
              </button>
              <button type="button" id="bulk-stamp" class="btn btn-sm btn-outline" data-bulk-action={bulk_event("stamp", @lang_filter, @field_filter)}>
                {gettext("Stamp as reference")}
              </button>
            </div>
          </div>
        </div>

        <.table_default id="translations-table" variant="zebra" items={@rows}>
          <.table_default_header>
            <.table_default_row hover={false}>
              <.bulk_select_header_cell id="translations-select-all" aria_label={gettext("Select all")} />
              <.table_default_header_cell>{gettext("Resource")}</.table_default_header_cell>
              <%= for lang <- @target_langs do %>
                <.table_default_header_cell>{lang}</.table_default_header_cell>
              <% end %>
            </.table_default_row>
          </.table_default_header>

          <.table_default_body>
            <%= if Enum.empty?(@rows) do %>
              <.table_default_row hover={false}>
                <.table_default_cell colspan={2 + length(@target_langs)} class="text-center py-12 text-base-content/50">
                  <.icon name="hero-language" class="w-12 h-12 mx-auto mb-3 opacity-50" />
                  <p class="text-lg">{gettext("No resources match these filters")}</p>
                </.table_default_cell>
              </.table_default_row>
            <% else %>
              <%= for row <- @rows do %>
                <.table_default_row id={"translation-row-#{row.uuid}"}>
                  <.bulk_select_cell value={row.uuid} />
                  <.table_default_cell class="font-medium">
                    {row.title}
                    <div :if={row.category} class="text-xs text-base-content/50">{Translations.get(row.category, :name, @source_lang)}</div>
                  </.table_default_cell>
                  <%= for lang <- @target_langs do %>
                    <.table_default_cell>
                      <% state = row.states |> Map.get(lang, %{}) |> Map.values() |> Fingerprint.fold() %>
                      <span class={state_badge_class(state)} title={stale_fields_tooltip(Map.get(row.states, lang, %{}))}>
                        {state_label(state)}
                      </span>
                    </.table_default_cell>
                  <% end %>
                </.table_default_row>
              <% end %>
            <% end %>
          </.table_default_body>
        </.table_default>
      </.bulk_select_scope>

      <div class="flex items-center justify-between mt-4 mb-8">
        <button type="button" id="page-prev" class="btn btn-sm" phx-click="change_page" phx-value-page={@page - 1} disabled={@page <= 1}>
          « {gettext("Prev")}
        </button>
        <span id="page-info"><.pagination_info page={@page} per_page={@per_page} total_count={@total} /></span>
        <button type="button" id="page-next" class="btn btn-sm" phx-click="change_page" phx-value-page={@page + 1} disabled={@page * @per_page >= @total}>
          {gettext("Next")} »
        </button>
      </div>

      <%!-- Diagnostics panel (design §4.5) --%>
      <.accordion id="translations-diagnostics" open={false}>
        <:title>{gettext("Diagnostics — recent AI request log entries")}</:title>
        <:content>
          <p class="text-sm text-base-content/60 mb-3">
            {gettext("Only successful model calls are attributed to a resource here — a transport failure (e.g. a timeout) never carries attribution, so it won't appear even though it may have been a retryable failure. See the design notes for why.")}
          </p>
          <.empty_state :if={@diagnostics == []} title={gettext("No AI requests logged for shop resources yet")} variant="compact" />
          <div :for={entry <- @diagnostics} id={"diagnostic-#{entry.uuid}"} class="border border-base-300 rounded-lg p-3 mb-2">
            <div class="flex flex-wrap items-center gap-2 text-sm">
              <span class={if(entry.status == "success", do: "badge badge-success badge-sm", else: "badge badge-error badge-sm")}>{entry.status}</span>
              <span class="font-mono text-xs">{entry.resource_type}:{entry.resource_uuid}</span>
              <.time_ago datetime={entry.inserted_at} />
            </div>
            <div :if={entry.error_message} class="text-error text-sm mt-1">{entry.error_message}</div>
            <details :if={entry.response} class="mt-2">
              <summary class="cursor-pointer text-sm text-base-content/60">{gettext("Raw model response")}</summary>
              <pre class="whitespace-pre-wrap text-xs bg-base-200 rounded p-2 mt-1 max-h-64 overflow-y-auto" phx-no-curly-interpolation><%= entry.response %></pre>
            </details>
            <% sent_prompt = prompt_text(entry.messages) %>
            <details :if={sent_prompt} id={"diagnostic-prompt-#{entry.uuid}"} class="mt-2">
              <summary class="cursor-pointer text-sm text-base-content/60">{gettext("Prompt as sent")}</summary>
              <pre class="whitespace-pre-wrap text-xs bg-base-200 rounded p-2 mt-1 max-h-64 overflow-y-auto" phx-no-curly-interpolation><%= sent_prompt %></pre>
            </details>
          </div>
        </:content>
      </.accordion>

      <.confirm_modal
        :if={@modal}
        show={true}
        on_confirm="confirm_bulk_action"
        on_cancel="cancel_bulk_action"
        title={@modal.title}
        prompt={@modal.prompt}
        messages={Map.get(@modal, :messages, [])}
        danger={@modal.danger}
      />
    </div>
    """
  end

  defp last_run_summary(nil), do: gettext("never run yet")

  # `"errors"` is the per-language `enqueue_all_missing/2` failure count a
  # tick can now report (review fix on the sweep, task 5) — a tick that
  # enqueued nothing because every insert failed is otherwise
  # indistinguishable here from "nothing needed doing", which is exactly
  # the silent-failure shape that fix closed at the source. Surfacing it
  # is what makes that fix's outcome actually visible per design §1.
  defp last_run_summary(%{"reason" => "ok"} = run) do
    n = Map.get(run, "enqueued", 0)
    errors = Map.get(run, "errors", 0)
    base = ngettext("ran, %{count} job queued", "ran, %{count} jobs queued", n, count: n)

    if errors > 0 do
      base <>
        " — " <>
        ngettext("%{count} enqueue error", "%{count} enqueue errors", errors, count: errors)
    else
      base
    end
  end

  defp last_run_summary(%{"reason" => reason}), do: reason
end
