defmodule PhoenixKitEcommerce.AITranslatableTest do
  use PhoenixKitEcommerce.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Utils.Slug
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.AITranslatable
  alias PhoenixKitEcommerce.Product
  alias PhoenixKitEcommerce.TranslationFingerprint

  defp create_product(attrs \\ %{}) do
    base = %{
      title: %{"en" => "Wooden Vase"},
      description: %{"en" => "A nice vase"},
      seo_title: %{"en" => "Buy Wooden Vase"},
      price: Decimal.new("10.00"),
      status: "active"
    }

    {:ok, product} = Shop.create_product(Map.merge(base, attrs))
    product
  end

  test "registered as shop_product" do
    assert {"shop_product", AITranslatable} in PhoenixKitEcommerce.ai_translatables()
  end

  test "fetch/2 loads by uuid, errors on miss" do
    product = create_product()
    assert {:ok, %Product{}} = AITranslatable.fetch("shop_product", product.uuid)

    assert {:error, :resource_not_found} =
             AITranslatable.fetch("shop_product", Ecto.UUID.generate())
  end

  test "source_fields/2 maps schema fields to prompt vocabulary, skipping empties" do
    product = create_product()
    fields = AITranslatable.source_fields(product, "en")

    assert fields["title"] == "Wooden Vase"
    assert fields["description"] == "A nice vase"
    assert fields["seo_title"] == "Buy Wooden Vase"
    # body_html empty ⇒ no "body" key
    refute Map.has_key?(fields, "body")
  end

  test "put_translation/4 merges fields and generates a local slug once" do
    product = create_product()

    {:ok, updated} =
      AITranslatable.put_translation(
        product,
        "fr",
        %{"title" => "Vase en Bois", "description" => "Un joli vase", "seo_title" => "Acheter"},
        []
      )

    assert updated.title["fr"] == "Vase en Bois"
    assert updated.description["fr"] == "Un joli vase"
    assert updated.seo_title["fr"] == "Acheter"
    # slug generated locally from translated title
    assert updated.slug["fr"] == "vase-en-bois"
    # sibling language untouched
    assert updated.title["en"] == "Wooden Vase"

    # re-translation must NOT change the existing slug
    {:ok, again} =
      AITranslatable.put_translation(updated, "fr", %{"title" => "Vase Nouveau"}, [])

    assert again.title["fr"] == "Vase Nouveau"
    assert again.slug["fr"] == "vase-en-bois"
  end

  test "an AI-provided slug field is ignored entirely" do
    product = create_product()

    {:ok, updated} =
      AITranslatable.put_translation(
        product,
        "fr",
        %{"title" => "Vase", "slug" => "../../evil"},
        []
      )

    assert updated.slug["fr"] == "vase"
  end

  test "slug collides within the language get suffixed" do
    _other = create_product(%{title: %{"en" => "Other"}, slug: %{"fr" => "vase-en-bois"}})
    product = create_product()

    {:ok, updated} =
      AITranslatable.put_translation(product, "fr", %{"title" => "Vase en Bois"}, [])

    assert updated.slug["fr"] == "vase-en-bois-2"
  end

  test "concurrent translations of two languages both survive" do
    product = create_product()
    parent = self()

    tasks =
      for {lang, title} <- [{"fr", "Vase FR"}, {"de", "Vase DE"}] do
        Task.async(fn ->
          Sandbox.allow(repo(), parent, self())
          AITranslatable.put_translation(product, lang, %{"title" => title}, [])
        end)
      end

    Enum.each(tasks, &Task.await/1)

    fresh = repo().get(Product, product.uuid)
    assert fresh.title["fr"] == "Vase FR"
    assert fresh.title["de"] == "Vase DE"
  end

  test "concurrent translations of two languages both keep their fingerprints" do
    # `metadata` is ONE JSONB column shared by every language, exactly
    # like `title` above, so the FOR UPDATE merge has to protect the
    # fingerprints too — a sibling language's reference silently lost
    # here would send that pair back to :unknown and out of the sweep's
    # reach (design §4.1).
    product = create_product()
    parent = self()

    tasks =
      for {lang, title} <- [{"fr", "Vase FR"}, {"de", "Vase DE"}] do
        Task.async(fn ->
          Sandbox.allow(repo(), parent, self())

          AITranslatable.put_translation(product, lang, %{"title" => title},
            source_fields: %{"title" => "Wooden Vase"}
          )
        end)
      end

    Enum.each(tasks, &Task.await/1)

    fresh = repo().get(Product, product.uuid)
    expected = TranslationFingerprint.hash("Wooden Vase")

    assert TranslationFingerprint.get(fresh.metadata, "fr", "title") == expected
    assert TranslationFingerprint.get(fresh.metadata, "de", "title") == expected
  end

  test "accented Latin titles transliterate in the slug" do
    product = create_product()

    {:ok, fr} =
      AITranslatable.put_translation(product, "fr", %{"title" => "Étagère décorative"}, [])

    assert fr.slug["fr"] == "etagere-decorative"

    {:ok, de} = AITranslatable.put_translation(product, "de", %{"title" => "Größe Fußball"}, [])
    assert de.slug["de"] == "groesse-fussball"
  end

  test "Cyrillic titles transliterate to a readable slug" do
    product = create_product()

    {:ok, ru} = AITranslatable.put_translation(product, "ru", %{"title" => "Ваза Деревянная"}, [])
    assert ru.slug["ru"] == "vaza-derevyannaya"
  end

  test "an extremely long title produces a capped slug" do
    product = create_product()
    long = String.duplicate("vase ", 2000)

    {:ok, updated} = AITranslatable.put_translation(product, "fr", %{"title" => long}, [])

    assert String.length(updated.slug["fr"]) <= 80
  end

  # The literal content of prompt_attrs/0 before §5.1's rewrite — the
  # template §2 diagnoses, whose hardcoded {{title}} slot the model read
  # as an unbound placeholder and skipped translating. Reproduced exactly
  # (verified against the pre-rewrite source via sha256, see the design
  # doc §5.2) so its sha256 matches the one entry AITranslatable ships in
  # its known_previous_shas list — this is what lets a stand's existing,
  # unversioned row get adopted below instead of left as a permanent
  # :diverged row nobody's code ever recognizes.
  @literal_placeholder_template """
  You are translating fields of an e-commerce product from {{SourceLanguage}} to {{TargetLanguage}}.

  RULES:
  - Preserve formatting exactly (line breaks, spacing, HTML if present).
  - Do NOT translate text inside code blocks, inline code, or URLs.
  - Translate naturally and idiomatically — commercial tone, natural for a shop.
  - Keep any HTML tags and attributes unchanged; translate only human-visible text.
  - Keep brand names, materials and measurements as-is unless they have a standard translation.
  - Output ONLY the structured markers below — no commentary, no preface, no closing remarks.

  OUTPUT FORMAT — for each non-empty field in the SOURCE section below,
  emit ONE marker named after the field (uppercased), followed by the
  translation:

      ---TITLE---
      [translated title]

  Skip any field that is missing, blank, or still a literal placeholder
  (a value like `{{title}}` means the caller did not bind it) — do NOT
  emit a marker for it, and do NOT translate the placeholder text itself.

  === SOURCE ===

  Title: {{title}}

  Description: {{description}}

  Body: {{body}}

  Seo_title: {{seo_title}}

  Seo_description: {{seo_description}}
  """

  describe "ensure_prompt/0" do
    test "is idempotent (slug must match create_prompt's name-derived slug)" do
      case AITranslatable.ensure_prompt() do
        {:ok, uuid1, _status} ->
          assert {:ok, ^uuid1, _status2} = AITranslatable.ensure_prompt()

        {:error, :ai_not_installed} ->
          # AI plugin/schema not present in this test env — nothing to assert.
          :ok
      end
    end

    test "the shipped template is built on {{SourceFields}}, not a fixed slot per field" do
      case AITranslatable.ensure_prompt() do
        {:ok, uuid, _status} ->
          prompt = PhoenixKitAI.get_prompt(uuid)
          assert prompt.content =~ "{{SourceFields}}"
          # the defect from design §2: a hardcoded {{title}} slot the model
          # could mistake for an unbound placeholder
          refute prompt.content =~ "{{title}}"
          # the rule that misfired on it — removed, not tightened
          refute prompt.content =~ "literal placeholder"

        {:error, :ai_not_installed} ->
          :ok
      end
    end

    test "adopts a stand's existing row still on the pre-§5.1 literal-placeholder template" do
      case Code.ensure_loaded?(PhoenixKitAI) and
             function_exported?(PhoenixKitAI, :create_prompt, 1) do
        true ->
          name = "PhoenixKit Shop Product Translation"
          slug = Slug.slugify(name)

          # Simulate a stand whose row predates the metadata scheme
          # entirely: created directly, bypassing ensure_prompt/0, exactly
          # as the real row would have been before this design shipped.
          {:ok, bootstrap} =
            PhoenixKitAI.create_prompt(%{
              slug: slug,
              name: name,
              content: @literal_placeholder_template
            })

          assert bootstrap.metadata == %{}

          assert {:ok, uuid, :adopted} = AITranslatable.ensure_prompt()
          assert uuid == bootstrap.uuid

          prompt = PhoenixKitAI.get_prompt(uuid)
          assert prompt.content =~ "{{SourceFields}}"
          refute prompt.content == @literal_placeholder_template
          assert prompt.metadata["managed_by"] == "phoenix_kit_ecommerce"

        false ->
          :ok
      end
    end
  end

  test "blank translations are rejected" do
    product = create_product()

    assert {:error, :no_translated_fields} =
             AITranslatable.put_translation(product, "fr", %{"title" => "  "}, [])
  end

  # ── Fingerprints, write-narrowing, reset, candidates (design §4.1/§4.4) ──

  describe "put_translation/4 stamps a fingerprint alongside each field it writes" do
    test "first write of a field stamps hash(trim(source)) under metadata" do
      product = create_product()

      {:ok, updated} =
        AITranslatable.put_translation(
          product,
          "fr",
          %{"title" => "Vase en Bois"},
          source_fields: %{"title" => "Wooden Vase"}
        )

      assert updated.title["fr"] == "Vase en Bois"

      assert updated.metadata["_translation_fingerprints"]["fr"]["title"] ==
               TranslationFingerprint.hash("Wooden Vase")
    end

    test "the fingerprint is taken from the SOURCE FIELDS THE JOB PASSED, not the row's current value" do
      # design §4.1: source_fields/2 and put_translation/4 are ~45s apart in
      # production; a Shopify sync can land in between. The fingerprint must
      # reflect what was actually translated, never whatever the row
      # happens to say by persist time.
      product = create_product()
      # Simulate the source changing between read and persist by passing a
      # DIFFERENT source text than the product's own current `title["en"]`.
      stale_source = "Wooden Vase (as read at translation time)"

      {:ok, updated} =
        AITranslatable.put_translation(
          product,
          "fr",
          %{"title" => "Vase en Bois"},
          source_fields: %{"title" => stale_source}
        )

      assert updated.metadata["_translation_fingerprints"]["fr"]["title"] ==
               TranslationFingerprint.hash(stale_source)

      refute updated.metadata["_translation_fingerprints"]["fr"]["title"] ==
               TranslationFingerprint.hash(product.title["en"])
    end

    test "a call with no :source_fields opt at all still writes, but stamps no fingerprint" do
      product = create_product()

      {:ok, updated} =
        AITranslatable.put_translation(product, "fr", %{"title" => "Vase en Bois"}, [])

      assert updated.title["fr"] == "Vase en Bois"
      assert TranslationFingerprint.get(updated.metadata, "fr", "title") == nil
    end

    test "a call with no :source_fields ERASES the fingerprint the field already had" do
      # The engine pinned here (phoenix_kit_ai 0.19.2) does not yet pass
      # :source_fields — design §9.3 is the upstream half of this work.
      # A write it makes must not leave behind a fingerprint describing a
      # source that is no longer what the stored translation came from.
      product = create_product()

      {:ok, first} =
        AITranslatable.put_translation(product, "fr", %{"title" => "Vase en Bois"},
          source_fields: %{"title" => "Wooden Vase"}
        )

      assert TranslationFingerprint.get(first.metadata, "fr", "title") != nil

      {:ok, second} =
        AITranslatable.put_translation(first, "fr", %{"title" => "Vase Sans Source"}, [])

      assert second.title["fr"] == "Vase Sans Source"
      assert TranslationFingerprint.get(second.metadata, "fr", "title") == nil

      # ...which is design §4.1's :unknown, the state it names for
      # "переводы, записанные в обход отпечатков".
      assert TranslationFingerprint.field_state(
               second.title["en"],
               second.title["fr"],
               TranslationFingerprint.get(second.metadata, "fr", "title")
             ) == :unknown
    end

    test "a sourceless write ENDS the sweep for that pair instead of looping it forever" do
      # The convergence guard for the sourceless path, the twin of the
      # empty-source carve-out (design §4.1). Before: a :stale field
      # written without :source_fields kept its old, still-mismatching
      # fingerprint, so `candidates/3` returned the product on every
      # tick, each one paying for a ~45s model call that changed nothing.
      # Title-only, so `title` is the ONLY field that can make this
      # product a candidate — the other fields' `missing` would mask the
      # transition this test is about.
      product = create_product(%{description: %{}, seo_title: %{}})

      {:ok, first} =
        AITranslatable.put_translation(product, "fr", %{"title" => "Vase en Bois"},
          source_fields: %{"title" => "Wooden Vase"}
        )

      refute Enum.any?(AITranslatable.candidates("en", ["fr"]), &(&1.uuid == product.uuid))

      # The source moves on ⇒ :stale ⇒ the sweep picks it up.
      {:ok, moved_on} =
        first
        |> Ecto.Changeset.change(%{title: Map.put(first.title, "en", "Oak Vase")})
        |> repo().update()

      assert Enum.any?(AITranslatable.candidates("en", ["fr"]), &(&1.uuid == product.uuid))

      # The engine translates it and persists WITHOUT :source_fields.
      {:ok, written} =
        AITranslatable.put_translation(moved_on, "fr", %{"title" => "Vase en Chene"}, [])

      assert written.title["fr"] == "Vase en Chene"
      refute Enum.any?(AITranslatable.candidates("en", ["fr"]), &(&1.uuid == product.uuid))
    end
  end

  describe "write-narrowing (design §4.4's table)" do
    test "an unchanged source is skipped — the stored translation is left alone" do
      product = create_product()
      source = product.title["en"]

      {:ok, first} =
        AITranslatable.put_translation(product, "fr", %{"title" => "Vase en Bois"},
          source_fields: %{"title" => source}
        )

      # A second call with the SAME source but a DIFFERENT AI response
      # (simulating a routine re-run) must not clobber the stored
      # translation — this is the manual-edit protection design §4.4
      # exists for.
      {:ok, second} =
        AITranslatable.put_translation(first, "fr", %{"title" => "Vase Complètement Différent"},
          source_fields: %{"title" => source}
        )

      assert second.title["fr"] == "Vase en Bois"

      assert second.metadata["_translation_fingerprints"]["fr"]["title"] ==
               TranslationFingerprint.hash(source)
    end

    test "a changed source is written and the fingerprint moves with it" do
      product = create_product()

      {:ok, first} =
        AITranslatable.put_translation(product, "fr", %{"title" => "Vase en Bois"},
          source_fields: %{"title" => "Wooden Vase"}
        )

      {:ok, second} =
        AITranslatable.put_translation(first, "fr", %{"title" => "Vase en Bois (Nouveau)"},
          source_fields: %{"title" => "Wooden Vase, Deluxe"}
        )

      assert second.title["fr"] == "Vase en Bois (Nouveau)"

      assert second.metadata["_translation_fingerprints"]["fr"]["title"] ==
               TranslationFingerprint.hash("Wooden Vase, Deluxe")
    end

    test "a field with no fingerprint yet (:unknown) is written even though a translation exists" do
      product = create_product()

      # Simulate a translation stored WITHOUT going through put_translation/4
      # (e.g. an import, or a translation done before this design shipped) —
      # translated but fingerprint-less: exactly design §4.1's `:unknown`.
      {:ok, unknown_state} =
        product
        |> Ecto.Changeset.change(%{title: Map.put(product.title, "fr", "Vase (import)")})
        |> repo().update()

      {:ok, updated} =
        AITranslatable.put_translation(unknown_state, "fr", %{"title" => "Vase en Bois"},
          source_fields: %{"title" => "Wooden Vase"}
        )

      assert updated.title["fr"] == "Vase en Bois"

      assert TranslationFingerprint.get(updated.metadata, "fr", "title") ==
               TranslationFingerprint.hash("Wooden Vase")
    end

    test "fields are narrowed independently — one stale, one fresh, in the same call" do
      product = create_product()

      {:ok, first} =
        AITranslatable.put_translation(
          product,
          "fr",
          %{"title" => "Vase en Bois", "description" => "Un joli vase"},
          source_fields: %{"title" => "Wooden Vase", "description" => "A nice vase"}
        )

      # Second call: title's source is UNCHANGED (skip expected), description's
      # source CHANGED (write expected) — both fields present in the same
      # AI response.
      {:ok, second} =
        AITranslatable.put_translation(
          first,
          "fr",
          %{
            "title" => "Vase Different (should be ignored)",
            "description" => "Description mise à jour"
          },
          source_fields: %{"title" => "Wooden Vase", "description" => "A nice vase, updated"}
        )

      assert second.title["fr"] == "Vase en Bois"
      assert second.description["fr"] == "Description mise à jour"
    end

    test "all fields write-narrowed away ⇒ success without a write, no event, no activity log" do
      product = create_product()
      source = product.title["en"]

      {:ok, first} =
        AITranslatable.put_translation(product, "fr", %{"title" => "Vase en Bois"},
          source_fields: %{"title" => source}
        )

      # The first (real) write already logged one activity entry — the
      # assertion below is that the SECOND (fully skipped) call adds no
      # further entry, not that none exist at all.
      activity_count_before = length(list_activities())

      PhoenixKitEcommerce.Events.subscribe_products()

      {:ok, second} =
        AITranslatable.put_translation(first, "fr", %{"title" => "Ignored, unchanged source"},
          source_fields: %{"title" => source}
        )

      assert second.uuid == first.uuid
      assert second.title["fr"] == "Vase en Bois"
      assert second.updated_at == first.updated_at

      refute_receive {:product_updated, _}, 50

      assert length(list_activities()) == activity_count_before
    end

    test "a write DOES broadcast the update event and log the activity entry" do
      product = create_product()
      PhoenixKitEcommerce.Events.subscribe_products()

      {:ok, _updated} =
        AITranslatable.put_translation(product, "fr", %{"title" => "Vase en Bois"},
          source_fields: %{"title" => "Wooden Vase"},
          actor_uuid: nil
        )

      assert_receive {:product_updated, _}, 100

      assert_activity_logged("shop.product.updated",
        resource_uuid: product.uuid,
        metadata_has: %{"target_language" => "fr"}
      )
    end
  end

  describe "the slug corner: title write-narrowed away falls back to the STORED title (design §4.4)" do
    test "title skipped (fresh), a different field written, slug still generated from stored title" do
      product = create_product()
      title_source = product.title["en"]

      # Set up a product that already has a FRESH French title (fingerprint
      # matches) but — simulating the backfill (§4.1) or an import path
      # that never ran slug generation — no French slug yet.
      metadata =
        TranslationFingerprint.put_many(product.metadata, "fr", %{
          "title" => TranslationFingerprint.hash(title_source)
        })

      {:ok, primed} =
        product
        |> Ecto.Changeset.change(%{
          title: Map.put(product.title, "fr", "Vase en Bois"),
          metadata: metadata
        })
        |> repo().update()

      refute Map.has_key?(primed.slug || %{}, "fr")

      {:ok, updated} =
        AITranslatable.put_translation(
          primed,
          "fr",
          %{"title" => "Vase Ignoré", "description" => "Un joli vase"},
          source_fields: %{"title" => title_source, "description" => "A nice vase"}
        )

      # title write-narrowed away — untouched
      assert updated.title["fr"] == "Vase en Bois"
      # description written normally
      assert updated.description["fr"] == "Un joli vase"
      # slug generated from the STORED title, not the (ignored) AI response
      assert updated.slug["fr"] == "vase-en-bois"
    end

    test "title absent from the AI response entirely — same fallback applies" do
      product = create_product()

      {:ok, primed} =
        product
        |> Ecto.Changeset.change(%{title: Map.put(product.title, "fr", "Vase Préexistant")})
        |> repo().update()

      refute Map.has_key?(primed.slug || %{}, "fr")

      {:ok, updated} =
        AITranslatable.put_translation(primed, "fr", %{"description" => "Un joli vase"},
          source_fields: %{"description" => "A nice vase"}
        )

      assert updated.description["fr"] == "Un joli vase"
      assert updated.slug["fr"] == "vase-preexistant"
    end
  end

  describe "reset_reference/3 — \"перевести заново\" (design §4.4)" do
    test "erases the fingerprint for exactly the requested language/field pair" do
      product = create_product()

      {:ok, translated} =
        AITranslatable.put_translation(
          product,
          "fr",
          %{"title" => "Vase en Bois", "description" => "Un joli vase"},
          source_fields: %{"title" => "Wooden Vase", "description" => "A nice vase"}
        )

      assert TranslationFingerprint.get(translated.metadata, "fr", "title") != nil

      {:ok, reset} = AITranslatable.reset_reference(translated.uuid, ["fr"], [:title])

      # translated content is untouched
      assert reset.title["fr"] == "Vase en Bois"
      assert reset.description["fr"] == "Un joli vase"

      # only :title's fingerprint is gone
      assert TranslationFingerprint.get(reset.metadata, "fr", "title") == nil
      assert TranslationFingerprint.get(reset.metadata, "fr", "description") != nil
    end

    test "after a reset, a call with the SAME source writes again instead of skipping" do
      product = create_product()
      source = "Wooden Vase"

      {:ok, translated} =
        AITranslatable.put_translation(product, "fr", %{"title" => "Vase en Bois"},
          source_fields: %{"title" => source}
        )

      {:ok, _reset} = AITranslatable.reset_reference(translated.uuid, ["fr"], [:title])
      reset_product = repo().get(Product, product.uuid)

      {:ok, retranslated} =
        AITranslatable.put_translation(
          reset_product,
          "fr",
          %{"title" => "Vase en Bois (Amélioré)"},
          source_fields: %{"title" => source}
        )

      assert retranslated.title["fr"] == "Vase en Bois (Amélioré)"
    end

    test "defaults to every fingerprinted field when none are given" do
      product = create_product()

      {:ok, translated} =
        AITranslatable.put_translation(
          product,
          "fr",
          %{"title" => "Vase en Bois", "description" => "Un joli vase"},
          source_fields: %{"title" => "Wooden Vase", "description" => "A nice vase"}
        )

      {:ok, reset} = AITranslatable.reset_reference(translated.uuid, ["fr"])

      assert TranslationFingerprint.get(reset.metadata, "fr", "title") == nil
      assert TranslationFingerprint.get(reset.metadata, "fr", "description") == nil
    end

    test "errors on an unknown uuid" do
      assert {:error, :resource_not_found} =
               AITranslatable.reset_reference(Ecto.UUID.generate(), ["fr"], [:title])
    end
  end

  describe "stamp_reference/4 — \"проштамповать текущий источник как эталон\" (design §4.1, §4.5)" do
    test "an unfingerprinted (:unknown) translation moves to :fresh, no model call" do
      product = create_product()

      # Simulate a pre-existing translation with no fingerprint at all —
      # the 627-product bulk-adoption case design §4.1 describes.
      {:ok, primed} =
        product
        |> Ecto.Changeset.change(%{
          title: Map.put(product.title, "fr", "Vase Préexistant"),
          description: Map.put(product.description, "fr", "Description préexistante")
        })
        |> repo().update()

      assert TranslationFingerprint.get(primed.metadata, "fr", "title") == nil

      {:ok, stamped} = AITranslatable.stamp_reference(primed.uuid, "en", ["fr"])

      # Translated content is untouched.
      assert stamped.title["fr"] == "Vase Préexistant"
      assert stamped.description["fr"] == "Description préexistante"

      # Fingerprint now matches the CURRENT source exactly — the field
      # reads :fresh by construction.
      assert TranslationFingerprint.get(stamped.metadata, "fr", "title") ==
               TranslationFingerprint.hash("Wooden Vase")

      assert TranslationFingerprint.field_state(
               "Wooden Vase",
               stamped.title["fr"],
               TranslationFingerprint.get(stamped.metadata, "fr", "title")
             ) == :fresh
    end

    test "a field with no stored translation is left alone (still :missing)" do
      product = create_product()

      # seo_description has an "en" source in create_product/1's base? No —
      # it's absent entirely, so this field has NO state at all, which is
      # exactly the case this test wants: nothing to certify.
      {:ok, stamped} =
        AITranslatable.stamp_reference(product.uuid, "en", ["fr"], [:seo_description])

      assert TranslationFingerprint.get(stamped.metadata, "fr", "seo_description") == nil
    end

    test "does not overwrite an ALREADY-stamped field's translation or fingerprint" do
      product = create_product()

      {:ok, translated} =
        AITranslatable.put_translation(product, "fr", %{"title" => "Vase en Bois"},
          source_fields: %{"title" => "Wooden Vase"}
        )

      fp_before = TranslationFingerprint.get(translated.metadata, "fr", "title")

      {:ok, restamped} = AITranslatable.stamp_reference(translated.uuid, "en", ["fr"], [:title])

      assert restamped.title["fr"] == "Vase en Bois"
      assert TranslationFingerprint.get(restamped.metadata, "fr", "title") == fp_before
    end

    test "narrows to exactly the given fields and languages, leaving others untouched" do
      product = create_product()

      {:ok, primed} =
        product
        |> Ecto.Changeset.change(%{
          title: Map.merge(product.title, %{"fr" => "Vase FR", "de" => "Vase DE"})
        })
        |> repo().update()

      {:ok, stamped} = AITranslatable.stamp_reference(primed.uuid, "en", ["fr"], [:title])

      assert TranslationFingerprint.get(stamped.metadata, "fr", "title") != nil
      assert TranslationFingerprint.get(stamped.metadata, "de", "title") == nil
    end

    test "a :stale pair is ACCEPTED as reference — it reads :fresh afterwards" do
      # The consequential half of "проштамповать" and the one the confirm
      # modal is asking about: the source moved on, the old translation
      # stayed, and stamping declares that translation good. Design §4.1
      # already books this cost explicitly for the one-time catalog stamp
      # ("если какой-то из существующих переводов уже разошёлся с
      # источником, это расхождение замораживается"); pinning it here so
      # the freeze can never become accidental.
      product = create_product()

      {:ok, translated} =
        AITranslatable.put_translation(product, "fr", %{"title" => "Vase en Bois"},
          source_fields: %{"title" => "Wooden Vase"}
        )

      {:ok, moved_on} =
        translated
        |> Ecto.Changeset.change(%{title: Map.put(translated.title, "en", "Oak Vase")})
        |> repo().update()

      assert TranslationFingerprint.field_state(
               "Oak Vase",
               moved_on.title["fr"],
               TranslationFingerprint.get(moved_on.metadata, "fr", "title")
             ) == :stale

      {:ok, stamped} = AITranslatable.stamp_reference(moved_on.uuid, "en", ["fr"], [:title])

      # The translation itself is untouched — only the reference moved.
      assert stamped.title["fr"] == "Vase en Bois"

      assert TranslationFingerprint.field_state(
               "Oak Vase",
               stamped.title["fr"],
               TranslationFingerprint.get(stamped.metadata, "fr", "title")
             ) == :fresh
    end

    test "errors on an unknown uuid" do
      assert {:error, :resource_not_found} =
               AITranslatable.stamp_reference(Ecto.UUID.generate(), "en", ["fr"])
    end
  end

  describe "candidates/3 — the hash-in-the-database query (design §4.3)" do
    # create_product/1's base attrs give description/seo_title an "en"
    # value with no "de" counterpart — fine for :missing/:stale fixtures
    # (an extra missing field doesn't change whether the resource is a
    # candidate), but it would make :unknown/:fresh/:empty_source spuriously
    # candidates too (via description/seo_title being :missing for "de"
    # regardless of what title does). Those three fixtures clear
    # description/seo_title entirely so title is the only field with any
    # state at all — isolating exactly what each is meant to test.
    @no_other_sources %{description: %{}, seo_title: %{}}

    setup do
      # :missing — source present ("en"), no "de" translation at all.
      missing = create_product(%{title: %{"en" => "Missing Title"}})

      # :stale — translated, but the fingerprint no longer matches source.
      stale =
        create_product(%{title: %{"en" => "Stale Title V2", "de" => "Alter Titel"}})

      stale_metadata =
        TranslationFingerprint.put_many(stale.metadata, "de", %{
          "title" => TranslationFingerprint.hash("Stale Title V1")
        })

      {:ok, stale} =
        stale |> Ecto.Changeset.change(%{metadata: stale_metadata}) |> repo().update()

      # :unknown — translated, no fingerprint. Must NEVER be a candidate.
      unknown =
        create_product(
          Map.merge(@no_other_sources, %{
            title: %{"en" => "Unknown Title", "de" => "Unbekannter Titel"}
          })
        )

      # :fresh — translated, fingerprint matches. Must NEVER be a candidate.
      fresh_source = "Fresh Title"

      fresh =
        create_product(
          Map.merge(@no_other_sources, %{
            title: %{"en" => fresh_source, "de" => "Frischer Titel"}
          })
        )

      fresh_metadata =
        TranslationFingerprint.put_many(fresh.metadata, "de", %{
          "title" => TranslationFingerprint.hash(fresh_source)
        })

      {:ok, fresh} =
        fresh |> Ecto.Changeset.change(%{metadata: fresh_metadata}) |> repo().update()

      # Empty source, but a LIVE "de" translation — must NEVER be a
      # candidate (design §4.1's convergence rule: empty source excludes
      # the field entirely, it does not count as "stale"). Built via a
      # raw changeset (bypassing Product.changeset/2's "en required"
      # validation) so the "en" title can be genuinely absent, not just
      # blank.
      {:ok, empty_source} =
        create_product(@no_other_sources)
        |> Ecto.Changeset.change(%{title: %{"de" => "Verwaistes Deutsch"}})
        |> repo().update()

      draft_missing =
        create_product(%{title: %{"en" => "Draft Missing Title"}, status: "draft"})

      %{
        missing: missing,
        stale: stale,
        unknown: unknown,
        fresh: fresh,
        empty_source: empty_source,
        draft_missing: draft_missing
      }
    end

    test "missing and stale are candidates; unknown, fresh, and empty-source are not", %{
      missing: missing,
      stale: stale,
      unknown: unknown,
      fresh: fresh,
      empty_source: empty_source
    } do
      results = AITranslatable.candidates("en", ["de"])
      uuids = MapSet.new(results, & &1.uuid)

      assert MapSet.member?(uuids, missing.uuid)
      assert MapSet.member?(uuids, stale.uuid)
      refute MapSet.member?(uuids, unknown.uuid)
      refute MapSet.member?(uuids, fresh.uuid)
      refute MapSet.member?(uuids, empty_source.uuid)

      missing_row = Enum.find(results, &(&1.uuid == missing.uuid))
      assert missing_row.languages == ["de"]
    end

    test "a status filter excludes non-matching statuses", %{
      missing: missing,
      draft_missing: draft_missing
    } do
      results = AITranslatable.candidates("en", ["de"], statuses: ["active"])
      uuids = MapSet.new(results, & &1.uuid)

      assert MapSet.member?(uuids, missing.uuid)
      refute MapSet.member?(uuids, draft_missing.uuid)

      # With no status filter, the draft one is included too.
      unfiltered_uuids = AITranslatable.candidates("en", ["de"]) |> MapSet.new(& &1.uuid)
      assert MapSet.member?(unfiltered_uuids, draft_missing.uuid)
    end

    test "limit caps the number of {uuid, language} candidate rows returned" do
      full = AITranslatable.candidates("en", ["de"])
      total_pairs = full |> Enum.map(&length(&1.languages)) |> Enum.sum()
      assert total_pairs > 1

      limited = AITranslatable.candidates("en", ["de"], limit: 1)
      limited_pairs = limited |> Enum.map(&length(&1.languages)) |> Enum.sum()
      assert limited_pairs == 1
    end

    test "an unrequested target language is never returned", %{missing: missing} do
      results = AITranslatable.candidates("en", ["fr"])
      row = Enum.find(results, &(&1.uuid == missing.uuid))

      # "de" was never requested, so even though missing has no "de" or
      # "fr" translation, only "fr" (the requested language) can appear.
      assert row.languages == ["fr"]
    end
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
