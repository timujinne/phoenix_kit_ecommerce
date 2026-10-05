defmodule Mix.Tasks.PhoenixKitEcommerce.BackfillImageFingerprintsTest do
  @moduledoc """
  The task is a thin entry point over `ImageDownloader.backfill_fingerprints/0`
  (covered in `image_downloader_store_test.exs`): this pins that it runs it
  and reports what it did. `Mix.Task.run("app.start")` is a no-op under
  `mix test`, where the application is already started.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  alias Mix.Tasks.PhoenixKitEcommerce.BackfillImageFingerprints, as: Task
  alias PhoenixKit.Modules.Storage
  alias PhoenixKitEcommerce.Services.ImageFingerprint

  @moduletag skip:
               if(System.find_executable("convert"),
                 do: false,
                 else: "ImageMagick (convert) is not installed"
               )

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    path = Path.join(System.tmp_dir!(), "backfill_task_#{System.unique_integer([:positive])}.png")
    {_, 0} = System.cmd("convert", ["-size", "64x64", "plasma:fractal", path])
    bytes = File.read!(path)
    File.rm(path)

    %{user: fixture_user(), bytes: bytes}
  end

  test "fingerprints a stored imported image and reports it", %{user: user, bytes: bytes} do
    uuid = store(bytes, user.uuid, %{"source_url" => "https://93.184.216.34/old.png"})

    Task.run([])

    assert_received {:mix_shell, :info, ["Fingerprinting imported images…"]}
    assert_received {:mix_shell, :info, ["  fingerprinted: 1"]}
    assert_received {:mix_shell, :info, ["  failed: 0"]}

    assert String.starts_with?(
             Storage.get_file(uuid).metadata["image_fingerprint"],
             ImageFingerprint.version() <> ":"
           )
  end

  test "a second run has nothing left to do", %{user: user, bytes: bytes} do
    store(bytes, user.uuid, %{"source_url" => "https://93.184.216.34/old.png"})

    Task.run([])
    Task.run([])

    assert_received {:mix_shell, :info, ["  fingerprinted: 1"]}
    assert_received {:mix_shell, :info, ["  fingerprinted: 0"]}
  end

  defp store(bytes, user_uuid, metadata) do
    tmp = Path.join(System.tmp_dir!(), "backfill_task_#{System.unique_integer([:positive])}.png")
    File.write!(tmp, bytes)

    {:ok, file} =
      Storage.store_file(tmp,
        filename: "old.png",
        content_type: "image/png",
        size_bytes: byte_size(bytes),
        user_uuid: user_uuid,
        metadata: metadata
      )

    File.rm(tmp)
    file.uuid
  end
end
