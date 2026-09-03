defmodule PhoenixKitEcommerce.Workers.TranslationSweepWorker do
  @moduledoc """
  Self-rescheduling Oban worker for the AI-translation reconciliation
  sweep (design §4.3). Ticks itself roughly every
  `TranslationSweepSettings.interval_minutes/0` minutes, without a cron
  entry or app-level heartbeat: no host config, and a changed interval
  takes effect on the very next reschedule (`reschedule/0`) rather than
  waiting for a static crontab edit.

  ## The chain

  `unique: [period: :infinity, states: [:available, :scheduled]]` (fixed,
  argument-free `%{}` args) keeps the queue holding at most one pending
  tick at a time. The state list is explicit rather than Oban's default
  because that default references `:suspended`, which is absent from the
  `oban_job_state` enum on hosts that upgraded the Oban library ahead of
  its migration — referencing it there raises `22P02` and would kill
  every insert (the exact reason `PhoenixKitAI.TranslateWorker` moved its
  own de-dup off Oban's `unique:`, see that module's docs).

  `perform/1` schedules its OWN successor as the very first action,
  before touching any settings or doing any work, via `ensure_scheduled/0`
  — a tick that crashes after that point still leaves the chain alive.
  `max_attempts: 1` follows from the same fact: retrying a failed tick is
  pointless when the next one is already queued.

  `ensure_scheduled/0` is unconditional — it does not check whether the
  sweep is enabled. The chain runs forever once started (design: "Тик
  выключенной сверки не прекращает цепочку, а выполняет пустую работу и
  планирует следующий" — accepted cost, ~24 no-op ticks/day at the
  default interval) so that a disabled-then-re-enabled sweep needs no
  manual kick to resume. It's called from three places designed to
  survive a broken chain regardless of cause (a server restart, Oban
  pruning, a run of failures): `PhoenixKitEcommerce.enable_system/0`,
  a settings save (`reschedule/0` below), and the management page's
  `mount/3` (next task). Because uniqueness does the actual de-duplication,
  calling it from all three concurrently is safe — see the moduledoc on
  `unique:` above; every racing call converges on at most one scheduled
  job.

  ## What one tick does (design §4.3 step order)

    1. Schedule the next tick (`ensure_scheduled/0`).
    2. Stop, recording why, unless `shop_translations_enabled` is on AND
       AI is actually usable (`PhoenixKitAI.Translations.available?/0`
       **and** a resolved default endpoint — `available?/0` alone doesn't
       confirm the configured endpoint still exists and is enabled). The
       SCHEDULED tick (`run_tick/0`) additionally requires
       `shop_translation_sweep_enabled` — the manual "Запустить сверку"
       button (`run_manual_tick/0`) does not, by owner decision: that
       setting gates automatic scheduling only. Checking every toggle
       fresh on every tick (never cached in the job) means a state
       flipped by direct SQL is honoured immediately, not on the next
       code deploy.
    3. Stop, recording why, if the shop's incomplete `TranslateWorker`
       jobs (`available`/`scheduled`/`executing`/`retryable` — the same
       four states `PhoenixKitAI.Translations` dedups against; a
       snoozed job is `scheduled` and still counts) are already at or
       past `shop_translation_max_in_flight`. The ceiling counts JOBS,
       not resources — a resource with N stale languages contributes N.
    4. Select candidates: every stale/missing category first (no status
       filter — a hidden category would otherwise ship translated
       navigation before it's visible), then products filtered by
       `shop_translation_statuses`. Selection stops before the running
       job-count would exceed the remaining ceiling budget, AND before
       the resource count would exceed `shop_translation_batch`
       (`take_within_budget/3`) — two independent caps, combined across
       categories and products in one tick.
    5. Enqueue `missing ∪ stale` languages per selected resource via
       `PhoenixKitAI.Translations.enqueue_all_missing/2`. That call's own
       app-level de-dup means a resource already mid-translation (manual
       action, a previous tick's snoozed job) is skipped without this
       worker needing to check first.

  Every stop — expected (disabled, AI down, ceiling) or a completed run —
  is recorded via `finish/2` into the `shop_translation_sweep_last_run`
  setting, readable through `last_run/0`, so the management page (next
  task) can show "last tick: …" without re-deriving it live; `status/0`
  bundles that with the live "when does the next one fire" instead.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 1,
    unique: [period: :infinity, states: [:available, :scheduled]]

  import Ecto.Query, warn: false

  # phoenix_kit_ai is an OPTIONAL dependency (see mix.exs) — the whole
  # translations feature compiles out when it's absent, and `ai_available?/0`
  # never reaches these calls in that build (mirrors the guard style in
  # `AITranslatable`/`CategoryAITranslatable`).
  @compile {:no_warn_undefined, PhoenixKitAI.Translations}

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKitEcommerce.AITranslatable
  alias PhoenixKitEcommerce.CategoryAITranslatable
  alias PhoenixKitEcommerce.Translations
  alias PhoenixKitEcommerce.TranslationSweepSettings, as: SweepSettings

  # Job states that mean "already covered" — deliberately the same four
  # `PhoenixKitAI.Translations` dedups against (see that module's
  # `@incomplete_states`), minus `:suspended` for the enum reason above.
  @incomplete_states ~w(available scheduled executing retryable)
  @translate_worker "PhoenixKitAI.TranslateWorker"

  # Persisted outcome of the most recent tick (design: "the tick records
  # why and stops"). A JSON setting rather than a new table/column —
  # every other small piece of sweep state already lives in Settings, and
  # this is exactly the kind of "one row, read on page load" value that
  # recipe is for.
  @last_run_key "shop_translation_sweep_last_run"
  @settings_module "shop_translations"

  # ── Oban callback ────────────────────────────────────────────────

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    # Design §4.3: scheduled FIRST, before any work — a tick that crashes
    # below this line still leaves the chain alive.
    ensure_scheduled()

    run_tick()

    :ok
  end

  # ── Scheduling ───────────────────────────────────────────────────

  @doc """
  Ensures a tick is scheduled (or already is — see the moduledoc on
  `unique:`). Unconditional: does not check `sweep_enabled?/0`, because
  the chain itself is meant to run forever once started (see moduledoc).

  Called on shop `enable_system/0`, after a sweep-settings save
  (`reschedule/0`), and on the management page's `mount/3`.
  """
  @spec ensure_scheduled() :: {:ok, Oban.Job.t()} | {:error, term()}
  def ensure_scheduled do
    %{}
    |> new(schedule_in: SweepSettings.interval_minutes() * 60)
    |> Oban.insert()
  end

  @doc """
  Cancels whatever tick is currently `scheduled` (an `available` tick — one
  already due to run — is left alone; it will read the new interval when
  scheduling ITS successor) and schedules a fresh one at the
  currently-configured interval.

  Design §4.3: a settings save must call this, or a shortened interval
  (say 60 minutes down to 5) would not take effect until the stale
  60-minute wait finished.
  """
  @spec reschedule() :: {:ok, Oban.Job.t()} | {:error, term()}
  def reschedule do
    cancel_scheduled_tick()
    ensure_scheduled()
  end

  defp cancel_scheduled_tick do
    repo = PhoenixKit.RepoHelper.repo()

    from(j in Oban.Job, where: j.worker == ^worker_name(), where: j.state == "scheduled")
    |> select([j], j.id)
    |> repo.all()
    |> Enum.each(&Oban.cancel_job/1)
  end

  @doc "The `scheduled_at` of the pending tick, if any (design §4.5: \"следующий тик в HH:MM\")."
  @spec next_tick_at() :: DateTime.t() | nil
  def next_tick_at do
    repo = PhoenixKit.RepoHelper.repo()

    from(j in Oban.Job,
      where: j.worker == ^worker_name(),
      where: j.state in ["available", "scheduled"],
      order_by: [asc: j.scheduled_at],
      limit: 1
    )
    |> select([j], j.scheduled_at)
    |> repo.one()
  end

  defp worker_name, do: inspect(__MODULE__)

  # ── The tick body (design §4.3 steps 2-6) ───────────────────────

  @doc """
  The tick's body, with the scheduling step removed — this is what
  `perform/1` runs after scheduling its successor. This is the
  AUTOMATIC path: it stops (`:sweep_disabled`) when
  `shop_translation_sweep_enabled` is off, exactly as before. The
  management page's "Запустить сверку" button calls `run_manual_tick/0`
  below instead, not this function.

  Returns `{reason, info}` — `reason` is one of `:translations_disabled`,
  `:sweep_disabled`, `:ai_unavailable`, `:ceiling_reached`,
  `:no_target_languages`, or `:ok` (ran; `info[:enqueued]` may still be
  `0` if nothing needed translating or everything was already in
  flight). Every outcome is also persisted — see `last_run/0`.
  """
  @spec run_tick() :: {atom(), map()}
  def run_tick, do: run_tick(bypass_sweep_gate?: false)

  @doc """
  Manual twin of `run_tick/0`, for the management page's "Запустить
  сверку" button — called directly for immediate feedback, without
  disturbing the scheduled tick (an Oban-inserted immediate job would
  just collide with the same uniqueness that keeps the chain
  single-instance).

  Owner decision overriding design §4.5 as written: `shop_translation_sweep_enabled`
  gates AUTOMATIC scheduling only. An operator-initiated run performs
  the tick's work regardless of that setting — the documented
  manual-only mode (badge: "Automatic sweep: off (manual only)") would
  otherwise make its own "Run sweep" button refuse to run. Every OTHER
  gate (AI availability, the in-flight ceiling, target languages) still
  applies exactly as it does for the scheduled tick.
  """
  @spec run_manual_tick() :: {atom(), map()}
  def run_manual_tick, do: run_tick(bypass_sweep_gate?: true)

  defp run_tick(bypass_sweep_gate?: bypass?) do
    cond do
      not SweepSettings.translations_enabled?() ->
        finish(:translations_disabled)

      not bypass? and not SweepSettings.sweep_enabled?() ->
        finish(:sweep_disabled)

      not ai_available?() ->
        finish(:ai_unavailable)

      true ->
        run_active_tick()
    end
  end

  defp run_active_tick do
    in_flight = count_in_flight()
    remaining_jobs = SweepSettings.max_in_flight() - in_flight

    if remaining_jobs <= 0 do
      finish(:ceiling_reached, %{in_flight: in_flight})
    else
      do_sweep(remaining_jobs, in_flight)
    end
  end

  defp do_sweep(remaining_jobs, in_flight) do
    source_lang = Translations.default_language()
    target_langs = SweepSettings.languages()

    if target_langs == [] do
      finish(:no_target_languages, %{in_flight: in_flight})
    else
      selected =
        take_within_budget(
          candidates(source_lang, target_langs),
          SweepSettings.batch_size(),
          remaining_jobs
        )

      {enqueued, errors} = enqueue_selected(selected, source_lang)

      finish(:ok, %{
        candidates: length(selected),
        enqueued: enqueued,
        errors: length(errors),
        in_flight: in_flight
      })
    end
  end

  # Categories first (design §4.3: 7 of them, more costly a wrong
  # translation is — it's navigation — and never status-filtered), then
  # products filtered by `shop_translation_statuses`. Unbounded reads:
  # design §2 measured the full-catalog hash pass at tens of
  # milliseconds, so there's no query-cost reason to LIMIT here, and a
  # LIMIT on `select_candidates/2`'s `(uuid, lang)` rows could split one
  # resource's language list across a boundary — `take_within_budget/3`
  # below is where the real caps apply, against complete per-resource
  # language lists.
  defp candidates(source_lang, target_langs) do
    tag(CategoryAITranslatable.candidates(source_lang, target_langs), :category) ++
      tag(
        AITranslatable.candidates(source_lang, target_langs, statuses: SweepSettings.statuses()),
        :product
      )
  end

  defp tag(candidates, type), do: Enum.map(candidates, &Map.put(&1, :type, type))

  @doc """
  Design §4.3: the limit is counted in JOBS (one per candidate language),
  not resources — `job_budget` — while `resource_budget`
  (`shop_translation_batch`) independently caps how many resources a
  single tick touches. Selection stops BEFORE either running total would
  be exceeded, never partially consuming a candidate's language list.
  """
  @spec take_within_budget([map()], non_neg_integer(), non_neg_integer()) :: [map()]
  def take_within_budget(candidates, resource_budget, job_budget) do
    candidates
    |> Enum.reduce_while({[], resource_budget, job_budget}, fn candidate,
                                                               {acc, res_left, job_left} ->
      job_count = length(candidate.languages)

      cond do
        res_left <= 0 -> {:halt, {acc, res_left, job_left}}
        job_count > job_left -> {:halt, {acc, res_left, job_left}}
        true -> {:cont, {[candidate | acc], res_left - 1, job_left - job_count}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp enqueue_selected([], _source_lang), do: {0, []}

  defp enqueue_selected(selected, source_lang) do
    endpoint_uuid = PhoenixKitAI.Translations.default_endpoint_uuid()

    prompts = %{
      category: ensure_prompt(CategoryAITranslatable),
      product: ensure_prompt(AITranslatable)
    }

    Enum.reduce(selected, {0, []}, fn candidate, {enqueued, errors} ->
      case Map.fetch!(prompts, candidate.type) do
        {:ok, prompt_uuid} ->
          enqueue_one(candidate, prompt_uuid, endpoint_uuid, source_lang, enqueued, errors)

        {:error, reason} ->
          {enqueued, [{candidate.uuid, reason} | errors]}
      end
    end)
  end

  defp enqueue_one(candidate, prompt_uuid, endpoint_uuid, source_lang, enqueued, errors) do
    adapter = if candidate.type == :category, do: CategoryAITranslatable, else: AITranslatable

    base_params = %{
      resource_type: adapter.resource_type(),
      resource_uuid: candidate.uuid,
      endpoint_uuid: endpoint_uuid,
      prompt_uuid: prompt_uuid,
      source_lang: source_lang,
      # System run — no operator initiated this job (design §4.3 step 3).
      actor_uuid: nil
    }

    case PhoenixKitAI.Translations.enqueue_all_missing(base_params, candidate.languages) do
      # Per-language failures arrive INSIDE the ok tuple (`enqueue/1`
      # refused one language, or Oban rejected its insert) — they must be
      # counted here, or a tick where every insert failed would record
      # `{:ok, enqueued: 0, errors: 0}`, indistinguishable from "nothing
      # needed doing". `last_run/0` is the only place a system-run tick is
      # ever observable (design §1: every capability has observable state).
      {:ok, %{enqueued: n} = result} ->
        lang_errors = Map.get(result, :errors, [])
        {enqueued + n, Enum.map(lang_errors, &{candidate.uuid, &1}) ++ errors}

      {:error, reason} ->
        {enqueued, [{candidate.uuid, reason} | errors]}
    end
  end

  # `ensure_prompt/0` is idempotent but does a DB round-trip — called at
  # most twice per tick (once per adapter actually needed), never per
  # candidate.
  defp ensure_prompt(adapter) do
    case adapter.ensure_prompt() do
      {:ok, uuid, _sync_status} -> {:ok, uuid}
      {:error, _reason} = error -> error
    end
  end

  # `PhoenixKitAI.Translations.available?/0` alone isn't enough (design
  # §4.3): it confirms the plugin is enabled and SOME endpoint exists, not
  # that the specific endpoint `default_endpoint_uuid/0` would resolve
  # still exists and is enabled — that setting can point at a
  # since-deleted or since-disabled endpoint.
  defp ai_available? do
    Code.ensure_loaded?(PhoenixKitAI.Translations) and
      function_exported?(PhoenixKitAI.Translations, :available?, 0) and
      PhoenixKitAI.Translations.available?() and
      not is_nil(PhoenixKitAI.Translations.default_endpoint_uuid())
  end

  # Fails OPEN (0) on any query error, matching
  # `PhoenixKitAI.Translations.job_in_flight?/1`'s own documented
  # trade-off: getting stuck forever behind a transient query failure is
  # worse than occasionally exceeding the ceiling by whatever a
  # concurrent actor inserted, which the next tick corrects for anyway.
  defp count_in_flight do
    repo = PhoenixKit.RepoHelper.repo()
    product_type = AITranslatable.resource_type()
    category_type = CategoryAITranslatable.resource_type()

    from(j in "oban_jobs",
      where: j.worker == ^@translate_worker,
      where: j.state in ^@incomplete_states,
      where:
        fragment("?->>'resource_type' = ?", j.args, ^product_type) or
          fragment("?->>'resource_type' = ?", j.args, ^category_type)
    )
    |> select([j], count(j.id))
    |> repo.one()
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  # ── Recording + reading the outcome ─────────────────────────────

  defp finish(reason, extra \\ %{}) do
    payload =
      extra
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("reason", to_string(reason))
      |> Map.put("at", DateTime.to_iso8601(UtilsDate.utc_now()))

    Settings.update_json_setting_with_module(@last_run_key, payload, @settings_module)

    {reason, extra}
  end

  @doc """
  The persisted outcome of the most recent tick — `nil` before the first
  tick has ever run. Shape: `%{"reason" => string, "at" => iso8601
  string, ...}`; the extra keys vary by reason (see `run_tick/0`'s docs
  for the reason list). This is how the management page (next task)
  shows "why the sweep last stopped" without re-deriving it live —
  `status/0` below is the live version, for "is it configured to run at
  all right now".
  """
  @spec last_run() :: map() | nil
  def last_run do
    case Settings.get_json_setting_cached(@last_run_key, nil) do
      %{} = map -> map
      _ -> nil
    end
  end

  @doc """
  Live scheduling status — `next_tick_at/0` plus `last_run/0` — bundled
  for the management page's sweep block (design §4.5).
  """
  @spec status() :: %{next_tick_at: DateTime.t() | nil, last_run: map() | nil}
  def status do
    %{next_tick_at: next_tick_at(), last_run: last_run()}
  end
end
