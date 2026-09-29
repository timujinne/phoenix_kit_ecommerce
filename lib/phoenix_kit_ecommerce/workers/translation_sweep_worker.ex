defmodule PhoenixKitEcommerce.Workers.TranslationSweepWorker do
  @moduledoc """
  The shop's AI-translation sweep (design §4.3): a self-rescheduling Oban
  chain that tops up the translations products and categories are
  missing or have let go stale, every
  `TranslationSweepSettings.interval_minutes/0` minutes.

  The chain, the gates, the budget and the recorded outcome are
  `PhoenixKitAI.TranslationSweep`'s — this worker is the shop's source
  for it, implementing that module's callbacks structurally:

    * `sweep_ready/1` — stops the tick while `shop_translations_enabled`
      is off (`:translations_disabled`), and under the catalogue product
      source (`:product_source_unsupported`: no shop adapter is registered
      with `phoenix_kit_ai` then, so every job would be discarded — see
      `PhoenixKitEcommerce.translations_supported?/0`). Neither is
      bypassed by the page's "Run sweep", which skips only the automatic
      switch (`shop_translation_sweep_enabled`).
    * `sweep_settings/0` — the interval, the target languages, `batch`
      (`shop_translation_batch`, resources per tick) and `max_in_flight`
      (`shop_translation_max_in_flight`, incomplete shop `TranslateWorker`
      JOBS), read fresh on every tick.
    * `sweep_candidates/2` — every stale or missing category first (never
      status-filtered: a hidden category would otherwise ship translated
      navigation before it is visible), then products filtered by
      `shop_translation_statuses`. Unbounded reads — the caps apply in the
      engine, against complete per-resource language lists.
    * `sweep_prompts/0` — the two code-managed prompts; a type whose
      prompt cannot be prepared counts its languages as errors while the
      other type still enqueues.

  The outcome of every tick is kept by the engine (`last_run/0`,
  `status/0`).

  `ensure_scheduled/0` is unconditional: the chain runs whether or not
  the sweep is on (a tick of a disabled sweep records why and schedules
  the next), so a re-enabled sweep needs no kick. It is called from
  `PhoenixKitEcommerce.enable_system/0`, a sweep-settings save
  (`reschedule/0`) and the translations page's mount — uniqueness keeps
  those converging on one waiting tick.

  `phoenix_kit_ai` is an optional dependency, so the behaviour is not
  declared (it would force the dependency at compile time) and every
  entry point checks the engine is loaded. Without it the tick answers
  `:ai_unavailable` and a scheduled job snoozes for an interval.
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  @compile {:no_warn_undefined, PhoenixKitAI.TranslationSweep}

  alias PhoenixKitEcommerce.AITranslatable
  alias PhoenixKitEcommerce.CategoryAITranslatable
  alias PhoenixKitEcommerce.Translations
  alias PhoenixKitEcommerce.TranslationSweepSettings, as: SweepSettings

  @engine PhoenixKitAI.TranslationSweep

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if engine?(),
      do: scheduled_tick(),
      else: {:snooze, SweepSettings.interval_minutes() * 60}
  end

  # ── The chain ──────────────────────────────────────────────────────

  @doc """
  Makes sure one tick is waiting, at the current interval. Unconditional
  and safe to call from anywhere — see the moduledoc.
  """
  @spec ensure_scheduled() :: {:ok, Oban.Job.t()} | {:error, term()}
  def ensure_scheduled,
    do: if(engine?(), do: @engine.ensure_scheduled(__MODULE__), else: {:error, :ai_unavailable})

  @doc """
  Replaces the waiting tick with one at the current interval. A settings
  save calls it, or a shortened interval would wait out the old one.
  """
  @spec reschedule() :: {:ok, Oban.Job.t()} | {:error, term()}
  def reschedule,
    do: if(engine?(), do: @engine.reschedule(__MODULE__), else: {:error, :ai_unavailable})

  @doc "When the waiting tick fires, or `nil` when none is waiting."
  @spec next_tick_at() :: DateTime.t() | nil
  def next_tick_at, do: if(engine?(), do: @engine.next_tick_at(__MODULE__))

  # ── A tick ─────────────────────────────────────────────────────────

  @doc """
  The automatic tick's work, without the scheduling. Answers and records
  `{reason, info}` — the engine's reasons (`PhoenixKitAI.TranslationSweep.run_tick/2`)
  plus this source's `:translations_disabled` and
  `:product_source_unsupported`.
  """
  @spec run_tick() :: {atom(), map()}
  def run_tick, do: tick(:interval)

  @doc """
  The page's "Run sweep": the same work, run now, whether or not the
  automatic sweep is on (owner decision — that switch gates scheduling
  only). Every other gate still applies.
  """
  @spec run_manual_tick() :: {atom(), map()}
  def run_manual_tick, do: tick(:manual)

  @tick_lock_key "phoenix_kit_ecommerce:translation_sweep_tick"

  # One direct tick at a time. The engine sees an executing Oban sweep job
  # (`:sweep_running`), not another direct call: two tabs pressing Run
  # sweep at once would both select the same candidates and enqueue them
  # twice. A transaction-scoped try-lock makes the second one answer
  # `:sweep_running` instead, the wording the page already has.
  defp tick(trigger) do
    if engine?(), do: locked_tick(trigger), else: {:ai_unavailable, %{}}
  end

  defp locked_tick(trigger) do
    {:ok, result} =
      PhoenixKit.RepoHelper.repo().transaction(fn ->
        if tick_lock?(), do: @engine.run_tick(__MODULE__, trigger), else: {:sweep_running, %{}}
      end)

    result
  end

  # The scheduled tick waits for a direct one to commit. The engine only
  # refuses a direct tick while a scheduled one executes, not the other way
  # round, and a direct tick's jobs are invisible until its transaction
  # commits — without the wait, a scheduled tick starting mid-run reads
  # them as not in flight and enqueues the same pairs again. The successor
  # is scheduled first and outside the lock's transaction, as the engine's
  # own `perform/1` does, so a tick that raises cannot roll the chain back.
  defp scheduled_tick do
    _ = @engine.ensure_scheduled(__MODULE__)

    {:ok, _result} =
      PhoenixKit.RepoHelper.repo().transaction(fn ->
        PhoenixKit.RepoHelper.repo().query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
          @tick_lock_key
        ])

        @engine.run_tick(__MODULE__, :interval)
      end)

    :ok
  end

  defp tick_lock? do
    %{rows: [[locked?]]} =
      PhoenixKit.RepoHelper.repo().query!("SELECT pg_try_advisory_xact_lock(hashtext($1))", [
        @tick_lock_key
      ])

    locked?
  end

  @doc ~s(The last tick's outcome — `%{"reason" => …, "since" => …}`, `since` being when ticks began ending this way — or `nil`.)
  @spec last_run() :: map() | nil
  def last_run, do: if(engine?(), do: @engine.last_run(__MODULE__))

  @doc "The last outcome, the waiting tick and whether one is running."
  @spec status() :: %{
          last_run: map() | nil,
          next_tick_at: DateTime.t() | nil,
          running?: boolean()
        }
  def status do
    if engine?(),
      do: @engine.status(__MODULE__),
      else: %{last_run: nil, next_tick_at: nil, running?: false}
  end

  # ── PhoenixKitAI.TranslationSweep callbacks ────────────────────────

  @doc false
  def sweep_key, do: "shop"

  @doc false
  def sweep_settings do
    %{
      enabled?: SweepSettings.sweep_enabled?(),
      interval_minutes: SweepSettings.interval_minutes(),
      languages: SweepSettings.languages(),
      batch: SweepSettings.batch_size(),
      max_in_flight: SweepSettings.max_in_flight(),
      source_language: Translations.default_language()
    }
  end

  @doc false
  def sweep_ready(_trigger) do
    cond do
      not SweepSettings.translations_enabled?() -> {:stop, :translations_disabled}
      not PhoenixKitEcommerce.translations_supported?() -> {:stop, :product_source_unsupported}
      true -> :ok
    end
  end

  @doc false
  def sweep_resource_types,
    do: [CategoryAITranslatable.resource_type(), AITranslatable.resource_type()]

  @doc false
  def sweep_candidates(source_lang, target_langs) do
    tag(CategoryAITranslatable, CategoryAITranslatable.candidates(source_lang, target_langs)) ++
      tag(
        AITranslatable,
        AITranslatable.candidates(source_lang, target_langs, statuses: SweepSettings.statuses())
      )
  end

  defp tag(adapter, candidates) do
    type = adapter.resource_type()
    Enum.map(candidates, &%{resource_type: type, uuid: &1.uuid, languages: &1.languages})
  end

  @doc false
  def sweep_prompts do
    [CategoryAITranslatable, AITranslatable]
    |> Enum.map(fn adapter -> {adapter.resource_type(), adapter.ensure_prompt()} end)
    |> Enum.reduce({%{}, nil}, fn
      {type, {:ok, uuid, _sync_status}}, {prompts, error} -> {Map.put(prompts, type, uuid), error}
      {_type, {:error, reason}}, {prompts, _error} -> {prompts, reason}
    end)
    |> case do
      {prompts, error} when map_size(prompts) == 0 -> {:error, error}
      {prompts, _error} -> {:ok, prompts}
    end
  end

  defp engine?, do: Code.ensure_loaded?(@engine)
end
