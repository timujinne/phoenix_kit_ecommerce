defmodule PhoenixKitEcommerce.AITranslatableTest do
  use PhoenixKitEcommerce.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Utils.Slug
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.AITranslatable
  alias PhoenixKitEcommerce.Product

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

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
