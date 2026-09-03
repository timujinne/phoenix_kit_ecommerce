defmodule Mix.Tasks.PhoenixKitEcommerce.BackfillTranslationFingerprintsTest do
  @moduledoc """
  The one-shot fingerprint backfill (design §4.1, owner's decision
  2026-09-03). Exercises `backfill/4` directly — the piece factored out
  of `run/1` precisely so it's testable against the sandboxed test
  database without going through `Mix.Task.run("app.start")` or a
  separate OS process.

  IMPORTANT: never point this suite (or this task, ever) at the shared
  dev database — it runs against `PhoenixKitEcommerce.Test.Repo`
  exclusively, like every other test in this package.
  """
  use PhoenixKitEcommerce.DataCase, async: false

  alias Mix.Tasks.PhoenixKitEcommerce.BackfillTranslationFingerprints, as: Backfill
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Category
  alias PhoenixKitEcommerce.Product
  alias PhoenixKitEcommerce.TranslationFingerprint, as: FP

  defp create_product(attrs) do
    base = %{price: Decimal.new("10.00"), status: "active"}
    {:ok, product} = Shop.create_product(Map.merge(base, attrs))
    product
  end

  defp create_category(attrs) do
    {:ok, category} = Shop.create_category(attrs)
    category
  end

  describe "backfill/4 — products" do
    test "stamps a fingerprint for every field with both a source and a live translation" do
      product =
        create_product(%{
          title: %{"en" => "Wooden Vase", "de" => "Holzvase"},
          description: %{"en" => "A nice vase", "de" => "Eine schöne Vase"}
        })

      {results, _} = {Backfill.backfill(repo(), "en", ["de"]), :ok}

      assert {"phoenix_kit_shop_products", count} =
               List.keyfind(results, "phoenix_kit_shop_products", 0)

      assert count >= 1

      reloaded = repo().get(Product, product.uuid)

      assert FP.get(reloaded.metadata, "de", "title") == FP.hash("Wooden Vase")
      assert FP.get(reloaded.metadata, "de", "description") == FP.hash("A nice vase")
    end

    test "a field with a translation but no source is left alone" do
      product = create_product(%{title: %{"en" => "Wooden Vase", "de" => "Holzvase"}})

      {:ok, product} =
        product
        |> Ecto.Changeset.change(%{seo_title: %{"de" => "Verwaiste SEO"}})
        |> repo().update()

      Backfill.backfill(repo(), "en", ["de"])

      reloaded = repo().get(Product, product.uuid)
      assert FP.get(reloaded.metadata, "de", "seo_title") == nil
    end

    test "a field with a source but no translation is left alone (still :missing afterward)" do
      product = create_product(%{title: %{"en" => "Wooden Vase"}})

      Backfill.backfill(repo(), "en", ["de"])

      reloaded = repo().get(Product, product.uuid)
      assert FP.get(reloaded.metadata, "de", "title") == nil
    end

    test "OVERWRITES an existing (possibly wrong) fingerprint with a hash of the CURRENT source" do
      # Design §4.1's accepted cost: the backfill is blunt — "whatever is
      # live today is the reference" — so a stale/incorrect fingerprint
      # left over from before this scheme existed must be replaced, not
      # preserved.
      product = create_product(%{title: %{"en" => "Wooden Vase", "de" => "Holzvase"}})

      wrong_metadata = FP.put_many(product.metadata, "de", %{"title" => "not-a-real-hash"})

      {:ok, product} =
        product |> Ecto.Changeset.change(%{metadata: wrong_metadata}) |> repo().update()

      Backfill.backfill(repo(), "en", ["de"])

      reloaded = repo().get(Product, product.uuid)
      assert FP.get(reloaded.metadata, "de", "title") == FP.hash("Wooden Vase")
    end

    test "a fingerprint for a language NOT in target_langs is carried through untouched" do
      product =
        create_product(%{
          title: %{"en" => "Wooden Vase", "de" => "Holzvase", "fr" => "Vase en Bois"}
        })

      fr_metadata = FP.put_many(product.metadata, "fr", %{"title" => "existing-fr-hash"})

      {:ok, product} =
        product |> Ecto.Changeset.change(%{metadata: fr_metadata}) |> repo().update()

      # Only backfilling "de" this time.
      Backfill.backfill(repo(), "en", ["de"])

      reloaded = repo().get(Product, product.uuid)
      assert FP.get(reloaded.metadata, "de", "title") == FP.hash("Wooden Vase")
      assert FP.get(reloaded.metadata, "fr", "title") == "existing-fr-hash"
    end

    test "a product with nothing translated at all is left untouched" do
      product = create_product(%{title: %{"en" => "Untranslated"}})

      Backfill.backfill(repo(), "en", ["de"])

      reloaded = repo().get(Product, product.uuid)
      assert reloaded.metadata == product.metadata
    end
  end

  describe "backfill/4 — categories" do
    test "stamps name/description fingerprints the same way products do" do
      category =
        create_category(%{
          "name" => %{"en" => "Vases", "de" => "Vasen"},
          "description" => %{"en" => "All vases", "de" => "Alle Vasen"}
        })

      Backfill.backfill(repo(), "en", ["de"])

      reloaded = repo().get(Category, category.uuid)
      assert FP.get(reloaded.metadata, "de", "name") == FP.hash("Vases")
      assert FP.get(reloaded.metadata, "de", "description") == FP.hash("All vases")
    end

    test "slug is never fingerprinted (design §4.1 — write-once, not part of the staleness model)" do
      category = create_category(%{"name" => %{"en" => "Vases", "de" => "Vasen"}})

      Backfill.backfill(repo(), "en", ["de"])

      reloaded = repo().get(Category, category.uuid)
      assert FP.get(reloaded.metadata, "de", "slug") == nil
    end
  end

  describe "backfill/4 — dry_run" do
    test "reports the count without writing anything" do
      product = create_product(%{title: %{"en" => "Wooden Vase", "de" => "Holzvase"}})

      results = Backfill.backfill(repo(), "en", ["de"], dry_run: true)

      assert {"phoenix_kit_shop_products", count} =
               List.keyfind(results, "phoenix_kit_shop_products", 0)

      assert count >= 1

      reloaded = repo().get(Product, product.uuid)
      assert FP.get(reloaded.metadata, "de", "title") == nil
    end

    test "dry_run and the real run agree on the affected count" do
      create_product(%{title: %{"en" => "A", "de" => "A-de"}})
      create_product(%{title: %{"en" => "B", "de" => "B-de"}})
      # This one has nothing to stamp — must not inflate either count.
      create_product(%{title: %{"en" => "C, untranslated"}})

      [{_table, dry_count} | _] = Backfill.backfill(repo(), "en", ["de"], dry_run: true)
      [{_table, real_count} | _] = Backfill.backfill(repo(), "en", ["de"], dry_run: false)

      assert dry_count == real_count
    end
  end

  test "is idempotent — running it twice in a row produces the same fingerprints" do
    create_product(%{title: %{"en" => "Wooden Vase", "de" => "Holzvase"}})

    Backfill.backfill(repo(), "en", ["de"])
    first_pass = repo().all(Product) |> Enum.map(& &1.metadata)

    Backfill.backfill(repo(), "en", ["de"])
    second_pass = repo().all(Product) |> Enum.map(& &1.metadata)

    assert first_pass == second_pass
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
