defmodule PhoenixKitEcommerce.API.DetachImagesTest do
  @moduledoc """
  `ecommerce.detach_images` against a real catalogue: pictures leave the
  product's gallery (by file id or by the URL they were attached from), the
  featured pointer follows, a retry changes nothing, a dry run writes nothing
  and says whether the real call would be held, and another product's picture
  is never touched.

  The first block works on gallery entries alone (a picture the gallery names
  whose file is gone is still removed from the list). The second attaches
  real pictures through `ecommerce.attach_images` (HTTP through `Req.Test`,
  pictures drawn with ImageMagick, skipped where it is missing) to see what
  happens to the stored file. `async: false`: `attach_images` reads the
  shop-wide URL index, and the tests that move the world between the plan and
  the write, or watch the queries, use telemetry handlers that are global.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :catalogue_api
  @moduletag :core_confirm

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog, only: [with_log: 1]

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.ResourceFolders
  alias PhoenixKit.Settings
  alias PhoenixKitCatalogue.Schemas.Item
  alias PhoenixKitEcommerce.API.DetachImages
  alias PhoenixKitEcommerce.APICase
  alias PhoenixKitEcommerce.APIFixtures, as: F
  alias PhoenixKitEcommerce.StorefrontCache
  alias PhoenixKitEcommerce.Test.Repo

  @one "0192a7c0-0000-7000-8000-00000000000a"
  @two "0192a7c0-0000-7000-8000-00000000000b"
  @three "0192a7c0-0000-7000-8000-00000000000c"

  setup do
    catalogue = F.shop_catalogue!()
    user = F.user!()
    %{catalogue: catalogue, user: user, ctx: F.ctx(user)}
  end

  defp detach(rows, ctx), do: APICase.call("ecommerce.detach_images", %{"items" => rows}, ctx)
  defp dry(ctx), do: %{ctx | dry_run?: true}

  # What core's executor sets once a dangerous call was confirmed.
  defp confirmed(ctx), do: Map.put(ctx, :confirmation_uuid, Ecto.UUID.generate())

  defp row(item, images), do: %{"ref" => %{"id" => item.uuid}, "images" => images}
  defp ids(uuids), do: Enum.map(uuids, &%{"id" => &1})

  defp item_with(catalogue, order, featured \\ nil) do
    data =
      %{"_primary_language" => "en", "ecommerce" => %{"shop_status" => "active"}}
      |> Map.put("media_order", order)
      |> then(&if(featured, do: Map.put(&1, "featured_image_uuid", featured), else: &1))

    F.item!(catalogue, %{data: data})
  end

  describe "the gallery" do
    test "takes the named pictures out and keeps the order of the others", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = item_with(catalogue, [@one, @two, @three], @one)

      assert {:ok, %{"results" => [result], "summary" => %{"updated" => 1}}} =
               detach([row(item, ids([@two]))], ctx)

      assert result["action"] == "updated"
      assert result["detached"] == 1
      assert result["not_attached"] == []
      assert result["changes"] == %{"images" => %{"remove" => 1}}

      data = F.reload!(item).data
      assert data["media_order"] == [@one, @three]
      assert data["featured_image_uuid"] == @one
    end

    test "removing the featured picture clears the pointer, as the editor's remove button does",
         %{catalogue: catalogue, ctx: ctx} do
      item = item_with(catalogue, [@one, @two], @one)

      assert {:ok, %{"summary" => %{"updated" => 1}}} = detach([row(item, ids([@one]))], ctx)

      data = F.reload!(item).data
      assert data["media_order"] == [@two]
      refute Map.has_key?(data, "featured_image_uuid")
    end

    test "a featured pointer that is not in the order is a picture of the gallery too", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = item_with(catalogue, [@two], @one)

      assert {:ok, %{"summary" => %{"updated" => 1}}} = detach([row(item, ids([@one]))], ctx)

      data = F.reload!(item).data
      assert data["media_order"] == [@two]
      refute Map.has_key?(data, "featured_image_uuid")
    end

    test "a picture the product does not have is reported and changes nothing", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      mine = item_with(catalogue, [@one])
      other = item_with(catalogue, [@two])

      assert {:ok, %{"results" => [result], "summary" => %{"unchanged" => 1}}} =
               detach([row(mine, ids([@two]))], ctx)

      assert result["action"] == "unchanged"
      assert result["detached"] == 0
      assert result["not_attached"] == [@two]

      assert F.reload!(mine).data["media_order"] == [@one]
      assert F.reload!(other).data["media_order"] == [@two]
    end

    test "the same call again is unchanged: the retry of a call that succeeded", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = item_with(catalogue, [@one, @two], @one)
      rows = [row(item, ids([@two]))]

      assert {:ok, %{"summary" => %{"updated" => 1}}} = detach(rows, ctx)

      assert {:ok, %{"results" => [again], "summary" => %{"unchanged" => 1}}} =
               detach(rows, ctx)

      assert again["detached"] == 0
      assert F.reload!(item).data["media_order"] == [@one]
    end

    test "a call that empties a gallery without a confirmation is not written", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = item_with(catalogue, [@one])

      assert {:error, :validation_failed, _message, %{errors: [%{path: "items"}]}} =
               detach([row(item, ids([@one]))], ctx)

      assert F.reload!(item).data["media_order"] == [@one]

      assert {:ok, %{"summary" => %{"updated" => 1}}} =
               detach([row(item, ids([@one]))], confirmed(ctx))

      assert F.reload!(item).data["media_order"] == []
    end

    test "a picture asked for twice is removed once", %{catalogue: catalogue, ctx: ctx} do
      item = item_with(catalogue, [@one, @two])

      assert {:ok, %{"results" => [result]}} =
               detach([row(item, ids([@one, String.upcase(@one)]))], ctx)

      assert result["detached"] == 1
      assert F.reload!(item).data["media_order"] == [@two]
    end

    test "a row that fails does not stop the others", %{catalogue: catalogue, ctx: ctx} do
      item = item_with(catalogue, [@one])

      rows = [
        %{"ref" => %{"sku" => "NO-SUCH-SKU"}, "images" => ids([@one])},
        row(item, ids([@one]))
      ]

      assert {:ok, %{"results" => [missing, done], "summary" => summary}} =
               detach(rows, confirmed(ctx))

      assert missing["error"]["code"] == "not_found"
      assert done["action"] == "updated"
      assert summary == %{"updated" => 1, "unchanged" => 0, "error" => 1}
    end

    test "refuses a picture given by both id and url, or by neither, on its own row", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = item_with(catalogue, [@one])

      for image <- [%{"id" => @one, "url" => "https://93.184.216.34/a.png"}, %{}] do
        assert {:ok, %{"results" => [result]}} = detach([row(item, [image])], ctx)
        assert result["error"]["code"] == "validation_failed"
        assert inspect(result["error"]) =~ "images[0]"
        assert F.reload!(item).data["media_order"] == [@one]
      end
    end

    test "logs the removal with the API metadata", %{catalogue: catalogue, user: user, ctx: ctx} do
      item = item_with(catalogue, [@one, @two])

      assert {:ok, _} = detach([row(item, ids([@one]))], ctx)

      entry =
        assert_activity_logged("shop.api_images_detached",
          resource_uuid: item.uuid,
          actor_uuid: user.uuid,
          metadata_has: %{"via" => "api", "tool" => "ecommerce.detach_images", "detached" => 1}
        )

      assert entry.mode == "auto"
    end
  end

  # Runs `fun` once, in the process that is writing, when the first product
  # lock of the call is taken: a way to change the world between the plan and
  # the write, deterministically.
  defp at_lock(fun) do
    id = {:at_lock, make_ref()}

    :telemetry.attach(
      id,
      [:phoenix_kit_ecommerce, :test, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if String.contains?(meta.query, "FOR SHARE") do
          :telemetry.detach(id)
          fun.()
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp set_item(item, set),
    do: Repo.update_all(from(i in Item, where: i.uuid == ^item.uuid), set: set)

  defp set_order(item, order),
    do: set_item(item, data: Map.put(item.data, "media_order", order))

  describe "a product that changes between the plan and the write" do
    test "a gallery that changed is not written: the call was judged on the old one", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = item_with(catalogue, [@one, @two])
      # another writer takes @two out after the plan: removing @one would now
      # empty the gallery, which only a confirmed call may do
      at_lock(fn -> set_order(item, [@one]) end)

      assert {:ok, %{"results" => [result], "summary" => %{"error" => 1}}} =
               detach([row(item, ids([@one]))], ctx)

      assert result["error"]["code"] == "validation_failed"
      assert result["error"]["context"]["reason"] == "changed_since_planned"
      assert F.reload!(item).data["media_order"] == [@one]
    end

    test "a featured picture that moved is a changed gallery too", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = item_with(catalogue, [@one, @two], @one)

      at_lock(fn ->
        set_item(item, data: Map.put(item.data, "featured_image_uuid", @two))
      end)

      assert {:ok, %{"results" => [result]}} = detach([row(item, ids([@one]))], ctx)

      assert result["error"]["context"]["reason"] == "changed_since_planned"
      assert F.reload!(item).data["media_order"] == [@one, @two]
    end

    test "a product trashed after the plan answers not_found and is left alone", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = item_with(catalogue, [@one, @two])
      at_lock(fn -> set_item(item, status: "deleted") end)

      assert {:ok, %{"results" => [result]}} = detach([row(item, ids([@one]))], ctx)

      assert result["error"]["code"] == "not_found"
      assert F.reload!(item).data["media_order"] == [@one, @two]
    end

    test "the row that changed does not stop the next one", %{catalogue: catalogue, ctx: ctx} do
      moved = item_with(catalogue, [@one, @two])
      other = item_with(catalogue, [@one, @two])
      at_lock(fn -> set_order(moved, [@one]) end)

      assert {:ok, %{"results" => [first, second], "summary" => summary}} =
               detach([row(moved, ids([@one])), row(other, ids([@one]))], ctx)

      assert first["error"]["context"]["reason"] == "changed_since_planned"
      assert second["action"] == "updated"
      assert summary == %{"updated" => 1, "unchanged" => 0, "error" => 1}
    end
  end

  describe "the size of a call" do
    defp fake_rows(rows, images) do
      for _ <- 1..rows do
        %{
          "ref" => %{"id" => Ecto.UUID.generate()},
          "images" => ids(for _ <- 1..images, do: Ecto.UUID.generate())
        }
      end
    end

    test "at most 50 pictures per product", %{ctx: ctx} do
      assert {:error, :validation_failed, _message, %{errors: [%{path: path}]}} =
               detach(fake_rows(1, DetachImages.max_images() + 1), ctx)

      assert path =~ "images"
    end

    test "at most 500 pictures per call, counted over all products", %{ctx: ctx} do
      assert {:preview, _, _} = detach(fake_rows(10, 50), dry(ctx))

      assert {:error, :validation_failed, _message, %{errors: [%{path: "items", limit: 500}]}} =
               detach(fake_rows(10, 50) ++ fake_rows(1, 1), dry(ctx))

      assert {:error, :validation_failed, _message, _} = detach(fake_rows(11, 50), ctx)
      assert DetachImages.dangerous?(%{"items" => fake_rows(11, 50)}, ctx) == false
    end

    test "the stored pictures of all the galleries are read in one query", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      rows =
        for _ <- 1..3,
            do:
              row(item_with(catalogue, [@one, @two]), [%{"url" => "https://93.184.216.34/a.png"}])

      test = self()
      id = {:count_file_reads, make_ref()}

      :telemetry.attach(
        id,
        [:phoenix_kit_ecommerce, :test, :repo, :query],
        fn _event, _measurements, meta, _config ->
          if meta.source == "phoenix_kit_files", do: send(test, :file_read)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)

      assert {:preview, _, _} = detach(rows, dry(ctx))
      assert_received :file_read
      refute_received :file_read

      # nothing to look up when no row names a URL
      assert {:preview, _, _} = detach([row(item_with(catalogue, [@one]), ids([@two]))], dry(ctx))
      refute_received :file_read
    end
  end

  describe "the Shopify warning" do
    test "only for a linked product, only while the sync is on", %{catalogue: catalogue, ctx: ctx} do
      shopify = PhoenixKitEcommerce.shopify_enabled?()

      on_exit(fn ->
        Settings.update_boolean_setting_with_module("shop_shopify_enabled", shopify, "shop")
      end)

      linked =
        F.item!(catalogue, %{
          data: %{
            "_primary_language" => "en",
            "ecommerce" => %{"shop_status" => "active", "shopify" => %{"product_id" => "7"}},
            "media_order" => [@one, @two]
          }
        })

      plain = item_with(catalogue, [@one, @two])
      rows = [row(linked, ids([@one])), row(plain, ids([@one]))]

      Settings.update_boolean_setting_with_module("shop_shopify_enabled", true, "shop")
      assert {:preview, on, _} = detach(rows, dry(ctx))
      assert [%{"warnings" => ["shopify_sync_may_overwrite"]}, %{"warnings" => []}] = on["rows"]

      Settings.update_boolean_setting_with_module("shop_shopify_enabled", false, "shop")
      assert {:preview, off, _} = detach(rows, dry(ctx))
      assert [%{"warnings" => []}, %{"warnings" => []}] = off["rows"]
    end
  end

  describe "the storefront cache" do
    setup do
      start_supervised!(PhoenixKit.Cache.Registry)
      [spec] = StorefrontCache.children()
      start_supervised!(spec)
      :ok
    end

    test "a write clears it; a dry run and an unchanged row leave it", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = item_with(catalogue, [@one])

      :stale = StorefrontCache.fetch(:probe, fn -> :stale end)
      assert {:preview, _, _} = detach([row(item, ids([@one]))], dry(ctx))
      assert {:ok, _} = detach([row(item, ids([@two]))], ctx)
      assert StorefrontCache.fetch(:probe, fn -> :fresh end) == :stale

      assert {:ok, _} = detach([row(item, ids([@one]))], confirmed(ctx))
      assert StorefrontCache.fetch(:probe, fn -> :fresh end) == :fresh
    end
  end

  describe "dry run" do
    test "previews the removal, writes nothing and logs nothing", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = item_with(catalogue, [@one, @two])

      assert {:preview, preview, fingerprint} = detach([row(item, ids([@one]))], dry(ctx))

      assert fingerprint =~ ~r/\A[0-9a-f]{64}\z/
      assert preview["totals"]["update"] == 1

      assert [%{"action" => "update", "changes" => %{"images" => %{"remove" => 1}}}] =
               preview["rows"]

      assert F.reload!(item).data["media_order"] == [@one, @two]
      refute_activity_logged("shop.api_images_detached", resource_uuid: item.uuid)
    end

    test "says the real call is held only when it would leave a product with no pictures", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = item_with(catalogue, [@one, @two], @one)

      requires = fn images ->
        {:preview, preview, _} = detach([row(item, ids(images))], dry(ctx))
        preview["requires_confirmation"]
      end

      refute requires.([@two])
      # the featured picture alone is replaced all the time: not held
      refute requires.([@one])
      assert requires.([@one, @two])
      # nothing to remove is nothing to hold
      refute requires.([@three])
    end

    test "carries core's row threshold among the rules", %{catalogue: catalogue, ctx: ctx} do
      item = item_with(catalogue, [@one])

      assert {:preview, preview, _} = detach([row(item, ids([@two]))], dry(ctx))
      assert preview["confirmation_rules"] == %{"confirm_batch_over" => 50}
    end

    test "agrees with the danger check of the tool", %{catalogue: catalogue, ctx: ctx} do
      item = item_with(catalogue, [@one, @two])

      for images <- [[@one], [@one, @two], [@three]] do
        rows = [row(item, ids(images))]
        input = %{"items" => rows}

        assert {:preview, preview, _} = detach(rows, dry(ctx))
        assert preview["requires_confirmation"] == DetachImages.dangerous?(input, ctx)
      end
    end

    test "a batch over core's row threshold is held whatever it removes", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      previous = Settings.get_setting("api_confirm_batch_over")
      {:ok, _} = Settings.update_setting("api_confirm_batch_over", "2")
      on_exit(fn -> Settings.update_setting("api_confirm_batch_over", previous || "50") end)

      rows = for _ <- 1..3, do: row(item_with(catalogue, [@one, @two]), ids([@one]))

      assert {:preview, preview, _} = detach(rows, dry(ctx))
      assert preview["requires_confirmation"] == true
    end
  end

  describe "real pictures" do
    @describetag skip:
                   if(System.find_executable("convert"),
                     do: false,
                     else: "ImageMagick (convert) is not installed"
                   )

    @stub __MODULE__
    @host "https://93.184.216.34"

    setup %{catalogue: catalogue} do
      dir = Path.join(System.tmp_dir!(), "detach_images_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      Application.put_env(:phoenix_kit_ecommerce, :api_image_download_opts,
        req_options: [plug: {Req.Test, @stub}]
      )

      on_exit(fn ->
        File.rm_rf(dir)
        Application.delete_env(:phoenix_kit_ecommerce, :api_image_download_opts)
      end)

      first = draw(dir, "first.png", 21)
      second = draw(dir, "second.png", 22)
      third = draw(dir, "third.png", 23)

      Req.Test.stub(@stub, fn conn ->
        body =
          case conn.request_path do
            "/a.png" -> first
            "/c.png" -> third
            _ -> second
          end

        conn |> Plug.Conn.put_resp_content_type("image/png") |> Plug.Conn.send_resp(200, body)
      end)

      %{catalogue: catalogue}
    end

    defp draw(dir, name, seed) do
      path = Path.join(dir, name)

      {_, 0} =
        System.cmd(
          "convert",
          ["-size", "320x240", "-seed", to_string(seed), "plasma:fractal", path],
          stderr_to_stdout: true
        )

      File.read!(path)
    end

    defp attach(item, paths, ctx) do
      images = Enum.map(paths, &%{"url" => @host <> &1})

      {:ok, _} =
        APICase.call("ecommerce.attach_images", %{"items" => [row(item, images)]}, ctx)

      F.reload!(item).data["media_order"]
    end

    defp status(uuid), do: Storage.get_file(uuid).status

    test "the only product that has a picture: the file is trashed, not deleted", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = F.item!(catalogue)
      [kept, gone] = attach(item, ["/a.png", "/b.png"], ctx)

      assert {:ok, %{"results" => [%{"detached" => 1}]}} = detach([row(item, ids([gone]))], ctx)

      assert F.reload!(item).data["media_order"] == [kept]
      assert status(gone) == "trashed"
      assert status(kept) == "active"
    end

    test "a picture is found by the URL it was attached from, query and all", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = F.item!(catalogue)
      [kept, gone] = attach(item, ["/a.png", "/b.png"], ctx)

      assert {:ok, %{"results" => [result]}} =
               detach([row(item, [%{"url" => @host <> "/b.png?sig=secret"}])], ctx)

      assert result["detached"] == 1
      refute inspect(result) =~ "secret"
      assert F.reload!(item).data["media_order"] == [kept]
      assert status(gone) == "trashed"
    end

    test "a URL that no stored picture came from is reported without its query", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = F.item!(catalogue)
      [kept] = attach(item, ["/a.png"], ctx)

      assert {:ok, %{"results" => [result], "summary" => %{"unchanged" => 1}}} =
               detach([row(item, [%{"url" => @host <> "/nope.png?sig=secret"}])], ctx)

      assert result["not_attached"] == [@host <> "/nope.png"]
      refute inspect(result) =~ "secret"
      assert F.reload!(item).data["media_order"] == [kept]
    end

    test "a picture another product shares stays alive and stays theirs", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      mine = F.item!(catalogue)
      theirs = F.item!(catalogue)
      [shared] = attach(mine, ["/a.png"], ctx)
      assert attach(theirs, ["/a.png"], ctx) == [shared]

      assert {:ok, %{"summary" => %{"updated" => 1}}} =
               detach([row(mine, ids([shared]))], confirmed(ctx))

      assert F.reload!(mine).data["media_order"] == []
      assert F.reload!(theirs).data["media_order"] == [shared]
      assert status(shared) == "active"

      # and the other way round: the one that held the link lets go of it
      assert {:ok, %{"summary" => %{"updated" => 1}}} =
               detach([row(theirs, ids([shared]))], confirmed(ctx))

      assert status(shared) == "trashed"
    end

    test "a picture of another product is not removed by naming it", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      mine = F.item!(catalogue)
      theirs = F.item!(catalogue)
      [_own] = attach(mine, ["/a.png"], ctx)
      [foreign] = attach(theirs, ["/b.png"], ctx)

      assert {:ok, %{"results" => [result]}} = detach([row(mine, ids([foreign]))], ctx)

      assert result["action"] == "unchanged"
      assert result["not_attached"] == [foreign]
      assert F.reload!(theirs).data["media_order"] == [foreign]
      assert status(foreign) == "active"
    end

    test "a URL is matched against the product's own pictures, not the shop's first file for it",
         %{catalogue: catalogue, ctx: ctx} do
      theirs = F.item!(catalogue)
      mine = F.item!(catalogue)
      [older] = attach(theirs, ["/a.png"], ctx)
      [newer] = attach(mine, ["/b.png"], ctx)
      assert newer != older

      # a duplicate of /a.png that an earlier run left: the same source URL on a newer file
      file = Storage.get_file(newer)

      Repo.update_all(
        from(f in Storage.File, where: f.uuid == ^newer),
        set: [metadata: Map.put(file.metadata, "source_url", @host <> "/a.png")]
      )

      assert {:ok, %{"results" => [result]}} =
               detach([row(mine, [%{"url" => @host <> "/a.png"}])], confirmed(ctx))

      assert result["detached"] == 1
      assert result["not_attached"] == []
      assert F.reload!(mine).data["media_order"] == []
      assert F.reload!(theirs).data["media_order"] == [older]
      assert status(older) == "active"
      assert status(newer) == "trashed"
    end

    test "a picture whose file is already in the trash can still be taken out by URL", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = F.item!(catalogue)
      [kept, dead] = attach(item, ["/a.png", "/b.png"], ctx)
      Repo.update_all(from(f in Storage.File, where: f.uuid == ^dead), set: [status: "trashed"])

      assert {:ok, %{"results" => [%{"detached" => 1}]}} =
               detach([row(item, [%{"url" => @host <> "/b.png"}])], ctx)

      assert F.reload!(item).data["media_order"] == [kept]
    end

    test "a gallery that can not be saved gives the files back", %{catalogue: catalogue, ctx: ctx} do
      item = F.item!(catalogue)
      [kept, gone] = attach(item, ["/a.png", "/b.png"], ctx)
      # a blank name fails the catalogue's validation of the write
      set_item(item, name: "")

      {answer, log} = with_log(fn -> detach([row(item, ids([gone]))], ctx) end)

      assert {:ok, %{"results" => [result], "summary" => %{"error" => 1}}} = answer
      assert result["error"]["context"]["reason"] == "database_error"
      assert log =~ "saving the gallery failed"
      assert status(gone) == "active"
      assert F.reload!(item).data["media_order"] == [kept, gone]
    end

    test "an exception inside core's removal rolls the row back as a database error", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = F.item!(catalogue)
      [kept, gone] = attach(item, ["/a.png", "/b.png"], ctx)
      # a folder that is not a UUID: core's removal rule raises on the lookup of its link,
      # inside the nested transaction, which poisons the one around it
      set_item(item, data: Map.put(F.reload!(item).data, "files_folder_uuid", "not-a-uuid"))

      {answer, log} = with_log(fn -> detach([row(item, ids([gone]))], ctx) end)

      assert {:ok, %{"results" => [result]}} = answer
      assert result["error"]["code"] == "validation_failed"
      assert result["error"]["context"]["reason"] == "database_error"
      assert log =~ "detaching a file failed"
      assert F.reload!(item).data["media_order"] == [kept, gone]
      assert status(gone) == "active"
    end

    # Core's removal of the files in `fail_for` is replaced by `failure`; every
    # other file goes through core.
    defp release_with(fail_for, failure) do
      Application.put_env(:phoenix_kit_ecommerce, :api_detach_file, fn file, folder ->
        if file in fail_for, do: failure.(file), else: ResourceFolders.detach(file, folder)
      end)

      on_exit(fn -> Application.delete_env(:phoenix_kit_ecommerce, :api_detach_file) end)
    end

    defp three(catalogue, ctx) do
      item = F.item!(catalogue)
      [a, b, c] = attach(item, ["/a.png", "/b.png", "/c.png"], ctx)
      {item, a, b, c}
    end

    test "a file core refuses to release stays in the gallery, the others go", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      {item, a, b, c} = three(catalogue, ctx)
      release_with([b], fn _file -> {:error, :boom} end)

      {answer, log} = with_log(fn -> detach([row(item, ids([b, c]))], ctx) end)

      assert {:ok, %{"results" => [result], "summary" => %{"updated" => 1}}} = answer
      assert result["detached"] == 1
      assert result["failed"] == [b]
      assert log =~ "detaching a file failed"
      assert F.reload!(item).data["media_order"] == [a, b]
      assert status(b) == "active"
      assert status(c) == "trashed"
    end

    test "when core refuses every file the row fails and nothing moves", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      {item, a, b, c} = three(catalogue, ctx)
      release_with([b], fn _file -> {:error, :boom} end)

      {answer, _log} = with_log(fn -> detach([row(item, ids([b]))], ctx) end)

      assert {:ok, %{"results" => [result], "summary" => %{"error" => 1}}} = answer
      assert result["error"]["code"] == "validation_failed"
      assert result["error"]["message"] == "No picture could be detached."
      assert result["error"]["context"]["images"] == [b]
      refute Map.has_key?(result["error"]["context"], "reason")
      assert F.reload!(item).data["media_order"] == [a, b, c]
      assert status(b) == "active"
    end

    test "a file whose release raises fails the row and gives back the files already released",
         %{catalogue: catalogue, ctx: ctx} do
      {item, a, b, c} = three(catalogue, ctx)
      [first, second] = Enum.sort([b, c])
      release_with([second], fn _file -> raise "boom" end)

      {answer, log} = with_log(fn -> detach([row(item, ids([b, c]))], ctx) end)

      assert {:ok, %{"results" => [result]}} = answer
      assert result["error"]["context"]["reason"] == "storage_error"
      assert log =~ "detaching raised: RuntimeError"
      refute log =~ "boom"
      assert F.reload!(item).data["media_order"] == [a, b, c]
      assert status(first) == "active"
      assert status(second) == "active"
    end

    defp set_source(uuid, set) do
      metadata = Map.merge(Storage.get_file(uuid).metadata, set)
      Repo.update_all(from(f in Storage.File, where: f.uuid == ^uuid), set: [metadata: metadata])
    end

    test "every file of the gallery that came from the URL goes", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = F.item!(catalogue)
      [one, two] = attach(item, ["/a.png", "/b.png"], ctx)
      set_source(two, %{"source_url" => @host <> "/a.png"})

      assert {:ok, %{"results" => [result]}} =
               detach([row(item, [%{"url" => @host <> "/a.png"}])], confirmed(ctx))

      assert result["detached"] == 2
      assert F.reload!(item).data["media_order"] == []
      assert status(one) == "trashed"
      assert status(two) == "trashed"
    end

    test "a URL a file also resolved to, kept as an alias, finds it", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = F.item!(catalogue)
      [kept, aliased] = attach(item, ["/a.png", "/b.png"], ctx)
      set_source(aliased, %{"source_url_aliases" => [@host <> "/old.png"]})

      assert {:ok, %{"results" => [result]}} =
               detach([row(item, [%{"url" => @host <> "/old.png?v=2"}])], ctx)

      assert result["detached"] == 1
      assert F.reload!(item).data["media_order"] == [kept]
      assert status(aliased) == "trashed"
    end

    test "files are locked in sorted order whatever order the call names them", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      {item, _a, b, c} = three(catalogue, ctx)
      [low, high] = Enum.sort([b, c])

      test = self()
      id = {:lock_order, make_ref()}

      :telemetry.attach(
        id,
        [:phoenix_kit_ecommerce, :test, :repo, :query],
        fn _event, _measurements, meta, _config ->
          if meta.source == "phoenix_kit_files" and String.contains?(meta.query, "FOR UPDATE"),
            do: send(test, {:locked, hd(meta.params)})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)

      assert {:ok, %{"results" => [%{"detached" => 2}]}} =
               detach([row(item, ids([high, low]))], ctx)

      locked = receive_locked([])
      assert locked |> Enum.map(&Ecto.UUID.cast!/1) |> Enum.dedup() == [low, high]
    end

    defp receive_locked(acc) do
      receive do
        {:locked, uuid} -> receive_locked([uuid | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end
  end
end
