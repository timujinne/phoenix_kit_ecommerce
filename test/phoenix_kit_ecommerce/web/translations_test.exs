defmodule PhoenixKitEcommerce.Web.TranslationsTest do
  @moduledoc """
  `/admin/shop/translations` (design §4.5, §7):

    * unreachable unless BOTH `shop_translations_enabled` and AI are on
      (design §1 — no capability without a visible/reachable entry point,
      and conversely no page pretending to work when its backing
      capability doesn't exist);
    * filters round-trip through the URL;
    * the three bulk verbs (translate / retranslate / stamp) go through
      request → confirm and, on confirm, do exactly what design §4.4
      specifies — most importantly that "retranslate" resets the
      fingerprint BEFORE enqueueing, so a fresh pair actually gets
      requeued instead of silently no-op'ing;
    * "Stop translations" cancels only this shop's `TranslateWorker`
      jobs, never another module's;
    * a `PhoenixKitAI.Translations` PubSub event updates a row's state
      without a manual reload.

  Oban runs `testing: :manual` (config/test.exs) — nothing executes on
  its own; every job assertion is a direct query against `oban_jobs`,
  mirroring `TranslationSweepWorkerTest`.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  import Ecto.Query

  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.AITranslatable
  alias PhoenixKitEcommerce.TranslationFingerprint
  alias PhoenixKitEcommerce.TranslationSweepSettings, as: SweepSettings
  alias PhoenixKitEcommerce.Workers.TranslationSweepWorker, as: SweepWorker

  @translate_worker "PhoenixKitAI.TranslateWorker"

  # -- fixtures (mirrors TranslationSweepWorkerTest) -------------------

  defp create_product(attrs \\ %{}) do
    base = %{
      title: %{"en" => "Wooden Vase"},
      description: %{"en" => "A nice vase"},
      price: Decimal.new("10.00"),
      status: "active"
    }

    {:ok, product} = Shop.create_product(Map.merge(base, attrs))
    product
  end

  defp create_category(attrs \\ %{}) do
    base = %{name: %{"en" => "Vases"}, description: %{"en" => "Decorative vases"}}
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
  end

  # A real, enabled endpoint — nothing here ever calls it (Oban is manual).
  defp setup_ai! do
    {:ok, _} = PhoenixKitAI.enable_system()

    {:ok, endpoint} =
      PhoenixKitAI.create_endpoint(%{
        name: "Translations Page Test Endpoint #{System.unique_integer([:positive])}",
        provider: "test",
        model: "test-chat-model",
        api_key: "unused-test-key"
      })

    endpoint
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()

  defp translate_jobs do
    from(j in "oban_jobs", where: j.worker == ^@translate_worker)
    |> select([j], %{state: j.state, args: j.args})
    |> repo().all()
  end

  defp jobs_for(uuid) do
    translate_jobs()
    |> Enum.filter(&(&1.args["resource_uuid"] == uuid))
  end

  defp confirm!(view), do: render_click(view, "confirm_bulk_action", %{})

  defp ready! do
    enable_translations!()
    setup_ai!()
    enable_languages!(["en", "de", "fr"])
  end

  # ============================================================
  # Mount availability (design §1)
  # ============================================================

  describe "mount availability" do
    test "redirects when shop_translations_enabled is false", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, "/en/admin/shop/translations")
      assert to =~ "/admin/shop"
    end

    test "redirects when enabled but AI is unavailable", %{conn: conn} do
      enable_translations!()
      conn = put_test_scope(conn, fake_scope())

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, "/en/admin/shop/translations")
      assert to =~ "/admin/shop"
    end

    test "redirects without shop.manage_catalog even when both gates are open", %{conn: conn} do
      ready!()
      conn = put_test_scope(conn, fake_scope(permissions: ["shop"]))

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, "/en/admin/shop/translations")
      assert to =~ "/admin/shop"
    end

    test "mounts and renders once both gates are open", %{conn: conn} do
      ready!()
      conn = put_test_scope(conn, fake_scope())

      {:ok, _view, html} = live(conn, "/en/admin/shop/translations")

      assert html =~ "Shop Translations"
      assert html =~ ~s(id="sweep-block")
      assert html =~ ~s(id="coverage-stats")
      assert html =~ ~s(id="stop-translations")
    end
  end

  # ============================================================
  # Filters round-trip through the URL
  # ============================================================

  describe "filters" do
    setup %{conn: conn} do
      ready!()
      {:ok, conn: put_test_scope(conn, fake_scope())}
    end

    test "changing the state filter patches the URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/translations")

      render_change(view, "filter_state", %{"state" => "missing"})
      assert_patch(view)
    end

    test "?state= in the URL restores the filter on mount", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/shop/translations?state=stale")

      assert html =~ ~s(<option value="stale" selected)
    end

    test "?type=category restores the category listing on mount", %{conn: conn} do
      create_category(%{name: %{"en" => "Bowls"}})

      {:ok, _view, html} = live(conn, "/en/admin/shop/translations?type=category")

      assert html =~ ~s(<option value="category" selected)
      assert html =~ "Bowls"
    end

    test "switching type resets the category filter", %{conn: conn} do
      category = create_category()

      {:ok, view, _html} =
        live(conn, "/en/admin/shop/translations?category=#{category.uuid}")

      render_change(view, "filter_type", %{"type" => "category"})
      path = assert_patch(view)

      refute path =~ "category="
    end
  end

  # ============================================================
  # Bulk verb: translate
  # ============================================================

  describe "bulk translate" do
    setup %{conn: conn} do
      ready!()
      {:ok, conn: put_test_scope(conn, fake_scope())}
    end

    test "request opens a confirm modal; confirm enqueues missing∪stale languages", %{
      conn: conn
    } do
      product = create_product()
      {:ok, view, _html} = live(conn, "/en/admin/shop/translations")

      html = render_click(view, "request_translate:all:all", %{"uuids" => [product.uuid]})
      assert html =~ "Translate?"
      # Design §4.5: the confirmation names resources, LANGUAGES and the estimate.
      assert html =~ "de, fr"
      assert html =~ "model call"

      html = confirm!(view)

      jobs = jobs_for(product.uuid)
      assert length(jobs) == 2
      assert Enum.all?(jobs, &(&1.args["resource_type"] == "shop_product"))
      assert Enum.sort(Enum.map(jobs, & &1.args["target_lang"])) == ["de", "fr"]
      assert html =~ "queued"
    end

    test "narrowing to one language enqueues only that language", %{conn: conn} do
      product = create_product()
      {:ok, view, _html} = live(conn, "/en/admin/shop/translations")

      render_click(view, "request_translate:de:all", %{"uuids" => [product.uuid]})
      confirm!(view)

      jobs = jobs_for(product.uuid)
      assert [%{args: %{"target_lang" => "de"}}] = jobs
    end

    test "a resource with every language already :fresh queues nothing", %{conn: conn} do
      # No `description` source at all — otherwise it would sit :missing
      # for "de"/"fr" and keep BOTH languages legitimate candidates, which
      # is not what this test is isolating (title-only fixtures mirror
      # `AITranslatableTest`'s own `@no_other_sources` pattern).
      product = create_product(%{description: %{}})

      {:ok, translated} =
        AITranslatable.put_translation(product, "de", %{"title" => "Holzvase"},
          source_fields: %{"title" => "Wooden Vase"}
        )

      {:ok, translated} =
        AITranslatable.put_translation(translated, "fr", %{"title" => "Vase en Bois"},
          source_fields: %{"title" => "Wooden Vase"}
        )

      {:ok, view, _html} = live(conn, "/en/admin/shop/translations")

      render_click(view, "request_translate:all:all", %{"uuids" => [translated.uuid]})
      confirm!(view)

      assert jobs_for(translated.uuid) == []
    end

    test "denied without shop.manage_settings", %{conn: conn} do
      product = create_product()
      conn = put_test_scope(conn, fake_scope(permissions: ["shop", "shop.manage_catalog"]))
      {:ok, view, _html} = live(conn, "/en/admin/shop/translations")

      html = render_click(view, "request_translate:all:all", %{"uuids" => [product.uuid]})

      assert html =~ "You don&#39;t have permission to do that"
      assert jobs_for(product.uuid) == []
    end
  end

  # ============================================================
  # Bulk verb: retranslate ("перевести заново") — design §4.4
  # ============================================================

  describe "bulk retranslate" do
    setup %{conn: conn} do
      ready!()
      {:ok, conn: put_test_scope(conn, fake_scope())}
    end

    test "resets the fingerprint for the selected scope BEFORE enqueueing, so a :fresh pair still gets requeued",
         %{conn: conn} do
      # No `description` source — field doesn't narrow job composition
      # (design §4.4: "На состав задания он не влияет"), so a genuinely
      # :missing `description` for "de" would keep this pair a legitimate
      # translate candidate regardless of :title's own state, defeating
      # what this test isolates.
      product = create_product(%{description: %{}})

      {:ok, translated} =
        AITranslatable.put_translation(product, "de", %{"title" => "Holzvase"},
          source_fields: %{"title" => "Wooden Vase"}
        )

      assert TranslationFingerprint.get(translated.metadata, "de", "title") != nil

      # A plain "translate" on this already-:fresh pair queues nothing —
      # pinning that the SAME source, unchanged, would otherwise be a
      # no-op (see the "bulk translate" describe above), which is exactly
      # the case "перевести заново" exists to override.
      {:ok, view, _html} = live(conn, "/en/admin/shop/translations")
      render_click(view, "request_translate:de:title", %{"uuids" => [translated.uuid]})
      confirm!(view)
      assert jobs_for(translated.uuid) == []

      html =
        render_click(view, "request_retranslate:de:title", %{"uuids" => [translated.uuid]})

      assert html =~ "Translate again?"
      html = confirm!(view)

      reloaded = Shop.get_product!(translated.uuid)
      assert TranslationFingerprint.get(reloaded.metadata, "de", "title") == nil

      jobs = jobs_for(translated.uuid)
      assert [%{args: %{"target_lang" => "de"}}] = jobs
      assert html =~ "queued"
    end

    test "narrows to exactly the selected field, other fields' fingerprints survive", %{
      conn: conn
    } do
      product = create_product()

      {:ok, translated} =
        AITranslatable.put_translation(
          product,
          "de",
          %{"title" => "Holzvase", "description" => "Eine schöne Vase"},
          source_fields: %{"title" => "Wooden Vase", "description" => "A nice vase"}
        )

      {:ok, view, _html} = live(conn, "/en/admin/shop/translations")
      render_click(view, "request_retranslate:de:title", %{"uuids" => [translated.uuid]})
      confirm!(view)

      reloaded = Shop.get_product!(translated.uuid)
      assert TranslationFingerprint.get(reloaded.metadata, "de", "title") == nil
      assert TranslationFingerprint.get(reloaded.metadata, "de", "description") != nil
    end
  end

  # ============================================================
  # Bulk verb: stamp as reference — design §4.1, §4.5
  # ============================================================

  describe "bulk stamp" do
    setup %{conn: conn} do
      ready!()
      {:ok, conn: put_test_scope(conn, fake_scope())}
    end

    test "stamps an :unknown translation to :fresh, without calling the model", %{conn: conn} do
      product = create_product()

      {:ok, primed} =
        product
        |> Ecto.Changeset.change(%{title: Map.put(product.title, "de", "Vorhandene Vase")})
        |> repo().update()

      assert TranslationFingerprint.get(primed.metadata, "de", "title") == nil

      {:ok, view, _html} = live(conn, "/en/admin/shop/translations")

      html = render_click(view, "request_stamp:all:all", %{"uuids" => [primed.uuid]})
      assert html =~ "Stamp as reference?"
      # Stamping a `stale` row freezes its divergence (design §4.1's booked
      # cost) — the confirmation has to say so before it happens.
      assert html =~ "accepted as up to date"
      html = confirm!(view)

      reloaded = Shop.get_product!(primed.uuid)
      assert TranslationFingerprint.get(reloaded.metadata, "de", "title") != nil
      assert reloaded.title["de"] == "Vorhandene Vase"

      # No model call — no TranslateWorker job for this resource.
      assert jobs_for(primed.uuid) == []
      assert html =~ "Stamped"
    end
  end

  # ============================================================
  # Stop translations — cancels this shop's jobs only
  # ============================================================

  describe "stop translations" do
    setup %{conn: conn} do
      ready!()
      {:ok, conn: put_test_scope(conn, fake_scope())}
    end

    test "cancels incomplete shop TranslateWorker jobs but not a foreign resource_type's job",
         %{conn: conn} do
      product = create_product()
      category = create_category()

      shop_args = fn resource_type, uuid, lang ->
        %{
          "resource_type" => resource_type,
          "resource_uuid" => uuid,
          "endpoint_uuid" => Ecto.UUID.generate(),
          "prompt_uuid" => Ecto.UUID.generate(),
          "source_lang" => "en",
          "target_lang" => lang,
          "actor_uuid" => nil,
          "resource_scope" => nil
        }
      end

      {:ok, product_job} =
        shop_args.("shop_product", product.uuid, "de")
        |> PhoenixKitAI.TranslateWorker.new()
        |> Oban.insert()

      {:ok, category_job} =
        shop_args.("shop_category", category.uuid, "fr")
        |> PhoenixKitAI.TranslateWorker.new()
        |> Oban.insert()

      # Same worker, DIFFERENT module's resource_type — must survive.
      {:ok, foreign_job} =
        shop_args.("blog_post", Ecto.UUID.generate(), "de")
        |> PhoenixKitAI.TranslateWorker.new()
        |> Oban.insert()

      {:ok, view, _html} = live(conn, "/en/admin/shop/translations")

      html = render_click(view, "request_stop", %{})
      assert html =~ "Stop translations?"
      html = confirm!(view)

      assert repo().get(Oban.Job, product_job.id).state == "cancelled"
      assert repo().get(Oban.Job, category_job.id).state == "cancelled"
      refute repo().get(Oban.Job, foreign_job.id).state == "cancelled"
      assert html =~ "Cancelled"
    end

    test "denied without shop.manage_settings", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope(permissions: ["shop", "shop.manage_catalog"]))
      {:ok, view, _html} = live(conn, "/en/admin/shop/translations")

      html = render_click(view, "request_stop", %{})

      assert html =~ "You don&#39;t have permission to do that"
    end
  end

  # ============================================================
  # Live PubSub updates (design §4.5's "живой статус")
  # ============================================================

  describe "PubSub live status" do
    setup %{conn: conn} do
      ready!()
      {:ok, conn: put_test_scope(conn, fake_scope())}
    end

    test "an :ai_translation broadcast triggers a reload that reflects the new state", %{
      conn: conn
    } do
      product = create_product()
      {:ok, view, html} = live(conn, "/en/admin/shop/translations")

      assert html =~ "Missing"

      # Simulate what `PhoenixKitAI.TranslateWorker` does on success: write
      # the translation directly (bypassing the real AI call), THEN
      # broadcast the same event it would.
      {:ok, _translated} =
        AITranslatable.put_translation(product, "de", %{"title" => "Holzvase"},
          source_fields: %{"title" => "Wooden Vase"}
        )

      PhoenixKitAI.Translations.broadcast(:translation_completed, %{
        resource_type: "shop_product",
        resource_uuid: product.uuid,
        source_lang: "en",
        target_lang: "de",
        fields: %{"title" => "Holzvase"}
      })

      # Synchronization barrier: block until the LiveView process has
      # processed every message already in its mailbox (per AGENTS.md —
      # never Process.sleep to wait for another process).
      _ = :sys.get_state(view.pid)

      assert render(view) =~ "Fresh"
    end
  end

  # ============================================================
  # Operational settings panel (design §4.6's keys, edited here per §4.5)
  # ============================================================

  describe "operational sweep panel" do
    setup %{conn: conn} do
      ready!()
      {:ok, conn: put_test_scope(conn, fake_scope())}
    end

    test "saves every operational key, logs it, and reschedules the tick", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/translations")

      # Mount's `ensure_scheduled/0` left a tick at the 60-minute default.
      before = SweepWorker.status().next_tick_at
      assert DateTime.diff(before, DateTime.utc_now()) > 50 * 60

      html =
        view
        |> element("#sweep-settings-form")
        |> render_submit(%{
          "sweep_enabled" => "true",
          "interval_minutes" => "15",
          "batch_size" => "4",
          "max_in_flight" => "9",
          "languages" => ["de"],
          "statuses" => ["active", "draft"]
        })

      assert html =~ "Sweep settings updated"

      assert SweepSettings.sweep_enabled?()
      assert SweepSettings.interval_minutes() == 15
      assert SweepSettings.batch_size() == 4
      assert SweepSettings.max_in_flight() == 9
      assert SweepSettings.languages() == ["de"]
      assert Enum.sort(SweepSettings.statuses()) == ["active", "draft"]

      # Design §4.3/§7: a shortened interval must move the ALREADY
      # scheduled tick, not wait out the stale one.
      after_save = SweepWorker.status().next_tick_at
      assert DateTime.diff(after_save, DateTime.utc_now()) <= 15 * 60

      assert_activity_logged("shop.translation_sweep_settings_changed",
        metadata_has: %{"interval_minutes" => 15, "sweep_enabled" => true}
      )
    end

    test "the primary language is never accepted as a sweep target", %{conn: conn} do
      # The checkbox list never renders "en" (design §4.6: targets are
      # "все включённые, кроме основного"); a stale or hand-crafted submit
      # must not be able to smuggle it in either, or the sweep would queue
      # en → en translations.
      {:ok, view, _html} = live(conn, "/en/admin/shop/translations")

      view
      |> element("#sweep-settings-form")
      |> render_submit(%{
        "interval_minutes" => "60",
        "batch_size" => "3",
        "max_in_flight" => "6",
        "languages" => ["en", "de"],
        "statuses" => ["active"]
      })

      assert SweepSettings.languages() == ["de"]
    end

    test "denied without shop.manage_settings", %{conn: conn} do
      conn = put_test_scope(conn, fake_scope(permissions: ["shop", "shop.manage_catalog"]))
      {:ok, view, _html} = live(conn, "/en/admin/shop/translations")

      html =
        view
        |> element("#sweep-settings-form")
        |> render_submit(%{
          "interval_minutes" => "5",
          "batch_size" => "3",
          "max_in_flight" => "6"
        })

      assert html =~ "You don&#39;t have permission to do that"
      assert SweepSettings.interval_minutes() == 60
    end
  end

  # ============================================================
  # "Запустить сверку" — the tick body, called directly (design §4.5)
  # ============================================================

  describe "run sweep now" do
    setup %{conn: conn} do
      ready!()
      {:ok, conn: put_test_scope(conn, fake_scope())}
    end

    test "reports the tick's own refusal reason when the sweep is switched off", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/translations")

      html = render_click(view, "run_sweep_now", %{})

      assert html =~ "automatic sweeping is turned off"
    end

    test "runs the tick body directly and queues the work it finds", %{conn: conn} do
      Settings.update_boolean_setting_with_module("shop_translation_sweep_enabled", true, "shop")
      product = create_product()

      {:ok, view, _html} = live(conn, "/en/admin/shop/translations")
      html = render_click(view, "run_sweep_now", %{})

      assert html =~ "Sweep ran"
      assert jobs_for(product.uuid) != []
    end

    test "a tick that recorded enqueue errors shows the count, not just the queued total", %{
      conn: conn
    } do
      # Review fix on the sweep (task 5): a tick where every per-language
      # enqueue_all_missing/2 call failed used to record {enqueued: 0,
      # errors: 0} — byte-identical to "nothing needed doing" — so an
      # operator staring at this page had no way to tell a silently
      # failing sweep from a healthy, idle one. Written directly rather
      # than provoked through a real failing tick: the persisted shape is
      # the worker's own contract (`finish/2`), and this pins that the
      # page actually reads the `"errors"` key it writes.
      Settings.update_json_setting_with_module(
        "shop_translation_sweep_last_run",
        %{
          "reason" => "ok",
          "candidates" => 2,
          "enqueued" => 0,
          "errors" => 2,
          "in_flight" => 0,
          "at" => DateTime.to_iso8601(DateTime.utc_now())
        },
        "shop_translations"
      )

      {:ok, _view, html} = live(conn, "/en/admin/shop/translations")

      assert html =~ "0 jobs queued"
      assert html =~ "2 enqueue errors"
    end

    test "denied without shop.manage_settings", %{conn: conn} do
      Settings.update_boolean_setting_with_module("shop_translation_sweep_enabled", true, "shop")
      product = create_product()
      conn = put_test_scope(conn, fake_scope(permissions: ["shop", "shop.manage_catalog"]))

      {:ok, view, _html} = live(conn, "/en/admin/shop/translations")
      html = render_click(view, "run_sweep_now", %{})

      assert html =~ "You don&#39;t have permission to do that"
      assert jobs_for(product.uuid) == []
    end
  end

  # ============================================================
  # Diagnostics panel (design §4.5)
  # ============================================================

  describe "diagnostics panel" do
    setup %{conn: conn} do
      ready!()
      {:ok, conn: put_test_scope(conn, fake_scope())}
    end

    test "shows the prompt as sent, not only the raw response", %{conn: conn} do
      product = create_product()

      {:ok, endpoint} =
        PhoenixKitAI.create_endpoint(%{
          name: "Diag Endpoint #{System.unique_integer([:positive])}",
          provider: "test",
          model: "test-chat-model",
          api_key: "unused-test-key"
        })

      {:ok, _request} =
        PhoenixKitAI.create_request(%{
          endpoint_uuid: endpoint.uuid,
          endpoint_name: endpoint.name,
          model: "test-chat-model",
          request_type: "chat",
          status: "success",
          metadata: %{
            "attribution" => %{
              "resource_type" => "shop_product",
              "resource_uuid" => product.uuid
            },
            "response" => "---TITLE---\nHolzvase",
            "messages" => [
              %{"role" => "system", "content" => "SENTINEL-PROMPT-TEXT for Wooden Vase"}
            ]
          }
        })

      {:ok, _view, html} = live(conn, "/en/admin/shop/translations")

      # Design §2 diagnosed this whole initiative by reading the RENDERED
      # prompt off these rows — the panel is half-useless without it.
      assert html =~ "Prompt as sent"
      assert html =~ "SENTINEL-PROMPT-TEXT for Wooden Vase"
      assert html =~ "Raw model response"
    end
  end

  # ============================================================
  # Categories share the same table (design §4.2's own resource type)
  # ============================================================

  describe "category resources" do
    setup %{conn: conn} do
      ready!()
      {:ok, conn: put_test_scope(conn, fake_scope())}
    end

    test "translate enqueues a category job via CategoryAITranslatable", %{conn: conn} do
      category = create_category()
      {:ok, view, _html} = live(conn, "/en/admin/shop/translations?type=category")

      render_click(view, "request_translate:all:all", %{"uuids" => [category.uuid]})
      confirm!(view)

      jobs = jobs_for(category.uuid)
      assert length(jobs) == 2
      assert Enum.all?(jobs, &(&1.args["resource_type"] == "shop_category"))
    end
  end
end
