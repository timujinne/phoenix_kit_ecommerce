defmodule PhoenixKitEcommerce.API.LoaderCatalogueTest do
  @moduledoc """
  `API.Loader` on the Catalogue source: the raw item statuses the view-struct
  hides, categories hidden by shop status or deleted, and an archived catalogue.

  `async: false`: `Query.catalogue_uuid/0` resolves the shop's catalogue by name
  across the whole test database.
  """
  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :catalogue

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}
  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue.AttributeSets}
  @compile {:no_warn_undefined, PhoenixKitEntities.EntityData}

  import PhoenixKitEcommerce.SearchFixtures

  alias PhoenixKit.Settings
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.AttributeSets
  alias PhoenixKitEcommerce.API.Loader
  alias PhoenixKitEcommerce.ProductSource.Catalogue, as: CatalogueSource
  alias PhoenixKitEcommerce.ProductSource.Catalogue.Query
  alias PhoenixKitEntities.EntityData

  test "maps the six item states onto the three visibility states" do
    catalogue = catalogue_source!()

    items = %{
      listed: catalogue_item!(catalogue, "Active"),
      inactive: catalogue_item!(catalogue, "Inactive", %{status: "inactive"}),
      deleted: catalogue_item!(catalogue, "Deleted", %{status: "deleted"}),
      discontinued: catalogue_item!(catalogue, "Discontinued", %{status: "discontinued"}),
      draft: catalogue_item!(catalogue, "Draft", %{data: shop_data("draft")}),
      archived: catalogue_item!(catalogue, "Archived", %{data: shop_data("archived")})
    }

    records = items |> Map.values() |> Enum.map(& &1.uuid) |> Loader.load()
    state = fn key -> records[items[key].uuid].state end

    assert state.(:listed) == :listed
    assert state.(:inactive) == :hidden
    assert state.(:deleted) == :hidden
    assert state.(:discontinued) == :discontinued
    assert state.(:draft) == :hidden
    assert state.(:archived) == :discontinued
  end

  test "a category hidden by its shop status hides its products; unlisted does not" do
    catalogue = catalogue_source!()
    hidden = catalogue_category!(catalogue, "Hidden", %{data: shop_data("hidden")})
    unlisted = catalogue_category!(catalogue, "Unlisted", %{data: shop_data("unlisted")})

    in_hidden = catalogue_item!(catalogue, "In hidden", %{category_uuid: hidden.uuid})
    in_unlisted = catalogue_item!(catalogue, "In unlisted", %{category_uuid: unlisted.uuid})

    records = Loader.load([in_hidden.uuid, in_unlisted.uuid])

    assert records[in_hidden.uuid].state == :hidden
    assert records[in_unlisted.uuid].state == :listed
  end

  test "a stored shop status nobody defined hides the product instead of becoming active" do
    catalogue = catalogue_source!()

    items =
      for status <- ["hidden", "Draft", "Active", "", "banana"] do
        {status, catalogue_item!(catalogue, "Odd #{status}", %{data: shop_data(status)})}
      end

    records = Loader.load(Enum.map(items, fn {_status, item} -> item.uuid end))

    for {status, item} <- items do
      assert records[item.uuid].facts.shop_status == status
      assert records[item.uuid].state == :hidden, "shop status #{inspect(status)}"
    end
  end

  test "an item without a stored shop status counts as active" do
    catalogue = catalogue_source!()
    bare = catalogue_item!(catalogue, "Bare", %{data: %{}})

    record = Loader.load([bare.uuid])[bare.uuid]

    assert record.facts.shop_status == "active"
    assert record.state == :listed
  end

  test "a category shop status nobody defined hides its products" do
    catalogue = catalogue_source!()
    odd = catalogue_category!(catalogue, "Odd", %{data: shop_data("Hidden")})
    banana = catalogue_category!(catalogue, "Banana", %{data: shop_data("banana")})
    in_odd = catalogue_item!(catalogue, "In odd", %{category_uuid: odd.uuid})
    in_banana = catalogue_item!(catalogue, "In banana", %{category_uuid: banana.uuid})

    records = Loader.load([in_odd.uuid, in_banana.uuid])

    assert records[in_odd.uuid].facts.category_status == "Hidden"
    assert records[in_odd.uuid].state == :hidden
    assert records[in_banana.uuid].state == :hidden
  end

  test "a product whose category is not in the given snapshot is hidden" do
    catalogue = catalogue_source!()
    category = catalogue_category!(catalogue, "Vases")
    item = catalogue_item!(catalogue, "Vase", %{category_uuid: category.uuid})

    assert Loader.load([item.uuid])[item.uuid].state == :listed

    record = Loader.load([item.uuid], categories: %{})[item.uuid]

    assert record.category == nil
    assert record.facts.category_status == "missing"
    assert record.state == :hidden
  end

  test "categories/0 reports a deleted category as deleted and keeps the stored shop status" do
    catalogue = catalogue_source!()
    shown = catalogue_category!(catalogue, "Shown")
    hidden = catalogue_category!(catalogue, "Hidden", %{data: shop_data("hidden")})
    deleted = catalogue_category!(catalogue, "Deleted")
    :ok = delete_category_directly!(deleted)

    categories = Loader.categories()

    assert categories[shown.uuid].status == "active"
    assert categories[hidden.uuid].status == "hidden"
    assert categories[deleted.uuid].status == "deleted"
  end

  test "the category chain is root first and the item position is a fact" do
    catalogue = catalogue_source!()
    root = catalogue_category!(catalogue, "Root")
    leaf = catalogue_category!(catalogue, "Leaf", %{parent_uuid: root.uuid})
    item = catalogue_item!(catalogue, "Vase", %{category_uuid: leaf.uuid, position: 7})

    record = Loader.load([item.uuid])[item.uuid]

    assert Enum.map(record.chain, & &1.uuid) == [root.uuid, leaf.uuid]
    assert record.category.uuid == leaf.uuid
    assert record.facts.position == 7
  end

  test "source_resolvable?/0 and catalogue_listed?/0 follow the shop catalogue" do
    set_product_source!("catalogue")

    refute Loader.source_resolvable?()
    refute Loader.catalogue_listed?()

    {:ok, catalogue} = Catalogue.create_catalogue(%{name: "decor3dprint"})

    assert Loader.source_resolvable?()
    assert Loader.catalogue_listed?()

    {:ok, _} = Catalogue.update_catalogue(catalogue, %{status: "archived"})

    assert Loader.source_resolvable?()
    refute Loader.catalogue_listed?()
  end

  test "source_resolvable?/0 is always true on the legacy source" do
    assert Loader.source_resolvable?()
  end

  test "another catalogue's items and categories stay out of every read" do
    catalogue = catalogue_source!()
    mine = catalogue_item!(catalogue, "Mine")
    my_category = catalogue_category!(catalogue, "Mine")
    mine_in_category = catalogue_item!(catalogue, "Mine in", %{category_uuid: my_category.uuid})

    {:ok, other} = Catalogue.create_catalogue(%{name: "equipment"})
    foreign = catalogue_item!(other, "Foreign")
    foreign_category = catalogue_category!(other, "Foreign")

    foreign_in_category =
      catalogue_item!(other, "Foreign in", %{category_uuid: foreign_category.uuid})

    assert {:ok, ids} = Loader.all_ids()
    assert Enum.sort(ids) == Enum.sort([mine.uuid, mine_in_category.uuid])

    assert Loader.item_ids_in_categories([foreign_category.uuid]) == []

    assert Enum.sort(Loader.item_ids_in_categories([my_category.uuid, foreign_category.uuid])) ==
             [mine_in_category.uuid]

    records = Loader.load([mine.uuid, foreign.uuid, foreign_in_category.uuid])
    assert Map.keys(records) == [mine.uuid]

    categories = Loader.categories()
    assert Map.has_key?(categories, my_category.uuid)
    refute Map.has_key?(categories, foreign_category.uuid)
  end

  # A separate test, so that a broken fixture here can never hide the
  # hidden/unlisted assertions above.
  test "a category deleted in the catalogue hides its products (after a stray write)" do
    catalogue = catalogue_source!()
    deleted = catalogue_category!(catalogue, "Deleted")
    in_deleted = catalogue_item!(catalogue, "In deleted", %{category_uuid: deleted.uuid})

    assert Loader.load([in_deleted.uuid])[in_deleted.uuid].state == :listed

    :ok = delete_category_directly!(deleted)

    assert Loader.load([in_deleted.uuid])[in_deleted.uuid].state == :hidden
  end

  test "an archived catalogue hides every product" do
    catalogue = catalogue_source!()
    item = catalogue_item!(catalogue, "Vase")

    assert Loader.load([item.uuid])[item.uuid].state == :listed

    {:ok, _} = Catalogue.update_catalogue(catalogue, %{status: "archived"})

    assert Loader.load([item.uuid])[item.uuid].state == :hidden
    refute Loader.catalogue_listed?()
  end

  test "load/2 answers an upper-case id under the canonical lower-case key, once" do
    catalogue = catalogue_source!()
    item = catalogue_item!(catalogue, "Vase")

    assert %{} = records = Loader.load([String.upcase(item.uuid)])
    assert Map.keys(records) == [item.uuid]
    assert records[item.uuid].id == item.uuid
    assert records[item.uuid].state == :listed

    assert Map.keys(Loader.load([String.upcase(item.uuid), item.uuid])) == [item.uuid]
  end

  test "all_ids/0 lists every item of the shop catalogue, whatever its status" do
    catalogue = catalogue_source!()
    a = catalogue_item!(catalogue, "A")
    b = catalogue_item!(catalogue, "B", %{status: "deleted"})

    assert {:ok, ids} = Loader.all_ids()
    assert Enum.sort(ids) == Enum.sort([a.uuid, b.uuid])
    assert Loader.shop_catalogue_uuid() == catalogue.uuid
  end

  test "all_ids/0 reports a missing shop catalogue instead of an empty shop" do
    set_product_source!("catalogue")

    assert Loader.all_ids() == {:error, :no_catalogue}
    assert Loader.shop_catalogue_uuid() == nil
  end

  test "item_ids_in_categories/1 reads the catalogue's items" do
    catalogue = catalogue_source!()
    category = catalogue_category!(catalogue, "Vases")
    inside = catalogue_item!(catalogue, "Inside", %{category_uuid: category.uuid})
    _outside = catalogue_item!(catalogue, "Outside")

    assert Loader.item_ids_in_categories([category.uuid]) == [inside.uuid]
  end

  describe "option labels follow the language" do
    setup do
      AttributeSets.register_deletion_guard()
      Settings.update_setting("entities_enabled", "true")
      on_exit(fn -> Settings.update_setting("entities_enabled", "false") end)
      :ok
    end

    # One attribute set "color" with the value "Red", translated for fr-FR.
    defp item_with_translated_option!(catalogue) do
      item = catalogue_item!(catalogue, "Vase")
      actor = [actor_uuid: Ecto.UUID.generate()]
      {:ok, set} = AttributeSets.create_set(%{name: "Color", slug: "color"}, actor)
      {:ok, value} = AttributeSets.create_value(set, %{label: "Red", slug: "red"}, actor)

      {:ok, _} =
        EntityData.update(
          value,
          %{data: %{"_primary_language" => "en-US", "fr-FR" => %{"_title" => "Rouge"}}},
          activity_log: false
        )

      {:ok, _} = AttributeSets.attach_set(item.uuid, set.uuid)
      :ok = AttributeSets.set_attachment_selection(item.uuid, set.uuid, ["red"])
      item
    end

    defp option_values(product), do: product.metadata["_option_values"]
    defp value_labels(product), do: product.metadata["_value_labels"]

    test "products_for_items/2 labels the options in the language it is given" do
      item = item_with_translated_option!(catalogue_source!())
      items = Query.list_items_by_uuids([item.uuid])

      assert [fr] = CatalogueSource.products_for_items(items, language: "fr-FR")
      assert [en] = CatalogueSource.products_for_items(items, language: "en-US")
      assert [none] = CatalogueSource.products_for_items(items)

      assert option_values(fr) == %{"color" => ["red"]}
      assert option_values(en) == option_values(fr)
      assert option_values(none) == option_values(fr)

      assert value_labels(fr) == %{"color" => %{"red" => "Rouge"}}
      assert value_labels(en) == %{"color" => %{"red" => "Red"}}
      assert value_labels(none) == %{"color" => %{"red" => "Red"}}
    end

    test "load/2 passes its language option on" do
      item = item_with_translated_option!(catalogue_source!())

      fr = Loader.load([item.uuid], language: "fr-FR")[item.uuid]
      en = Loader.load([item.uuid], language: "en-US")[item.uuid]
      none = Loader.load([item.uuid])[item.uuid]

      assert value_labels(fr.product) == %{"color" => %{"red" => "Rouge"}}
      assert value_labels(en.product) == %{"color" => %{"red" => "Red"}}
      assert value_labels(none.product) == %{"color" => %{"red" => "Red"}}
    end
  end

  test "products_for_items/2 keeps the order and builds the same views as list_products_by_ids/1" do
    catalogue = catalogue_source!()
    first = catalogue_item!(catalogue, "First")
    second = catalogue_item!(catalogue, "Second")
    ids = [second.uuid, first.uuid]

    items = Query.list_items_by_uuids(ids)
    products = CatalogueSource.products_for_items(items, language: "en")

    assert Enum.map(products, & &1.uuid) == ids

    assert Enum.map(products, &{&1.uuid, &1.title}) ==
             ids |> CatalogueSource.list_products_by_ids() |> Enum.map(&{&1.uuid, &1.title})
  end
end
