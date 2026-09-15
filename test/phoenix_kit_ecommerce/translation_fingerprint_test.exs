defmodule PhoenixKitEcommerce.TranslationFingerprintTest do
  @moduledoc """
  Pure-function coverage for the staleness model (design §4.1, §4.4):
  hashing, the four states, resource-level folding, write-narrowing, and
  the metadata accessors fingerprints live under. Plain `ExUnit.Case` —
  none of this touches the database, and under `DataCase` it would
  inherit `@moduletag :integration` and be skipped on a checkout without
  PostgreSQL.

  The hash-in-the-database candidate query
  (`TranslationFingerprint.select_candidates/2`) and the
  `AITranslatable.put_translation/4` write path it feeds are covered in
  `PhoenixKitEcommerce.AITranslatableTest` instead — both need real rows.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.TranslationFingerprint, as: FP

  describe "hash/1" do
    test "trims before hashing — leading/trailing whitespace doesn't change the source" do
      assert FP.hash("Wooden Vase") == FP.hash("  Wooden Vase  ")
      assert FP.hash("Wooden Vase") == FP.hash("\nWooden Vase\t")
    end

    test "different text hashes differently" do
      refute FP.hash("Wooden Vase") == FP.hash("Wooden Vase.")
    end

    test "internal whitespace is NOT normalized — trim/1 only (design §4.1)" do
      # "considering text unchanged when it changed is worse than an
      # occasional extra translation" — only the outer whitespace is
      # stripped, not internal collapsing/HTML canonicalization.
      refute FP.hash("Wooden  Vase") == FP.hash("Wooden Vase")
    end

    test "handles unicode source text" do
      assert is_binary(FP.hash("Кашпо Деревянное"))
      assert FP.hash("Größe Fußball") == FP.hash("Größe Fußball")
      refute FP.hash("Größe Fußball") == FP.hash("Grosse Fussball")
    end

    test "returns a 64-char lowercase hex digest" do
      digest = FP.hash("anything")
      assert String.length(digest) == 64
      assert digest == String.downcase(digest)
      assert digest =~ ~r/^[0-9a-f]{64}$/
    end
  end

  describe "field_state/3 — the four states" do
    test "blank or missing source has NO state (nil), regardless of translation/fingerprint" do
      assert FP.field_state(nil, "Vase", FP.hash("Vase")) == nil
      assert FP.field_state("", "Vase", FP.hash("Vase")) == nil
      assert FP.field_state("   ", nil, nil) == nil
    end

    test ":missing — source present, no translation yet" do
      assert FP.field_state("Vase", nil, nil) == :missing
      assert FP.field_state("Vase", "", nil) == :missing
      # even with a leftover fingerprint from a since-cleared translation
      assert FP.field_state("Vase", nil, FP.hash("Vase")) == :missing
    end

    test ":unknown — translation exists, no fingerprint at all" do
      assert FP.field_state("Vase", "Vase (translated)", nil) == :unknown
    end

    test ":stale — translation and fingerprint exist, but the source moved on" do
      old_fp = FP.hash("Vase")
      assert FP.field_state("Vase v2", "Vase (translated)", old_fp) == :stale
    end

    test ":fresh — translation exists and its fingerprint matches the current source" do
      fp = FP.hash("Vase")
      assert FP.field_state("Vase", "Vase (translated)", fp) == :fresh
    end

    test "fresh comparison also trims the source, matching hash/1" do
      fp = FP.hash("Vase")
      assert FP.field_state("  Vase  ", "Vase (translated)", fp) == :fresh
    end
  end

  describe "fold/1 — resource-level state" do
    test "worst state wins: missing > stale > unknown > fresh" do
      assert FP.fold([:fresh, :stale]) == :stale
      assert FP.fold([:fresh, :unknown]) == :unknown
      assert FP.fold([:unknown, :stale]) == :stale
      assert FP.fold([:missing, :fresh, :stale, :unknown]) == :missing
    end

    test "nil (no-source) fields don't participate" do
      assert FP.fold([nil, :fresh]) == :fresh
      assert FP.fold([nil, :stale, nil]) == :stale
    end

    test "all fields nil ⇒ the resource itself has no state" do
      assert FP.fold([nil, nil]) == nil
      assert FP.fold([]) == nil
    end

    test "single state folds to itself" do
      assert FP.fold([:fresh]) == :fresh
    end
  end

  describe "write_decision/3 — design §4.4's table" do
    test "no translation yet ⇒ write + fingerprint" do
      assert FP.write_decision("Vase", nil, nil) == {:write, FP.hash("Vase")}
      assert FP.write_decision("Vase", "", nil) == {:write, FP.hash("Vase")}
    end

    test "no fingerprint yet (unknown) ⇒ write + fingerprint, even though a translation exists" do
      assert FP.write_decision("Vase", "Vase (old)", nil) == {:write, FP.hash("Vase")}
    end

    test "source changed since the fingerprint was taken ⇒ write + new fingerprint" do
      old_fp = FP.hash("Vase")

      assert FP.write_decision("Vase v2", "Vase (translated)", old_fp) ==
               {:write, FP.hash("Vase v2")}
    end

    test "fingerprint matches and a translation exists ⇒ skip (the manual-edit protection)" do
      fp = FP.hash("Vase")
      assert FP.write_decision("Vase", "Vase, hand-edited by an operator", fp) == :skip
    end

    test "no source supplied at all (legacy caller) ⇒ unconditional write, no fingerprint stamped" do
      assert FP.write_decision(nil, "old translation", FP.hash("whatever")) == {:write, nil}
      assert FP.write_decision(nil, nil, nil) == {:write, nil}
    end
  end

  describe "metadata accessors — get/3, put_many/3, drop/3" do
    test "get/3 on nil or empty metadata returns nil" do
      assert FP.get(nil, "de-DE", "title") == nil
      assert FP.get(%{}, "de-DE", "title") == nil
    end

    test "put_many/3 then get/3 round-trips" do
      metadata = FP.put_many(%{}, "de-DE", %{"title" => "abc123"})
      assert FP.get(metadata, "de-DE", "title") == "abc123"
    end

    test "put_many/3 merges into an existing language without disturbing sibling fields" do
      metadata = %{
        "_translation_fingerprints" => %{"de-DE" => %{"title" => "old-title-hash"}}
      }

      updated = FP.put_many(metadata, "de-DE", %{"description" => "desc-hash"})

      assert FP.get(updated, "de-DE", "title") == "old-title-hash"
      assert FP.get(updated, "de-DE", "description") == "desc-hash"
    end

    test "put_many/3 doesn't disturb a sibling language" do
      metadata = %{"_translation_fingerprints" => %{"fr-FR" => %{"title" => "fr-hash"}}}
      updated = FP.put_many(metadata, "de-DE", %{"title" => "de-hash"})

      assert FP.get(updated, "fr-FR", "title") == "fr-hash"
      assert FP.get(updated, "de-DE", "title") == "de-hash"
    end

    test "put_many/3 with an empty map is a no-op" do
      metadata = %{"_translation_fingerprints" => %{"de-DE" => %{"title" => "x"}}}
      assert FP.put_many(metadata, "de-DE", %{}) == metadata
    end

    test "drop/3 erases exactly the requested field/lang pairs" do
      metadata = %{
        "_translation_fingerprints" => %{
          "de-DE" => %{"title" => "t-de", "description" => "d-de"},
          "fr-FR" => %{"title" => "t-fr"}
        }
      }

      updated = FP.drop(metadata, ["de-DE"], ["title"])

      assert FP.get(updated, "de-DE", "title") == nil
      # sibling field, same language — untouched
      assert FP.get(updated, "de-DE", "description") == "d-de"
      # sibling language — untouched
      assert FP.get(updated, "fr-FR", "title") == "t-fr"
    end

    test "drop/3 removes an emptied-out language key entirely rather than leaving {}" do
      metadata = %{
        "_translation_fingerprints" => %{
          "de-DE" => %{"title" => "t-de"},
          "fr-FR" => %{"title" => "t-fr"}
        }
      }

      updated = FP.drop(metadata, ["de-DE"], ["title"])

      refute Map.has_key?(updated["_translation_fingerprints"], "de-DE")
      assert Map.has_key?(updated["_translation_fingerprints"], "fr-FR")
    end

    test "drop/3 removes the top-level key entirely once every language is empty" do
      metadata = %{"_translation_fingerprints" => %{"de-DE" => %{"title" => "t-de"}}}
      updated = FP.drop(metadata, ["de-DE"], ["title"])

      refute Map.has_key?(updated, "_translation_fingerprints")
    end

    test "drop/3 on nil metadata is a no-op that returns an empty map" do
      assert FP.drop(nil, ["de-DE"], ["title"]) == %{}
    end

    test "drop/3 ignores a language that has no fingerprints at all" do
      metadata = %{"_translation_fingerprints" => %{"de-DE" => %{"title" => "t-de"}}}
      assert FP.drop(metadata, ["fr-FR"], ["title"]) == metadata
    end
  end

  describe "apply_writes/3 — one round of write_decision/3's output" do
    test "a hash stamps, a nil ERASES the fingerprint the field had" do
      metadata = %{
        "_translation_fingerprints" => %{
          "de-DE" => %{"title" => "old-title", "description" => "old-desc"}
        }
      }

      updated = FP.apply_writes(metadata, "de-DE", %{"title" => nil, "description" => "new-desc"})

      # nil erased the entry outright rather than leaving the old hash
      # in place (see apply_writes/3's doc: a retained mismatching
      # fingerprint is a permanent sweep candidate).
      assert FP.get(updated, "de-DE", "title") == nil
      refute Map.has_key?(updated["_translation_fingerprints"]["de-DE"], "title")
      assert FP.get(updated, "de-DE", "description") == "new-desc"
    end

    test "a field left in :unknown by a nil is exactly field_state/3's :unknown" do
      metadata = %{"_translation_fingerprints" => %{"de-DE" => %{"title" => FP.hash("Vase")}}}
      updated = FP.apply_writes(metadata, "de-DE", %{"title" => nil})

      assert FP.field_state("Vase", "Vase (de)", FP.get(updated, "de-DE", "title")) == :unknown
    end

    test "erasing every field of a language cleans the leftovers away" do
      metadata = %{"_translation_fingerprints" => %{"de-DE" => %{"title" => "old"}}}
      assert FP.apply_writes(metadata, "de-DE", %{"title" => nil}) == %{}
    end

    test "other languages and unmentioned fields are untouched" do
      metadata = %{
        "_translation_fingerprints" => %{
          "de-DE" => %{"title" => "old-title", "body_html" => "keep-me"},
          "fr-FR" => %{"title" => "fr-title"}
        }
      }

      updated = FP.apply_writes(metadata, "de-DE", %{"title" => nil})

      assert FP.get(updated, "de-DE", "body_html") == "keep-me"
      assert FP.get(updated, "fr-FR", "title") == "fr-title"
    end

    test "a nil for a field that had no fingerprint changes nothing" do
      metadata = %{"_translation_fingerprints" => %{"de-DE" => %{"title" => "old-title"}}}
      assert FP.apply_writes(metadata, "de-DE", %{"description" => nil}) == metadata
    end

    test "foreign metadata keys survive both the stamp and the erase" do
      metadata = %{
        "_option_values" => %{"keep" => true},
        "_translation_fingerprints" => %{"de-DE" => %{"title" => "old"}}
      }

      updated = FP.apply_writes(metadata, "de-DE", %{"title" => nil, "description" => "d"})
      assert updated["_option_values"] == %{"keep" => true}
    end
  end

  describe "qualify_table/2 — schema-prefix support (Fix E)" do
    test "nil prefix (the default, unprefixed public install) leaves the table name untouched" do
      assert FP.qualify_table("phoenix_kit_shop_products", nil) == "phoenix_kit_shop_products"
    end

    test "a configured prefix schema-qualifies the table name" do
      assert FP.qualify_table("phoenix_kit_shop_products", "custom_schema") ==
               "custom_schema.phoenix_kit_shop_products"
    end
  end

  describe "candidates_sql/2 — the prefix actually reaching the generated SQL (Fix E)" do
    # select_candidates/2 always calls candidates_sql/2 with
    # qualify_table(table, @schema_prefix) applied first — so pinning
    # candidates_sql/2's own FROM clause against an explicitly-qualified
    # table name pins exactly what a prefixed install's sweep tick and
    # management page send to Postgres, without needing a second live
    # database compiled with a different `config :phoenix_kit, :prefix`
    # (that value is read at compile time — see PhoenixKit.SchemaPrefix).
    test "an unqualified (public-install) table name reaches the FROM clause bare" do
      sql = FP.candidates_sql("phoenix_kit_shop_products", ["title"])
      assert sql =~ "FROM phoenix_kit_shop_products AS p"
    end

    test "a schema-qualified table name reaches the FROM clause fully qualified" do
      qualified = FP.qualify_table("phoenix_kit_shop_products", "custom_schema")
      sql = FP.candidates_sql(qualified, ["title"])

      assert sql =~ "FROM custom_schema.phoenix_kit_shop_products AS p"
      refute sql =~ "FROM phoenix_kit_shop_products AS p"
    end
  end
end
