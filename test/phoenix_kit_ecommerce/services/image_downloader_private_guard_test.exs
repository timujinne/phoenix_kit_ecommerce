defmodule PhoenixKitEcommerce.Services.ImageDownloaderPrivateGuardTest do
  @moduledoc """
  `private_networks: :forbid` of `ImageDownloader`: the admin API refuses
  loopback, private and link-local addresses whatever the shop's own import
  setting says, on the first URL and on every redirect, and `check_url/2`
  says so without making a request. The default (`:policy`) is unchanged.

  HTTP goes through `Req.Test`'s plug adapter, never the network; the public
  literal address `93.184.216.34` passes the guard without a DNS lookup.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce.Services.ImageDownloader

  @stub __MODULE__
  @public "https://93.184.216.34/pic.png"

  setup do
    on_exit(fn ->
      Settings.update_boolean_setting_with_module(
        "shop_image_import_allow_private_networks",
        false,
        "shop"
      )
    end)

    Settings.update_boolean_setting_with_module(
      "shop_image_import_allow_private_networks",
      true,
      "shop"
    )

    :ok
  end

  defp opts(extra), do: [req_options: [plug: {Req.Test, @stub}]] ++ extra

  defp png(conn) do
    conn |> Plug.Conn.put_resp_content_type("image/png") |> Plug.Conn.send_resp(200, "png-bytes")
  end

  defp private_urls do
    [
      "http://127.0.0.1/a.png",
      "https://10.0.0.5/a.png",
      "https://192.168.1.1/a.png",
      "https://169.254.169.254/latest/meta-data/",
      "https://[::1]/a.png",
      "https://[fd00::1]/a.png"
    ]
  end

  describe "check_url/2" do
    test "forbid refuses every private address even while the shop setting allows them" do
      for url <- private_urls() do
        assert {:error, :private_address_blocked} =
                 ImageDownloader.check_url(url, private_networks: :forbid),
               "#{url} must be refused"
      end
    end

    test "the default follows the shop setting, which is on here" do
      for url <- private_urls() do
        assert :ok = ImageDownloader.check_url(url), "#{url} is allowed by the setting"
      end
    end

    test "a public address passes, a bad scheme or host never does" do
      assert :ok = ImageDownloader.check_url(@public, private_networks: :forbid)

      assert {:error, :invalid_scheme} =
               ImageDownloader.check_url("file:///etc/passwd", private_networks: :forbid)

      assert {:error, :invalid_scheme} =
               ImageDownloader.check_url("ftp://93.184.216.34/a.png", private_networks: :forbid)

      assert {:error, :invalid_host} =
               ImageDownloader.check_url("https:///a.png", private_networks: :forbid)
    end

    test "a name that does not resolve is refused, not trusted" do
      assert {:error, :private_address_blocked} =
               ImageDownloader.check_url("https://no-such-host.invalid/a.png",
                 private_networks: :forbid
               )
    end
  end

  describe "check_url/2 — addresses that embed an IPv4 address, and ranges that are never public" do
    defp check(host),
      do: ImageDownloader.check_url("https://#{host}/a.png", private_networks: :forbid)

    test "NAT64, 6to4 and SIIT forms of a loopback, private or metadata address are refused" do
      hosts = [
        # NAT64 64:ff9b::/96 -> 127.0.0.1, 10.0.0.5, 169.254.169.254
        "[64:ff9b::7f00:1]",
        "[64:ff9b::a00:5]",
        "[64:ff9b::a9fe:a9fe]",
        # 6to4 2002::/16
        "[2002:7f00:1::]",
        "[2002:a00:5::]",
        "[2002:a9fe:a9fe::]",
        # SIIT ::ffff:0:0:0/96
        "[::ffff:0:7f00:1]",
        "[::ffff:0:a00:5]",
        "[::ffff:0:a9fe:a9fe]"
      ]

      for host <- hosts do
        assert {:error, :private_address_blocked} = check(host), "#{host} must be refused"
      end
    end

    test "the same forms carrying a public IPv4 address are judged as that address" do
      for host <- ["[64:ff9b::5db8:d822]", "[2002:5db8:d822::]", "[::ffff:0:5db8:d822]"] do
        assert :ok = check(host), "#{host} carries 93.184.216.34"
      end
    end

    test "site-local, local-use NAT64 and the reserved IPv4 ranges are refused" do
      for host <- [
            "[fec0::1]",
            "[feff::1]",
            "[64:ff9b:1::1]",
            "192.0.0.1",
            "192.0.0.192",
            "198.18.0.1",
            "198.19.255.255"
          ] do
        assert {:error, :private_address_blocked} = check(host), "#{host} must be refused"
      end
    end

    test "the neighbours of those IPv4 ranges stay public" do
      for host <- ["192.0.1.1", "198.17.255.255", "198.20.0.1", "203.0.112.1", "203.0.114.1"] do
        assert :ok = check(host), "#{host} is public"
      end
    end

    test "multicast, Teredo, benchmarking, discard and documentation ranges are refused" do
      for host <- [
            # ff00::/8
            "[ff02::1]",
            "[ff0e::1]",
            "[ffff::1]",
            # 2001::/32 Teredo, 2001:2::/48 benchmarking, 2001:db8::/32 and 3fff::/20 documentation
            "[2001::1]",
            "[2001:0:4136:e378:8000:63bf:3fff:fdd2]",
            "[2001:2::1]",
            "[2001:db8::1]",
            "[3fff::1]",
            "[3fff:fff::1]",
            # 100::/64 discard-only
            "[100::1]",
            # IPv4 documentation ranges
            "192.0.2.1",
            "198.51.100.7",
            "203.0.113.200"
          ] do
        assert {:error, :private_address_blocked} = check(host), "#{host} must be refused"
      end
    end

    test "the neighbours of those IPv6 ranges stay public" do
      for host <- [
            "[2001:1::1]",
            "[2001:3::1]",
            "[2001:db9::1]",
            "[3fff:1000::1]",
            "[100:0:0:1::1]"
          ] do
        assert :ok = check(host), "#{host} is public"
      end
    end

    test "a download never reaches an embedded private address" do
      test_pid = self()
      Req.Test.stub(@stub, fn conn -> send(test_pid, :requested) && png(conn) end)

      assert {:error, :private_address_blocked} =
               ImageDownloader.download_image(
                 "http://[64:ff9b::7f00:1]/a.png",
                 opts(private_networks: :forbid)
               )

      refute_received :requested
    end
  end

  describe "download_image/2" do
    test "forbid never makes the request to a private address" do
      test_pid = self()
      Req.Test.stub(@stub, fn conn -> send(test_pid, :requested) && png(conn) end)

      assert {:error, :private_address_blocked} =
               ImageDownloader.download_image(
                 "http://127.0.0.1/a.png",
                 opts(private_networks: :forbid)
               )

      refute_received :requested
    end

    test "forbid refuses a redirect to a private address; the default follows it" do
      Req.Test.stub(@stub, fn conn ->
        case conn.host do
          "93.184.216.34" ->
            conn
            |> Plug.Conn.put_resp_header("location", "https://127.0.0.1/secret.png")
            |> Plug.Conn.send_resp(302, "")

          "127.0.0.1" ->
            png(conn)
        end
      end)

      assert {:error, :private_address_blocked} =
               ImageDownloader.download_image(@public, opts(private_networks: :forbid))

      assert {:ok, path, "image/png", _size} = ImageDownloader.download_image(@public, opts([]))
      File.rm(path)
    end

    test "a public address downloads under forbid" do
      Req.Test.stub(@stub, &png/1)

      assert {:ok, path, "image/png", 9} =
               ImageDownloader.download_image(@public, opts(private_networks: :forbid))

      File.rm(path)
    end
  end
end
