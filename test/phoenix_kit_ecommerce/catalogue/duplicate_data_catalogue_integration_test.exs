defmodule PhoenixKitEcommerce.Catalogue.DuplicateDataCatalogueIntegrationTest do
  @moduledoc """
  A catalogue copy — the item Duplicate and a whole catalogue's — goes
  through `PhoenixKitCatalogue.Extensions.duplicate_data/2`, which asks
  this extension what the copy keeps: never the Shopify link, which the
  collection and media syncs match items by.

  Needs `phoenix_kit_catalogue` with the `duplicate_data/2` hook —
  excluded via `test_helper.exs`'s `:catalogue` tag whenever the
  optional dependency isn't present, and skipped when the catalogue
  loaded is older than the hook. Bridge in via
  `PHOENIX_KIT_CATALOGUE_PATH`/`PHOENIX_KIT_ENTITIES_PATH` to run it
  locally.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :catalogue

  # An older catalogue has no hook: the behaviour under test doesn't
  # exist there, which is a skip, not a failure.
  unless Code.ensure_loaded?(PhoenixKitCatalogue.Extensions) and
           function_exported?(PhoenixKitCatalogue.Extensions, :duplicate_data, 2) do
    @moduletag skip: "phoenix_kit_catalogue predates the duplicate_data/2 hook"
  end

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}

  alias PhoenixKitCatalogue.Catalogue

  @shop %{
    "shop_status" => "active",
    "vendor" => "Acme",
    "shopify" => %{"product_id" => "8123", "handle" => "oak-door"}
  }

  setup do
    {:ok, catalogue} = Catalogue.create_catalogue(%{name: "Copy source"})

    {:ok, item} =
      Catalogue.create_item(%{
        name: "Oak door",
        catalogue_uuid: catalogue.uuid,
        data: %{"ecommerce" => @shop}
      })

    %{catalogue: catalogue, item: item}
  end

  test "the item Duplicate leaves the Shopify link on the original", %{item: item} do
    {:ok, copy} = Catalogue.duplicate_item(item)

    assert copy.data["ecommerce"] == %{"shop_status" => "active", "vendor" => "Acme"}
    assert Catalogue.get_item(item.uuid).data["ecommerce"] == @shop
  end

  test "a category copy leaves the collection id and its items' product ids behind" do
    {:ok, catalogue} = Catalogue.create_catalogue(%{name: "Collections"})

    {:ok, category} =
      Catalogue.create_category(%{
        name: "Doors",
        catalogue_uuid: catalogue.uuid,
        data: %{
          "ecommerce" => %{"shop_status" => "active", "shopify" => %{"collection_id" => "77"}}
        }
      })

    {:ok, _item} =
      Catalogue.create_item(%{
        name: "Door",
        category_uuid: category.uuid,
        data: %{"ecommerce" => @shop}
      })

    {:ok, %{category: copy}} = Catalogue.duplicate_category(category)
    [copied_item] = Catalogue.list_items_for_category(copy.uuid)

    assert copy.data["ecommerce"] == %{"shop_status" => "active"}
    refute Map.has_key?(copied_item.data["ecommerce"], "shopify")
  end

  test "a whole catalogue's copy does the same", %{catalogue: catalogue} do
    {:ok, %{catalogue: copy}} = Catalogue.duplicate_catalogue(catalogue)
    [copied] = Catalogue.list_items_for_catalogue(copy.uuid)

    refute Map.has_key?(copied.data["ecommerce"], "shopify")
    assert copied.data["ecommerce"]["vendor"] == "Acme"
  end
end
