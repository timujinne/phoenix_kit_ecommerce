defmodule PhoenixKitEcommerce.Workers.TranslationSweepWorkerTest do
  @moduledoc """
  Coverage for the reconciliation sweep's Oban worker (design §4.3, §7):

    * the self-rescheduling chain — `ensure_scheduled/0`'s idempotency,
      `reschedule/0`'s cancel-and-reapply on an interval change, and that
      `perform/1` schedules its successor even when the tick's own work
      is skipped or crashes;
    * `run_tick/0`'s gates, in order — translations off, sweep off (both
      re-read fresh every call, not baked in at schedule time), AI
      unavailable, ceiling reached;
    * candidate selection under `shop_translation_batch` /
      `shop_translation_max_in_flight` — categories prioritized, the
      ceiling counted in jobs (not resources), a scheduled ("snoozed")
      job pressuring the ceiling same as an available one, and no
      duplicate job for a pair already in flight.

  Oban runs `testing: :manual` here (config/test.exs) — nothing executes
  on its own; every job assertion below is a direct query against
  `oban_jobs`, and `perform/1` is always called directly on a
  hand-built `%Oban.Job{}`, mirroring `phoenix_kit_ai`'s own
  `TranslateWorkerTest`.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.AITranslatable
  alias PhoenixKitEcommerce.CategoryAITranslatable
  alias PhoenixKitEcommerce.TranslationFingerprint
  alias PhoenixKitEcommerce.Workers.TranslationSweepWorker

  @worker "PhoenixKitEcommerce.Workers.TranslationSweepWorker"
  @translate_worker "PhoenixKitAI.TranslateWorker"

  # -- fixtures ------------------------------------------------------

  defp create_product(attrs \\ %{}) do
    base = %{title: %{"en" => "Wooden Vase"}, price: Decimal.new("10.00"), status: "active"}
    {:ok, product} = Shop.create_product(Map.merge(base, attrs))
    product
  end

  defp create_category(attrs \\ %{}) do
    base = %{name: %{"en" => "Vases"}}
    {:ok, category} = Shop.create_category(Map.merge(base, attrs))
    category
  end

  defp enable_languages!(codes) do
    {:ok, _} = Settings.update_boolean_setting_with_module("languages_enabled", true, "languages")

    languages =
      codes
      |> Enum.with_index()
      |> Enum.map(fn {code, index} ->
        %{"code" => code, "name" => code, "is_default" => index == 0, "is_enabled" => true}
      end)

    {:ok, _} =
      Settings.update_json_setting_with_module(
        "languages_config",
        %{"languages" => languages},
        "languages"
      )
  end

  defp enable_translations! do
    Settings.update_boolean_setting_with_module("shop_translations_enabled", true, "shop")
    Settings.update_boolean_setting_with_module("shop_translation_sweep_enabled", true, "shop")
  end

  # A real, enabled endpoint (no live API key needed — nothing here ever
  # calls it; `TranslateWorker.perform/1`, which would, is never invoked).
  defp setup_ai! do
    {:ok, _} = PhoenixKitAI.enable_system()

    {:ok, endpoint} =
      PhoenixKitAI.create_endpoint(%{
        name: "Sweep Test Endpoint #{System.unique_integer([:positive])}",
        provider: "test",
        model: "test-chat-model",
        # A blank string is treated by `cast/4`'s default `empty_values`
        # as "field not provided", which leaves `api_key` nil and trips
        # the column's NOT NULL constraint — a real, non-blank placeholder
        # is required even though nothing here ever calls the endpoint.
        api_key: "unused-test-key"
      })

    endpoint
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()

  defp job, do: %Oban.Job{id: 1, args: %{}, attempt: 1, max_attempts: 1}

  defp pending_tick_jobs do
    from(j in "oban_jobs",
      where: j.worker == ^@worker,
      where: j.state in ["available", "scheduled"]
    )
    |> select([j], %{id: j.id, scheduled_at: j.scheduled_at})
    |> repo().all()
  end

  defp translate_jobs do
    from(j in "oban_jobs", where: j.worker == ^@translate_worker)
    |> select([j], %{state: j.state, args: j.args})
    |> repo().all()
  end

  defp seed_translate_job(resource_type, resource_uuid, target_lang, opts \\ []) do
    args = %{
      "resource_type" => resource_type,
      "resource_uuid" => resource_uuid,
      "endpoint_uuid" => Ecto.UUID.generate(),
      "prompt_uuid" => Ecto.UUID.generate(),
      "source_lang" => "en",
      "target_lang" => target_lang,
      "actor_uuid" => nil,
      "resource_scope" => nil
    }

    {:ok, oban_job} = args |> PhoenixKitAI.TranslateWorker.new(opts) |> Oban.insert()
    oban_job
  end

  # -- ensure_scheduled/0 ---------------------------------------------

  describe "ensure_scheduled/0" do
    test "inserts a tick scheduled at the configured interval" do
      Settings.update_setting_with_module("shop_translation_interval_minutes", "30", "shop")

      {:ok, job} = TranslationSweepWorker.ensure_scheduled()

      assert job.worker == @worker
      assert job.args == %{}
      assert_in_delta DateTime.diff(job.scheduled_at, DateTime.utc_now()), 1800, 5
    end

    test "is idempotent — a second call converges on the same job" do
      {:ok, job1} = TranslationSweepWorker.ensure_scheduled()
      {:ok, job2} = TranslationSweepWorker.ensure_scheduled()

      assert job1.id == job2.id
      assert length(pending_tick_jobs()) == 1
    end

    test "unconditional — schedules even when the sweep has never been enabled" do
      refute Settings.get_boolean_setting("shop_translation_sweep_enabled", false)

      assert {:ok, _job} = TranslationSweepWorker.ensure_scheduled()
      assert length(pending_tick_jobs()) == 1
    end
  end

  # -- PhoenixKitEcommerce.enable_system/0 -----------------------------

  describe "PhoenixKitEcommerce.enable_system/0" do
    test "also recovers the sweep chain" do
      refute TranslationSweepWorker.next_tick_at()

      {:ok, _setting} = Shop.enable_system()

      assert TranslationSweepWorker.next_tick_at()
    end
  end

  # -- reschedule/0 ----------------------------------------------------

  describe "reschedule/0" do
    test "cancels the stale scheduled tick and applies the new interval" do
      Settings.update_setting_with_module("shop_translation_interval_minutes", "60", "shop")
      {:ok, old_job} = TranslationSweepWorker.ensure_scheduled()

      Settings.update_setting_with_module("shop_translation_interval_minutes", "5", "shop")
      {:ok, new_job} = TranslationSweepWorker.reschedule()

      refute new_job.id == old_job.id

      pending = pending_tick_jobs()
      assert [%{id: id}] = pending
      assert id == new_job.id

      # Reflects the shortened 5-minute interval, not the stale 60-minute wait.
      assert_in_delta DateTime.diff(new_job.scheduled_at, DateTime.utc_now()), 300, 5
    end
  end

  # -- next_tick_at/0 / status/0 / last_run/0 --------------------------

  describe "next_tick_at/0" do
    test "nil before any tick has ever been scheduled" do
      refute TranslationSweepWorker.next_tick_at()
    end

    test "reflects the pending tick's scheduled_at" do
      {:ok, job} = TranslationSweepWorker.ensure_scheduled()
      assert TranslationSweepWorker.next_tick_at() == job.scheduled_at
    end
  end

  describe "last_run/0 and status/0" do
    test "last_run/0 is nil before the first tick" do
      refute TranslationSweepWorker.last_run()
    end

    test "status/0 bundles next_tick_at and the last recorded outcome" do
      {:ok, job} = TranslationSweepWorker.ensure_scheduled()
      TranslationSweepWorker.run_tick()

      status = TranslationSweepWorker.status()
      assert status.next_tick_at == job.scheduled_at
      assert status.last_run["reason"] == "translations_disabled"
    end
  end

  # -- perform/1: the chain survives regardless of tick outcome -------

  describe "perform/1 schedules its successor first" do
    test "even when the tick stops immediately (translations disabled)" do
      refute TranslationSweepWorker.next_tick_at()
      assert :ok = TranslationSweepWorker.perform(job())
      assert TranslationSweepWorker.next_tick_at()
    end

    test "even when the tick body raises after the successor was already scheduled" do
      enable_translations!()
      setup_ai!()
      enable_languages!(["en", "de"])

      # A genuine crash inside the tick body: `TranslationFingerprint.
      # select_candidates/2` raises on a real query failure (design §4.3
      # — categories are queried first, so this fires deterministically).
      # Sandboxed: the DROP rolls back with the rest of this test's
      # transaction.
      SQL.query!(repo(), "DROP TABLE phoenix_kit_shop_categories CASCADE", [])

      assert_raise RuntimeError, ~r/select_candidates.*query failed/, fn ->
        TranslationSweepWorker.perform(job())
      end

      # The successor was scheduled BEFORE the crash — the chain survives.
      assert TranslationSweepWorker.next_tick_at()
    end
  end

  # -- run_tick/0: the gates, in order ---------------------------------

  describe "run_tick/0 gates" do
    test "translations disabled ⇒ stops, records why, nothing enqueued" do
      assert {:translations_disabled, _} = TranslationSweepWorker.run_tick()
      assert TranslationSweepWorker.last_run()["reason"] == "translations_disabled"
      assert translate_jobs() == []
    end

    test "translations enabled but sweep disabled ⇒ stops, records why" do
      Settings.update_boolean_setting_with_module("shop_translations_enabled", true, "shop")

      assert {:sweep_disabled, _} = TranslationSweepWorker.run_tick()
      assert TranslationSweepWorker.last_run()["reason"] == "sweep_disabled"
      assert translate_jobs() == []
    end

    test "AI plugin never enabled ⇒ ai_unavailable" do
      enable_translations!()

      assert {:ai_unavailable, _} = TranslationSweepWorker.run_tick()
      assert TranslationSweepWorker.last_run()["reason"] == "ai_unavailable"
    end

    test "AI plugin enabled but no endpoints configured ⇒ ai_unavailable" do
      enable_translations!()
      {:ok, _} = PhoenixKitAI.enable_system()

      assert {:ai_unavailable, _} = TranslationSweepWorker.run_tick()
    end

    test "AI plugin enabled with only a disabled endpoint ⇒ ai_unavailable" do
      enable_translations!()
      {:ok, _} = PhoenixKitAI.enable_system()

      {:ok, _} =
        PhoenixKitAI.create_endpoint(%{
          name: "Disabled Endpoint",
          provider: "test",
          model: "test-chat-model",
          # A blank string is treated by `cast/4`'s default `empty_values`
          # as "field not provided", which leaves `api_key` nil and trips
          # the column's NOT NULL constraint — a real, non-blank placeholder
          # is required even though nothing here ever calls the endpoint.
          api_key: "unused-test-key",
          enabled: false
        })

      assert {:ai_unavailable, _} = TranslationSweepWorker.run_tick()
    end

    test "both toggles are re-read fresh every call — flipping one changes the very next tick" do
      enable_translations!()
      setup_ai!()
      enable_languages!(["en", "de"])

      assert {:ok, _} = TranslationSweepWorker.run_tick()

      Settings.update_boolean_setting_with_module("shop_translation_sweep_enabled", false, "shop")
      assert {:sweep_disabled, _} = TranslationSweepWorker.run_tick()

      Settings.update_boolean_setting_with_module("shop_translation_sweep_enabled", true, "shop")
      Settings.update_boolean_setting_with_module("shop_translations_enabled", false, "shop")
      assert {:translations_disabled, _} = TranslationSweepWorker.run_tick()

      Settings.update_boolean_setting_with_module("shop_translations_enabled", true, "shop")
      assert {:ok, _} = TranslationSweepWorker.run_tick()
    end

    test "no target languages resolved ⇒ stops without enqueueing" do
      enable_translations!()
      setup_ai!()
      # Languages module left disabled: enabled_languages/0 == [default_language()],
      # so the dynamic default ("enabled minus primary") is empty.

      assert {:no_target_languages, _} = TranslationSweepWorker.run_tick()
      assert translate_jobs() == []
    end

    test "ceiling already reached ⇒ stops without enqueueing, in_flight reported" do
      enable_translations!()
      setup_ai!()
      enable_languages!(["en", "de"])
      Settings.update_setting_with_module("shop_translation_max_in_flight", "1", "shop")

      product = create_product()
      seed_translate_job(AITranslatable.resource_type(), product.uuid, "de")

      assert {:ceiling_reached, %{in_flight: 1}} = TranslationSweepWorker.run_tick()
      assert TranslationSweepWorker.last_run()["reason"] == "ceiling_reached"
      assert TranslationSweepWorker.last_run()["in_flight"] == 1
    end

    test "a finished TranslateWorker job no longer presses on the ceiling" do
      enable_translations!()
      setup_ai!()
      enable_languages!(["en", "de"])
      Settings.update_setting_with_module("shop_translation_max_in_flight", "1", "shop")

      product = create_product()
      done = seed_translate_job(AITranslatable.resource_type(), Ecto.UUID.generate(), "de")

      from(j in "oban_jobs", where: j.id == ^done.id)
      |> repo().update_all(set: [state: "completed"])

      # Terminal states must drop out of the count, or every finished
      # translation would accumulate against the ceiling until Oban pruning
      # ran and the sweep would jam shut permanently on a busy stand.
      assert {:ok, %{enqueued: 1, in_flight: 0}} = TranslationSweepWorker.run_tick()

      assert [queued] =
               translate_jobs() |> Enum.filter(&(&1.args["resource_uuid"] == product.uuid))

      assert queued.args["target_lang"] == "de"
    end

    test "another module's TranslateWorker job does not press on the shop ceiling" do
      enable_translations!()
      setup_ai!()
      enable_languages!(["en", "de"])
      Settings.update_setting_with_module("shop_translation_max_in_flight", "1", "shop")

      create_product()
      # The ceiling bounds THIS shop's contribution (design §4.3: "по типам
      # ресурсов магазина"); a blog-post translation from another module
      # sharing the queue must not count against it.
      seed_translate_job("blog_post", Ecto.UUID.generate(), "de")

      assert {:ok, %{enqueued: 1, in_flight: 0}} = TranslationSweepWorker.run_tick()
    end

    test "a scheduled (snoozed) TranslateWorker job presses on the ceiling exactly like an available one" do
      enable_translations!()
      setup_ai!()
      enable_languages!(["en", "de"])
      Settings.update_setting_with_module("shop_translation_max_in_flight", "1", "shop")

      category = create_category()
      # `schedule_in:` here produces the same `scheduled` state a real
      # snooze does (design §4.3: "снуз-задания в scheduled давят на потолок").
      seed_translate_job(CategoryAITranslatable.resource_type(), category.uuid, "de",
        schedule_in: 3600
      )

      assert {:ceiling_reached, _} = TranslationSweepWorker.run_tick()
    end
  end

  # -- run_tick/0: candidate selection + enqueueing --------------------

  describe "run_tick/0 candidate selection" do
    setup do
      enable_translations!()
      setup_ai!()
      enable_languages!(["en", "de"])
      :ok
    end

    test "enqueues exactly the expected set for a product and a category" do
      product = create_product(%{title: %{"en" => "Wooden Vase"}})
      category = create_category(%{name: %{"en" => "Vases"}})

      assert {:ok, %{enqueued: 2, candidates: 2, errors: 0, in_flight: 0}} =
               TranslationSweepWorker.run_tick()

      jobs = translate_jobs()
      assert length(jobs) == 2

      uuids_and_types =
        Enum.map(
          jobs,
          &{&1.args["resource_type"], &1.args["resource_uuid"], &1.args["target_lang"]}
        )

      assert {"shop_product", product.uuid, "de"} in uuids_and_types
      assert {"shop_category", category.uuid, "de"} in uuids_and_types

      assert TranslationSweepWorker.last_run()["reason"] == "ok"
      assert TranslationSweepWorker.last_run()["enqueued"] == 2
    end

    test "fresh resources (nothing stale/missing) ⇒ ok with nothing enqueued" do
      # Stamp the reference so the product reads as fresh, not merely
      # "unknown" — either way it must not be a candidate, but this
      # exercises the actual "nothing to do" success path rather than a
      # gate stopping the tick early.
      product = create_product(%{title: %{"en" => "Wooden Vase", "de" => "Holzvase"}})

      fresh_metadata =
        TranslationFingerprint.put_many(product.metadata, "de", %{
          "title" => TranslationFingerprint.hash("Wooden Vase")
        })

      {:ok, _product} =
        product |> Ecto.Changeset.change(%{metadata: fresh_metadata}) |> repo().update()

      assert {:ok, %{enqueued: 0}} = TranslationSweepWorker.run_tick()
      assert translate_jobs() == []
    end

    test "categories are prioritized over products when the batch is tight" do
      Settings.update_setting_with_module("shop_translation_batch", "1", "shop")

      _product = create_product(%{title: %{"en" => "Wooden Vase"}})
      category = create_category(%{name: %{"en" => "Vases"}})

      assert {:ok, %{enqueued: 1, candidates: 1}} = TranslationSweepWorker.run_tick()

      [job] = translate_jobs()
      assert job.args["resource_type"] == "shop_category"
      assert job.args["resource_uuid"] == category.uuid
    end

    test "the job ceiling stops selection before partially consuming a candidate's languages" do
      enable_languages!(["en", "de", "fr"])
      Settings.update_setting_with_module("shop_translation_max_in_flight", "1", "shop")

      # Needs BOTH de and fr ⇒ 2 jobs, which exceeds the ceiling of 1 — the
      # whole candidate is skipped rather than enqueuing just one language.
      create_product(%{title: %{"en" => "Wooden Vase"}})

      assert {:ok, %{enqueued: 0, candidates: 0}} = TranslationSweepWorker.run_tick()
      assert translate_jobs() == []
    end

    test "a resource-language pair already in flight is not duplicated" do
      product = create_product(%{title: %{"en" => "Wooden Vase"}})
      enable_languages!(["en", "de", "fr"])

      seed_translate_job("shop_product", product.uuid, "de")

      assert {:ok, %{enqueued: 1, candidates: 1, in_flight: 1}} =
               TranslationSweepWorker.run_tick()

      jobs = translate_jobs() |> Enum.filter(&(&1.args["resource_uuid"] == product.uuid))
      target_langs = Enum.map(jobs, & &1.args["target_lang"]) |> Enum.sort()

      # Exactly one "de" job (the pre-seeded one — not duplicated) and one
      # new "fr" job.
      assert target_langs == ["de", "fr"]
    end

    test "the product status filter is honoured; categories are never filtered by it" do
      Settings.update_json_setting_with_module(
        "shop_translation_statuses",
        %{"statuses" => ["active"]},
        "shop"
      )

      _draft = create_product(%{title: %{"en" => "Draft Vase"}, status: "draft"})
      active = create_product(%{title: %{"en" => "Active Vase"}, status: "active"})
      hidden_category = create_category(%{name: %{"en" => "Hidden"}, status: "hidden"})

      assert {:ok, %{enqueued: 2}} = TranslationSweepWorker.run_tick()

      uuids = translate_jobs() |> MapSet.new(& &1.args["resource_uuid"])
      assert MapSet.member?(uuids, active.uuid)
      assert MapSet.member?(uuids, hidden_category.uuid)
    end
  end
end
