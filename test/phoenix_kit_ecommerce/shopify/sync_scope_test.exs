defmodule PhoenixKitEcommerce.Shopify.SyncScopeTest do
  @moduledoc """
  `PhoenixKitEcommerce.Shopify.SyncScope` — the operator-configured
  allowlist deciding which UNMATCHED Shopify products
  `Workers.ShopifyMediaSyncWorker` and `Shopify.Sync.check/2` treat as
  "missing from the catalogue" versus "out of scope, ignore".

  `in_scope?/2`/`partition/2`/`filtered?/1` are pure — covered without
  touching the database. `get/0`/`put/1` round-trip through the real
  `phoenix_kit_shop_config` table, same as `CollectionSyncTest`'s own
  `"shopify_collections_filter"` coverage — `async: true` is safe: each
  test uses its own sandboxed connection and this key is never read by
  any OTHER test module concurrently.
  """

  use PhoenixKitEcommerce.DataCase, async: true

  alias PhoenixKitEcommerce.ShopConfig
  alias PhoenixKitEcommerce.Shopify.SyncScope
  alias PhoenixKitEcommerce.Test.Repo

  describe "in_scope?/2 — mode: all" do
    test "every product is in scope, regardless of tags/product_type" do
      scope = SyncScope.all()
      assert SyncScope.in_scope?(%{"tags" => "", "product_type" => ""}, scope)
      assert SyncScope.in_scope?(%{}, scope)
    end
  end

  describe "in_scope?/2 — mode: filtered, both lists empty" do
    test "behaves like all()" do
      scope = %{mode: :filtered, tags: [], product_types: []}
      assert SyncScope.in_scope?(%{"tags" => "random"}, scope)
      assert SyncScope.in_scope?(%{}, scope)
    end
  end

  describe "in_scope?/2 — mode: filtered, tags only" do
    setup do
      %{scope: %{mode: :filtered, tags: ["catalog-3d", "Featured"], product_types: []}}
    end

    test "matches a product carrying one of the tags (comma-separated string)", %{scope: scope} do
      assert SyncScope.in_scope?(%{"tags" => "gift, catalog-3d, sale"}, scope)
    end

    test "matches case-insensitively and trims whitespace", %{scope: scope} do
      assert SyncScope.in_scope?(%{"tags" => "  FEATURED  "}, scope)
    end

    test "matches when tags already arrive as a list", %{scope: scope} do
      assert SyncScope.in_scope?(%{"tags" => ["catalog-3d"]}, scope)
    end

    test "rejects a product with none of the tags", %{scope: scope} do
      refute SyncScope.in_scope?(%{"tags" => "gift, sale"}, scope)
    end

    test "rejects a product with no tags at all", %{scope: scope} do
      refute SyncScope.in_scope?(%{"tags" => nil}, scope)
      refute SyncScope.in_scope?(%{}, scope)
    end
  end

  describe "in_scope?/2 — mode: filtered, product_types only" do
    setup do
      %{scope: %{mode: :filtered, tags: [], product_types: ["Mug", "Poster"]}}
    end

    test "matches a listed product_type, case-insensitively", %{scope: scope} do
      assert SyncScope.in_scope?(%{"product_type" => "mug"}, scope)
    end

    test "rejects an unlisted product_type", %{scope: scope} do
      refute SyncScope.in_scope?(%{"product_type" => "Frame"}, scope)
    end

    test "rejects a missing product_type", %{scope: scope} do
      refute SyncScope.in_scope?(%{}, scope)
    end
  end

  describe "in_scope?/2 — mode: filtered, both tags and product_types" do
    setup do
      %{scope: %{mode: :filtered, tags: ["catalog-3d"], product_types: ["Mug"]}}
    end

    test "requires BOTH to match", %{scope: scope} do
      assert SyncScope.in_scope?(%{"tags" => "catalog-3d", "product_type" => "Mug"}, scope)
      refute SyncScope.in_scope?(%{"tags" => "catalog-3d", "product_type" => "Poster"}, scope)
      refute SyncScope.in_scope?(%{"tags" => "other", "product_type" => "Mug"}, scope)
    end
  end

  describe "partition/2" do
    test "splits products, preserving relative order on each side" do
      scope = %{mode: :filtered, tags: ["catalog-3d"], product_types: []}

      a = %{"handle" => "a", "tags" => "catalog-3d"}
      b = %{"handle" => "b", "tags" => "other"}
      c = %{"handle" => "c", "tags" => "catalog-3d,other"}

      assert {[^a, ^c], [^b]} = SyncScope.partition([a, b, c], scope)
    end
  end

  describe "filtered?/1" do
    test "true only for mode: :filtered" do
      assert SyncScope.filtered?(%{mode: :filtered, tags: [], product_types: []})
      refute SyncScope.filtered?(%{mode: :all, tags: [], product_types: []})
    end
  end

  describe "get/0" do
    test "defaults to all() when never configured" do
      assert SyncScope.get() == SyncScope.all()
    end

    test "tolerates a malformed stored value by reading as all()" do
      %ShopConfig{}
      |> ShopConfig.changeset(%{key: "shopify_sync_scope", value: %{"value" => "garbage"}})
      |> Repo.insert!()

      assert SyncScope.get() == SyncScope.all()
    end

    test "drops non-string tag/product-type entries instead of raising" do
      %ShopConfig{}
      |> ShopConfig.changeset(%{
        key: "shopify_sync_scope",
        value: %{
          "value" => %{
            "mode" => "filtered",
            "tags" => ["catalog-3d", %{"x" => 1}, 7],
            "product_types" => [["Mug"], "Poster"]
          }
        }
      })
      |> Repo.insert!()

      assert SyncScope.get() == %{
               mode: :filtered,
               tags: ["catalog-3d"],
               product_types: ["Poster"]
             }
    end

    test "tolerates an unrecognized mode by reading as all()" do
      %ShopConfig{}
      |> ShopConfig.changeset(%{
        key: "shopify_sync_scope",
        value: %{"value" => %{"mode" => "bogus"}}
      })
      |> Repo.insert!()

      assert SyncScope.get() == SyncScope.all()
    end
  end

  describe "put/1 and get/0 round-trip" do
    test "persists a filtered scope, normalizing tags/product_types" do
      assert {:ok, scope} =
               SyncScope.put(%{
                 "mode" => "filtered",
                 "tags" => [" catalog-3d ", "catalog-3d", ""],
                 "product_types" => "Mug, Poster,, Mug"
               })

      assert scope == %{mode: :filtered, tags: ["catalog-3d"], product_types: ["Mug", "Poster"]}
      assert SyncScope.get() == scope
    end

    test "persists mode: all, dropping any stray tags/product_types" do
      assert {:ok, scope} =
               SyncScope.put(%{"mode" => "all", "tags" => ["ignored"], "product_types" => []})

      assert scope == SyncScope.all()
      assert SyncScope.get() == SyncScope.all()
    end

    test "a second put/1 updates the existing row rather than inserting a second one" do
      assert {:ok, _} = SyncScope.put(%{"mode" => "all"})
      assert {:ok, _} = SyncScope.put(%{"mode" => "filtered", "tags" => ["a"]})

      assert Repo.get(ShopConfig, "shopify_sync_scope") |> then(& &1.value)
      assert SyncScope.get() == %{mode: :filtered, tags: ["a"], product_types: []}
    end

    test "refuses an invalid mode" do
      assert SyncScope.put(%{"mode" => "everything"}) == {:error, :invalid_mode}
      assert SyncScope.get() == SyncScope.all()
    end
  end
end
