defmodule PhoenixKitEcommerce.API.Public.CatalogCatalogueTest do
  @moduledoc """
  The public catalogue tools on the Catalogue source. `shop.get_products` over
  catalogue items: the item states of the catalogue (active, inactive, deleted,
  discontinued) and the shop statuses of `API.Visibility`, row by row.
  `shop.list_categories` and `shop.similar_products` over the shop's catalogue
  and a second catalogue of the same install.

  `async: false`: the shop's catalogue is found by name across the database.
  """
  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :catalogue

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}

  import PhoenixKitEcommerce.SearchFixtures

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce.API.Public.Catalog
  alias PhoenixKitEcommerce.Search.Indexer
  alias PhoenixKitEcommerce.Test.Repo

  setup do
    disable_languages!()
    currencies!()
    :ok
  end

  test "inactive, deleted and draft items are not found; discontinued and archived ones are stubs" do
    catalogue = catalogue_source!()

    listed = catalogue_item!(catalogue, "Listed")
    inactive = catalogue_item!(catalogue, "Inactive", %{status: "inactive"})
    deleted = catalogue_item!(catalogue, "Deleted", %{status: "deleted"})
    discontinued = catalogue_item!(catalogue, "Discontinued", %{status: "discontinued"})
    draft = catalogue_item!(catalogue, "Draft", %{data: shop_data("draft")})
    archived = catalogue_item!(catalogue, "Archived", %{data: shop_data("archived")})

    ids = Enum.map([listed, inactive, deleted, discontinued, draft, archived], & &1.uuid)

    assert {:ok, out} = Catalog.get_products(%{"ids" => ids}, public_ctx())

    shape =
      Enum.map(out["results"], fn
        %{"product" => %{"status" => status}} -> status
        %{"error" => %{"code" => code}} -> code
      end)

    assert shape == [
             "active",
             "not_found",
             "not_found",
             "discontinued",
             "not_found",
             "discontinued"
           ]

    assert out["summary"] == %{"found" => 1, "discontinued" => 2, "not_found" => 3}

    stub = Enum.at(out["results"], 3)["product"]
    assert Map.keys(stub) |> Enum.sort() == ["id", "status", "title"]
  end

  test "a product in a hidden category is not found; in an unlisted one it is shown" do
    catalogue = catalogue_source!()
    hidden = catalogue_category!(catalogue, "Hidden", %{data: shop_data("hidden")})
    unlisted = catalogue_category!(catalogue, "Unlisted", %{data: shop_data("unlisted")})

    in_hidden = catalogue_item!(catalogue, "In hidden", %{category_uuid: hidden.uuid})
    in_unlisted = catalogue_item!(catalogue, "In unlisted", %{category_uuid: unlisted.uuid})

    assert {:ok, out} =
             Catalog.get_products(%{"ids" => [in_hidden.uuid, in_unlisted.uuid]}, public_ctx())

    assert out["summary"] == %{"found" => 1, "discontinued" => 0, "not_found" => 1}
    assert Enum.at(out["results"], 1)["product"]["id"] == in_unlisted.uuid
  end

  test "a product in a category deleted in the catalogue is not found (after a stray write)" do
    catalogue = catalogue_source!()
    deleted = catalogue_category!(catalogue, "Deleted")
    in_deleted = catalogue_item!(catalogue, "In deleted", %{category_uuid: deleted.uuid})

    assert {:ok, %{"summary" => %{"found" => 1}}} =
             Catalog.get_products(%{"ids" => [in_deleted.uuid]}, public_ctx())

    :ok = delete_category_directly!(deleted)

    assert {:ok, %{"summary" => %{"found" => 0, "not_found" => 1}}} =
             Catalog.get_products(%{"ids" => [in_deleted.uuid]}, public_ctx())
  end

  describe "list_categories and similar_products" do
    setup do
      catalogue = catalogue_source!()
      home = catalogue_category!(catalogue, "Home")

      vases =
        catalogue_category!(catalogue, "Vases", %{
          parent_uuid: home.uuid,
          slug: %{"en" => "vases"}
        })

      backstage = catalogue_category!(catalogue, "Backstage", %{data: shop_data("hidden")})

      vase = catalogue_item!(catalogue, "Red Vase", %{category_uuid: vases.uuid})
      twin = catalogue_item!(catalogue, "Blue Vase", %{category_uuid: vases.uuid})
      _unseen = catalogue_item!(catalogue, "Backstage Vase", %{category_uuid: backstage.uuid})

      {:ok, other} = Catalogue.create_catalogue(%{name: "Warehouse stock"})
      spare_parts = catalogue_category!(other, "Spare parts")
      foreign = catalogue_item!(other, "Spare Vase", %{category_uuid: spare_parts.uuid})

      {:ok, _} = Indexer.rebuild()

      %{catalogue: catalogue, home: home, vases: vases, vase: vase, twin: twin, foreign: foreign}
    end

    defp categories!(overrides \\ []) do
      assert {:ok, out} = Catalog.list_categories(%{}, public_ctx(overrides))
      out
    end

    defp similar!(id) do
      Catalog.similar_products(%{"id" => id}, public_ctx())
    end

    test "list_categories shows the active categories of the shop's catalogue with their counts",
         t do
      out = categories!()

      assert out["count"] == 2
      assert [home] = out["categories"]
      assert home["id"] == t.home.uuid
      assert home["product_count"] == 0
      assert home["total_count"] == 2
      assert [vases] = home["children"]
      assert {vases["id"], vases["name"], vases["product_count"]} == {t.vases.uuid, "Vases", 2}
      assert vases["slug"] == "vases"
      assert String.starts_with?(vases["url"], "https://shop.test/")
      assert String.ends_with?(vases["url"], "/shop/category/vases")
      # "Home" was given no slug: it has no page, so no slug and no url.
      refute Map.has_key?(home, "slug")
      refute Map.has_key?(home, "url")
    end

    test "list_categories of an archived shop catalogue is empty, not a list of empty categories",
         t do
      {:ok, _} = Catalogue.update_catalogue(t.catalogue, %{status: "archived"})

      assert categories!() == %{"categories" => [], "count" => 0}
    end

    test "similar_products finds the other item of the category, in the shop's catalogue only",
         t do
      assert {:ok, %{"items" => items, "count" => 1}} = similar!(t.vase.uuid)
      assert Enum.map(items, & &1["id"]) == [t.twin.uuid]
    end

    test "an item of another catalogue is neither a similar product nor a base, whatever the index holds",
         t do
      # An index row for the foreign item, in the shop's category: stale or planted.
      Repo.query!(
        """
        INSERT INTO phoenix_kit_shop_search_index
          (item_uuid, language, title, title_trgm, document, category_uuid)
        VALUES ($1, 'en', 'Spare Vase', 'spare vase', to_tsvector('simple', 'spare vase'), $2)
        """,
        [Ecto.UUID.dump!(t.foreign.uuid), Ecto.UUID.dump!(t.vases.uuid)]
      )

      assert {:ok, %{"items" => items}} = similar!(t.vase.uuid)
      assert Enum.map(items, & &1["id"]) == [t.twin.uuid]

      assert {:error, :not_found, _message, _context} = similar!(t.foreign.uuid)

      assert {:ok, %{"summary" => %{"not_found" => 1}}} =
               Catalog.get_products(%{"ids" => [t.foreign.uuid]}, public_ctx())
    end
  end
end
