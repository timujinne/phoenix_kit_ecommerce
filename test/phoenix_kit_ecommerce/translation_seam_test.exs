defmodule PhoenixKitEcommerce.TranslationSeamTest do
  @moduledoc """
  Cross-task seam coverage for the translation-control work (design
  §4.1/§4.3/§4.4). Each task's own suite pins the inside of one unit;
  these tests pin the boundaries BETWEEN them, where a disagreement can
  hide in two individually-correct halves:

    * the write path's fingerprint (Elixir `String.trim/1` + sha256) and
      the sweep's candidate SQL (`btrim` + `sha256`) must compute the
      SAME digest for the same source text — otherwise a resource the
      sweep calls `:stale` gets write-narrowed away on arrival and comes
      straight back as a candidate on the next tick, paying for a model
      call every hour forever;
    * the management page's per-cell state (`field_state/3`) and the
      sweep's candidate query must agree about the same row;
    * the product and category adapters must lay fingerprints out
      identically, so one sweep can read both;
    * `source_fields/2`'s output must be usable verbatim as
      `opts[:source_fields]` — that is exactly what
      `PhoenixKitAI.TranslateWorker.safe_put_translation/3` threads
      through after design §9.3.
  """
  use PhoenixKitEcommerce.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias Mix.Tasks.PhoenixKitEcommerce.BackfillTranslationFingerprints
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.AITranslatable
  alias PhoenixKitEcommerce.CategoryAITranslatable
  alias PhoenixKitEcommerce.TranslationFingerprint, as: FP

  defp repo, do: PhoenixKit.RepoHelper.repo()

  defp create_product(attrs) do
    base = %{
      title: %{"en" => "Wooden Vase"},
      description: %{},
      seo_title: %{},
      price: Decimal.new("10.00"),
      status: "active"
    }

    {:ok, product} = Shop.create_product(Map.merge(base, attrs))
    product
  end

  defp create_category(attrs) do
    base = %{name: %{"en" => "Vases"}, status: "active"}
    {:ok, category} = Shop.create_category(Map.merge(base, attrs))
    category
  end

  describe "hash agreement between the write path and the candidate SQL" do
    # Design §4.1 fixes ONE hash: sha256(trim(source)). The write path
    # computes it in Elixir; the sweep recomputes it in Postgres. If the
    # two trims differ on any character, a fingerprint written by one is
    # unreadable by the other.
    for {label, source} <- [
          {"plain text", "Wooden Vase"},
          {"leading and trailing ASCII spaces", "  Wooden Vase  "},
          {"trailing newline (what an HTML body_html normally ends with)",
           "<p>A nice vase</p>\n"},
          {"leading newline and trailing tab", "\nWooden Vase\t"},
          {"CRLF terminated", "Wooden Vase\r\n"},
          {"unicode body", "  Кашпо Деревянное  "}
        ] do
      test "database and Elixir digests match: #{label}" do
        source = unquote(source)

        elixir_digest = FP.hash(source)

        {:ok, %{rows: [[sql_digest]]}} =
          SQL.query(
            repo(),
            "SELECT encode(sha256(convert_to(btrim($1, $2),'UTF8')),'hex')",
            [source, FP.sql_trim_chars()]
          )

        assert elixir_digest == sql_digest,
               "the write path and the candidate query disagree about " <>
                 "sha256(trim(source)) for #{inspect(source)} — a row " <>
                 "fingerprinted by one is permanently :stale to the other"
      end
    end
  end

  describe "the one-shot backfill stamps the same digest the write path would" do
    test "a backfilled product reads as :fresh in Elixir and is not a candidate in SQL" do
      # The backfill is the very first thing that touches the live
      # catalogue (design §4.1). If its SQL hash disagreed with
      # `hash/1`, all 634 resources would land in a state the page calls
      # `:stale` and the sweep calls `:fresh` (or vice versa) — from
      # minute one.
      source = "<p>A nice vase</p>\n"

      product =
        create_product(%{
          title: %{"en" => " Wooden Vase\n", "de" => "Holzvase"},
          body_html: %{"en" => source, "de" => "Beschreibung"}
        })

      BackfillTranslationFingerprints.backfill(
        repo(),
        "en",
        ["de"]
      )

      fresh_row = repo().get(PhoenixKitEcommerce.Product, product.uuid)

      assert FP.get(fresh_row.metadata, "de", "title") == FP.hash(" Wooden Vase\n")
      assert FP.get(fresh_row.metadata, "de", "body_html") == FP.hash(source)

      refute MapSet.member?(
               AITranslatable.candidates("en", ["de"]) |> MapSet.new(& &1.uuid),
               product.uuid
             )
    end
  end

  describe "sweep candidate selection agrees with write-narrowing (convergence)" do
    test "a product the sweep calls stale is actually rewritten by put_translation/4" do
      # The loop guard: whatever the candidate query hands the sweep must
      # be something the write path will genuinely write. If it isn't,
      # the tick enqueues, the worker pays for a translation, the write
      # is narrowed away, nothing changes — and the next tick does it
      # again, forever.
      source = "<p>A nice vase</p>\n"

      product =
        create_product(%{
          title: %{"en" => "Wooden Vase", "de" => "Holzvase"},
          body_html: %{"en" => source, "de" => "Alte Beschreibung"}
        })

      # Stamp the CURRENT source as reference for both fields, exactly as
      # the write path / "stamp as reference" does.
      metadata =
        FP.put_many(product.metadata, "de", %{
          "title" => FP.hash("Wooden Vase"),
          "body_html" => FP.hash(source)
        })

      {:ok, product} =
        product |> Ecto.Changeset.change(%{metadata: metadata}) |> repo().update()

      # Every field is :fresh by the Elixir model...
      assert FP.field_state(
               source,
               "Alte Beschreibung",
               FP.get(product.metadata, "de", "body_html")
             ) ==
               :fresh

      # ...so the sweep must not offer it as a candidate.
      uuids = AITranslatable.candidates("en", ["de"]) |> MapSet.new(& &1.uuid)

      refute MapSet.member?(uuids, product.uuid),
             "the candidate query selected a resource every field of which " <>
               "the write path considers fresh — the sweep would re-translate " <>
               "and re-narrow this row on every tick"
    end

    test "a category the sweep calls stale is actually rewritten by put_translation/4" do
      source = "Vases and pots\n"

      category =
        create_category(%{
          name: %{"en" => "Vases", "de" => "Vasen"},
          description: %{"en" => source, "de" => "Alte Beschreibung"}
        })

      metadata =
        FP.put_many(category.metadata, "de", %{
          "name" => FP.hash("Vases"),
          "description" => FP.hash(source)
        })

      {:ok, category} =
        category |> Ecto.Changeset.change(%{metadata: metadata}) |> repo().update()

      uuids = CategoryAITranslatable.candidates("en", ["de"]) |> MapSet.new(& &1.uuid)

      refute MapSet.member?(uuids, category.uuid)
    end

    test "a genuinely changed source IS still selected (the guard above doesn't blunt the query)" do
      product =
        create_product(%{
          title: %{"en" => "Wooden Vase V2", "de" => "Holzvase"}
        })

      metadata =
        FP.put_many(product.metadata, "de", %{"title" => FP.hash("Wooden Vase V1")})

      {:ok, product} =
        product |> Ecto.Changeset.change(%{metadata: metadata}) |> repo().update()

      uuids = AITranslatable.candidates("en", ["de"]) |> MapSet.new(& &1.uuid)
      assert MapSet.member?(uuids, product.uuid)
    end
  end

  describe "the page's four states agree with the candidate query, row for row" do
    test "every product the page reads as fresh/unknown is absent from the candidate set, and vice versa" do
      # Rows chosen to cover each state AND the whitespace forms the two
      # implementations trim differently.
      whitespace_fresh_source = "Wooden Vase\n"

      whitespace_fresh =
        create_product(%{title: %{"en" => whitespace_fresh_source, "de" => "Holzvase"}})

      {:ok, whitespace_fresh} =
        whitespace_fresh
        |> Ecto.Changeset.change(%{
          metadata:
            FP.put_many(whitespace_fresh.metadata, "de", %{
              "title" => FP.hash(whitespace_fresh_source)
            })
        })
        |> repo().update()

      missing = create_product(%{title: %{"en" => "No German Yet"}})

      unknown =
        create_product(%{title: %{"en" => "Unknown Title", "de" => "Unbekannt"}})

      candidate_uuids = AITranslatable.candidates("en", ["de"]) |> MapSet.new(& &1.uuid)

      for product <- [whitespace_fresh, missing, unknown] do
        fresh_row = repo().get(PhoenixKitEcommerce.Product, product.uuid)

        page_state =
          FP.field_state(
            fresh_row.title["en"],
            fresh_row.title["de"],
            FP.get(fresh_row.metadata, "de", "title")
          )

        in_candidates? = MapSet.member?(candidate_uuids, product.uuid)

        assert in_candidates? == page_state in [:missing, :stale],
               "page shows #{inspect(page_state)} for #{fresh_row.title["en"] |> inspect()} " <>
                 "but the candidate query #{if in_candidates?, do: "DOES", else: "does NOT"} " <>
                 "select it — the operator and the sweep disagree about the same row"
      end
    end
  end

  describe "the candidate query's per-language list matches the page's, language by language" do
    test "a row stale in one language and fresh in another yields exactly the stale language" do
      product =
        create_product(%{
          title: %{"en" => "Wooden Vase V2\n", "de" => "Holzvase", "fr" => "Vase en bois"}
        })

      metadata =
        FP.put_many(product.metadata, "de", %{"title" => FP.hash("Wooden Vase V1")})

      metadata = FP.put_many(metadata, "fr", %{"title" => FP.hash("Wooden Vase V2\n")})

      {:ok, product} =
        product |> Ecto.Changeset.change(%{metadata: metadata}) |> repo().update()

      [candidate] =
        AITranslatable.candidates("en", ["de", "fr"])
        |> Enum.filter(&(&1.uuid == product.uuid))

      assert candidate.languages == ["de"]

      # …and the page, computing the same thing in Elixir, agrees.
      fresh_row = repo().get(PhoenixKitEcommerce.Product, product.uuid)

      page_langs =
        for lang <- ["de", "fr"],
            FP.field_state(
              fresh_row.title["en"],
              fresh_row.title[lang],
              FP.get(fresh_row.metadata, lang, "title")
            ) in [:missing, :stale],
            do: lang

      assert page_langs == candidate.languages
    end
  end

  describe "the four field lists stay in lockstep" do
    # The same field list is spelled out in four places: the adapters'
    # `@field_map`, the one-shot backfill task's `@product_fields` /
    # `@category_fields`, and `Translations.product_fields/0` /
    # `category_fields/0` (which is what the management page reads). A
    # field present in one and absent from another is silently
    # unfingerprinted, unswept, or invisible.
    test "products: page list == what put_translation/4 actually fingerprints" do
      page_fields = PhoenixKitEcommerce.Translations.product_fields() -- [:slug]

      product =
        create_product(%{
          title: %{"en" => "T"},
          description: %{"en" => "D"},
          body_html: %{"en" => "B"},
          seo_title: %{"en" => "ST"},
          seo_description: %{"en" => "SD"}
        })

      source_fields = AITranslatable.source_fields(product, "en")

      {:ok, updated} =
        AITranslatable.put_translation(
          product,
          "de",
          %{
            "title" => "t",
            "description" => "d",
            "body" => "b",
            "seo_title" => "st",
            "seo_description" => "sd"
          },
          source_fields: source_fields
        )

      stamped =
        updated.metadata["_translation_fingerprints"]["de"] |> Map.keys() |> Enum.sort()

      assert stamped == page_fields |> Enum.map(&Atom.to_string/1) |> Enum.sort()
    end

    test "categories: page list == what put_translation/4 actually fingerprints" do
      page_fields = PhoenixKitEcommerce.Translations.category_fields() -- [:slug]

      category = create_category(%{name: %{"en" => "N"}, description: %{"en" => "D"}})
      source_fields = CategoryAITranslatable.source_fields(category, "en")

      {:ok, updated} =
        CategoryAITranslatable.put_translation(
          category,
          "de",
          %{"name" => "n", "description" => "d"},
          source_fields: source_fields
        )

      stamped =
        updated.metadata["_translation_fingerprints"]["de"] |> Map.keys() |> Enum.sort()

      assert stamped == page_fields |> Enum.map(&Atom.to_string/1) |> Enum.sort()
    end
  end

  describe "product and category adapters lay fingerprints out identically" do
    test "both write under the same metadata key, keyed by schema field name" do
      product = create_product(%{title: %{"en" => "Wooden Vase"}})

      {:ok, product} =
        AITranslatable.put_translation(product, "de", %{"title" => "Holzvase"},
          source_fields: %{"title" => "Wooden Vase"}
        )

      category = create_category(%{name: %{"en" => "Vases"}})

      {:ok, category} =
        CategoryAITranslatable.put_translation(category, "de", %{"name" => "Vasen"},
          source_fields: %{"name" => "Vases"}
        )

      assert %{"_translation_fingerprints" => %{"de" => %{"title" => product_fp}}} =
               product.metadata

      assert %{"_translation_fingerprints" => %{"de" => %{"name" => category_fp}}} =
               category.metadata

      # Same function, same layout — one sweep can read both.
      assert product_fp == FP.hash("Wooden Vase")
      assert category_fp == FP.hash("Vases")
      assert FP.get(product.metadata, "de", "title") == product_fp
      assert FP.get(category.metadata, "de", "name") == category_fp
    end

    test "both erase a stale fingerprint when a write carries no source for the field" do
      # The engine pinned here (phoenix_kit_ai 0.19.2) predates design
      # §9.3 and passes no :source_fields at all, so this is not a
      # corner case but the CURRENT shape of every worker write. If an
      # adapter kept the old fingerprint, the pair would stay a
      # candidate the write can never satisfy — the same non-convergent
      # loop the btrim seam above exists to prevent. Pinned for both
      # adapters together so they can't drift apart on it.
      product = create_product(%{title: %{"en" => "Wooden Vase"}})

      {:ok, product} =
        AITranslatable.put_translation(product, "de", %{"title" => "Holzvase"},
          source_fields: %{"title" => "Wooden Vase"}
        )

      {:ok, product} =
        AITranslatable.put_translation(product, "de", %{"title" => "Holzvase Neu"}, [])

      category = create_category(%{name: %{"en" => "Vases"}})

      {:ok, category} =
        CategoryAITranslatable.put_translation(category, "de", %{"name" => "Vasen"},
          source_fields: %{"name" => "Vases"}
        )

      {:ok, category} =
        CategoryAITranslatable.put_translation(category, "de", %{"name" => "Vasen Neu"}, [])

      assert FP.get(product.metadata, "de", "title") == nil
      assert FP.get(category.metadata, "de", "name") == nil

      # ...so neither is a candidate the next tick would re-queue.
      refute Enum.any?(AITranslatable.candidates("en", ["de"]), &(&1.uuid == product.uuid))

      refute Enum.any?(
               CategoryAITranslatable.candidates("en", ["de"]),
               &(&1.uuid == category.uuid)
             )
    end
  end

  describe "source_fields/2 output is usable verbatim as opts[:source_fields] (design §9.3)" do
    test "products: the exact map the worker reads stamps every field" do
      product =
        create_product(%{
          title: %{"en" => "Wooden Vase"},
          description: %{"en" => "A nice vase"},
          body_html: %{"en" => "<p>Body</p>\n"},
          seo_title: %{"en" => "Buy It"}
        })

      # This is literally what TranslateWorker passes: the adapter's own
      # source_fields/2 return value, keyed by PROMPT vocabulary.
      source_fields = AITranslatable.source_fields(product, "en")
      assert Map.has_key?(source_fields, "body"), "prompt vocabulary key expected"

      {:ok, updated} =
        AITranslatable.put_translation(
          product,
          "de",
          %{
            "title" => "Holzvase",
            "description" => "Eine schöne Vase",
            "body" => "<p>Körper</p>",
            "seo_title" => "Kaufen"
          },
          source_fields: source_fields
        )

      # Fingerprints are keyed by SCHEMA name — the translation across the
      # two vocabularies is the seam this test exists for.
      assert FP.get(updated.metadata, "de", "title") == FP.hash("Wooden Vase")
      assert FP.get(updated.metadata, "de", "description") == FP.hash("A nice vase")
      assert FP.get(updated.metadata, "de", "body_html") == FP.hash("<p>Body</p>\n")
      assert FP.get(updated.metadata, "de", "seo_title") == FP.hash("Buy It")

      # And the row is immediately fresh — no field left behind.
      refute MapSet.member?(
               AITranslatable.candidates("en", ["de"]) |> MapSet.new(& &1.uuid),
               updated.uuid
             )
    end

    test "categories: same round trip" do
      category =
        create_category(%{
          name: %{"en" => "Vases"},
          description: %{"en" => "Nice vases\n"}
        })

      source_fields = CategoryAITranslatable.source_fields(category, "en")

      {:ok, updated} =
        CategoryAITranslatable.put_translation(
          category,
          "de",
          %{"name" => "Vasen", "description" => "Schöne Vasen"},
          source_fields: source_fields
        )

      assert FP.get(updated.metadata, "de", "name") == FP.hash("Vases")
      assert FP.get(updated.metadata, "de", "description") == FP.hash("Nice vases\n")

      refute MapSet.member?(
               CategoryAITranslatable.candidates("en", ["de"]) |> MapSet.new(& &1.uuid),
               updated.uuid
             )
    end
  end
end
