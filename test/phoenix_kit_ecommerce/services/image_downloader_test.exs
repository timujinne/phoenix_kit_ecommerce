defmodule PhoenixKitEcommerce.Services.ImageDownloaderTest do
  @moduledoc """
  `PhoenixKitEcommerce.Services.ImageDownloader`'s request shaping and
  body bounding: `pinned_request/2` (connect to the address the SSRF
  guard validated, keep the hostname for TLS/Host) and `download_image/2`'s
  streaming size limit. HTTP goes through `Req.Test`'s plug adapter
  (`opts[:req_options]`), never the network; the URLs use a PUBLIC
  literal address so the private-range guard passes with no DNS lookup.
  `DataCase` only for the sandbox `Policy` reads its setting through.
  """

  use PhoenixKitEcommerce.DataCase, async: true

  alias PhoenixKitEcommerce.Services.ImageDownloader

  @stub __MODULE__
  @url "https://93.184.216.34/images/pic.png"

  defp opts(extra \\ []), do: [req_options: [plug: {Req.Test, @stub}]] ++ extra

  defp png(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("image/png")
    |> Plug.Conn.send_resp(200, body)
  end

  describe "source_key/1" do
    test "drops the query, the fragment and the credentials, keeps the rest" do
      assert ImageDownloader.source_key("https://cdn.example.com/a.jpg?v=1#top") ==
               "https://cdn.example.com/a.jpg"

      assert ImageDownloader.source_key("https://user:secret@cdn.example.com:8443/a.jpg") ==
               "https://cdn.example.com:8443/a.jpg"

      assert ImageDownloader.source_key("https://token@cdn.example.com/a@b.jpg?x=y@z") ==
               "https://cdn.example.com/a@b.jpg"

      assert ImageDownloader.source_key("https://cdn.example.com/a.jpg") ==
               "https://cdn.example.com/a.jpg"
    end

    test "never prints credentials, even when the URL has no host" do
      refute ImageDownloader.source_key("https://user:secret@:443/p.png?sig=abc") =~ "secret"
      refute ImageDownloader.source_key("https://user:secret@/p.png") =~ "secret"
      refute ImageDownloader.source_key("https://user:secret@:443/p.png?sig=abc") =~ "user"
    end

    test "is nil for anything that is not a string" do
      assert ImageDownloader.source_key(nil) == nil
      assert ImageDownloader.source_key(42) == nil
    end
  end

  describe "pinned_request/2" do
    test "a nil pin leaves the URL and options untouched" do
      assert ImageDownloader.pinned_request("https://cdn.example.com/a.jpg", nil) ==
               {"https://cdn.example.com/a.jpg", []}
    end

    test "connects to the validated address, keeps the hostname for SNI and the Host header" do
      assert {url, opts} =
               ImageDownloader.pinned_request(
                 "https://cdn.example.com/a.jpg?w=1",
                 {93, 184, 216, 34}
               )

      assert url == "https://93.184.216.34/a.jpg?w=1"
      assert opts[:adapter] == PhoenixKitEcommerce.Services.PinnedAdapter
      assert opts[:headers] == [{"host", "cdn.example.com"}]
      refute Keyword.has_key?(opts, :connect_options)
    end

    test "a non-default port stays in the Host header" do
      assert {"https://93.184.216.34:8443/a.jpg", opts} =
               ImageDownloader.pinned_request(
                 "https://cdn.example.com:8443/a.jpg",
                 {93, 184, 216, 34}
               )

      assert opts[:headers] == [{"host", "cdn.example.com:8443"}]
    end

    test "a URL that is not strictly valid does not raise" do
      assert {url, _opts} =
               ImageDownloader.pinned_request(
                 "https://cdn.example.com/a b.png?sig=abc",
                 {93, 184, 216, 34}
               )

      assert url =~ "93.184.216.34"
    end

    test "an IPv6 address is bracketed in the URL" do
      assert {"https://[2606:4700::1]/a.jpg", opts} =
               ImageDownloader.pinned_request(
                 "https://cdn.example.com/a.jpg",
                 {0x2606, 0x4700, 0, 0, 0, 0, 0, 1}
               )

      assert opts[:headers] == [{"host", "cdn.example.com"}]
    end
  end

  describe "a URL the request cannot be built from" do
    test "is refused as invalid before any lookup or request" do
      for url <- [
            "https://cdn.example.com/a b.png?sig=abc",
            "https://cdn.example.com/caf\u00E9.png",
            "https://cdn.example.com/a|b.png",
            "https://cdn.example.com/a.png?x={y}"
          ] do
        assert ImageDownloader.check_url(url) == {:error, :invalid_url}
        assert {:error, :invalid_url} = ImageDownloader.download_image(url, opts())
      end
    end

    test "a redirect to such a URL fails the picture, it does not crash" do
      Req.Test.stub(@stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://93.184.216.34/caf\u00E9.png")
        |> Plug.Conn.send_resp(302, "")
      end)

      assert {:error, :invalid_url} = ImageDownloader.download_image(@url, opts())
    end
  end

  describe "download_batch/3 — one URL cannot take the caller down" do
    test "a crash while fetching is a failed picture and its URL reaches no log line" do
      url = @url <> "?sig=SUPERSECRETSIGNATURE"
      crash = fn _conn -> raise "boom" end

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert [{^url, {:error, :download_failed}}] =
                   ImageDownloader.download_batch([url], nil,
                     req_options: [plug: crash],
                     redact_query: true
                   )
        end)

      refute log =~ "SUPERSECRETSIGNATURE"
    end
  end

  describe "download_image/2 — size limit" do
    test "a body under the limit is written to a temp file" do
      Req.Test.stub(@stub, fn conn -> png(conn, "png-bytes") end)

      assert {:ok, path, "image/png", 9} = ImageDownloader.download_image(@url, opts())
      assert File.read!(path) == "png-bytes"
      File.rm(path)
    end

    test "a content-length past the limit is refused" do
      Req.Test.stub(@stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-length", "1000")
        |> png(conn_body_under_limit())
      end)

      assert {:error, {:file_too_large, message}} =
               ImageDownloader.download_image(@url, opts(max_bytes: 100))

      assert message =~ "exceeds limit"
    end

    test "a streamed body is halted once it passes the limit" do
      Req.Test.stub(@stub, fn conn ->
        conn = conn |> Plug.Conn.put_resp_content_type("image/png") |> Plug.Conn.send_chunked(200)

        Enum.reduce(1..5, conn, fn _, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, String.duplicate("x", 40))
          conn
        end)
      end)

      assert {:error, {:file_too_large, _}} =
               ImageDownloader.download_image(@url, opts(max_bytes: 100))
    end

    test "a streamed body within the limit is reassembled whole" do
      Req.Test.stub(@stub, fn conn ->
        conn = conn |> Plug.Conn.put_resp_content_type("image/png") |> Plug.Conn.send_chunked(200)
        {:ok, conn} = Plug.Conn.chunk(conn, "ab")
        {:ok, conn} = Plug.Conn.chunk(conn, "cd")
        conn
      end)

      assert {:ok, path, "image/png", 4} =
               ImageDownloader.download_image(@url, opts(max_bytes: 100))

      assert File.read!(path) == "abcd"
      File.rm(path)
    end

    test "the content type is still validated on the final response" do
      Req.Test.stub(@stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(200, "<html>")
      end)

      assert {:error, {:invalid_content_type, "text/html"}} =
               ImageDownloader.download_image(@url, opts())
    end
  end

  describe "a content type the server made up" do
    import ExUnit.CaptureLog, only: [capture_log: 1]

    test "reaches the log cut short and printable, and the answer keeps the type" do
      type = "text/\e[31m\t\x7f" <> String.duplicate("a", 3000)

      Req.Test.stub(@stub, fn conn ->
        conn |> Plug.Conn.put_resp_header("content-type", type) |> Plug.Conn.send_resp(200, "x")
      end)

      log = capture_log(fn -> assert {:error, {:invalid_content_type, _}} = download() end)

      assert log =~ "Invalid content type for image download: text/?[31m??aaaa"
      refute log =~ String.duplicate("a", 200)
      refute log =~ "\e["
      refute log =~ "\t"
      refute log =~ <<0x7F>>
    end

    test "combining marks do not get past the cap" do
      type = "text/a" <> String.duplicate("\u0301", 4000)

      Req.Test.stub(@stub, fn conn ->
        conn |> Plug.Conn.put_resp_header("content-type", type) |> Plug.Conn.send_resp(200, "x")
      end)

      log = capture_log(fn -> assert {:error, {:invalid_content_type, ^type}} = download() end)

      assert [_, logged] = Regex.run(~r/Invalid content type for image download: (\S+)/, log)
      assert byte_size(logged) <= 80
      assert String.starts_with?(logged, "text/a?")
      refute log =~ "\u0301"
    end

    defp download, do: ImageDownloader.download_image(@url, opts())
  end

  describe "download_image/2 with require_raster" do
    @png Base.decode64!(
           "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
         )
    @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0, 16, "JFIF", 0, 1, 1, 0, 0, 1, 0, 1, 0, 0>>

    defp serve_as(type, body) do
      Req.Test.stub(@stub, fn conn ->
        conn |> Plug.Conn.put_resp_content_type(type) |> Plug.Conn.send_resp(200, body)
      end)
    end

    defp raster(extra \\ []),
      do: ImageDownloader.download_image(@url, opts([require_raster: true] ++ extra))

    test "accepts the bytes of the declared raster type" do
      serve_as("image/png", @png)
      assert {:ok, path, "image/png", _size} = raster()
      File.rm(path)

      serve_as("image/jpeg", @jpeg)
      assert {:ok, path, "image/jpeg", _size} = raster()
      File.rm(path)
    end

    test "refuses HTML served as an image, and bytes of another image type" do
      serve_as("image/png", "<html><script>alert(1)</script></html>")
      assert {:error, :content_mismatch} = raster()

      serve_as("image/png", @jpeg)
      assert {:error, :content_mismatch} = raster()

      serve_as("image/jpeg", @png)
      assert {:error, :content_mismatch} = raster()
    end

    test "refuses an empty body" do
      serve_as("image/png", "")
      assert {:error, :content_mismatch} = raster()
    end

    test "without the option the declared type is trusted, as the importer always did" do
      serve_as("image/png", "<html>")
      assert {:ok, path, "image/png", 6} = ImageDownloader.download_image(@url, opts())
      File.rm(path)
    end
  end

  defp conn_body_under_limit, do: "tiny"
end
