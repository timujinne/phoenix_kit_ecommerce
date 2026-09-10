defmodule PhoenixKitEcommerce.Shopify.CollectionSyncNamePrefixTest do
  @moduledoc """
  `shop_name_prefixes` must never reach `CollectionSync`'s category
  matching or creation. `find_category_by_name/2` compares Shopify's raw
  collection `title` against the raw catalogue `category.name` metadata
  field directly (never through `Translations`/`NamePrefix`); a category
  created from a collection stores that same raw title. If stripping
  ever leaked into either side, a category whose stored name carries the
  configured prefix would stop matching its own Shopify collection by
  name (falling back to creating a DUPLICATE category every sync run),
  and a newly-created category would end up with a corrupted, stripped
  name in storage — exactly the "never touch stored values" boundary
  this feature must not cross.

  Same test-doubles/setup shape as `collection_sync_test.exs` — see that
  file's moduledoc for why this needs `phoenix_kit_catalogue` (tagged
  `:catalogue`) and `async: false`.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :catalogue

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce.NamePrefix
  alias PhoenixKitEcommerce.ShopConfig
  alias PhoenixKitEcommerce.Shopify.CollectionSync
  alias PhoenixKitEcommerce.Test.Repo

  setup do
    on_exit(fn -> set_product_source("legacy") end)
    set_product_source("catalogue")
    PhoenixKit.Settings.update_setting(NamePrefix.setting_key(), "3D Printed")

    {:ok, catalogue} =
      Catalogue.create_catalogue(%{
        name: "collection-sync-prefix-#{System.unique_integer([:positive])}"
      })

    %{catalogue: catalogue}
  end

  defp set_product_source(value) do
    case Repo.get(ShopConfig, "shop_product_source") do
      nil ->
        %ShopConfig{}
        |> ShopConfig.changeset(%{key: "shop_product_source", value: %{"value" => value}})
        |> Repo.insert!()

      config ->
        config
        |> ShopConfig.changeset(%{value: %{"value" => value}})
        |> Repo.update!()
    end
  end

  # A collection whose Shopify title still carries the configured prefix,
  # with a handle that deliberately does NOT match the local category's
  # slug — forcing the match to go through `find_category_by_name/2`
  # (name-based fallback) rather than the handle match, which is what
  # this test needs to exercise.
  defmodule NameMatchStub do
    @moduledoc false

    def fetch_collections(_opts) do
      {:ok,
       [
         %{
           "id" => 1,
           "handle" => "frames-shopify-handle",
           "title" => "3D Printed Frames",
           "position" => 0
         },
         %{"id" => 2, "handle" => "gifts", "title" => "3D Printed Gifts", "position" => 1}
       ]}
    end

    def fetch_collection_product_ids(1, _opts), do: {:ok, []}
    def fetch_collection_product_ids(2, _opts), do: {:ok, []}
  end

  test "a category name-matches its collection by the RAW title (unaffected by the prefix setting), and its stored name is untouched",
       %{catalogue: catalogue} do
    {:ok, frames} =
      Catalogue.create_category(%{
        name: "3D Printed Frames",
        catalogue_uuid: catalogue.uuid,
        # Deliberately mismatched vs the Shopify handle, so the handle
        # match fails and resolution falls through to the name match.
        slug: %{"en" => "old-local-slug"},
        position: 9
      })

    assert {:ok, result} =
             CollectionSync.run(client: NameMatchStub, catalogue_uuid: catalogue.uuid)

    # One match (Frames, by raw name), one create (Gifts, no local match).
    assert result.categories_matched == 1
    assert result.categories_created == 1

    updated_frames = Catalogue.get_category!(frames.uuid)
    assert updated_frames.uuid == frames.uuid
    # The stored name is exactly what it was before the sync - never
    # rewritten, stripped or otherwise touched.
    assert updated_frames.name == "3D Printed Frames"
    assert updated_frames.data["ecommerce"]["shopify"]["collection_id"] == "1"

    [gifts] =
      catalogue.uuid
      |> Catalogue.list_categories_metadata_for_catalogue()
      |> Enum.filter(&(&1.uuid != frames.uuid))

    # A freshly CREATED category stores the RAW Shopify title too.
    assert gifts.name == "3D Printed Gifts"
  end
end
