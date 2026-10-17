defmodule PhoenixKitEcommerce.API.AttachImagesTest do
  @moduledoc """
  `ecommerce.attach_images` against a real catalogue and real Storage rows:
  pictures are downloaded, stored and appended; a known URL is reused; the
  private-network guard holds even with the shop's import setting on; a dry
  run fetches nothing.

  HTTP goes through `Req.Test`'s plug adapter (the hook
  `config :phoenix_kit_ecommerce, :api_image_download_opts`), never the
  network. The pictures are drawn with ImageMagick, as in the downloader's
  own store tests; skipped where it is missing. `async: false`: it reads the
  shop-wide URL index and flips settings.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :catalogue_api
  @moduletag :core_confirm
  @moduletag skip:
               if(System.find_executable("convert"),
                 do: false,
                 else: "ImageMagick (convert) is not installed"
               )

  import ExUnit.CaptureLog, only: [with_log: 2]

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Settings
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce.API.AttachImages
  alias PhoenixKitEcommerce.APICase
  alias PhoenixKitEcommerce.APIFixtures, as: F
  alias PhoenixKitEcommerce.Services.ImageDownloader
  alias PhoenixKitEcommerce.StorefrontCache
  alias PhoenixKitEcommerce.Test.Repo

  @stub __MODULE__
  @host "https://93.184.216.34"

  setup do
    dir = Path.join(System.tmp_dir!(), "attach_images_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    Application.put_env(:phoenix_kit_ecommerce, :api_image_download_opts,
      req_options: [plug: {Req.Test, @stub}]
    )

    on_exit(fn ->
      File.rm_rf(dir)
      Application.delete_env(:phoenix_kit_ecommerce, :api_image_download_opts)

      Settings.update_boolean_setting_with_module(
        "shop_image_import_allow_private_networks",
        false,
        "shop"
      )
    end)

    catalogue = F.shop_catalogue!()
    user = F.user!()

    %{
      catalogue: catalogue,
      user: user,
      ctx: F.ctx(user),
      first: draw(dir, "first.png", 11),
      second: draw(dir, "second.png", 12)
    }
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

  # The same picture saved again as a lossy JPEG: other bytes, other file name.
  defp reencode(png) do
    base =
      Path.join(System.tmp_dir!(), "attach_images_copy_#{System.unique_integer([:positive])}")

    File.write!(base <> ".png", png)

    {_, 0} =
      System.cmd("convert", [base <> ".png", "-quality", "60", base <> ".jpg"],
        stderr_to_stdout: true
      )

    jpeg = File.read!(base <> ".jpg")
    File.rm(base <> ".png")
    File.rm(base <> ".jpg")
    jpeg
  end

  # Serves `%{"/path" => {content_type, body}}` and reports each request to the test.
  defp serve(routes) do
    test_pid = self()

    Req.Test.stub(@stub, fn conn ->
      send(test_pid, {:requested, conn.request_path})
      {type, body} = Map.fetch!(routes, conn.request_path)
      conn |> Plug.Conn.put_resp_content_type(type) |> Plug.Conn.send_resp(200, body)
    end)
  end

  defp attach(rows, ctx), do: APICase.call("ecommerce.attach_images", %{"items" => rows}, ctx)

  # The handler without the schema in front of it: for the test that pins the
  # planner's own second line of defence (a scheme the schema already refuses).
  defp attach_raw(rows, ctx), do: AttachImages.run(%{"items" => rows}, ctx)

  defp row(item, images), do: %{"ref" => %{"id" => item.uuid}, "images" => images}
  defp image(path, extra \\ %{}), do: Map.merge(%{"url" => @host <> path}, extra)

  test "downloads, stores and appends pictures; the first becomes the featured one",
       %{catalogue: catalogue, ctx: ctx, first: first, second: second} do
    item = F.item!(catalogue)
    serve(%{"/a.png" => {"image/png", first}, "/b.png" => {"image/png", second}})

    assert {:ok, %{"results" => [result], "summary" => %{"updated" => 1}}} =
             attach([row(item, [image("/a.png"), image("/b.png")])], ctx)

    assert result["action"] == "updated"
    assert result["attached"] == 2
    assert result["downloaded"] == 2
    assert result["reused"] == 0
    assert result["failed"] == []

    data = F.reload!(item).data
    assert [one, two] = data["media_order"]
    assert one != two
    assert data["featured_image_uuid"] == one
  end

  test "new pictures go after the ones the product has, and a featured flag moves the main one",
       %{catalogue: catalogue, ctx: ctx, first: first, second: second} do
    item = F.item!(catalogue)
    serve(%{"/a.png" => {"image/png", first}, "/b.png" => {"image/png", second}})

    assert {:ok, _} = attach([row(item, [image("/a.png")])], ctx)
    [first_uuid] = F.reload!(item).data["media_order"]

    assert {:ok, %{"results" => [%{"attached" => 1}]}} =
             attach([row(item, [image("/b.png", %{"featured" => true})])], ctx)

    data = F.reload!(item).data
    assert [^first_uuid, second_uuid] = data["media_order"]
    assert data["featured_image_uuid"] == second_uuid
  end

  test "a URL that is already stored is reused without a request", %{
    catalogue: catalogue,
    ctx: ctx,
    first: first
  } do
    one = F.item!(catalogue)
    two = F.item!(catalogue)
    serve(%{"/a.png" => {"image/png", first}})

    assert {:ok, _} = attach([row(one, [image("/a.png")])], ctx)
    assert_received {:requested, "/a.png"}

    assert {:ok, %{"results" => [result]}} = attach([row(two, [image("/a.png")])], ctx)
    refute_received {:requested, _}

    assert result["reused"] == 1
    assert result["downloaded"] == 0
    assert F.reload!(one).data["media_order"] == F.reload!(two).data["media_order"]
  end

  test "a stored picture trashed after the call looked it up is not attached", %{
    catalogue: catalogue,
    ctx: ctx,
    first: first
  } do
    one = F.item!(catalogue)
    two = F.item!(catalogue)
    serve(%{"/a.png" => {"image/png", first}})

    assert {:ok, _} = attach([row(one, [image("/a.png")])], ctx)
    [stored] = F.reload!(one).data["media_order"]

    # Between the lookup of the stored pictures and the product's lock.
    trash_after_the_lookup(stored)

    assert {:ok, %{"results" => [result], "summary" => %{"error" => 1}}} =
             attach([row(two, [image("/a.png")])], ctx)

    assert result["error"]["context"]["images"] == [
             %{
               "url" => @host <> "/a.png",
               "reason" => "the stored picture is no longer available"
             }
           ]

    refute Map.has_key?(F.reload!(two).data, "media_order")
  end

  defp trash_after_the_lookup(file_uuid) do
    id = {:trash_after_lookup, make_ref()}

    :telemetry.attach(
      id,
      [:phoenix_kit_ecommerce, :test, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if meta.source == "phoenix_kit_files" and String.starts_with?(meta.query, "SELECT") do
          :telemetry.detach(id)
          trash_file(file_uuid)
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp trash_file(file_uuid) do
    Repo.update_all(
      from(f in Storage.File, where: f.uuid == ^file_uuid),
      set: [status: "trashed"]
    )
  end

  test "a re-encoded copy of a picture the shop already has reuses that file instead of storing another",
       %{catalogue: catalogue, ctx: ctx, first: first, second: second} do
    one = F.item!(catalogue)
    two = F.item!(catalogue)

    serve(%{
      "/a.png" => {"image/png", first},
      "/copy.jpg" => {"image/jpeg", reencode(first)},
      "/other.png" => {"image/png", second}
    })

    assert {:ok, _} = attach([row(one, [image("/a.png")])], ctx)
    [stored] = F.reload!(one).data["media_order"]

    assert {:ok, %{"results" => [copy, different]}} =
             attach([row(two, [image("/copy.jpg")]), row(one, [image("/other.png")])], ctx)

    assert_received {:requested, "/copy.jpg"}
    assert copy["downloaded"] == 1
    assert F.reload!(two).data["media_order"] == [stored]

    # a different picture is still stored as a new file
    assert different["attached"] == 1
    assert [^stored, other] = F.reload!(one).data["media_order"]
    assert other != stored
  end

  test "private addresses and other schemes are refused even with the import setting on, and nothing is fetched",
       %{catalogue: catalogue, ctx: ctx} do
    Settings.update_boolean_setting_with_module(
      "shop_image_import_allow_private_networks",
      true,
      "shop"
    )

    serve(%{})
    item = F.item!(catalogue)

    # private addresses pass the schema (they are http(s) URLs) and are refused by the planner
    for url <- ["http://127.0.0.1/a.png", "https://10.0.0.5/a.png", "https://169.254.169.254/x"] do
      assert {:ok, %{"results" => [result]}} = attach([row(item, [%{"url" => url}])], ctx)

      assert result["action"] == "error", "#{url} must be refused"
      assert result["error"]["code"] == "validation_failed"
      assert [%{"path" => "images[0].url"}] = result["error"]["context"]["errors"]
    end

    # other schemes: the schema refuses them before any handler runs ...
    for url <- ["file:///etc/passwd", "ftp://93.184.216.34/a.png"] do
      assert {:error, :validation_failed, _message, %{errors: [%{path: path} | _]}} =
               attach([row(item, [%{"url" => url}])], ctx)

      assert path == "items[0].images[0].url", "#{url} must be refused by the schema"

      # ... and the planner refuses them too, were one to get past it
      assert {:ok, %{"results" => [result]}} = attach_raw([row(item, [%{"url" => url}])], ctx)
      assert result["action"] == "error"
      assert [%{"path" => "images[0].url"}] = result["error"]["context"]["errors"]
    end

    refute_received {:requested, _}
    assert F.reload!(item).data["media_order"] in [nil, []]
  end

  test "a URL with credentials in it is refused and reaches no log line, answer or request", %{
    catalogue: catalogue,
    ctx: ctx
  } do
    serve(%{})
    item = F.item!(catalogue)
    url = "https://user:sekrit@93.184.216.34/a.png"

    {answers, log} =
      with_log([level: :debug], fn ->
        {attach([row(item, [%{"url" => url}])], ctx),
         attach_raw([row(item, [%{"url" => url}])], ctx)}
      end)

    # the schema refuses it ...
    assert {{:error, :validation_failed, _message, %{errors: [%{path: path} | _]}}, raw} = answers
    assert path == "items[0].images[0].url"

    # ... and the planner refuses it too, were one to get past the schema
    assert {:ok, %{"results" => [result]}} = raw
    assert result["action"] == "error"
    assert result["error"]["code"] == "validation_failed"
    assert [%{"path" => "images[0].url"}] = result["error"]["context"]["errors"]

    refute inspect(answers) =~ "sekrit"
    refute log =~ "sekrit"
    refute_received {:requested, _}
    assert F.reload!(item).data["media_order"] in [nil, []]
  end

  test "a fragment of the URL is in no stored source_url and not in the answer for a failed picture",
       %{
         catalogue: catalogue,
         ctx: ctx,
         first: first
       } do
    item = F.item!(catalogue)
    serve(%{"/ok.png" => {"image/png", first}, "/doc.pdf" => {"application/pdf", "%PDF"}})

    assert {:ok, %{"results" => [result]}} =
             attach(
               [row(item, [image("/ok.png#sekrit1"), image("/doc.pdf#sekrit2")])],
               ctx
             )

    assert [%{"url" => failed_url}] = result["failed"]
    assert failed_url == @host <> "/doc.pdf"

    [file_uuid] = F.reload!(item).data["media_order"]
    file = Storage.get_file(file_uuid)
    assert file.metadata["source_url"] == @host <> "/ok.png"
    refute inspect({result, file.metadata}) =~ "sekrit"
  end

  test "a redirect to a private address fails the picture and attaches nothing", %{
    catalogue: catalogue,
    ctx: ctx
  } do
    Settings.update_boolean_setting_with_module(
      "shop_image_import_allow_private_networks",
      true,
      "shop"
    )

    Req.Test.stub(@stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "https://127.0.0.1/secret.png")
      |> Plug.Conn.send_resp(302, "")
    end)

    item = F.item!(catalogue)

    assert {:ok, %{"results" => [result]}} = attach([row(item, [image("/a.png")])], ctx)

    assert result["action"] == "error"
    assert [%{"reason" => reason}] = result["error"]["context"]["images"]
    assert reason =~ "private"
    assert F.reload!(item).data["media_order"] in [nil, []]
  end

  test "a body that is not the picture it claims to be is refused, an SVG whatever the shop setting says",
       %{catalogue: catalogue, ctx: ctx, first: first} do
    on_exit(fn ->
      Settings.update_boolean_setting_with_module("shop_allow_svg_uploads", false, "shop")
    end)

    Settings.update_boolean_setting_with_module("shop_allow_svg_uploads", true, "shop")
    item = F.item!(catalogue)

    serve(%{
      "/page.png" => {"image/png", "<html><script>alert(1)</script></html>"},
      "/vector.svg" =>
        {"image/svg+xml", ~s(<svg xmlns="http://www.w3.org/2000/svg"><script/></svg>)},
      "/fine.png" => {"image/png", first}
    })

    assert {:ok, %{"results" => [result]}} =
             attach(
               [row(item, [image("/page.png"), image("/vector.svg"), image("/fine.png")])],
               ctx
             )

    assert result["attached"] == 1

    assert [%{"url" => page, "reason" => reason}, %{"url" => vector, "reason" => reason_two}] =
             result["failed"]

    assert page == @host <> "/page.png"
    assert vector == @host <> "/vector.svg"
    assert reason =~ "not a PNG, JPEG, GIF or WebP"
    assert reason_two == reason
    assert [_one] = F.reload!(item).data["media_order"]
  end

  test "a picture that fails does not hide the one that worked", %{
    catalogue: catalogue,
    ctx: ctx,
    first: first
  } do
    item = F.item!(catalogue)
    serve(%{"/a.png" => {"image/png", first}, "/doc.pdf" => {"application/pdf", "%PDF"}})

    assert {:ok, %{"results" => [result]}} =
             attach([row(item, [image("/a.png"), image("/doc.pdf?token=secret")])], ctx)

    assert result["action"] == "updated"
    assert result["attached"] == 1
    assert [%{"url" => failed_url}] = result["failed"]
    assert failed_url == @host <> "/doc.pdf"
    refute inspect(result) =~ "secret"
  end

  test "a dry run checks the URLs and fetches nothing", %{catalogue: catalogue, ctx: ctx} do
    serve(%{})
    item = F.item!(catalogue)
    logged = length(list_activities())

    rows = [
      row(item, [image("/a.png")]),
      %{"ref" => %{"sku" => "NONE"}, "images" => [image("/b.png")]}
    ]

    assert {:preview, preview, fingerprint} = attach(rows, %{ctx | dry_run?: true})

    assert fingerprint =~ ~r/\A[0-9a-f]{64}\z/
    assert Enum.map(preview["rows"], & &1["action"]) == ["update", "error"]
    refute_received {:requested, _}
    assert F.reload!(item).data["media_order"] in [nil, []]
    assert length(list_activities()) == logged
  end

  test "a picture attached to a product linked to Shopify carries the overwrite warning while the sync is on",
       %{catalogue: catalogue, ctx: ctx, first: first, second: second} do
    shopify = PhoenixKitEcommerce.shopify_enabled?()

    on_exit(fn ->
      Settings.update_boolean_setting_with_module("shop_shopify_enabled", shopify, "shop")
    end)

    linked =
      F.item!(catalogue, %{
        data: %{
          "_primary_language" => "en",
          "ecommerce" => %{"shop_status" => "active", "shopify" => %{"handle" => "mug"}}
        }
      })

    plain = F.item!(catalogue)
    serve(%{"/a.png" => {"image/png", first}, "/b.png" => {"image/png", second}})

    Settings.update_boolean_setting_with_module("shop_shopify_enabled", true, "shop")

    assert {:ok, %{"results" => [a, b]}} =
             attach([row(linked, [image("/a.png")]), row(plain, [image("/b.png")])], ctx)

    assert a["warnings"] == ["shopify_sync_may_overwrite"]
    assert b["warnings"] == []

    Settings.update_boolean_setting_with_module("shop_shopify_enabled", false, "shop")

    assert {:ok, %{"results" => [off]}} = attach([row(linked, [image("/b.png")])], ctx)
    assert off["warnings"] == []
  end

  test "more than 20 pictures in a call are refused before anything happens", %{
    catalogue: catalogue,
    ctx: ctx
  } do
    one = F.item!(catalogue)
    two = F.item!(catalogue)
    first = for n <- 1..11, do: image("/#{n}.png")
    second = for n <- 12..21, do: image("/#{n}.png")

    # 11 + 10: each row is within the schema's 20 per row, the call is not
    assert {:error, :validation_failed, _detail, %{errors: [%{path: "items", limit: 20}]}} =
             attach([row(one, first), row(two, second)], ctx)

    # 21 in one row is refused earlier, by the schema
    assert {:error, :validation_failed, _detail, %{errors: [%{path: path} | _]}} =
             attach([row(one, first ++ second)], ctx)

    assert path == "items[0].images"
  end

  test "two featured pictures in one row are refused", %{catalogue: catalogue, ctx: ctx} do
    item = F.item!(catalogue)

    assert {:ok, %{"results" => [result]}} =
             attach(
               [
                 row(item, [
                   image("/a.png", %{"featured" => true}),
                   image("/b.png", %{"featured" => true})
                 ])
               ],
               ctx
             )

    assert result["error"]["code"] == "validation_failed"
  end

  test "logs the attachment with the API metadata and no URLs", %{
    catalogue: catalogue,
    user: user,
    ctx: ctx,
    first: first
  } do
    item = F.item!(catalogue)
    serve(%{"/a.png" => {"image/png", first}})

    assert {:ok, _} = attach([row(item, [image("/a.png?sig=abc")])], ctx)

    entry =
      assert_activity_logged("shop.api_images_attached",
        resource_uuid: item.uuid,
        actor_uuid: user.uuid,
        metadata_has: %{"via" => "api", "tool" => "ecommerce.attach_images", "attached" => 1}
      )

    refute inspect(entry) =~ "sig=abc"
  end

  describe "the name lookups of the planning" do
    setup do
      previous = Application.get_env(:phoenix_kit_ecommerce, :image_resolver)

      Application.put_env(
        :phoenix_kit_ecommerce,
        :image_resolver,
        PhoenixKitEcommerce.Test.StubResolver
      )

      Application.put_env(:phoenix_kit_ecommerce, :image_dns_timeout, 300)

      on_exit(fn ->
        Application.delete_env(:phoenix_kit_ecommerce, :image_dns_timeout)

        if previous,
          do: Application.put_env(:phoenix_kit_ecommerce, :image_resolver, previous),
          else: Application.delete_env(:phoenix_kit_ecommerce, :image_resolver)
      end)
    end

    test "a resolver that never answers holds a dry run for one deadline per batch of five URLs, not one per URL",
         %{catalogue: catalogue, ctx: ctx} do
      item = F.item!(catalogue)
      urls = for n <- 1..10, do: %{"url" => "https://slow-#{n}.example.test/a.png"}

      {microseconds, answer} =
        :timer.tc(fn -> attach([row(item, urls)], %{ctx | dry_run?: true}) end)

      assert {:preview, %{"rows" => [%{"action" => "error", "error" => error}]}, _fingerprint} =
               answer

      assert length(error["context"]["errors"]) == 10
      assert microseconds < 2_000_000
    end
  end

  describe "a product that leaves the shop catalogue while its pictures download" do
    # The picture is fetched by the stub below, which first lets `leave` happen
    # to the product: the downloads take long enough in production for that.
    defp serve_while(png, leave) do
      Req.Test.stub(@stub, fn conn ->
        leave.()
        conn |> Plug.Conn.put_resp_content_type("image/png") |> Plug.Conn.send_resp(200, png)
      end)
    end

    test "a trashed product gets no pictures and its row says so", %{
      catalogue: catalogue,
      ctx: ctx,
      first: first
    } do
      item = F.item!(catalogue)
      serve_while(first, fn -> {:ok, _} = Catalogue.trash_item(item) end)

      assert {:ok, %{"results" => [result], "summary" => %{"error" => 1, "updated" => 0}}} =
               attach([row(item, [image("/a.png")])], ctx)

      assert result["error"]["code"] == "not_found"
      assert F.reload!(item).data["media_order"] in [nil, []]
    end

    test "a product moved to another catalogue gets no pictures", %{
      catalogue: catalogue,
      ctx: ctx,
      first: first
    } do
      item = F.item!(catalogue)
      other = F.other_catalogue!()

      serve_while(first, fn ->
        {:ok, _} = Catalogue.update_item(item, %{catalogue_uuid: other.uuid})
      end)

      assert {:ok, %{"results" => [%{"error" => %{"code" => "not_found"}}]}} =
               attach([row(item, [image("/a.png")])], ctx)

      assert F.reload!(item).data["media_order"] in [nil, []]
    end

    test "a product that stays gets its pictures", %{catalogue: catalogue, ctx: ctx, first: first} do
      item = F.item!(catalogue)
      serve_while(first, fn -> :ok end)

      assert {:ok, %{"summary" => %{"updated" => 1}}} =
               attach([row(item, [image("/a.png")])], ctx)

      assert [_picture] = F.reload!(item).data["media_order"]
    end
  end

  describe "a row whose attachment rolls the lock's transaction back" do
    # An item whose name is blank fails the catalogue's validation inside
    # `Attachments.attach_files/3`, which rolls back the transaction it is
    # nested in. That row must answer an error; the call must go on.
    defp blank_name!(item) do
      import Ecto.Query, only: [from: 2]

      {1, _} =
        PhoenixKit.Config.get_repo().update_all(
          from(i in PhoenixKitCatalogue.Schemas.Item, where: i.uuid == ^item.uuid),
          set: [name: ""]
        )
    end

    test "answers a database_error for that row and still attaches the next one",
         %{catalogue: catalogue, ctx: ctx, first: first} do
      broken = F.item!(catalogue)
      fine = F.item!(catalogue)
      blank_name!(broken)
      serve(%{"/a.png" => {"image/png", first}})

      {answer, _log} =
        with_log([level: :error], fn ->
          attach([row(broken, [image("/a.png")]), row(fine, [image("/a.png")])], ctx)
        end)

      assert {:ok, %{"results" => [bad, good], "summary" => %{"error" => 1, "updated" => 1}}} =
               answer

      assert bad["action"] == "error"
      assert bad["error"]["code"] == "validation_failed"
      assert bad["error"]["context"]["reason"] == "database_error"
      assert good["action"] == "updated"

      assert F.reload!(broken).data["media_order"] in [nil, []]
      assert [_picture] = F.reload!(fine).data["media_order"]
    end
  end

  test "a signed URL's query string reaches no log line, no stored file metadata, no activity entry and no answer",
       %{catalogue: catalogue, user: user, ctx: ctx, first: first} do
    # The test environment logs from :warning up; the downloader's lines that
    # carried the URL are :info, so raise the level for this test only.
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)

    item = F.item!(catalogue)
    serve(%{"/signed.png" => {"image/png", first}, "/doc.pdf" => {"application/pdf", "%PDF"}})

    {answer, log} =
      with_log([level: :info], fn ->
        attach(
          [
            row(item, [
              image("/signed.png?X-Amz-Signature=sekrit"),
              image("/doc.pdf?X-Amz-Signature=sekrit")
            ])
          ],
          ctx
        )
      end)

    assert {:ok, %{"results" => [result]}} = answer
    assert result["attached"] == 1
    assert [%{"url" => failed_url}] = result["failed"]
    assert failed_url == @host <> "/doc.pdf"

    # The lines were emitted (they name the host) and carry neither the query
    # nor the path, which can hold a signed token too.
    assert log =~ "Storing new file from URL #{@host}/..."
    refute log =~ "signed.png"
    refute log =~ "sekrit"
    refute log =~ "X-Amz-Signature"
    refute inspect(result) =~ "sekrit"

    # The stored file remembers the URL without the credential.
    [file_uuid] = F.reload!(item).data["media_order"]
    file = Storage.get_file(file_uuid)
    assert file.metadata["source_url"] == @host <> "/signed.png"
    refute inspect(file.metadata) =~ "sekrit"

    entry =
      assert_activity_logged("shop.api_images_attached",
        resource_uuid: item.uuid,
        actor_uuid: user.uuid
      )

    refute inspect(entry) =~ "sekrit"
  end

  test "a picture stored earlier by the importer under a URL with a query is reused for the same URL with another query",
       %{catalogue: catalogue, user: user, ctx: ctx, first: first} do
    serve(%{"/a.png" => {"image/png", first}})

    assert {:ok, file_uuid} =
             ImageDownloader.download_and_store(@host <> "/a.png?v=1", user.uuid,
               req_options: [plug: {Req.Test, @stub}]
             )

    assert_received {:requested, "/a.png"}

    item = F.item!(catalogue)
    assert {:ok, %{"results" => [result]}} = attach([row(item, [image("/a.png?v=2")])], ctx)

    refute_received {:requested, _}
    assert result["reused"] == 1
    assert F.reload!(item).data["media_order"] == [file_uuid]
  end

  test "a picture over the API's size limit fails its row", %{catalogue: catalogue, ctx: ctx} do
    Req.Test.stub(@stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, :binary.copy("x", AttachImages.max_image_bytes() + 1))
    end)

    item = F.item!(catalogue)

    assert {:ok, %{"results" => [result]}} = attach([row(item, [image("/big.png")])], ctx)

    assert result["action"] == "error"
    assert [%{"reason" => reason}] = result["error"]["context"]["images"]
    assert reason =~ "exceeds limit"
    assert F.reload!(item).data["media_order"] in [nil, []]
  end

  test "pictures of several products are fetched together, and a URL given twice once", %{
    catalogue: catalogue,
    ctx: ctx,
    first: first,
    second: second
  } do
    one = F.item!(catalogue)
    two = F.item!(catalogue)
    serve(%{"/a.png" => {"image/png", first}, "/b.png" => {"image/png", second}})

    assert {:ok, %{"results" => [r1, r2], "summary" => %{"updated" => 2}}} =
             attach(
               [row(one, [image("/a.png")]), row(two, [image("/a.png"), image("/b.png")])],
               ctx
             )

    assert r1["attached"] == 1
    assert r2["attached"] == 2

    assert_received {:requested, "/a.png"}
    assert_received {:requested, "/b.png"}
    refute_received {:requested, _}

    assert [shared] = F.reload!(one).data["media_order"]
    assert [^shared, _other] = F.reload!(two).data["media_order"]
  end

  test "a picture added to the product while the download runs keeps its place in the order", %{
    catalogue: catalogue,
    ctx: ctx,
    first: first
  } do
    item = F.item!(catalogue)
    test_pid = self()

    Req.Test.stub(@stub, fn conn ->
      # an editor adds a picture to the product while this request is served
      {:ok, _} =
        PhoenixKitCatalogue.Catalogue.update_item(
          F.reload!(item),
          %{data: %{"media_order" => ["added-meanwhile"]}},
          data_owned_keys: ["media_order"]
        )

      send(test_pid, {:requested, conn.request_path})
      conn |> Plug.Conn.put_resp_content_type("image/png") |> Plug.Conn.send_resp(200, first)
    end)

    assert {:ok, %{"results" => [%{"attached" => 1}]}} =
             attach([row(item, [image("/a.png")])], ctx)

    assert ["added-meanwhile", _new] = F.reload!(item).data["media_order"]
  end

  test "the log entry of the call is marked as not made by hand", %{
    catalogue: catalogue,
    ctx: ctx,
    first: first
  } do
    item = F.item!(catalogue)
    serve(%{"/a.png" => {"image/png", first}})

    assert {:ok, _} = attach([row(item, [image("/a.png")])], ctx)

    entry = assert_activity_logged("shop.api_images_attached", resource_uuid: item.uuid)
    assert entry.mode == "auto"
  end

  test "a long content type of the remote server is cut in the answer", %{
    catalogue: catalogue,
    ctx: ctx
  } do
    Req.Test.stub(@stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/" <> String.duplicate("a", 500))
      |> Plug.Conn.send_resp(200, "x")
    end)

    item = F.item!(catalogue)
    assert {:ok, %{"results" => [result]}} = attach([row(item, [image("/a.png")])], ctx)

    assert [%{"reason" => reason}] = result["error"]["context"]["images"]
    assert reason =~ "not an accepted image type"
    assert String.length(reason) < 150
  end

  test "combining marks in the content type do not get past the cap in the answer", %{
    catalogue: catalogue,
    ctx: ctx
  } do
    Req.Test.stub(@stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/a" <> String.duplicate("\u0301", 4000))
      |> Plug.Conn.send_resp(200, "x")
    end)

    item = F.item!(catalogue)
    assert {:ok, %{"results" => [result]}} = attach([row(item, [image("/a.png")])], ctx)

    assert [%{"reason" => reason}] = result["error"]["context"]["images"]
    assert reason =~ "not an accepted image type: text/a?"
    assert byte_size(reason) < 150
  end

  describe "a picture that cannot be fetched never takes the call down" do
    @cdn "cdn.sec-test.example"

    setup do
      lookup = :inet_db.res_option(:lookup)
      :inet_db.set_lookup([:file, :native])
      :inet_db.add_host({93, 184, 216, 34}, [String.to_charlist(@cdn)])

      on_exit(fn ->
        :inet_db.del_host({93, 184, 216, 34})
        :inet_db.set_lookup(lookup)
      end)
    end

    test "a host name URL with a space is refused for its row, with no request and no log line of it",
         %{catalogue: catalogue, ctx: ctx} do
      serve(%{})
      item = F.item!(catalogue)
      url = "https://#{@cdn}/a b.png?sig=SUPERSECRETSIGNATURE"

      {answer, log} =
        with_log([level: :debug], fn -> attach([row(item, [%{"url" => url}])], ctx) end)

      assert {:ok, %{"results" => [result]}} = answer
      assert result["action"] == "error"
      assert [%{"path" => "images[0].url"}] = result["error"]["context"]["errors"]
      refute inspect(answer) =~ "SUPERSECRETSIGNATURE"
      refute log =~ "SUPERSECRETSIGNATURE"
      refute_received {:requested, _}
    end

    test "a very long file name is shortened, the picture is stored",
         %{catalogue: catalogue, ctx: ctx, first: first} do
      item = F.item!(catalogue)
      path = "/" <> String.duplicate("a", 300) <> ".png"
      serve(%{path => {"image/png", first}})

      assert {:ok, %{"results" => [%{"attached" => 1, "failed" => []}]}} =
               attach([row(item, [host_image(path)])], ctx)

      [file_uuid] = F.reload!(item).data["media_order"]
      assert String.length(Storage.get_file(file_uuid).original_file_name) <= 130
    end

    test "a redirect to a URL with a non-ASCII path fails that picture; the others are kept",
         %{catalogue: catalogue, ctx: ctx, first: first} do
      item = F.item!(catalogue)
      test_pid = self()

      Req.Test.stub(@stub, fn conn ->
        send(test_pid, {:requested, conn.request_path})

        case conn.request_path do
          "/ok.png" ->
            conn
            |> Plug.Conn.put_resp_content_type("image/png")
            |> Plug.Conn.send_resp(200, first)

          "/moved.png" ->
            conn
            |> Plug.Conn.put_resp_header("location", "https://#{@cdn}/caf\u00E9.png?sig=SECRET")
            |> Plug.Conn.send_resp(302, "")
        end
      end)

      {answer, log} =
        with_log([level: :debug], fn ->
          attach(
            [row(item, [host_image("/ok.png"), host_image("/moved.png?sig=SECRET")])],
            ctx
          )
        end)

      assert {:ok, %{"results" => [result]}} = answer
      assert result["attached"] == 1
      assert [%{"url" => failed_url, "reason" => reason}] = result["failed"]
      assert failed_url == "https://#{@cdn}/moved.png"
      assert reason =~ "percent-encoded"
      refute log =~ "SECRET"
      refute inspect(answer) =~ "SECRET"
    end

    defp host_image(path), do: %{"url" => "https://#{@cdn}" <> path}
  end

  describe "the storefront cache" do
    setup do
      start_supervised!(PhoenixKit.Cache.Registry)
      [spec] = StorefrontCache.children()
      start_supervised!(spec)
      :ok
    end

    test "a stored picture clears it; a dry run and a failed row leave it", %{
      catalogue: catalogue,
      ctx: ctx,
      first: first
    } do
      item = F.item!(catalogue)
      serve(%{"/a.png" => {"image/png", first}, "/doc.pdf" => {"application/pdf", "%PDF"}})

      :stale = StorefrontCache.fetch(:probe, fn -> :stale end)

      assert {:preview, _, _} = attach([row(item, [image("/a.png")])], %{ctx | dry_run?: true})

      assert {:ok, %{"summary" => %{"error" => 1}}} =
               attach([row(item, [image("/doc.pdf")])], ctx)

      assert StorefrontCache.fetch(:probe, fn -> :fresh end) == :stale

      assert {:ok, %{"summary" => %{"updated" => 1}}} =
               attach([row(item, [image("/a.png")])], ctx)

      assert StorefrontCache.fetch(:probe, fn -> :fresh end) == :fresh
    end
  end

  test "the legacy source is refused", %{catalogue: catalogue, ctx: ctx} do
    item = F.item!(catalogue)
    F.put_config!("shop_product_source", "legacy")

    assert {:error, :unsupported_source, _detail, %{reason: "legacy_source"}} =
             attach([row(item, [image("/a.png")])], ctx)
  end
end
