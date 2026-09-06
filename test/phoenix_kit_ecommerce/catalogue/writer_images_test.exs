defmodule PhoenixKitEcommerce.Catalogue.WriterImagesTest do
  @moduledoc """
  `PhoenixKitEcommerce.Catalogue.Writer.sync_images/3` (Block 7 Task 3,
  `docs/superpowers/plans/2026-09-06-block7-shopify-media-collections.md`):
  Shopify product images downloaded (via an injected `opts[:downloader]`
  stub — no real HTTP in this suite) and attached to the catalogue item
  in Shopify's own `position` order, deduped across runs by the Shopify
  image id recorded in `data["ecommerce"]["shopify"]["image_ids"]`.

  Needs `phoenix_kit_catalogue` loaded (real `Attachments.attach_files/3`
  against a live catalogue item) — tagged `:catalogue` and excluded via
  `test_helper.exs` whenever the optional dependency isn't present, same
  as `writer_variants_test.exs`. `async: false`: flips the process-wide
  `shop_product_source` config key.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :catalogue

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}
  @compile {:no_warn_undefined, PhoenixKitCatalogue.Attachments}

  alias PhoenixKit.Modules.Storage
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce.Catalogue.Writer
  alias PhoenixKitEcommerce.ShopConfig
  alias PhoenixKitEcommerce.Test.Repo

  setup do
    on_exit(fn -> set_product_source("legacy") end)

    user = fixture_user()

    {:ok, catalogue} =
      Catalogue.create_catalogue(%{name: "writer-images-#{System.unique_integer([:positive])}"})

    {:ok, item} =
      Catalogue.create_item(%{
        catalogue_uuid: catalogue.uuid,
        name: "Photographed Mug",
        base_price: Decimal.new("10.00"),
        status: "active",
        data: %{
          "ecommerce" => %{
            "shop_status" => "active",
            "shopify" => %{"handle" => "photographed-mug", "product_id" => "888"}
          }
        }
      })

    %{item: item, user_uuid: user.uuid}
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

  # Positions deliberately out of listing order (3, 1, 2) so a
  # sort-by-position bug (attaching in payload order) would show up as
  # the wrong `featured`/order in the assertions below.
  defp three_image_product do
    %{
      "id" => 888,
      "images" => [
        %{"id" => 301, "src" => "https://cdn.example/third.jpg", "position" => 3},
        %{"id" => 101, "src" => "https://cdn.example/first.jpg", "position" => 1},
        %{"id" => 201, "src" => "https://cdn.example/second.jpg", "position" => 2}
      ]
    }
  end

  # Every call creates a real, distinct `Storage.File` row (so
  # `Attachments.attach_files/3`'s own file-existence check passes) and
  # counts its own invocations via an Agent — a genuine stand-in for
  # `ImageDownloader.download_and_store/3`, not a mock of the writer's
  # own behaviour.
  defp counting_downloader(user_uuid, fail_urls \\ []) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    downloader = fn url, downloader_user_uuid, _opts ->
      if url in fail_urls do
        {:error, :not_found}
      else
        Agent.update(counter, &(&1 + 1))
        store_fixture_file(url, downloader_user_uuid || user_uuid)
      end
    end

    {downloader, counter}
  end

  defp store_fixture_file(url, user_uuid) do
    body = "fixture-bytes-#{url}"
    tmp = Path.join(System.tmp_dir!(), "writer_images_test_#{System.unique_integer([:positive])}")
    File.write!(tmp, body)

    result =
      Storage.store_file(tmp,
        filename: Path.basename(url),
        content_type: "image/jpeg",
        size_bytes: byte_size(body),
        user_uuid: user_uuid
      )

    File.rm(tmp)

    case result do
      {:ok, file} -> {:ok, file.uuid}
      {:error, reason} -> {:error, reason}
    end
  end

  describe "sync_images/3 — legacy source" do
    test "is a no-op returning :catalogue_source_inactive", %{item: item, user_uuid: user_uuid} do
      {downloader, _counter} = counting_downloader(user_uuid)

      assert Writer.sync_images(item, three_image_product(), downloader: downloader) ==
               {:error, :catalogue_source_inactive}
    end
  end

  describe "sync_images/3 — catalogue source" do
    setup %{user_uuid: user_uuid} do
      set_product_source("catalogue")
      {downloader, counter} = counting_downloader(user_uuid)
      %{downloader: downloader, counter: counter}
    end

    test "attaches images in Shopify position order with the position-1 image featured", %{
      item: item,
      user_uuid: user_uuid,
      downloader: downloader
    } do
      assert {:ok, %{downloaded: 3, reused: 0, attached: 3}} =
               Writer.sync_images(item, three_image_product(),
                 downloader: downloader,
                 user_uuid: user_uuid
               )

      updated = Catalogue.get_item!(item.uuid)
      first_uuid = updated.data["ecommerce"]["shopify"]["image_ids"]["101"]
      second_uuid = updated.data["ecommerce"]["shopify"]["image_ids"]["201"]
      third_uuid = updated.data["ecommerce"]["shopify"]["image_ids"]["301"]

      assert updated.data["media_order"] == [first_uuid, second_uuid, third_uuid]
      assert updated.data["featured_image_uuid"] == first_uuid
    end

    test "a second run against the same payload downloads nothing and reuses every image", %{
      item: item,
      user_uuid: user_uuid,
      downloader: downloader,
      counter: counter
    } do
      assert {:ok, %{downloaded: 3, reused: 0, attached: 3}} =
               Writer.sync_images(item, three_image_product(),
                 downloader: downloader,
                 user_uuid: user_uuid
               )

      item = Catalogue.get_item!(item.uuid)

      assert {:ok, %{downloaded: 0, reused: 3, attached: 3}} =
               Writer.sync_images(item, three_image_product(),
                 downloader: downloader,
                 user_uuid: user_uuid
               )

      assert Agent.get(counter, & &1) == 3
    end

    test "a failing download skips that image and reports it, attaching the rest", %{
      item: item,
      user_uuid: user_uuid
    } do
      {downloader, _counter} =
        counting_downloader(user_uuid, ["https://cdn.example/second.jpg"])

      assert {:ok, %{downloaded: 2, reused: 0, attached: 2, errors: [error]}} =
               Writer.sync_images(item, three_image_product(),
                 downloader: downloader,
                 user_uuid: user_uuid
               )

      assert {"201", :not_found} = error

      updated = Catalogue.get_item!(item.uuid)
      refute Map.has_key?(updated.data["ecommerce"]["shopify"]["image_ids"], "201")
      assert map_size(updated.data["ecommerce"]["shopify"]["image_ids"]) == 2
    end

    test "a product with no images attaches nothing", %{
      item: item,
      user_uuid: user_uuid,
      downloader: downloader
    } do
      assert {:ok, %{downloaded: 0, reused: 0, attached: 0}} =
               Writer.sync_images(item, %{"id" => 888, "images" => []},
                 downloader: downloader,
                 user_uuid: user_uuid
               )

      updated = Catalogue.get_item!(item.uuid)
      refute Map.has_key?(updated.data, "media_order")
    end
  end
end
