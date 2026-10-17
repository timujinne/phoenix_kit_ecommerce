defmodule PhoenixKitEcommerce.Catalogue.WriterAttributionTest do
  @moduledoc """
  End to end, against a real catalogue that has the admin API's write
  options: a Shopify sync write names itself in the item's change log, and a
  sync that read an item before someone else wrote to it does not overwrite
  that write (the sync writes only the paths it changed, so the last write
  wins per field).

  Needs a catalogue that ships the admin API: `:catalogue_api`.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :catalogue_api

  alias PhoenixKitEcommerce.API.{SetAvailability, SetPrices}
  alias PhoenixKitEcommerce.APIFixtures, as: F
  alias PhoenixKitEcommerce.Catalogue.Writer

  setup do
    catalogue = F.shop_catalogue!()

    item =
      F.item!(catalogue, %{
        data: %{
          "_primary_language" => "en",
          "ecommerce" => %{
            "shop_status" => "active",
            "vendor" => "Old vendor",
            "shopify" => %{"handle" => "mug", "product_id" => "9001"}
          }
        }
      })

    %{item: item, ctx: F.ctx(F.user!())}
  end

  test "a sync write names the sync in the change log and shows the data it changed", %{
    item: item
  } do
    assert {:ok, _} = Writer.update_from_shopify(item, %{vendor: "New vendor"}, "en")

    entry =
      assert_activity_logged("item.updated",
        resource_uuid: item.uuid,
        metadata_has: %{"via" => "shopify_sync"}
      )

    assert inspect(entry.metadata["changes"]) =~ "vendor"
  end

  test "a sync that read the item before an API write does not overwrite that write",
       %{item: item, ctx: ctx} do
    stale = item

    assert {:ok, _} =
             SetPrices.run(
               %{
                 "items" => [
                   %{"ref" => %{"id" => item.uuid}, "compare_at" => "55.00", "price" => "120.00"}
                 ]
               },
               ctx
             )

    assert {:ok, _} =
             SetAvailability.run(
               %{"items" => [%{"ref" => %{"id" => item.uuid}, "made_to_order" => true}]},
               ctx
             )

    # the sync still holds the item as it was before both writes
    assert {:ok, _} = Writer.update_from_shopify(stale, %{vendor: "New vendor"}, "en")

    reloaded = F.reload!(item)
    ecommerce = reloaded.data["ecommerce"]

    assert ecommerce["vendor"] == "New vendor"
    assert ecommerce["compare_at_price"] == "55.00"
    assert ecommerce["made_to_order"] == true
    assert ecommerce["shopify"]["product_id"] == "9001"
    assert Decimal.equal?(reloaded.base_price, Decimal.new("120.00"))
  end

  test "the other direction: an API write keeps what the sync wrote", %{item: item, ctx: ctx} do
    assert {:ok, _} =
             Writer.update_from_shopify(item, %{vendor: "Synced", tags: ["a", "b"]}, "en")

    assert {:ok, _} =
             SetPrices.run(
               %{"items" => [%{"ref" => %{"id" => item.uuid}, "compare_at" => "9.00"}]},
               ctx
             )

    ecommerce = F.reload!(item).data["ecommerce"]
    assert ecommerce["vendor"] == "Synced"
    assert ecommerce["tags"] == ["a", "b"]
    assert ecommerce["compare_at_price"] == "9.00"
    assert ecommerce["shopify"]["handle"] == "mug"
  end

  test "a price-only sync that read the item before an API write keeps that write", %{
    item: item,
    ctx: ctx
  } do
    stale = item

    assert {:ok, _} =
             SetPrices.run(
               %{
                 "items" => [%{"ref" => %{"id" => item.uuid}, "compare_at" => "55.00"}]
               },
               ctx
             )

    assert {:ok, _} =
             SetAvailability.run(
               %{"items" => [%{"ref" => %{"id" => item.uuid}, "visibility" => "archived"}]},
               ctx
             )

    # a column-only change: nothing in `data` is the sync's to write
    assert {:ok, _} = Writer.update_from_shopify(stale, %{price: Decimal.new("20.00")}, "en")

    reloaded = F.reload!(item)
    ecommerce = reloaded.data["ecommerce"]

    assert Decimal.equal?(reloaded.base_price, Decimal.new("20.00"))
    assert ecommerce["compare_at_price"] == "55.00"
    assert ecommerce["shop_status"] == "archived"
    assert ecommerce["shopify"]["product_id"] == "9001"
  end

  test "a default the sync did not mean to write is not stored" do
    bare =
      F.item!(F.shop_catalogue!(), %{
        data: %{"_primary_language" => "en", "ecommerce" => %{"vendor" => "Old vendor"}}
      })

    assert {:ok, _} = Writer.update_from_shopify(bare, %{vendor: "New vendor"}, "en")

    ecommerce = F.reload!(bare).data["ecommerce"]
    assert ecommerce["vendor"] == "New vendor"
    refute Map.has_key?(ecommerce, "shop_status")
    refute Map.has_key?(ecommerce, "made_to_order")
  end

  test "image ids written by the media sync keep their own attribution and name the actor", %{
    item: item
  } do
    product = %{"id" => 9001, "images" => []}
    user = F.user!()

    assert {:ok, _} = Writer.sync_images(item, product, user_uuid: user.uuid)

    assert_activity_logged("item.updated",
      resource_uuid: item.uuid,
      actor_uuid: user.uuid,
      metadata_has: %{"via" => "shopify_sync"}
    )
  end

  test "an item the sync creates names the sync in the change log" do
    product = %{
      "id" => 4242,
      "handle" => "created-by-sync",
      "title" => "Created by sync",
      "variants" => [%{"price" => "9.00"}]
    }

    assert {:ok, created} = Writer.create_from_shopify(product, "en")

    assert_activity_logged("item.created",
      resource_uuid: created.uuid,
      metadata_has: %{"via" => "shopify_sync"}
    )
  end
end
