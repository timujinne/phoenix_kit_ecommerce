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
  alias PhoenixKitEcommerce.Services.ImageDownloader
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
  # `unique_bytes: true` gives every download distinct content. Core's
  # Storage dedups a stored file on its per-user checksum, so a re-download
  # of the same URL with the same fixture bytes hands back the EXISTING
  # file row — including one that has since been trashed — which is the
  # wrong thing to prove when the test is about falling through to a
  # fresh file.
  defp counting_downloader(user_uuid, fail_urls \\ [], opts \\ []) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    unique? = Keyword.get(opts, :unique_bytes, false)

    downloader = fn url, downloader_user_uuid, _opts ->
      if url in fail_urls do
        {:error, :not_found}
      else
        Agent.update(counter, &(&1 + 1))
        store_fixture_file(url, downloader_user_uuid || user_uuid, body_suffix(unique?))
      end
    end

    {downloader, counter}
  end

  defp body_suffix(true), do: "-#{System.unique_integer([:positive])}"
  defp body_suffix(false), do: ""

  defp store_fixture_file(url, user_uuid, suffix \\ "") do
    body = "fixture-bytes-#{url}#{suffix}"
    tmp = Path.join(System.tmp_dir!(), "writer_images_test_#{System.unique_integer([:positive])}")
    File.write!(tmp, body)

    result =
      Storage.store_file(tmp,
        filename: Path.basename(url),
        content_type: "image/jpeg",
        size_bytes: byte_size(body),
        user_uuid: user_uuid,
        metadata: %{"source_url" => url}
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

    # Live-run finding (Block 7b Task 2): a run against 665 products
    # re-downloaded 582 of them despite this exact source_url match
    # already existing, because the match was scoped to files already
    # linked to THIS item — and Shopify shops commonly reuse the exact
    # same image `src` (a shared lifestyle photo, a size chart, ...)
    # across many otherwise-unrelated products in the same line. The fix
    # widens the match to any active file in the whole shop, so a file
    # downloaded moments ago for a SIBLING item is found too.
    test "reuses a file downloaded for a different item, by source_url, without a second download",
         %{item: item, user_uuid: user_uuid} do
      {:ok, other_catalogue} =
        Catalogue.create_catalogue(%{
          name: "writer-images-other-#{System.unique_integer([:positive])}"
        })

      {:ok, other_item} =
        Catalogue.create_item(%{
          catalogue_uuid: other_catalogue.uuid,
          name: "Sibling Mug",
          base_price: Decimal.new("10.00"),
          status: "active",
          data: %{
            "ecommerce" => %{
              "shop_status" => "active",
              "shopify" => %{"handle" => "sibling-mug", "product_id" => "999"}
            }
          }
        })

      {downloader, counter} = counting_downloader(user_uuid)

      shared_product = %{
        "id" => 999,
        "images" => [
          %{"id" => 401, "src" => "https://cdn.example/shared-lifestyle.jpg", "position" => 1}
        ]
      }

      assert {:ok, %{downloaded: 1, reused: 0, attached: 1}} =
               Writer.sync_images(other_item, shared_product,
                 downloader: downloader,
                 user_uuid: user_uuid
               )

      assert Agent.get(counter, & &1) == 1

      # A DIFFERENT catalogue item lists the exact same Shopify `src`
      # (a `?v=` query away) under its own image id — never linked to
      # `item`, never in its folder, only in `other_item`'s.
      product = %{
        "id" => 888,
        "images" => [
          %{
            "id" => 101,
            "src" => "https://cdn.example/shared-lifestyle.jpg?v=42",
            "position" => 1
          }
        ]
      }

      assert {:ok, %{downloaded: 0, reused: 1, attached: 1, errors: []}} =
               Writer.sync_images(item, product, downloader: downloader, user_uuid: user_uuid)

      assert Agent.get(counter, & &1) == 1

      other_updated = Catalogue.get_item!(other_item.uuid)
      updated = Catalogue.get_item!(item.uuid)
      shared_uuid = other_updated.data["ecommerce"]["shopify"]["image_ids"]["401"]

      assert shared_uuid
      assert updated.data["ecommerce"]["shopify"]["image_ids"]["101"] == shared_uuid
      assert updated.data["media_order"] == [shared_uuid]
    end

    # The widened shop-wide match is still an exact `source_url` match —
    # never a guess from a shared filename. Two files with the SAME
    # `original_file_name` but genuinely different `source_url`s (e.g.
    # two products' own "1.jpg") must resolve independently: reusing the
    # wrong one would attach one item's picture to another.
    test "a shop-wide filename collision does not cause cross-item reuse", %{
      item: item,
      user_uuid: user_uuid
    } do
      {:ok, other_catalogue} =
        Catalogue.create_catalogue(%{
          name: "writer-images-collision-#{System.unique_integer([:positive])}"
        })

      {:ok, other_item} =
        Catalogue.create_item(%{
          catalogue_uuid: other_catalogue.uuid,
          name: "Collision Mug",
          base_price: Decimal.new("10.00"),
          status: "active",
          data: %{
            "ecommerce" => %{
              "shop_status" => "active",
              "shopify" => %{"handle" => "collision-mug", "product_id" => "777"}
            }
          }
        })

      {downloader, counter} = counting_downloader(user_uuid)

      # Same basename ("photo.jpg") as `item`'s own image below, but a
      # different Shopify shop path — genuinely different content.
      other_product = %{
        "id" => 777,
        "images" => [
          %{"id" => 701, "src" => "https://cdn.example/other-shop/photo.jpg", "position" => 1}
        ]
      }

      assert {:ok, %{downloaded: 1}} =
               Writer.sync_images(other_item, other_product,
                 downloader: downloader,
                 user_uuid: user_uuid
               )

      product = %{
        "id" => 888,
        "images" => [
          %{"id" => 101, "src" => "https://cdn.example/this-shop/photo.jpg", "position" => 1}
        ]
      }

      assert {:ok, %{downloaded: 1, reused: 0, attached: 1, errors: []}} =
               Writer.sync_images(item, product, downloader: downloader, user_uuid: user_uuid)

      assert Agent.get(counter, & &1) == 2

      other_updated = Catalogue.get_item!(other_item.uuid)
      updated = Catalogue.get_item!(item.uuid)

      other_uuid = other_updated.data["ecommerce"]["shopify"]["image_ids"]["701"]
      this_uuid = updated.data["ecommerce"]["shopify"]["image_ids"]["101"]

      assert other_uuid && this_uuid
      refute other_uuid == this_uuid
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

    # Path (a) — reuse by known Shopify image id — used to trust the stored
    # uuid blindly, unlike path (b) which only ever indexes ACTIVE files. A
    # file trashed since the last sync must not be re-attached; the image
    # falls through to (b)/(c) and is downloaded again.
    test "a known image id whose file is no longer active falls through to a fresh download", %{
      item: item,
      user_uuid: user_uuid
    } do
      {:ok, stale_uuid} = store_fixture_file("https://cdn.example/first.jpg", user_uuid)
      {:ok, _trashed} = Storage.update_file(Storage.get_file(stale_uuid), %{status: "trashed"})

      {:ok, item} =
        Catalogue.update_item(item, %{
          data: put_in(item.data, ["ecommerce", "shopify", "image_ids"], %{"101" => stale_uuid})
        })

      product = %{
        "id" => 888,
        "images" => [%{"id" => 101, "src" => "https://cdn.example/first.jpg", "position" => 1}]
      }

      {downloader, counter} = counting_downloader(user_uuid, [], unique_bytes: true)

      assert {:ok, %{downloaded: 1, reused: 0, attached: 1, errors: []}} =
               Writer.sync_images(item, product, downloader: downloader, user_uuid: user_uuid)

      assert Agent.get(counter, & &1) == 1

      updated = Catalogue.get_item!(item.uuid)
      new_uuid = updated.data["ecommerce"]["shopify"]["image_ids"]["101"]
      assert new_uuid != stale_uuid
      assert updated.data["media_order"] == [new_uuid]
    end

    # A Shopify image with no `src` (seen mid-upload) used to reach the
    # downloader as `nil` and raise out of the whole product; now it is
    # this image's own recorded error and the rest of the product syncs.
    test "an image without a src is skipped with a recorded error, not raised", %{
      item: item,
      user_uuid: user_uuid
    } do
      product = %{
        "id" => 888,
        "images" => [
          %{"id" => 901, "src" => nil, "position" => 1},
          %{"id" => 101, "src" => "https://cdn.example/first.jpg", "position" => 2}
        ]
      }

      {downloader, _counter} = counting_downloader(user_uuid)

      assert {:ok, %{downloaded: 1, reused: 0, attached: 1, errors: [{"901", :missing_src}]}} =
               Writer.sync_images(item, product, downloader: downloader, user_uuid: user_uuid)

      updated = Catalogue.get_item!(item.uuid)
      refute Map.has_key?(updated.data["ecommerce"]["shopify"]["image_ids"], "901")
      assert [_uuid] = updated.data["media_order"]
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

  describe "url_index option" do
    test "a caller-supplied index is used, and comes back grown by this product's downloads",
         %{item: item, user_uuid: user_uuid} do
      # A catalogue-wide run builds the index once and threads it from one
      # product to the next; rebuilding it per product would scan every
      # stored file per item.
      set_product_source("catalogue")

      src = "https://cdn.shopify.com/s/files/1/fresh.jpg?v=9"
      product = %{"images" => [%{"id" => 901, "src" => src, "position" => 1}]}
      {downloader, counter} = counting_downloader(user_uuid)

      {:ok, result} =
        Writer.sync_images(item, product,
          downloader: downloader,
          user_uuid: user_uuid,
          url_index: %{}
        )

      assert result.downloaded == 1
      assert Agent.get(counter, & &1) == 1

      # The freshly downloaded file is in the index handed back, so the
      # next product sharing this src reuses it inside the same run.
      assert Map.has_key?(result.url_index, "https://cdn.shopify.com/s/files/1/fresh.jpg")

      {:ok, sibling} =
        Catalogue.create_item(%{
          catalogue_uuid: item.catalogue_uuid,
          name: "Sibling Mug",
          base_price: Decimal.new("10.00"),
          status: "active",
          data: %{"ecommerce" => %{"shop_status" => "active"}}
        })

      {:ok, second} =
        Writer.sync_images(sibling, product,
          downloader: fn _url, _uuid, _opts -> {:error, :should_not_download} end,
          user_uuid: user_uuid,
          url_index: result.url_index
        )

      assert second.reused == 1
      assert second.downloaded == 0
    end
  end

  describe "build_reuse_index/0" do
    test "a file's own source URL outranks another file's alias for it", %{user_uuid: user_uuid} do
      earlier = store_linked_file("https://cdn.example/a.jpg", user_uuid)

      {:ok, _} =
        Storage.update_file_metadata(
          earlier.uuid,
          &Map.put(&1, "source_url_aliases", ["https://cdn.example/b.jpg"])
        )

      later = store_linked_file("https://cdn.example/b.jpg?v=2", user_uuid)

      %{url_index: index} = Writer.build_reuse_index()

      assert index["https://cdn.example/a.jpg"] == earlier.uuid
      assert index["https://cdn.example/b.jpg"] == later.uuid
    end

    test "an alias no file owns resolves to the file that answers to it", %{user_uuid: user_uuid} do
      file = store_linked_file("https://cdn.example/a.jpg", user_uuid)

      {:ok, _} =
        Storage.update_file_metadata(
          file.uuid,
          &Map.put(&1, "source_url_aliases", ["https://cdn.example/copy.jpg"])
        )

      %{url_index: index} = Writer.build_reuse_index()
      assert index["https://cdn.example/copy.jpg"] == file.uuid
    end
  end

  # The seam between `ImageDownloader` (writes `source_url_aliases`) and
  # this module (reads them into the reuse index): the same banner listed
  # under a second Shopify src — its own file in Shopify, a few bytes
  # different — is stored once, and a later sync that meets that second
  # src again resolves it from the index, without a download.
  describe "near-duplicate pictures across products" do
    @describetag skip:
                   if(System.find_executable("convert"),
                     do: false,
                     else: "ImageMagick (convert) is not installed"
                   )

    test "a re-encoded copy under a new src is stored once and then reused by alias", %{
      item: item,
      user_uuid: user_uuid
    } do
      set_product_source("catalogue")

      dir = Path.join(System.tmp_dir!(), "writer_near_dup_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      banner = Path.join(dir, "banner.png")

      {_, 0} =
        System.cmd(
          "convert",
          ["-size", "320x240", "-seed", "7", "plasma:fractal", banner],
          stderr_to_stdout: true
        )

      copy = Path.join(dir, "copy.jpg")
      {_, 0} = System.cmd("convert", [banner, "-quality", "70", copy], stderr_to_stdout: true)

      bodies = %{
        "/s/files/banner.png" => {"image/png", File.read!(banner)},
        "/s/files/banner_copy.jpg" => {"image/jpeg", File.read!(copy)}
      }

      Req.Test.stub(__MODULE__, fn conn ->
        {type, body} = Map.fetch!(bodies, conn.request_path)
        conn |> Plug.Conn.put_resp_content_type(type) |> Plug.Conn.send_resp(200, body)
      end)

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      downloader = fn url, uuid, opts ->
        Agent.update(counter, &(&1 + 1))

        ImageDownloader.download_and_store(
          url,
          uuid,
          opts ++ [req_options: [plug: {Req.Test, __MODULE__}]]
        )
      end

      first_src = "https://93.184.216.34/s/files/banner.png?v=1"
      copy_src = "https://93.184.216.34/s/files/banner_copy.jpg?v=2"

      {:ok, _} =
        Writer.sync_images(
          item,
          %{"images" => [%{"id" => 1, "src" => first_src, "position" => 1}]},
          downloader: downloader,
          user_uuid: user_uuid
        )

      banner_uuid = Catalogue.get_item!(item.uuid).data["featured_image_uuid"]

      sibling = fn name ->
        {:ok, sibling} =
          Catalogue.create_item(%{
            catalogue_uuid: item.catalogue_uuid,
            name: name,
            base_price: Decimal.new("10.00"),
            status: "active",
            data: %{"ecommerce" => %{"shop_status" => "active"}}
          })

        sibling
      end

      copy_product = %{"images" => [%{"id" => 2, "src" => copy_src, "position" => 1}]}

      # The copy is fetched once — nothing in Storage answers to its URL
      # yet — and resolved to the banner already stored.
      second = sibling.("Second Mug")

      {:ok, _} =
        Writer.sync_images(second, copy_product, downloader: downloader, user_uuid: user_uuid)

      assert Catalogue.get_item!(second.uuid).data["media_order"] == [banner_uuid]
      assert Agent.get(counter, & &1) == 2

      # A fresh index now knows the copy's URL: no download at all.
      third = sibling.("Third Mug")

      assert {:ok, %{downloaded: 0, reused: 1}} =
               Writer.sync_images(third, copy_product,
                 downloader: downloader,
                 user_uuid: user_uuid
               )

      assert Catalogue.get_item!(third.uuid).data["media_order"] == [banner_uuid]
      assert Agent.get(counter, & &1) == 2
    end
  end
end
