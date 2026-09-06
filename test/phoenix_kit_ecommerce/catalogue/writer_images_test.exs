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
  alias PhoenixKit.Users.Auth
  alias PhoenixKitCatalogue.Attachments
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

  # A Storage file already stamped with `metadata["source_url"]` — the
  # same key `ImageDownloader.download_and_store/3` writes — as if it had
  # been downloaded (or migrated) from `source_url` already, distinct
  # from the Shopify `src` this test then syncs against (a `?v=` query
  # difference), so the reuse match has to strip the query to hit.
  defp store_linked_file(source_url, user_uuid) do
    body = "fixture-bytes-#{source_url}"
    tmp = Path.join(System.tmp_dir!(), "writer_images_test_#{System.unique_integer([:positive])}")
    File.write!(tmp, body)

    {:ok, file} =
      Storage.store_file(tmp,
        filename: Path.basename(source_url),
        content_type: "image/jpeg",
        size_bytes: byte_size(body),
        user_uuid: user_uuid,
        metadata: %{"source_url" => source_url}
      )

    File.rm(tmp)
    file
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

    # Block 7b Task 1
    # (docs/superpowers/plans/2026-09-06-block7b-shopify-live-fixes.md):
    # migrated items carry plain Storage files (never Shopify-image-id
    # tagged) whose `metadata["source_url"]` still records the Shopify
    # CDN URL they were downloaded from — reuse those by URL, query
    # stripped, before ever downloading a second copy.
    test "reuses Storage files already linked to the item by source_url, query stripped", %{
      item: item,
      user_uuid: user_uuid
    } do
      file1 = store_linked_file("https://cdn.example/first.jpg?v=111", user_uuid)
      file2 = store_linked_file("https://cdn.example/second.jpg?v=222", user_uuid)

      {:ok, item} =
        Attachments.attach_files(item, [file1.uuid, file2.uuid], order: [file1.uuid, file2.uuid])

      {downloader, counter} = counting_downloader(user_uuid)

      product = %{
        "id" => 888,
        "images" => [
          %{"id" => 101, "src" => "https://cdn.example/first.jpg?v=999", "position" => 1},
          %{"id" => 201, "src" => "https://cdn.example/second.jpg?v=888", "position" => 2}
        ]
      }

      assert {:ok, %{downloaded: 0, reused: 2, attached: 2, errors: []}} =
               Writer.sync_images(item, product, downloader: downloader, user_uuid: user_uuid)

      assert Agent.get(counter, & &1) == 0

      updated = Catalogue.get_item!(item.uuid)
      assert updated.data["ecommerce"]["shopify"]["image_ids"]["101"] == file1.uuid
      assert updated.data["ecommerce"]["shopify"]["image_ids"]["201"] == file2.uuid
      assert updated.data["media_order"] == [file1.uuid, file2.uuid]
      assert updated.data["featured_image_uuid"] == file1.uuid
    end

    # Review fix (Block 7b): a reverted version of this fallback bound a
    # failed image's Shopify id to whatever uuid happened to sit at the
    # SAME LIST POSITION in the item's previous `media_order` — wrong the
    # moment a new image is inserted ahead of an existing one, and the
    # bad binding then stuck forever (a later successful download of
    # that image was never attempted again, since the id already
    # "resolved"). The only bindings that may ever be trusted are keyed
    # by Shopify image id (`image_ids`) or by download source URL
    # (`source_url`) — never by position. An id with neither is skipped,
    # not bound to anything, so a later run retries it for real.
    test "a failing download for a genuinely new image is skipped (not bound by position) and retries next run",
         %{item: item, user_uuid: user_uuid} do
      {:ok, image_a} = store_fixture_file("https://cdn.example/first.jpg", user_uuid)
      {:ok, image_b} = store_fixture_file("https://cdn.example/second.jpg", user_uuid)

      {:ok, item} =
        Attachments.attach_files(item, [image_a, image_b], order: [image_a, image_b])

      {:ok, item} =
        Catalogue.update_item(item, %{
          data:
            put_in(item.data, ["ecommerce", "shopify", "image_ids"], %{
              "101" => image_a,
              "201" => image_b
            })
        })

      # 301 is a new image, inserted ahead of 201 in Shopify's own
      # order — the exact shape that made the position-based fallback
      # bind it to `image_b` (301's index used to land on 201's slot).
      product = %{
        "id" => 888,
        "images" => [
          %{"id" => 101, "src" => "https://cdn.example/first.jpg", "position" => 1},
          %{"id" => 301, "src" => "https://cdn.example/new.jpg", "position" => 2},
          %{"id" => 201, "src" => "https://cdn.example/second.jpg", "position" => 3}
        ]
      }

      {failing_downloader, _counter} =
        counting_downloader(user_uuid, ["https://cdn.example/new.jpg"])

      assert {:ok, %{downloaded: 0, reused: 2, attached: 2, errors: [{"301", :not_found}]}} =
               Writer.sync_images(item, product,
                 downloader: failing_downloader,
                 user_uuid: user_uuid
               )

      updated = Catalogue.get_item!(item.uuid)
      refute Map.has_key?(updated.data["ecommerce"]["shopify"]["image_ids"], "301")
      assert updated.data["media_order"] == [image_a, image_b]

      # A later run, once the image can actually be downloaded, binds
      # 301 for real — it was never poisoned with a fake binding.
      {healthy_downloader, counter} = counting_downloader(user_uuid)

      assert {:ok, %{downloaded: 1, reused: 2, attached: 3, errors: []}} =
               Writer.sync_images(updated, product,
                 downloader: healthy_downloader,
                 user_uuid: user_uuid
               )

      assert Agent.get(counter, & &1) == 1

      final = Catalogue.get_item!(item.uuid)
      new_uuid = final.data["ecommerce"]["shopify"]["image_ids"]["301"]
      assert new_uuid
      assert final.data["media_order"] == [image_a, new_uuid, image_b]
    end

    test "no user_uuid given inserts files under the default (first-admin) actor", %{
      item: item
    } do
      expected_actor_uuid = Auth.get_first_admin_uuid()
      assert expected_actor_uuid, "expected an Owner/Admin user to resolve a default actor"

      downloader = fn url, downloader_user_uuid, _opts ->
        store_fixture_file(url, downloader_user_uuid)
      end

      product = %{
        "id" => 888,
        "images" => [
          %{"id" => 501, "src" => "https://cdn.example/default-actor.jpg", "position" => 1}
        ]
      }

      assert {:ok, %{downloaded: 1, reused: 0, attached: 1}} =
               Writer.sync_images(item, product, downloader: downloader)

      updated = Catalogue.get_item!(item.uuid)
      file_uuid = updated.data["ecommerce"]["shopify"]["image_ids"]["501"]
      file = Storage.get_file(file_uuid)

      assert file.user_uuid == expected_actor_uuid
    end
  end
end
