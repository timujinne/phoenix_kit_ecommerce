defmodule PhoenixKitEcommerce.Services.ImageDownloaderCleanupTest do
  @moduledoc """
  A download refused after its body was written leaves no temporary file
  behind. `async: false`: it compares the shared temp directory before and
  after, which a parallel download would disturb.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKitEcommerce.Services.ImageDownloader

  @stub __MODULE__
  @url "https://93.184.216.34/images/pic.png"

  defp temp_files, do: Path.wildcard(Path.join(System.tmp_dir!(), "phx_img_*"))

  test "a :content_mismatch refusal removes the file it wrote" do
    Req.Test.stub(@stub, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, "<html>not a picture</html>")
    end)

    before = temp_files()

    assert {:error, :content_mismatch} =
             ImageDownloader.download_image(@url,
               req_options: [plug: {Req.Test, @stub}],
               require_raster: true
             )

    assert temp_files() -- before == []
  end
end
