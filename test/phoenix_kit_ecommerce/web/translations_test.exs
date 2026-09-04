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

      # The call count and the minute count are INDEPENDENT counts: 2
      # calls at 45s spread over 10 parallel jobs still rounds up to a
      # single minute, and so does everything from 2 to 13 calls. A
      # single `ngettext/4` governed by the CALL count picks one plural
      # form for the whole sentence and renders "about 1 minutes." —
      # here in en, and identically in de/fr/et. Two counts, two calls.
      assert html =~ "≈2 model calls, about 1 minute."
      refute html =~ "1 minutes"

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

    test "the estimate counts what will actually be queued, not only the filtered field's work",
         %{conn: conn} do
      # Design §4.4: the field axis never narrows a translate JOB ("на
      # состав задания он не влияет") — it only narrows what the write
      # step touches. So the confirmation's "≈N model calls" has to count
      # languages exactly as `candidate_langs/5` does, over EVERY field.
      # Here :title is already :fresh for "de" while :description is still
      # :missing, so a `field=title` scope must still own up to the one
      # call it is about to buy — an estimate that says nothing and then
      # queues a real model call is a confirmation that lied about money.
      product = create_product()

      {:ok, translated} =
        AITranslatable.put_translation(product, "de", %{"title" => "Holzvase"},
          source_fields: %{"title" => "Wooden Vase"}
        )

      {:ok, view, _html} = live(conn, "/en/admin/shop/translations")

      html = render_click(view, "request_translate:de:title", %{"uuids" => [translated.uuid]})

      assert html =~ "1 model call"
      # ...and the scope line must not claim the job is limited to :title.
      assert html =~ "all fields"

      confirm!(view)
      assert length(jobs_for(translated.uuid)) == 1
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

    test "an insert that fails for every language says so instead of \"0 jobs queued\"", %{
      conn: conn
    } do
      # Fix F's third bullet: `retranslate_one/2` folds through the SAME
      # `enqueue_reduce/8` `translate_one/2` (`bulk_translate/3`) uses —
      # this pins that a failed enqueue is surfaced through THIS entry
      # point too, rather than trusting the shared code by inspection
      # alone. Provoked via the AI section's endpoint override left
      # pointing at something that isn't a uuid: `enqueue_all_missing/2`
      # validates `endpoint_uuid` BEFORE looping languages, so this hits
      # `enqueue_reduce/8`'s `{:error, reason}` clause (one error for the
      # whole call) rather than its `{:ok, %{errors: [...]}}` per-language
      # list — commit 12b6f2e's own diff was to the latter, which needs a
      # language-level failure (not a base-params one) to reach at all,
      # and `TranslationSweepSettings.languages/0` already strips blank
      # codes before any language list reaches here, so that branch has
      # no live trigger through the public UI in either flow — the sweep
      # tick's own "enqueue errors" tests (`run sweep now` describe) hit
      # the identical `{:error, reason}` clause for the same reason.
      # `reset_reference/3` (called first, retranslate's distinguishing
      # step) still succeeds.
      product = create_product()

      {:ok, translated} =
        AITranslatable.put_translation(product, "de", %{"title" => "Holzvase"},
          source_fields: %{"title" => "Wooden Vase"}
        )

      {:ok, _} = Settings.update_setting_with_module("ai_translation_endpoint_uuid", "nope", "ai")

      {:ok, view, _html} = live(conn, "/en/admin/shop/translations")
      render_click(view, "request_retranslate:de:title", %{"uuids" => [translated.uuid]})
      html = confirm!(view)

      assert html =~ "0 jobs queued"
      assert html =~ "1 failed"
      assert jobs_for(translated.uuid) == []

      # And the fingerprint reset (this verb's whole point) still landed
      # even though the enqueue that was meant to follow it failed.
      reloaded = Shop.get_product!(translated.uuid)
      assert TranslationFingerprint.get(reloaded.metadata, "de", "title") == nil
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
  # Catalogue-wide stamp / reset (Fix D) — apply to EVERY resource the
  # current filter matches, not just the page `BulkSelectScope` can see.
  # `@per_page` is 25, so every test here seeds 30 matching products
  # specifically to put resources on a second page.
  # ============================================================

  describe "catalogue-wide stamp / reset" do
    setup %{conn: conn} do
      ready!()
      {:ok, conn: put_test_scope(conn, fake_scope())}
    end

    # Titles sort so product 30 lands on page 2 (rows are sorted by
    # title, page size 25) — this is the one whose fate proves whether
    # the action really reached past the first page.
    defp seed_primed_products(count) do
      for n <- 1..count do
        product = create_product(%{title: %{"en" => "Sortable Product #{pad(n)}"}})

        {:ok, primed} =
          product
          |> Ecto.Changeset.change(%{title: Map.put(product.title, "de", "Vorhandene #{pad(n)}")})
          |> repo().update()

        primed
      end
    end

    defp pad(n), do: String.pad_leading(Integer.to_string(n), 2, "0")

    # Real (non-empty, model-produced-looking) translations, one per
    # product with a unique target title — `Category.changeset/2`'s /
    # the product path's slug generation would collide two products on
    # an identical translated title otherwise.
    defp translate_all!(products) do
      products
      |> Enum.with_index(1)
      |> Enum.each(fn {product, n} ->
        {:ok, _} =
          AITranslatable.put_translation(product, "de", %{"title" => "Vorhandene #{pad(n)}"},
            source_fields: %{"title" => "Sortable Product #{pad(n)}"}
          )
      end)
    end

    test "request_stamp_all states the true catalogue-wide count, not the page size", %{
      conn: conn
    } do
      seed_primed_products(30)
      {:ok, view, _html} = live(conn, "/en/admin/shop/translations")

      html = render_click(view, "request_stamp_all", %{})

      assert html =~ "Stamp every matching resource as reference?"
      assert html =~ "30 resources matching the filters above"
      refute html =~ "25 resources matching the filters above"
    end

    test "confirm stamps every matching resource, including ones past the first page", %{
      conn: conn
    } do
      products = seed_primed_products(30)
      last = List.last(products)

      assert TranslationFingerprint.get(last.metadata, "de", "title") == nil

      {:ok, view, _html} = live(conn, "/en/admin/shop/translations")

      render_click(view, "request_stamp_all", %{})
      html = confirm!(view)

      assert html =~ "Stamped 30 resources"

      reloaded_last = Shop.get_product!(last.uuid)
      assert TranslationFingerprint.get(reloaded_last.metadata, "de", "title") != nil
      assert reloaded_last.title["de"] == "Vorhandene 30"

      # Every one of the 30 got stamped, not merely the 25 a page could show.
      assert products
             |> Enum.map(&Shop.get_product!(&1.uuid))
             |> Enum.all?(&(TranslationFingerprint.get(&1.metadata, "de", "title") != nil))

      # No model call anywhere in this — stamping is metadata-only.
      assert translate_jobs() == []
    end

    test "request_reset_all states the true catalogue-wide count, not the page size", %{
      conn: conn
    } do
      products = seed_primed_products(30)
      translate_all!(products)

      {:ok, view, _html} = live(conn, "/en/admin/shop/translations")

      html = render_click(view, "request_reset_all", %{})

      assert html =~ "Reset the reference for every matching resource?"
      assert html =~ "30 resources matching the filters above"
      refute html =~ "25 resources matching the filters above"
    end

    test "confirm resets the reference on every matching resource, including ones past the first page",
         %{conn: conn} do
      products = seed_primed_products(30)
      translate_all!(products)

      last = List.last(products)
      reloaded_last_before = Shop.get_product!(last.uuid)
      assert TranslationFingerprint.get(reloaded_last_before.metadata, "de", "title") != nil

      {:ok, view, _html} = live(conn, "/en/admin/shop/translations")

      render_click(view, "request_reset_all", %{})
      html = confirm!(view)

      assert html =~ "Reset the reference for 30 resources"

      reloaded_last = Shop.get_product!(last.uuid)
      assert TranslationFingerprint.get(reloaded_last.metadata, "de", "title") == nil
      # The translation itself is untouched — only the reference is cleared.
      assert reloaded_last.title["de"] == "Vorhandene 30"

      # Every one of the 30 was reset, not merely the 25 a page could show.
      assert products
             |> Enum.map(&Shop.get_product!(&1.uuid))
             |> Enum.all?(&(TranslationFingerprint.get(&1.metadata, "de", "title") == nil))

      # No model call anywhere in this — reset is metadata-only.
      assert translate_jobs() == []
    end

    test "an empty match never opens the confirm modal", %{conn: conn} do
      {:ok, view, html} = live(conn, "/en/admin/shop/translations")

      refute html =~ "Stamp every matching resource as reference?"

      html = render_click(view, "request_stamp_all", %{})

      refute html =~ "Stamp every matching resource as reference?"
    end

    test "denied without shop.manage_settings", %{conn: conn} do
      products = seed_primed_products(2)
      conn = put_test_scope(conn, fake_scope(permissions: ["shop", "shop.manage_catalog"]))
      {:ok, view, _html} = live(conn, "/en/admin/shop/translations")

      html = render_click(view, "request_stamp_all", %{})

      assert html =~ "You don&#39;t have permission to do that"

      assert products
             |> Enum.map(&Shop.get_product!(&1.uuid))
             |> Enum.all?(&(TranslationFingerprint.get(&1.metadata, "de", "title") == nil))
    end

    # "Across every page" is only half of what this verb promises — the
    # other half is "matching the current filter". Without the three
    # tests below, an `open_pending_all/2` that ignored every filter and
    # stamped the WHOLE catalogue would still pass this file: every test
    # above mounts with no filter on, so filtered and unfiltered are the
    # same set there. That is the more dangerous of the two failure
    # modes — a page-scoped bug under-reaches, an unfiltered one silently
    # freezes resources the operator deliberately excluded.

    test "the catalogue-wide stamp reaches only what the category filter matches", %{conn: conn} do
      kept = create_category(%{name: %{"en" => "Kept"}})
      other = create_category(%{name: %{"en" => "Other"}})

      inside =
        create_product(%{
          title: %{"en" => "Inside", "de" => "Drinnen"},
          category_uuid: kept.uuid
        })

      outside =
        create_product(%{
          title: %{"en" => "Outside", "de" => "Draussen"},
          category_uuid: other.uuid
        })

      {:ok, view, _html} = live(conn, "/en/admin/shop/translations?category=#{kept.uuid}")

      html = render_click(view, "request_stamp_all", %{})
      assert html =~ "for 1 resource matching the filters above"

      confirm!(view)

      assert TranslationFingerprint.get(Shop.get_product!(inside.uuid).metadata, "de", "title") !=
               nil

      assert TranslationFingerprint.get(Shop.get_product!(outside.uuid).metadata, "de", "title") ==
               nil
    end

    test "the catalogue-wide stamp reaches only what the state filter matches", %{conn: conn} do
      # Design §4.1's rollout is exactly this filter: `state=unknown`,
      # then stamp. A translation with no reference reads `:unknown`; a
      # resource that was never translated reads `:missing` and has to
      # stay out of the write.
      unknown = create_product(%{title: %{"en" => "Has A Translation", "de" => "Hat Eine"}})
      missing = create_product(%{title: %{"en" => "Never Translated"}})

      {:ok, view, _html} = live(conn, "/en/admin/shop/translations?state=unknown")

      html = render_click(view, "request_stamp_all", %{})
      assert html =~ "for 1 resource matching the filters above"

      confirm!(view)

      assert TranslationFingerprint.get(Shop.get_product!(unknown.uuid).metadata, "de", "title") !=
               nil

      assert TranslationFingerprint.get(Shop.get_product!(missing.uuid).metadata, "de", "title") ==
               nil
    end

    test "the catalogue-wide stamp writes only the filtered language and field", %{conn: conn} do
      product =
        create_product(%{
          title: %{"en" => "Wooden Vase", "de" => "Holzvase", "fr" => "Vase en Bois"},
          description: %{"en" => "A nice vase", "de" => "Eine Vase", "fr" => "Un vase"}
        })

      {:ok, view, _html} = live(conn, "/en/admin/shop/translations?lang=de&field=title")

      html = render_click(view, "request_stamp_all", %{})
      # The modal must name the narrowed scope, not "de, fr · all fields".
      assert html =~ "Scope: de · Title"

      confirm!(view)

      metadata = Shop.get_product!(product.uuid).metadata

      assert TranslationFingerprint.get(metadata, "de", "title") != nil
      assert TranslationFingerprint.get(metadata, "fr", "title") == nil
      assert TranslationFingerprint.get(metadata, "de", "description") == nil
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

      # The status checkboxes submit the RAW status, but what they render
      # has to be a translatable label: the bare `draft`/`active`/
      # `archived` value used to reach the DOM with no gettext call at
      # the render site at all, so no locale could translate it.
      assert html =~ ~s(value="draft")
      assert html =~ ">Draft<"
      assert html =~ ">Active<"
      assert html =~ ">Archived<"

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

    # -- Fix C: a stalled sweep must not report itself healthy — this half
    # stops the bad config from ever reaching storage in the first place.
    # `TranslationSweepWorker.structurally_stalled?/3` can only ever
    # report a deadlock after the fact; these three settings guarantee one
    # (`take_within_budget/3` HALTS, not skips, on the first candidate
    # whose language count exceeds the remaining budget).

    test "rejects a batch of zero — nothing is saved", %{conn: conn} do
      before_batch = SweepSettings.batch_size()
      {:ok, view, _html} = live(conn, "/en/admin/shop/translations")

      html =
        view
        |> element("#sweep-settings-form")
        |> render_submit(%{
          "interval_minutes" => "60",
          "batch_size" => "0",
          "max_in_flight" => "6",
          "languages" => ["de"],
          "statuses" => ["active"]
        })

      assert html =~ "Batch size must be at least 1."
      assert SweepSettings.batch_size() == before_batch

      refute_activity_logged("shop.translation_sweep_settings_changed",
        metadata_has: %{"batch_size" => 0}
      )
    end

    test "rejects a ceiling of zero — nothing is saved", %{conn: conn} do
      before_max_in_flight = SweepSettings.max_in_flight()
      {:ok, view, _html} = live(conn, "/en/admin/shop/translations")

      html =
        view
        |> element("#sweep-settings-form")
        |> render_submit(%{
          "interval_minutes" => "60",
          "batch_size" => "3",
          "max_in_flight" => "0",
          "languages" => ["de"],
          "statuses" => ["active"]
        })

      assert html =~ "Max in-flight jobs must be at least 1."
      assert SweepSettings.max_in_flight() == before_max_in_flight
    end

    test "rejects a ceiling below the number of target languages just selected — and does not clamp either value",
         %{
           conn: conn
         } do
      {:ok, view, _html} = live(conn, "/en/admin/shop/translations")

      # A known-good baseline, distinct from both the default and the
      # rejected attempt below, so a partial/clamped save of either field
      # would show up as a changed read afterwards.
      view
      |> element("#sweep-settings-form")
      |> render_submit(%{
        "interval_minutes" => "60",
        "batch_size" => "3",
        "max_in_flight" => "6",
        "languages" => ["de"],
        "statuses" => ["active"]
      })

      assert SweepSettings.languages() == ["de"]

      html =
        view
        |> element("#sweep-settings-form")
        |> render_submit(%{
          "interval_minutes" => "60",
          "batch_size" => "3",
          "max_in_flight" => "1",
          "languages" => ["de", "fr"],
          "statuses" => ["active"]
        })

      assert html =~ "Max in-flight jobs must be at least 2"

      # Neither half of the rejected save persisted — accepting the
      # language list while rejecting the ceiling (or vice versa) would
      # be just as capable of deadlocking the sweep as saving "1" outright.
      assert SweepSettings.max_in_flight() == 6
      assert SweepSettings.languages() == ["de"]
    end

    test "a rejected save does not reschedule the tick", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/translations")
      before = SweepWorker.status().next_tick_at

      view
      |> element("#sweep-settings-form")
      |> render_submit(%{
        "interval_minutes" => "5",
        "batch_size" => "0",
        "max_in_flight" => "6",
        "languages" => ["de"],
        "statuses" => ["active"]
      })

      # A successful save with "interval_minutes" => "5" would have moved
      # this — see the passing save test above. The rejected save must
      # leave the already-scheduled tick exactly where it was.
      assert SweepWorker.status().next_tick_at == before
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

    test "runs even while automatic sweeping is off — the manual path bypasses that gate", %{
      conn: conn
    } do
      # Owner decision (Fix B), overriding design §4.5 as written:
      # `shop_translation_sweep_enabled` gates the SCHEDULED tick only.
      # `ready!/0` leaves it at its default (off) — the documented
      # manual-only mode this button exists for — so this pins that the
      # button that mode's own badge points at ("Automatic sweep: off
      # (manual only)") actually performs the run rather than refusing.
      refute SweepSettings.sweep_enabled?()
      product = create_product()

      {:ok, view, _html} = live(conn, "/en/admin/shop/translations")
      html = render_click(view, "run_sweep_now", %{})

      assert html =~ "Sweep ran"
      assert jobs_for(product.uuid) != []
    end

    test "still surfaces a refusal the manual path does NOT bypass — the ceiling", %{conn: conn} do
      # The other half of Fix B, and the coverage the bypass test above
      # replaced: only `shop_translation_sweep_enabled` is bypassed, so a
      # manual run that stops for any other reason must still tell the
      # operator WHY rather than silently reporting success. Provoked
      # through a door the page itself opens (the "Max in-flight jobs"
      # field) with the sweep left off, so it pins the flash on the
      # manual path specifically.
      refute SweepSettings.sweep_enabled?()
      product = create_product()

      # Two in-flight jobs, one per target language (`ready!/0` leaves
      # de/fr configured) — the ceiling below matches that count exactly,
      # so this is a genuine, self-clearing "busy right now", never Fix
      # C's structural stall (which would fire regardless of in_flight
      # and has its own coverage in the "operational sweep panel" and
      # `TranslationSweepWorkerTest` describe blocks).
      for lang <- ["de", "fr"] do
        {:ok, _job} =
          %{
            "resource_type" => AITranslatable.resource_type(),
            "resource_uuid" => product.uuid,
            "endpoint_uuid" => Ecto.UUID.generate(),
            "prompt_uuid" => Ecto.UUID.generate(),
            "source_lang" => "en",
            "target_lang" => lang,
            "actor_uuid" => nil,
            "resource_scope" => nil
          }
          |> PhoenixKitAI.TranslateWorker.new()
          |> Oban.insert()
      end

      {:ok, _} =
        Settings.update_setting_with_module("shop_translation_max_in_flight", "2", "shop")

      {:ok, view, _html} = live(conn, "/en/admin/shop/translations")
      html = render_click(view, "run_sweep_now", %{})

      assert html =~ "2 jobs already in flight (at the ceiling)"
      refute html =~ "Sweep ran"
    end

    test "a structurally stalled config is named on the page, not reported as a healthy tick", %{
      conn: conn
    } do
      # Fix C's other half: the panel refuses to SAVE a batch of zero, so
      # this is written straight to Settings — the hand-edited row (or
      # pre-fix install) the tick's honesty check exists for. Pins both
      # operator-visible surfaces of the `:sweep_stalled` reason: the
      # flash from the manual button and the persisted "Last tick" line
      # that a SCHEDULED tick's stall would otherwise only ever reach.
      {:ok, _} = Settings.update_setting_with_module("shop_translation_batch", "0", "shop")
      create_product()

      {:ok, view, _html} = live(conn, "/en/admin/shop/translations")
      html = render_click(view, "run_sweep_now", %{})

      assert html =~ "Sweep queued nothing"
      assert html =~ "batch 0 / ceiling 6"
      refute html =~ "Sweep ran"
      assert SweepWorker.last_run()["reason"] == "sweep_stalled"

      assert render(view) =~ "Last tick: stalled — batch 0 / ceiling 6"
    end

    test "runs the tick body directly and queues the work it finds", %{conn: conn} do
      Settings.update_boolean_setting_with_module("shop_translation_sweep_enabled", true, "shop")
      product = create_product()

      {:ok, view, _html} = live(conn, "/en/admin/shop/translations")
      html = render_click(view, "run_sweep_now", %{})

      assert html =~ "Sweep ran"
      assert jobs_for(product.uuid) != []
    end

    test "a tick whose enqueues all failed says so in the flash, not just \"0 queued\"", %{
      conn: conn
    } do
      # The immediate-flash twin of the persisted-summary test below, and
      # provoked through a door an operator can actually open rather than
      # by writing the outcome by hand: the AI section's explicit endpoint
      # override left pointing at something that isn't a uuid.
      # `default_endpoint_uuid/0` hands that value back verbatim, so both
      # this page and the tick still consider AI available, while
      # `enqueue_all_missing/2` refuses every language with
      # `{:invalid_uuids, [:endpoint_uuid]}`. The tick then records
      # `enqueued: 0, errors: 1` — which, unsurfaced, reads exactly like
      # "nothing needed doing".
      Settings.update_boolean_setting_with_module("shop_translation_sweep_enabled", true, "shop")
      {:ok, _} = Settings.update_setting_with_module("ai_translation_endpoint_uuid", "nope", "ai")
      product = create_product()

      {:ok, view, _html} = live(conn, "/en/admin/shop/translations")
      html = render_click(view, "run_sweep_now", %{})

      # The FLASH specifically — its wording ("queued." + count) is
      # distinct from the persisted "Last tick" line rendered in
      # `#sweep-last-run`, so this can't pass on that line's back.
      assert html =~ "Sweep ran"
      assert html =~ "0 jobs queued. 1 enqueue error."
      assert jobs_for(product.uuid) == []
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

    test "the persisted 'Last tick' line translates a non-:ok reason instead of showing the raw atom",
         %{conn: conn} do
      # Fix F: `last_run_summary/1` special-cased only `"ok"` and
      # `"sweep_stalled"` — every OTHER stored reason
      # (`:translations_disabled`, `:sweep_disabled`, `:ai_unavailable`,
      # `:ceiling_reached`, `:no_target_languages`) fell through to a
      # bare `reason` return, so the "Last tick" span rendered the raw
      # persisted atom string verbatim ("Last tick: ceiling_reached")
      # while `sweep_result_message/2` — reachable from the very same
      # page, via the manual-run flash — already had a full, translated
      # sentence for that exact reason. Provoked the same way the manual
      # flash's own "ceiling" test provokes it (two in-flight jobs, a
      # ceiling that matches), but asserting on the PERSISTED line
      # `#sweep-last-run` renders on a plain, un-clicked page load, not
      # the flash a click produces.
      product = create_product()

      for lang <- ["de", "fr"] do
        {:ok, _job} =
          %{
            "resource_type" => AITranslatable.resource_type(),
            "resource_uuid" => product.uuid,
            "endpoint_uuid" => Ecto.UUID.generate(),
            "prompt_uuid" => Ecto.UUID.generate(),
            "source_lang" => "en",
            "target_lang" => lang,
            "actor_uuid" => nil,
            "resource_scope" => nil
          }
          |> PhoenixKitAI.TranslateWorker.new()
          |> Oban.insert()
      end

      {:ok, _} =
        Settings.update_setting_with_module("shop_translation_max_in_flight", "2", "shop")

      {:ceiling_reached, _info} = SweepWorker.run_manual_tick()

      {:ok, _view, html} = live(conn, "/en/admin/shop/translations")

      assert SweepWorker.last_run()["reason"] == "ceiling_reached"
      assert html =~ "Last tick:"
      assert html =~ "2 jobs already in flight (at the ceiling)"
      refute html =~ "Last tick: ceiling_reached"
    end

    test "a reason the page has no wording for still shows itself, never \"Sweep finished\"", %{
      conn: conn
    } do
      # Review guard on Fix F: routing the fallback through
      # `sweep_result_message/2` also routes UNKNOWN reasons into that
      # function's catch-all, which reads "Sweep finished." — a tick that
      # stopped for a reason this page has no wording for did NOT finish,
      # and saying so is worse than the raw atom Fix F set out to
      # replace. Written straight to the persisted row (the same
      # hand-edited-settings door the `:sweep_stalled` test above uses),
      # because by construction no reason the CURRENT worker records can
      # reach this clause — the point is that a future one must not
      # silently become a lie.
      {:ok, _} =
        Settings.update_json_setting_with_module(
          "shop_translation_sweep_last_run",
          %{
            "reason" => "quota_exhausted",
            "at" => DateTime.to_iso8601(DateTime.utc_now())
          },
          "shop_translations"
        )

      {:ok, _view, html} = live(conn, "/en/admin/shop/translations")

      assert html =~ "Last tick: quota_exhausted"
      refute html =~ "Sweep finished."
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
