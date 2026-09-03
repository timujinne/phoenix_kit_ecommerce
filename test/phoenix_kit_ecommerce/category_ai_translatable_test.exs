defmodule PhoenixKitEcommerce.CategoryAITranslatableTest do
  use PhoenixKitEcommerce.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Category
  alias PhoenixKitEcommerce.CategoryAITranslatable
  alias PhoenixKitEcommerce.TranslationFingerprint

  defp create_category(attrs \\ %{}) do
    base = %{name: %{"en" => "Vases"}, description: %{"en" => "Decorative vases"}}
    {:ok, category} = Shop.create_category(Map.merge(base, attrs))
    category
  end

  test "registered as shop_category" do
    assert {"shop_category", CategoryAITranslatable} in PhoenixKitEcommerce.ai_translatables()
  end

  test "fetch/2 loads by uuid, errors on miss" do
    category = create_category()
    assert {:ok, %Category{}} = CategoryAITranslatable.fetch("shop_category", category.uuid)

    assert {:error, :resource_not_found} =
             CategoryAITranslatable.fetch("shop_category", Ecto.UUID.generate())
  end

  test "source_fields/2 maps schema fields to prompt vocabulary, skipping empties" do
    category = create_category(%{description: %{}})
    fields = CategoryAITranslatable.source_fields(category, "en")

    assert fields["name"] == "Vases"
    refute Map.has_key?(fields, "description")
  end

  test "put_translation/4 merges fields and generates a local slug once" do
    category = create_category()

    {:ok, updated} =
      CategoryAITranslatable.put_translation(
        category,
        "fr",
        %{"name" => "Vases en Bois", "description" => "De jolis vases"},
        []
      )

    assert updated.name["fr"] == "Vases en Bois"
    assert updated.description["fr"] == "De jolis vases"
    # slug generated locally via LocalizedSlug, not sourced from the AI
    assert updated.slug["fr"] == "vases-en-bois"
    # sibling language untouched
    assert updated.name["en"] == "Vases"

    # re-translation must NOT change the existing slug (write-once)
    {:ok, again} =
      CategoryAITranslatable.put_translation(updated, "fr", %{"name" => "Vases Nouveaux"}, [])

    assert again.name["fr"] == "Vases Nouveaux"
    assert again.slug["fr"] == "vases-en-bois"
  end

  test "an AI-provided slug field is ignored entirely — it isn't even in the field map" do
    category = create_category()

    {:ok, updated} =
      CategoryAITranslatable.put_translation(
        category,
        "fr",
        %{"name" => "Vases", "slug" => "../../evil"},
        []
      )

    assert updated.slug["fr"] == "vases"
  end

  test "blank translations are rejected" do
    category = create_category()

    assert {:error, :no_translated_fields} =
             CategoryAITranslatable.put_translation(category, "fr", %{"name" => "  "}, [])
  end

  test "accented Latin names transliterate in the slug" do
    category = create_category()

    {:ok, fr} =
      CategoryAITranslatable.put_translation(
        category,
        "fr",
        %{"name" => "Étagère décorative"},
        []
      )

    assert fr.slug["fr"] == "etagere-decorative"

    {:ok, de} =
      CategoryAITranslatable.put_translation(category, "de", %{"name" => "Größe Fußball"}, [])

    assert de.slug["de"] == "groesse-fussball"
  end

  test "Cyrillic names transliterate to a readable slug" do
    category = create_category()

    {:ok, ru} =
      CategoryAITranslatable.put_translation(category, "ru", %{"name" => "Ваза Деревянная"}, [])

    assert ru.slug["ru"] == "vaza-derevyannaya"
  end

  # design §4.2: the DB, not app code, is the source of truth for slug
  # uniqueness — LocalizedSlug does no collision avoidance of its own, so
  # two categories translated to the same slug in the same language must
  # surface as a changeset error on :slug (via the V171 projection table's
  # pkey), never a raised Ecto.ConstraintError / Postgrex.Error.
  test "a slug collision between two categories comes back as a changeset error on :slug" do
    first = create_category(%{name: %{"en" => "First"}})
    second = create_category(%{name: %{"en" => "Second"}})

    {:ok, _} = CategoryAITranslatable.put_translation(first, "fr", %{"name" => "Chaise"}, [])

    assert {:error, %Ecto.Changeset{} = changeset} =
             CategoryAITranslatable.put_translation(second, "fr", %{"name" => "Chaise"}, [])

    assert %{slug: [_ | _]} = errors_on(changeset)

    # the losing category's row is untouched — no partial write
    reloaded = repo().get(Category, second.uuid)
    refute Map.has_key?(reloaded.slug || %{}, "fr")
  end

  # design §4.2/§7: the adapter MUST do its own locked merge, not wrap
  # update_category_translation/3 (which writes a stale in-memory struct
  # with no lock). Two concurrent language jobs on the SAME category must
  # both survive, not clobber each other.
  test "concurrent translations of two languages on the same category both survive" do
    category = create_category()
    parent = self()

    tasks =
      for {lang, name} <- [{"fr", "Chaises FR"}, {"de", "Stühle DE"}] do
        Task.async(fn ->
          Sandbox.allow(repo(), parent, self())
          CategoryAITranslatable.put_translation(category, lang, %{"name" => name}, [])
        end)
      end

    Enum.each(tasks, &Task.await/1)

    fresh = repo().get(Category, category.uuid)
    assert fresh.name["fr"] == "Chaises FR"
    assert fresh.name["de"] == "Stühle DE"
  end

  describe "put_translation/4 stamps a fingerprint alongside each field it writes" do
    test "first write of a field stamps hash(trim(source)) under metadata" do
      category = create_category()

      {:ok, updated} =
        CategoryAITranslatable.put_translation(
          category,
          "fr",
          %{"name" => "Vases en Bois"},
          source_fields: %{"name" => "Vases"}
        )

      assert updated.name["fr"] == "Vases en Bois"

      assert updated.metadata["_translation_fingerprints"]["fr"]["name"] ==
               TranslationFingerprint.hash("Vases")
    end

    test "the fingerprint is taken from the SOURCE FIELDS THE JOB PASSED, not the row's current value" do
      category = create_category()
      stale_source = "Vases (as read at translation time)"

      {:ok, updated} =
        CategoryAITranslatable.put_translation(
          category,
          "fr",
          %{"name" => "Vases en Bois"},
          source_fields: %{"name" => stale_source}
        )

      assert updated.metadata["_translation_fingerprints"]["fr"]["name"] ==
               TranslationFingerprint.hash(stale_source)

      refute updated.metadata["_translation_fingerprints"]["fr"]["name"] ==
               TranslationFingerprint.hash(category.name["en"])
    end

    test "a call with no :source_fields opt at all still writes, but stamps no fingerprint" do
      category = create_category()

      {:ok, updated} =
        CategoryAITranslatable.put_translation(category, "fr", %{"name" => "Vases en Bois"}, [])

      assert updated.name["fr"] == "Vases en Bois"
      assert TranslationFingerprint.get(updated.metadata, "fr", "name") == nil
    end
  end

  describe "write-narrowing (design §4.4's table)" do
    test "an unchanged source is skipped — the stored translation is left alone" do
      category = create_category()
      source = category.name["en"]

      {:ok, first} =
        CategoryAITranslatable.put_translation(category, "fr", %{"name" => "Vases en Bois"},
          source_fields: %{"name" => source}
        )

      # A second call with the SAME source but a DIFFERENT AI response
      # (simulating a routine re-run) must not clobber the manual/prior
      # translation.
      {:ok, second} =
        CategoryAITranslatable.put_translation(
          first,
          "fr",
          %{"name" => "Vases Complètement Différents"},
          source_fields: %{"name" => source}
        )

      assert second.name["fr"] == "Vases en Bois"

      assert second.metadata["_translation_fingerprints"]["fr"]["name"] ==
               TranslationFingerprint.hash(source)
    end

    test "a changed source is written and the fingerprint moves with it" do
      category = create_category()

      {:ok, first} =
        CategoryAITranslatable.put_translation(category, "fr", %{"name" => "Vases en Bois"},
          source_fields: %{"name" => "Vases"}
        )

      {:ok, second} =
        CategoryAITranslatable.put_translation(
          first,
          "fr",
          %{"name" => "Vases en Bois (Nouveau)"},
          source_fields: %{"name" => "Vases, Deluxe"}
        )

      assert second.name["fr"] == "Vases en Bois (Nouveau)"

      assert second.metadata["_translation_fingerprints"]["fr"]["name"] ==
               TranslationFingerprint.hash("Vases, Deluxe")
    end

    test "a field with no fingerprint yet (:unknown) is written even though a translation exists" do
      category = create_category()

      # Simulate a translation stored WITHOUT going through put_translation/4
      # — translated but fingerprint-less: design §4.1's `:unknown`.
      {:ok, unknown_state} =
        category
        |> Ecto.Changeset.change(%{name: Map.put(category.name, "fr", "Vases (import)")})
        |> repo().update()

      {:ok, updated} =
        CategoryAITranslatable.put_translation(unknown_state, "fr", %{"name" => "Vases en Bois"},
          source_fields: %{"name" => "Vases"}
        )

      assert updated.name["fr"] == "Vases en Bois"

      assert TranslationFingerprint.get(updated.metadata, "fr", "name") ==
               TranslationFingerprint.hash("Vases")
    end

    test "fields are narrowed independently — one stale, one fresh, in the same call" do
      category = create_category()

      {:ok, first} =
        CategoryAITranslatable.put_translation(
          category,
          "fr",
          %{"name" => "Vases en Bois", "description" => "De jolis vases"},
          source_fields: %{"name" => "Vases", "description" => "Decorative vases"}
        )

      {:ok, second} =
        CategoryAITranslatable.put_translation(
          first,
          "fr",
          %{
            "name" => "Vases Différents (ignoré)",
            "description" => "Description mise à jour"
          },
          source_fields: %{"name" => "Vases", "description" => "Decorative vases, updated"}
        )

      assert second.name["fr"] == "Vases en Bois"
      assert second.description["fr"] == "Description mise à jour"
    end

    test "all fields write-narrowed away ⇒ success without a write, no event, no activity log" do
      category = create_category()
      source = category.name["en"]

      {:ok, first} =
        CategoryAITranslatable.put_translation(category, "fr", %{"name" => "Vases en Bois"},
          source_fields: %{"name" => source}
        )

      activity_count_before = length(list_activities())

      PhoenixKitEcommerce.Events.subscribe_categories()

      {:ok, second} =
        CategoryAITranslatable.put_translation(
          first,
          "fr",
          %{"name" => "Ignored, unchanged source"},
          source_fields: %{"name" => source}
        )

      assert second.uuid == first.uuid
      assert second.name["fr"] == "Vases en Bois"
      assert second.updated_at == first.updated_at

      refute_receive {:category_updated, _}, 50

      assert length(list_activities()) == activity_count_before
    end

    test "a write DOES broadcast the update event and log the activity entry" do
      category = create_category()
      PhoenixKitEcommerce.Events.subscribe_categories()

      {:ok, _updated} =
        CategoryAITranslatable.put_translation(category, "fr", %{"name" => "Vases en Bois"},
          source_fields: %{"name" => "Vases"},
          actor_uuid: nil
        )

      assert_receive {:category_updated, _}, 100

      assert_activity_logged("shop.category.updated",
        resource_uuid: category.uuid,
        metadata_has: %{"target_language" => "fr"}
      )
    end
  end

  describe "the slug corner: name write-narrowed away falls back to the STORED name (design §4.4)" do
    test "name skipped (fresh), description written, slug still generated from stored name" do
      category = create_category()
      name_source = category.name["en"]

      metadata =
        TranslationFingerprint.put_many(category.metadata, "fr", %{
          "name" => TranslationFingerprint.hash(name_source)
        })

      {:ok, primed} =
        category
        |> Ecto.Changeset.change(%{
          name: Map.put(category.name, "fr", "Vases en Bois"),
          metadata: metadata
        })
        |> repo().update()

      refute Map.has_key?(primed.slug || %{}, "fr")

      {:ok, updated} =
        CategoryAITranslatable.put_translation(
          primed,
          "fr",
          %{"name" => "Vases Ignoré", "description" => "De jolis vases"},
          source_fields: %{"name" => name_source, "description" => "Decorative vases"}
        )

      # name write-narrowed away — untouched
      assert updated.name["fr"] == "Vases en Bois"
      assert updated.description["fr"] == "De jolis vases"
      # slug generated from the STORED name, not the (ignored) AI response
      assert updated.slug["fr"] == "vases-en-bois"
    end

    test "name absent from the AI response entirely — same fallback applies" do
      category = create_category()

      {:ok, primed} =
        category
        |> Ecto.Changeset.change(%{name: Map.put(category.name, "fr", "Vases Préexistants")})
        |> repo().update()

      refute Map.has_key?(primed.slug || %{}, "fr")

      {:ok, updated} =
        CategoryAITranslatable.put_translation(primed, "fr", %{"description" => "De jolis vases"},
          source_fields: %{"description" => "Decorative vases"}
        )

      assert updated.description["fr"] == "De jolis vases"
      assert updated.slug["fr"] == "vases-preexistants"
    end
  end

  describe "reset_reference/3 — \"перевести заново\" (design §4.4)" do
    test "erases the fingerprint for exactly the requested language/field pair" do
      category = create_category()

      {:ok, translated} =
        CategoryAITranslatable.put_translation(
          category,
          "fr",
          %{"name" => "Vases en Bois", "description" => "De jolis vases"},
          source_fields: %{"name" => "Vases", "description" => "Decorative vases"}
        )

      assert TranslationFingerprint.get(translated.metadata, "fr", "name") != nil

      {:ok, reset} = CategoryAITranslatable.reset_reference(translated.uuid, ["fr"], [:name])

      assert reset.name["fr"] == "Vases en Bois"
      assert reset.description["fr"] == "De jolis vases"

      assert TranslationFingerprint.get(reset.metadata, "fr", "name") == nil
      assert TranslationFingerprint.get(reset.metadata, "fr", "description") != nil
    end

    test "after a reset, a call with the SAME source writes again instead of skipping" do
      category = create_category()
      source = "Vases"

      {:ok, translated} =
        CategoryAITranslatable.put_translation(category, "fr", %{"name" => "Vases en Bois"},
          source_fields: %{"name" => source}
        )

      {:ok, _reset} = CategoryAITranslatable.reset_reference(translated.uuid, ["fr"], [:name])
      reset_category = repo().get(Category, category.uuid)

      {:ok, retranslated} =
        CategoryAITranslatable.put_translation(
          reset_category,
          "fr",
          %{"name" => "Vases en Bois (Amélioré)"},
          source_fields: %{"name" => source}
        )

      assert retranslated.name["fr"] == "Vases en Bois (Amélioré)"
    end

    test "defaults to every fingerprinted field when none are given" do
      category = create_category()

      {:ok, translated} =
        CategoryAITranslatable.put_translation(
          category,
          "fr",
          %{"name" => "Vases en Bois", "description" => "De jolis vases"},
          source_fields: %{"name" => "Vases", "description" => "Decorative vases"}
        )

      {:ok, reset} = CategoryAITranslatable.reset_reference(translated.uuid, ["fr"])

      assert TranslationFingerprint.get(reset.metadata, "fr", "name") == nil
      assert TranslationFingerprint.get(reset.metadata, "fr", "description") == nil
    end

    test "errors on an unknown uuid" do
      assert {:error, :resource_not_found} =
               CategoryAITranslatable.reset_reference(Ecto.UUID.generate(), ["fr"], [:name])
    end
  end

  describe "stamp_reference/4 — \"проштамповать текущий источник как эталон\" (design §4.1, §4.5)" do
    test "an unfingerprinted (:unknown) translation moves to :fresh, no model call" do
      category = create_category()

      {:ok, primed} =
        category
        |> Ecto.Changeset.change(%{name: Map.put(category.name, "fr", "Vases Préexistants")})
        |> repo().update()

      assert TranslationFingerprint.get(primed.metadata, "fr", "name") == nil

      {:ok, stamped} = CategoryAITranslatable.stamp_reference(primed.uuid, "en", ["fr"])

      assert stamped.name["fr"] == "Vases Préexistants"

      assert TranslationFingerprint.get(stamped.metadata, "fr", "name") ==
               TranslationFingerprint.hash("Vases")

      assert TranslationFingerprint.field_state(
               "Vases",
               stamped.name["fr"],
               TranslationFingerprint.get(stamped.metadata, "fr", "name")
             ) == :fresh
    end

    test "a field with no stored translation is left alone" do
      category = create_category(%{description: %{}})

      {:ok, stamped} = CategoryAITranslatable.stamp_reference(category.uuid, "en", ["fr"])

      assert TranslationFingerprint.get(stamped.metadata, "fr", "name") == nil
      assert TranslationFingerprint.get(stamped.metadata, "fr", "description") == nil
    end

    test "narrows to exactly the given fields and languages, leaving others untouched" do
      category = create_category()

      {:ok, primed} =
        category
        |> Ecto.Changeset.change(%{
          name: Map.merge(category.name, %{"fr" => "Vases FR", "de" => "Vasen DE"})
        })
        |> repo().update()

      {:ok, stamped} = CategoryAITranslatable.stamp_reference(primed.uuid, "en", ["fr"], [:name])

      assert TranslationFingerprint.get(stamped.metadata, "fr", "name") != nil
      assert TranslationFingerprint.get(stamped.metadata, "de", "name") == nil
    end

    test "errors on an unknown uuid" do
      assert {:error, :resource_not_found} =
               CategoryAITranslatable.stamp_reference(Ecto.UUID.generate(), "en", ["fr"])
    end
  end

  describe "candidates/3 — the hash-in-the-database query (design §4.3)" do
    @no_other_sources %{description: %{}}

    setup do
      missing = create_category(%{name: %{"en" => "Missing Name"}})

      stale = create_category(%{name: %{"en" => "Stale Name V2", "de" => "Alter Name"}})

      stale_metadata =
        TranslationFingerprint.put_many(stale.metadata, "de", %{
          "name" => TranslationFingerprint.hash("Stale Name V1")
        })

      {:ok, stale} =
        stale |> Ecto.Changeset.change(%{metadata: stale_metadata}) |> repo().update()

      unknown =
        create_category(
          Map.merge(@no_other_sources, %{
            name: %{"en" => "Unknown Name", "de" => "Unbekannter Name"}
          })
        )

      fresh_source = "Fresh Name"

      fresh =
        create_category(
          Map.merge(@no_other_sources, %{
            name: %{"en" => fresh_source, "de" => "Frischer Name"}
          })
        )

      fresh_metadata =
        TranslationFingerprint.put_many(fresh.metadata, "de", %{
          "name" => TranslationFingerprint.hash(fresh_source)
        })

      {:ok, fresh} =
        fresh |> Ecto.Changeset.change(%{metadata: fresh_metadata}) |> repo().update()

      {:ok, empty_source} =
        create_category(@no_other_sources)
        |> Ecto.Changeset.change(%{name: %{"de" => "Verwaistes Deutsch"}})
        |> repo().update()

      # design §4.3: categories are NEVER status-filtered — a hidden
      # category must still be a translation candidate.
      hidden_missing =
        create_category(%{name: %{"en" => "Hidden Missing Name"}, status: "hidden"})

      %{
        missing: missing,
        stale: stale,
        unknown: unknown,
        fresh: fresh,
        empty_source: empty_source,
        hidden_missing: hidden_missing
      }
    end

    test "missing and stale are candidates; unknown, fresh, and empty-source are not", %{
      missing: missing,
      stale: stale,
      unknown: unknown,
      fresh: fresh,
      empty_source: empty_source
    } do
      results = CategoryAITranslatable.candidates("en", ["de"])
      uuids = MapSet.new(results, & &1.uuid)

      assert MapSet.member?(uuids, missing.uuid)
      assert MapSet.member?(uuids, stale.uuid)
      refute MapSet.member?(uuids, unknown.uuid)
      refute MapSet.member?(uuids, fresh.uuid)
      refute MapSet.member?(uuids, empty_source.uuid)

      missing_row = Enum.find(results, &(&1.uuid == missing.uuid))
      assert missing_row.languages == ["de"]
    end

    # design §4.1/§4.3 + TranslationFingerprint.field_state/3, which pins
    # `field_state("   ", nil, nil) == nil`: a whitespace-only source is
    # BLANK, so its field has no state and cannot make the resource a
    # candidate. The SQL has to use the same trim the hash does — with a
    # bare `nullif(x,'')` this row is a candidate on every tick forever
    # (`source_fields/2` drops the blank field, so it is never written
    # and never fingerprinted), and the sibling `name` field keeps the
    # job a real, paid model call each time.
    test "a whitespace-only source is blank, not a candidate" do
      whitespace =
        create_category(%{name: %{"en" => "Whitespace Src", "de" => "Leerzeichen"}})

      metadata =
        TranslationFingerprint.put_many(whitespace.metadata, "de", %{
          "name" => TranslationFingerprint.hash("Whitespace Src")
        })

      {:ok, whitespace} =
        whitespace
        |> Ecto.Changeset.change(%{description: %{"en" => "   "}, metadata: metadata})
        |> repo().update()

      uuids = MapSet.new(CategoryAITranslatable.candidates("en", ["de"]), & &1.uuid)

      refute MapSet.member?(uuids, whitespace.uuid)
    end

    test "a whitespace-only translation reads as :missing, exactly as in field_state/3" do
      whitespace =
        create_category(
          Map.merge(@no_other_sources, %{name: %{"en" => "Blank Translation", "de" => "  "}})
        )

      uuids = MapSet.new(CategoryAITranslatable.candidates("en", ["de"]), & &1.uuid)

      assert MapSet.member?(uuids, whitespace.uuid)
    end

    test "a hidden category is still a candidate — no status filter exists for categories", %{
      hidden_missing: hidden_missing
    } do
      results = CategoryAITranslatable.candidates("en", ["de"])
      uuids = MapSet.new(results, & &1.uuid)

      assert MapSet.member?(uuids, hidden_missing.uuid)
    end

    test "limit caps the number of {uuid, language} candidate rows returned" do
      full = CategoryAITranslatable.candidates("en", ["de"])
      total_pairs = full |> Enum.map(&length(&1.languages)) |> Enum.sum()
      assert total_pairs > 1

      limited = CategoryAITranslatable.candidates("en", ["de"], limit: 1)
      limited_pairs = limited |> Enum.map(&length(&1.languages)) |> Enum.sum()
      assert limited_pairs == 1
    end

    test "an unrequested target language is never returned", %{missing: missing} do
      results = CategoryAITranslatable.candidates("en", ["fr"])
      row = Enum.find(results, &(&1.uuid == missing.uuid))

      assert row.languages == ["fr"]
    end
  end

  describe "ensure_prompt/0" do
    test "is idempotent and creates with metadata from the first call — no adoption path" do
      case CategoryAITranslatable.ensure_prompt() do
        {:ok, uuid1, :created} ->
          assert {:ok, ^uuid1, :unchanged} = CategoryAITranslatable.ensure_prompt()

          prompt = PhoenixKitAI.get_prompt(uuid1)
          assert prompt.metadata["managed_by"] == "phoenix_kit_ecommerce"
          assert is_binary(prompt.metadata["content_sha"])

        {:error, :ai_not_installed} ->
          :ok
      end
    end

    test "the shipped template is built on {{SourceFields}}, not a fixed slot per field" do
      case CategoryAITranslatable.ensure_prompt() do
        {:ok, uuid, _status} ->
          prompt = PhoenixKitAI.get_prompt(uuid)
          assert prompt.content =~ "{{SourceFields}}"
          refute prompt.content =~ "{{name}}"
          refute prompt.content =~ "{{description}}"

        {:error, :ai_not_installed} ->
          :ok
      end
    end
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
