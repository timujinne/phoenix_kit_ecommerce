defmodule PhoenixKitEcommerce.Workers.SearchWorkersTest do
  use PhoenixKitEcommerce.DataCase, async: true

  import PhoenixKitEcommerce.SearchFixtures

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Search.Entry
  alias PhoenixKitEcommerce.Search.Indexer
  alias PhoenixKitEcommerce.Test.Repo
  alias PhoenixKitEcommerce.Workers.SearchRebuildWorker
  alias PhoenixKitEcommerce.Workers.SearchReindexWorker

  defp perform(worker, args), do: worker.perform(%Oban.Job{args: args})

  defp paths do
    Repo.all(from(e in Entry, order_by: e.title, select: {e.title, e.category_path}))
  end

  test "an item job indexes the product" do
    product = legacy_product!(%{"en" => "Red Vase"})

    assert :ok = perform(SearchReindexWorker, %{"kind" => "item", "uuid" => product.uuid})

    assert paths() == [{"Red Vase", []}]
  end

  test "an items job indexes every product in it" do
    a = legacy_product!(%{"en" => "Alpha Vase"})
    b = legacy_product!(%{"en" => "Beta Vase"})

    assert :ok = perform(SearchReindexWorker, %{"kind" => "items", "uuids" => [a.uuid, b.uuid]})

    assert Enum.map(paths(), &elem(&1, 0)) == ["Alpha Vase", "Beta Vase"]
  end

  test "a category job re-indexes every product in the category's subtree" do
    root = legacy_category!(%{"en" => "Home"})
    leaf = legacy_category!(%{"en" => "Vases"}, %{parent_uuid: root.uuid})
    inside = legacy_product!(%{"en" => "Red Vase"}, %{category_uuid: leaf.uuid})
    _outside = legacy_product!(%{"en" => "Loose Bowl"})
    {:ok, _} = Indexer.reindex_items([inside.uuid])
    assert paths() == [{"Red Vase", ["Home", "Vases"]}]

    {:ok, _} = Shop.update_category(root, %{name: %{"en" => "Shop"}})

    assert :ok = perform(SearchReindexWorker, %{"kind" => "category", "uuid" => root.uuid})

    # The subtree was re-indexed; the product outside it was not touched (and was never indexed).
    assert paths() == [{"Red Vase", ["Shop", "Vases"]}]
  end

  test "a job nobody understands is cancelled, not retried" do
    assert {:cancel, reason} = perform(SearchReindexWorker, %{"kind" => "mystery"})
    assert reason =~ "unknown search job"
  end

  test "a rebuild job rebuilds the whole index" do
    _product = legacy_product!(%{"en" => "Red Vase"})

    assert :ok = perform(SearchRebuildWorker, %{})

    assert paths() == [{"Red Vase", []}]
    assert Repo.aggregate(Entry, :count) == 1
  end

  test "a rebuild job for a catalogue that is not the shop's is skipped" do
    _product = legacy_product!(%{"en" => "Red Vase"})

    assert :ok = perform(SearchRebuildWorker, %{"catalogue_uuid" => Ecto.UUID.generate()})

    assert paths() == []
  end

  test "a rebuild job does nothing while the shop module is switched off" do
    _product = legacy_product!(%{"en" => "Red Vase"})
    {:ok, _} = PhoenixKit.Settings.update_setting("shop_enabled", "false")

    assert :ok = perform(SearchRebuildWorker, %{})
    assert :ok = perform(SearchRebuildWorker, %{"catalogue_uuid" => Ecto.UUID.generate()})

    assert paths() == []
  end

  test "a reindex job does nothing while the shop module is switched off" do
    product = legacy_product!(%{"en" => "Red Vase"})
    root = legacy_category!(%{"en" => "Home"})
    {:ok, _} = PhoenixKit.Settings.update_setting("shop_enabled", "false")

    assert :ok = perform(SearchReindexWorker, %{"kind" => "item", "uuid" => product.uuid})
    assert :ok = perform(SearchReindexWorker, %{"kind" => "items", "uuids" => [product.uuid]})
    assert :ok = perform(SearchReindexWorker, %{"kind" => "category", "uuid" => root.uuid})

    assert paths() == []
  end

  test "both workers use the shop_search queue and a rebuild is unique" do
    assert to_string(SearchReindexWorker.new(%{}).changes.queue) == "shop_search"
    assert to_string(SearchRebuildWorker.new(%{}).changes.queue) == "shop_search"
    assert %{changes: %{unique: unique}} = SearchRebuildWorker.new(%{})
    assert unique.period == 120
  end
end
