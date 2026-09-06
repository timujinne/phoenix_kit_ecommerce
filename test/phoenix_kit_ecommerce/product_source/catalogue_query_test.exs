defmodule PhoenixKitEcommerce.ProductSource.Catalogue.QueryTest do
  use PhoenixKitEcommerce.DataCase, async: false

  # Needs `phoenix_kit_catalogue` loaded (with its own migrations applied
  # to the test DB) — excluded via `test_helper.exs`'s
  # `ExUnit.configure(exclude: ...)` whenever the optional dependency
  # isn't present. `async: false`: `Query.catalogue_uuid/0` resolves the
  # shop's one catalogue by NAME across the whole test DB, so two async
  # tests both bootstrapping a catalogue named "decor3dprint" would race.
  @moduletag :catalogue

  # Quiets the compiler's static xref check for `mix test` runs where the
  # optional `phoenix_kit_catalogue` dependency isn't declared — every
  # test in this module is excluded in that case (see `test_helper.exs`),
  # so the calls below are never actually reached.
  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce.ProductSource.Catalogue.Query
  alias PhoenixKitEcommerce.ProductSource.Catalogue.View

  setup do
    {:ok, catalogue} = Catalogue.create_catalogue(%{name: "decor3dprint"})
    %{catalogue: catalogue}
  end

  defp create_item(catalogue, attrs) do
    {:ok, item} =
      Catalogue.create_item(Map.merge(%{catalogue_uuid: catalogue.uuid}, attrs))

    item
  end

  describe "list_items/1" do
    test "filters by status (item.status active AND shop_status active) and search", %{
      catalogue: catalogue
    } do
      create_item(catalogue, %{
        name: "Red Vase",
        base_price: Decimal.new("10.00"),
        status: "active",
        data: %{"ecommerce" => %{"shop_status" => "active"}}
      })

      create_item(catalogue, %{
        name: "Blue Vase",
        base_price: Decimal.new("15.00"),
        status: "active",
        data: %{"ecommerce" => %{"shop_status" => "draft"}}
      })

      create_item(catalogue, %{
        name: "Green Bowl",
        base_price: Decimal.new("20.00"),
        status: "active",
        data: %{"ecommerce" => %{"shop_status" => "active"}}
      })

      results = Query.list_items(status: "active", search: "vase")

      assert Enum.map(results, & &1.name) == ["Red Vase"]
    end

    test "filters by price range and vendor", %{catalogue: catalogue} do
      create_item(catalogue, %{
        name: "Cheap",
        base_price: Decimal.new("5.00"),
        data: %{"ecommerce" => %{"shop_status" => "active", "vendor" => "Acme"}}
      })

      create_item(catalogue, %{
        name: "Mid",
        base_price: Decimal.new("15.00"),
        data: %{"ecommerce" => %{"shop_status" => "active", "vendor" => "Acme"}}
      })

      create_item(catalogue, %{
        name: "Pricey",
        base_price: Decimal.new("50.00"),
        data: %{"ecommerce" => %{"shop_status" => "active", "vendor" => "Other"}}
      })

      by_price =
        Query.list_items(price_min: Decimal.new("10.00"), price_max: Decimal.new("20.00"))

      assert Enum.map(by_price, & &1.name) == ["Mid"]

      by_vendor = Query.list_items(vendors: ["Acme"])
      assert Enum.map(by_vendor, & &1.name) |> Enum.sort() == ["Cheap", "Mid"]
    end

    test "paginates and counts", %{catalogue: catalogue} do
      for n <- 1..5 do
        create_item(catalogue, %{
          name: "Item #{n}",
          base_price: Decimal.new("1.00"),
          data: %{"ecommerce" => %{"shop_status" => "active"}}
        })
      end

      assert Query.count_items(status: "active") == 5

      {page1, total} = Query.list_items_with_count(status: "active", page: 1, per_page: 2)
      assert total == 5
      assert length(page1) == 2
    end

    test "status: \"active\" falls back to item.status when shop_status is absent, matching View.product_status/2",
         %{catalogue: catalogue} do
      no_shop_status =
        create_item(catalogue, %{name: "No Shop Status", base_price: Decimal.new("1.00")})

      inactive_item =
        create_item(catalogue, %{
          name: "Inactive",
          base_price: Decimal.new("1.00"),
          status: "inactive"
        })

      results = Query.list_items(status: "active")

      assert no_shop_status.uuid in Enum.map(results, & &1.uuid)
      refute inactive_item.uuid in Enum.map(results, & &1.uuid)
    end
  end

  describe "price_range/1 and vendor_counts/1" do
    test "aggregate over active items", %{catalogue: catalogue} do
      create_item(catalogue, %{
        name: "A",
        base_price: Decimal.new("10.00"),
        data: %{"ecommerce" => %{"shop_status" => "active", "vendor" => "Acme"}}
      })

      create_item(catalogue, %{
        name: "B",
        base_price: Decimal.new("30.00"),
        data: %{"ecommerce" => %{"shop_status" => "active", "vendor" => "Acme"}}
      })

      assert Query.price_range() == {Decimal.new("10.00"), Decimal.new("30.00")}
      assert [%{value: "Acme", count: 2}] = Query.vendor_counts()
    end
  end

  describe "slug lookups" do
    test "get_item_by_slug + View.product_view round-trips a real item", %{catalogue: catalogue} do
      item =
        create_item(catalogue, %{
          name: "Vase Rouge",
          base_price: Decimal.new("23.76"),
          slug: %{"fr-FR" => "vase-rouge"},
          data: %{"ecommerce" => %{"shop_status" => "active"}}
        })

      assert {:ok, found} = Catalogue.get_item_by_slug("vase-rouge", "fr-FR")
      assert found.uuid == item.uuid

      product = View.product_view(found, sets: [])
      assert product.price == Decimal.new("23.76")
    end
  end

  describe "list_categories/1" do
    test "scoped to the shop catalogue", %{catalogue: catalogue} do
      {:ok, category} =
        Catalogue.create_category(%{name: "Vases", catalogue_uuid: catalogue.uuid})

      {:ok, other_catalogue} = Catalogue.create_catalogue(%{name: "Warehouse Stock"})
      Catalogue.create_category(%{name: "Shelving", catalogue_uuid: other_catalogue.uuid})

      assert Enum.map(Query.list_categories(), & &1.name) == [category.name]
    end

    test "status/statuses filter the ecommerce shop_status (active|unlisted|hidden), not the catalogue's own status column",
         %{catalogue: catalogue} do
      {:ok, active} =
        Catalogue.create_category(%{
          name: "Active Cat",
          catalogue_uuid: catalogue.uuid,
          data: %{"ecommerce" => %{"shop_status" => "active"}}
        })

      {:ok, unlisted} =
        Catalogue.create_category(%{
          name: "Unlisted Cat",
          catalogue_uuid: catalogue.uuid,
          data: %{"ecommerce" => %{"shop_status" => "unlisted"}}
        })

      {:ok, hidden} =
        Catalogue.create_category(%{
          name: "Hidden Cat",
          catalogue_uuid: catalogue.uuid,
          data: %{"ecommerce" => %{"shop_status" => "hidden"}}
        })

      assert Enum.map(Query.list_categories(status: "active"), & &1.name) == [active.name]

      assert Query.list_categories(status: ["active", "unlisted"])
             |> Enum.map(& &1.name)
             |> Enum.sort() == Enum.sort([active.name, unlisted.name])

      refute hidden.name in Enum.map(Query.list_categories(status: "active"), & &1.name)
    end

    test "a category with no shop_status defaults to active", %{catalogue: catalogue} do
      {:ok, category} =
        Catalogue.create_category(%{name: "No Shop Status", catalogue_uuid: catalogue.uuid})

      assert Enum.map(Query.list_categories(status: "active"), & &1.name) == [category.name]
    end

    test "a catalogue-deleted category is excluded even with a stale shop_status: active",
         %{catalogue: catalogue} do
      {:ok, deleted} =
        Catalogue.create_category(%{
          name: "Ghost Cat",
          catalogue_uuid: catalogue.uuid,
          status: "deleted",
          data: %{"ecommerce" => %{"shop_status" => "active"}}
        })

      refute deleted.name in Enum.map(Query.list_categories(status: "active"), & &1.name)
    end
  end

  describe "list_items_by_uuids/1 and list_categories_by_uuids/1" do
    test "scoped to the shop catalogue — an item/category from another catalogue is dropped",
         %{catalogue: catalogue} do
      item = create_item(catalogue, %{name: "Ours", base_price: Decimal.new("1.00")})

      {:ok, category} =
        Catalogue.create_category(%{name: "Ours Cat", catalogue_uuid: catalogue.uuid})

      {:ok, other_catalogue} = Catalogue.create_catalogue(%{name: "Warehouse Stock"})

      other_item =
        create_item(other_catalogue, %{name: "Theirs", base_price: Decimal.new("1.00")})

      {:ok, other_category} =
        Catalogue.create_category(%{name: "Theirs Cat", catalogue_uuid: other_catalogue.uuid})

      assert Enum.map(Query.list_items_by_uuids([item.uuid, other_item.uuid]), & &1.uuid) == [
               item.uuid
             ]

      assert Enum.map(
               Query.list_categories_by_uuids([category.uuid, other_category.uuid]),
               & &1.uuid
             ) == [category.uuid]
    end
  end
end
