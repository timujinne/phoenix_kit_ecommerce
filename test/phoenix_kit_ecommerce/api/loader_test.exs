defmodule PhoenixKitEcommerce.API.LoaderTest do
  @moduledoc """
  `API.Loader` on the legacy product source (the default; no catalogue needed).
  The catalogue source is covered by `loader_catalogue_test.exs`.
  """
  use PhoenixKitEcommerce.DataCase, async: true

  import PhoenixKitEcommerce.SearchFixtures

  alias PhoenixKitEcommerce.API.Loader
  alias PhoenixKitEcommerce.API.Record

  describe "load/2" do
    test "answers an upper-case id under the canonical lower-case key, once" do
      product = legacy_product!(%{"en" => "Red Vase"})

      records = Loader.load([String.upcase(product.uuid)])

      assert Map.keys(records) == [product.uuid]
      assert records[product.uuid].id == product.uuid
      assert Map.keys(Loader.load([String.upcase(product.uuid), product.uuid])) == [product.uuid]
    end

    test "returns a listed record with its category chain, root first" do
      root = legacy_category!(%{"en" => "Home"})
      leaf = legacy_category!(%{"en" => "Vases"}, %{parent_uuid: root.uuid})
      product = legacy_product!(%{"en" => "Red Vase"}, %{category_uuid: leaf.uuid})

      assert %Record{id: id, state: :listed} = record = Loader.load([product.uuid])[product.uuid]
      assert id == product.uuid
      assert record.product.uuid == product.uuid
      assert Enum.map(record.chain, & &1.uuid) == [root.uuid, leaf.uuid]
      assert record.category.uuid == leaf.uuid
      assert record.facts.item_status == "active"
      assert record.facts.shop_status == "active"
      assert record.facts.category_status == "active"
    end

    test "catalogue_listed?/0 is true on the legacy source, where no catalogue is involved" do
      assert Loader.catalogue_listed?()
    end

    test "unknown and malformed ids are absent, never an error" do
      assert Loader.load(["not-a-uuid", Ecto.UUID.generate(), nil, 42]) == %{}
      assert Loader.load([]) == %{}
    end

    test "a 16-byte string is no id, even when its bytes are those of a product's uuid" do
      {product, raw} = raw_uuid_product!(%{"en" => "Red Vase"})
      category = legacy_category!(%{"en" => "Vases"})
      in_category = legacy_product!(%{"en" => "Blue Vase"}, %{category_uuid: category.uuid})
      assert byte_size(raw) == 16
      assert {:ok, product.uuid} == Ecto.UUID.cast(raw)

      assert Loader.load([raw]) == %{}
      assert Map.keys(Loader.load([raw, product.uuid])) == [product.uuid]

      # the category does hold a product: only the 16-byte form of its id finds nothing
      assert Loader.item_ids_in_categories([category.uuid]) == [in_category.uuid]
      assert Loader.item_ids_in_categories([Ecto.UUID.dump!(category.uuid)]) == []
    end

    test "canonical_uuid/1 is the lower-case form of a 36-character UUID and nothing else" do
      id = Ecto.UUID.generate()
      assert Loader.canonical_uuid(id) == id
      assert Loader.canonical_uuid(String.upcase(id)) == id
      assert Loader.canonical_uuid(Ecto.UUID.bingenerate()) == nil
      assert Loader.canonical_uuid(String.replace(id, "-", "")) == nil
      assert Loader.canonical_uuid(id <> " ") == nil
      assert Loader.canonical_uuid(nil) == nil
      assert Loader.canonical_uuid(42) == nil
    end

    test "a draft product is hidden and an archived one is a stub" do
      draft = legacy_product!(%{"en" => "Draft"}, %{status: "draft"})
      archived = legacy_product!(%{"en" => "Archived"}, %{status: "archived"})
      active = legacy_product!(%{"en" => "Active"})

      records = Loader.load([draft.uuid, archived.uuid, active.uuid])

      assert records[draft.uuid].state == :hidden
      assert records[archived.uuid].state == :discontinued
      assert records[active.uuid].state == :listed
    end

    test "a hidden category hides its products; an unlisted one does not" do
      hidden = legacy_category!(%{"en" => "Hidden"}, %{status: "hidden"})
      unlisted = legacy_category!(%{"en" => "Unlisted"}, %{status: "unlisted"})
      in_hidden = legacy_product!(%{"en" => "In hidden"}, %{category_uuid: hidden.uuid})
      in_unlisted = legacy_product!(%{"en" => "In unlisted"}, %{category_uuid: unlisted.uuid})

      records = Loader.load([in_hidden.uuid, in_unlisted.uuid])

      assert records[in_hidden.uuid].state == :hidden
      assert records[in_unlisted.uuid].state == :listed
    end

    test "uses the categories it is given instead of loading them again" do
      category = legacy_category!(%{"en" => "Vases"})
      product = legacy_product!(%{"en" => "Vase"}, %{category_uuid: category.uuid})

      record = Loader.load([product.uuid], categories: %{})[product.uuid]

      assert record.category == nil
      assert record.chain == []
      # A category the snapshot does not know cannot be shown to be visible.
      assert record.facts.category_status == "missing"
      assert record.state == :hidden
    end
  end

  describe "ids and categories" do
    test "all_ids/0 lists every product id" do
      a = legacy_product!(%{"en" => "A"})
      b = legacy_product!(%{"en" => "B"}, %{status: "draft"})

      assert {:ok, ids} = Loader.all_ids()
      assert Enum.sort(ids) == Enum.sort([a.uuid, b.uuid])
    end

    test "shop_catalogue_uuid/0 is nil on the legacy source" do
      assert Loader.shop_catalogue_uuid() == nil
    end

    test "categories/0 returns every category by uuid, hidden ones included" do
      shown = legacy_category!(%{"en" => "Shown"})
      hidden = legacy_category!(%{"en" => "Hidden"}, %{status: "hidden"})

      categories = Loader.categories()

      assert Map.keys(categories) |> Enum.sort() == Enum.sort([shown.uuid, hidden.uuid])
      assert categories[hidden.uuid].status == "hidden"
    end

    test "item_ids_in_categories/1 lists the products of those categories" do
      one = legacy_category!(%{"en" => "One"})
      two = legacy_category!(%{"en" => "Two"})
      a = legacy_product!(%{"en" => "A"}, %{category_uuid: one.uuid})
      _b = legacy_product!(%{"en" => "B"}, %{category_uuid: two.uuid})

      assert Loader.item_ids_in_categories([one.uuid]) == [a.uuid]
      assert Loader.item_ids_in_categories([]) == []
      assert Loader.item_ids_in_categories(["not-a-uuid"]) == []
    end
  end

  describe "chain/2 and subtree_uuids/2" do
    @cats %{
      "a" => %{uuid: "a", parent_uuid: nil},
      "b" => %{uuid: "b", parent_uuid: "a"},
      "c" => %{uuid: "c", parent_uuid: "b"},
      "d" => %{uuid: "d", parent_uuid: "a"}
    }

    test "chain/2 is root first and empty for no category" do
      assert Loader.chain(@cats["c"], @cats) |> Enum.map(& &1.uuid) == ["a", "b", "c"]
      assert Loader.chain(nil, @cats) == []
    end

    test "chain/2 stops at the first repeated category" do
      cyclic = %{
        "x" => %{uuid: "x", parent_uuid: "y"},
        "y" => %{uuid: "y", parent_uuid: "x"},
        "s" => %{uuid: "s", parent_uuid: "s"}
      }

      assert Loader.chain(cyclic["x"], cyclic) |> Enum.map(& &1.uuid) == ["y", "x"]
      assert Loader.chain(cyclic["s"], cyclic) |> Enum.map(& &1.uuid) == ["s"]
    end

    test "chain/2 stops after 20 levels of an endless parent line" do
      long = Map.new(1..30, &{"c#{&1}", %{uuid: "c#{&1}", parent_uuid: "c#{&1 + 1}"}})

      assert length(Loader.chain(long["c1"], long)) == 20
    end

    test "subtree_uuids/2 is the root and every descendant, once" do
      assert Loader.subtree_uuids("a", @cats) |> Enum.sort() == ["a", "b", "c", "d"]
      assert Loader.subtree_uuids("b", @cats) |> Enum.sort() == ["b", "c"]
      assert Loader.subtree_uuids("zzz", @cats) == ["zzz"]
    end

    test "subtree_uuids/2 survives a cycle" do
      cyclic = %{
        "x" => %{uuid: "x", parent_uuid: "y"},
        "y" => %{uuid: "y", parent_uuid: "x"}
      }

      assert Loader.subtree_uuids("x", cyclic) |> Enum.sort() == ["x", "y"]
    end
  end
end
