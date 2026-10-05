defmodule PhoenixKitEcommerce.Services.ImageDownloaderStoreTest do
  @moduledoc """
  `ImageDownloader.download_and_store/3` against real Storage rows: which
  existing file it hands back instead of storing a second copy, and what
  it records on the way. HTTP goes through `Req.Test`'s plug adapter
  (public literal address, so the SSRF guard needs no DNS); the image
  bytes are real pictures drawn with ImageMagick, so the fingerprint is
  the one production computes. Skipped where ImageMagick is missing.

  `async: false`: the near-duplicate lookup reads every imported file,
  and these tests reason about exactly which rows exist.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKitEcommerce.Services.ImageDownloader
  alias PhoenixKitEcommerce.Services.ImageFingerprint
  alias PhoenixKitEcommerce.Test.Repo

  @moduletag skip:
               if(System.find_executable("convert"),
                 do: false,
                 else: "ImageMagick (convert) is not installed"
               )

  @stub __MODULE__
  @host "https://93.184.216.34"

  setup do
    dir =
      Path.join(System.tmp_dir!(), "image_downloader_store_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    banner = draw(dir, "banner.png", 7)

    %{
      user: fixture_user(),
      banner_path: banner,
      banner: File.read!(banner),
      banner_jpeg: File.read!(reencode(banner, Path.join(dir, "banner.jpg"), ["-quality", "70"])),
      other: File.read!(draw(dir, "other.png", 8)),
      with_line:
        File.read!(
          reencode(banner, Path.join(dir, "line.png"), [
            "-stroke",
            "black",
            "-strokewidth",
            "2",
            "-draw",
            "line 60,170 260,170"
          ])
        ),
      third: File.read!(draw(dir, "third.png", 9))
    }
  end

  # A fractal texture: as stable a fingerprint under re-encoding as a photo.
  defp draw(dir, name, seed) do
    path = Path.join(dir, name)

    {_, 0} =
      System.cmd(
        "convert",
        ["-size", "320x240", "-seed", to_string(seed), "plasma:fractal", path],
        stderr_to_stdout: true
      )

    path
  end

  defp reencode(source, dest, args) do
    {_, 0} = System.cmd("convert", [source | args] ++ [dest], stderr_to_stdout: true)
    dest
  end

  # Serves `routes` (`%{"/path" => {content_type, body}}`) and returns the
  # options `download_and_store/3` needs to use the stub.
  defp serve(routes) do
    Req.Test.stub(@stub, fn conn ->
      {type, body} = Map.fetch!(routes, conn.request_path)

      conn
      |> Plug.Conn.put_resp_content_type(type)
      |> Plug.Conn.send_resp(200, body)
    end)

    [req_options: [plug: {Req.Test, @stub}]]
  end

  defp file!(uuid), do: Storage.get_file(uuid)

  defp current_version?(fingerprint),
    do: String.starts_with?(fingerprint || "", ImageFingerprint.version() <> ":")

  # `fingerprint` with its last `n` (<= 8) hash bits flipped.
  defp flip_bits(fingerprint, n) do
    [version, hash, colors] = String.split(fingerprint, ":")
    <<head::binary-size(31), last>> = Base.decode16!(hash, case: :lower)
    flipped = Bitwise.bxor(last, Bitwise.bsl(1, n) - 1)
    Enum.join([version, Base.encode16(head <> <<flipped>>, case: :lower), colors], ":")
  end

  test "a new picture is stored with its fingerprint and source", %{user: user, banner: banner} do
    opts = serve(%{"/a.png" => {"image/png", banner}})

    assert {:ok, uuid} = ImageDownloader.download_and_store("#{@host}/a.png?v=1", user.uuid, opts)

    file = file!(uuid)
    assert file.status == "active"
    assert file.metadata["source_url"] == "#{@host}/a.png?v=1"
    assert current_version?(file.metadata["image_fingerprint"])
  end

  test "a re-encoded copy at another URL reuses the stored file and remembers that URL", %{
    user: user,
    banner: banner,
    banner_jpeg: banner_jpeg
  } do
    opts =
      serve(%{"/a.png" => {"image/png", banner}, "/copy.jpg" => {"image/jpeg", banner_jpeg}})

    {:ok, original} = ImageDownloader.download_and_store("#{@host}/a.png", user.uuid, opts)
    count = Repo.aggregate(Storage.File, :count)

    assert {:ok, ^original} =
             ImageDownloader.download_and_store("#{@host}/copy.jpg?v=7", user.uuid, opts)

    assert Repo.aggregate(Storage.File, :count) == count
    assert file!(original).metadata["source_url_aliases"] == ["#{@host}/copy.jpg"]

    # Resolving the same URL again does not grow the list.
    assert {:ok, ^original} =
             ImageDownloader.download_and_store("#{@host}/copy.jpg?v=8", user.uuid, opts)

    assert file!(original).metadata["source_url_aliases"] == ["#{@host}/copy.jpg"]
  end

  test "a version with an added detail is stored as a new file though its fingerprint matches", %{
    user: user,
    banner: banner,
    with_line: with_line
  } do
    opts = serve(%{"/a.png" => {"image/png", banner}, "/line.png" => {"image/png", with_line}})

    {:ok, original} = ImageDownloader.download_and_store("#{@host}/a.png", user.uuid, opts)
    {:ok, version} = ImageDownloader.download_and_store("#{@host}/line.png", user.uuid, opts)

    refute version == original
    refute Map.has_key?(file!(original).metadata, "source_url_aliases")
  end

  test "a different picture is stored as a new file", %{user: user, banner: banner, other: other} do
    opts = serve(%{"/a.png" => {"image/png", banner}, "/b.png" => {"image/png", other}})

    {:ok, a} = ImageDownloader.download_and_store("#{@host}/a.png", user.uuid, opts)
    {:ok, b} = ImageDownloader.download_and_store("#{@host}/b.png", user.uuid, opts)

    refute a == b
    refute Map.has_key?(file!(a).metadata, "source_url_aliases")
  end

  test "a stretched copy is stored separately", %{user: user, banner_path: path, banner: banner} do
    stretched =
      reencode(path, Path.join(Path.dirname(path), "stretched.png"), ["-resize", "320x120!"])

    opts =
      serve(%{
        "/a.png" => {"image/png", banner},
        "/stretched.png" => {"image/png", File.read!(stretched)}
      })

    {:ok, original} = ImageDownloader.download_and_store("#{@host}/a.png", user.uuid, opts)
    {:ok, copy} = ImageDownloader.download_and_store("#{@host}/stretched.png", user.uuid, opts)

    refute copy == original
    refute Map.has_key?(file!(original).metadata, "source_url_aliases")
  end

  test "an animation with an old first-frame fingerprint cannot replace a static image", %{
    user: user,
    banner_path: path
  } do
    dir = Path.dirname(path)
    other = draw(dir, "other-frame.png", 8)
    animation = Path.join(dir, "animation.gif")
    {_, 0} = System.cmd("convert", [path, other, animation])
    first = reencode(animation <> "[0]", Path.join(dir, "first.png"), [])
    {:ok, fingerprint} = ImageFingerprint.compute(first)
    bytes = File.read!(animation)

    original =
      store_raw(bytes, "animation.gif", user.uuid, %{
        "source_url" => "#{@host}/animation.gif",
        "image_fingerprint" => fingerprint
      })

    opts =
      serve(%{
        "/first.png" => {"image/png", File.read!(first)},
        "/copy.gif" => {"image/gif", bytes}
      })

    {:ok, copy} = ImageDownloader.download_and_store("#{@host}/first.png", user.uuid, opts)
    refute copy == original
    refute Map.has_key?(file!(original).metadata, "source_url_aliases")

    # Exact bytes may still reuse the animation through core's checksum dedup.
    assert {:ok, ^original} =
             ImageDownloader.download_and_store("#{@host}/copy.gif", user.uuid, opts)
  end

  test "different animations with the same opening frame are stored separately", %{
    user: user,
    banner_path: path
  } do
    dir = Path.dirname(path)
    other = draw(dir, "other-frame.png", 8)
    third = draw(dir, "third-frame.png", 9)
    a = Path.join(dir, "a.gif")
    b = Path.join(dir, "b.gif")
    {_, 0} = System.cmd("convert", [path, other, a])
    {_, 0} = System.cmd("convert", [path, third, b])

    opts =
      serve(%{"/a.gif" => {"image/gif", File.read!(a)}, "/b.gif" => {"image/gif", File.read!(b)}})

    {:ok, original} = ImageDownloader.download_and_store("#{@host}/a.gif", user.uuid, opts)
    {:ok, copy} = ImageDownloader.download_and_store("#{@host}/b.gif", user.uuid, opts)

    refute copy == original
    refute Map.has_key?(file!(original).metadata, "image_fingerprint")
    refute Map.has_key?(file!(original).metadata, "source_url_aliases")
  end

  test "a trashed file is never handed back, by checksum or by fingerprint", %{
    user: user,
    banner: banner,
    banner_jpeg: banner_jpeg
  } do
    other_user = fixture_user()

    opts =
      serve(%{"/a.png" => {"image/png", banner}, "/copy.jpg" => {"image/jpeg", banner_jpeg}})

    {:ok, trashed} = ImageDownloader.download_and_store("#{@host}/a.png", user.uuid, opts)
    {:ok, _} = Storage.trash_file(trashed)

    # Same bytes, same name — another uploader, so core's own per-user
    # dedup does not answer first and only this module's lookup decides.
    assert {:ok, again} =
             ImageDownloader.download_and_store("#{@host}/a.png", other_user.uuid, opts)

    refute again == trashed
    assert file!(again).status == "active"

    {:ok, _} = Storage.trash_file(again)

    assert {:ok, copy} =
             ImageDownloader.download_and_store("#{@host}/copy.jpg", other_user.uuid, opts)

    refute copy in [trashed, again]
  end

  test "near_duplicates: false stores the copy and computes no fingerprint", %{
    user: user,
    banner: banner,
    banner_jpeg: banner_jpeg
  } do
    opts =
      serve(%{"/a.png" => {"image/png", banner}, "/copy.jpg" => {"image/jpeg", banner_jpeg}})

    {:ok, original} = ImageDownloader.download_and_store("#{@host}/a.png", user.uuid, opts)

    assert {:ok, copy} =
             ImageDownloader.download_and_store(
               "#{@host}/copy.jpg",
               user.uuid,
               opts ++ [near_duplicates: false]
             )

    refute copy == original
    refute Map.has_key?(file!(copy).metadata, "image_fingerprint")
  end

  test "a trashed copy core hands back for the same uploader is restored", %{
    user: user,
    banner: banner
  } do
    opts = serve(%{"/a.png" => {"image/png", banner}})

    {:ok, trashed} = ImageDownloader.download_and_store("#{@host}/a.png", user.uuid, opts)
    {:ok, _} = Storage.trash_file(trashed)

    # Neither lookup here picks the trashed row; core's own per-uploader
    # dedup in `store_file` does — and the row comes back to life rather
    # than an import pointing at a file in the trash.
    assert {:ok, ^trashed} = ImageDownloader.download_and_store("#{@host}/a.png", user.uuid, opts)
    assert file!(trashed).status == "active"
  end

  test "a file is not given its own URL as an alias", %{user: user, banner: banner} do
    opts = serve(%{"/a.png" => {"image/png", banner}})

    {:ok, uuid} = ImageDownloader.download_and_store("#{@host}/a.png?v=1", user.uuid, opts)

    assert {:ok, ^uuid} =
             ImageDownloader.download_and_store("#{@host}/a.png?v=2", user.uuid, opts)

    refute Map.has_key?(file!(uuid).metadata, "source_url_aliases")
  end

  test "a reused file that was not imported gets no aliases", %{user: user, banner: banner} do
    uploader = fixture_user()
    uploaded = store_raw(banner, "a.png", uploader.uuid, %{})
    opts = serve(%{"/a.png" => {"image/png", banner}})

    assert {:ok, ^uploaded} =
             ImageDownloader.download_and_store("#{@host}/a.png", user.uuid, opts)

    refute Map.has_key?(file!(uploaded).metadata || %{}, "source_url_aliases")
  end

  # Candidates hold re-encodes of the banner (so step 2 confirms each of
  # them) under crafted fingerprints (so their rank is known).
  describe "choosing among several matches" do
    setup %{banner_path: banner_path} do
      {:ok, fingerprint} = ImageFingerprint.compute(banner_path)
      dir = Path.dirname(banner_path)

      %{
        fingerprint: fingerprint,
        q60: File.read!(reencode(banner_path, Path.join(dir, "q60.jpg"), ["-quality", "60"])),
        q80: File.read!(reencode(banner_path, Path.join(dir, "q80.jpg"), ["-quality", "80"]))
      }
    end

    test "the closest match wins over an earlier, farther one", %{
      user: user,
      banner: banner,
      q60: q60,
      q80: q80,
      fingerprint: fingerprint
    } do
      _farther =
        store_raw(q60, "near.png", user.uuid, %{
          "source_url" => "#{@host}/near.png",
          "image_fingerprint" => flip_bits(fingerprint, 3)
        })

      closer =
        store_raw(q80, "exact.png", user.uuid, %{
          "source_url" => "#{@host}/exact.png",
          "image_fingerprint" => fingerprint
        })

      opts = serve(%{"/a.png" => {"image/png", banner}})

      assert {:ok, ^closer} =
               ImageDownloader.download_and_store("#{@host}/a.png", user.uuid, opts)
    end

    test "a closer candidate that fails the picture check gives way to the next", %{
      user: user,
      banner: banner,
      with_line: with_line,
      q80: q80,
      fingerprint: fingerprint
    } do
      _closest_but_other_version =
        store_raw(with_line, "line.png", user.uuid, %{
          "source_url" => "#{@host}/line.png",
          "image_fingerprint" => fingerprint
        })

      next =
        store_raw(q80, "q80.jpg", user.uuid, %{
          "source_url" => "#{@host}/q80.jpg",
          "image_fingerprint" => flip_bits(fingerprint, 2)
        })

      opts = serve(%{"/a.png" => {"image/png", banner}})
      assert {:ok, ^next} = ImageDownloader.download_and_store("#{@host}/a.png", user.uuid, opts)
    end

    test "a candidate whose original cannot be read is not reused", %{
      user: user,
      banner: banner,
      q80: q80,
      fingerprint: fingerprint
    } do
      unreadable =
        store_raw(q80, "q80.jpg", user.uuid, %{
          "source_url" => "#{@host}/q80.jpg",
          "image_fingerprint" => fingerprint
        })

      from(i in PhoenixKit.Modules.Storage.FileInstance,
        where: i.file_uuid == ^unreadable and i.variant_name == "original"
      )
      |> Repo.delete_all()

      opts = serve(%{"/a.png" => {"image/png", banner}})
      assert {:ok, stored} = ImageDownloader.download_and_store("#{@host}/a.png", user.uuid, opts)
      refute stored == unreadable
    end

    test "an equally close match goes to the earliest stored", %{
      user: user,
      banner: banner,
      q60: q60,
      q80: q80,
      fingerprint: fingerprint
    } do
      earlier =
        store_raw(q60, "first.png", user.uuid, %{
          "source_url" => "#{@host}/first.png",
          "image_fingerprint" => fingerprint
        })

      _later =
        store_raw(q80, "second.png", user.uuid, %{
          "source_url" => "#{@host}/second.png",
          "image_fingerprint" => fingerprint
        })

      opts = serve(%{"/a.png" => {"image/png", banner}})

      assert {:ok, ^earlier} =
               ImageDownloader.download_and_store("#{@host}/a.png", user.uuid, opts)
    end
  end

  describe "backfill_fingerprints/0" do
    test "fingerprints imported images that predate fingerprints, and only those", %{
      user: user,
      banner: banner,
      other: other
    } do
      imported = store_raw(banner, "old.png", user.uuid, %{"source_url" => "#{@host}/old.png"})
      uploaded = store_raw(other, "own.png", user.uuid, %{})

      assert %{fingerprinted: 1, failed: 0} = ImageDownloader.backfill_fingerprints()
      assert current_version?(file!(imported).metadata["image_fingerprint"])
      refute Map.has_key?(file!(uploaded).metadata || %{}, "image_fingerprint")

      # Nothing left to do on a second run.
      assert %{fingerprinted: 0, failed: 0} = ImageDownloader.backfill_fingerprints()
    end

    test "re-stamps an older fingerprint version and skips trashed and non-image files", %{
      user: user,
      banner: banner,
      other: other,
      third: third
    } do
      stale =
        store_raw(banner, "stale.png", user.uuid, %{
          "source_url" => "#{@host}/stale.png",
          "image_fingerprint" => "v1:00:00"
        })

      trashed = store_raw(other, "trashed.png", user.uuid, %{"source_url" => "#{@host}/t.png"})
      {:ok, _} = Storage.trash_file(trashed)

      document = store_raw(third, "doc.png", user.uuid, %{"source_url" => "#{@host}/doc.png"})

      from(f in Storage.File, where: f.uuid == ^document)
      |> Repo.update_all(set: [file_type: "document"])

      assert %{fingerprinted: 1, failed: 0} = ImageDownloader.backfill_fingerprints()
      assert current_version?(file!(stale).metadata["image_fingerprint"])
      refute Map.has_key?(file!(trashed).metadata, "image_fingerprint")
      refute Map.has_key?(file!(document).metadata, "image_fingerprint")
    end

    test "a backfilled file is then found as the same picture", %{
      user: user,
      banner: banner,
      banner_jpeg: banner_jpeg
    } do
      old = store_raw(banner, "old.png", user.uuid, %{"source_url" => "#{@host}/old.png"})
      ImageDownloader.backfill_fingerprints()

      opts = serve(%{"/copy.jpg" => {"image/jpeg", banner_jpeg}})

      assert {:ok, ^old} =
               ImageDownloader.download_and_store("#{@host}/copy.jpg", user.uuid, opts)
    end
  end

  # A file stored the way an import before fingerprints did: Storage row,
  # given metadata, no `image_fingerprint`.
  defp store_raw(bytes, name, user_uuid, metadata) do
    tmp = Path.join(System.tmp_dir!(), "store_raw_#{System.unique_integer([:positive])}_#{name}")
    File.write!(tmp, bytes)

    {:ok, file} =
      Storage.store_file(tmp,
        filename: name,
        content_type: "image/png",
        size_bytes: byte_size(bytes),
        user_uuid: user_uuid,
        metadata: metadata
      )

    File.rm(tmp)
    file.uuid
  end
end
