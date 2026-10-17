defmodule PhoenixKitEcommerce.Services.ImageDownloaderPinnedTest do
  @moduledoc """
  The pinned request of `ImageDownloader`: the connection goes to the
  address the SSRF guard validated while the original hostname is what the
  origin sees (Host header, TLS SNI and certificate check), the body is
  bounded as it streams, and fetching from many hostnames leaves no process
  or atom behind.

  The origin is a small socket server on loopback, plain or TLS, reached by
  pinning every test hostname to 127.0.0.1 through `pinned_get/3` (the
  private-range guard sits in front of it and has its own tests).

  `async: false`: it counts the node's atoms and processes, and it swaps the
  resolver the guard uses.
  """

  use ExUnit.Case, async: false

  alias PhoenixKitEcommerce.Services.ImageDownloader

  require Record

  Record.defrecordp(
    :extension,
    :Extension,
    Record.extract(:Extension, from_lib: "public_key/include/public_key.hrl")
  )

  @loopback {127, 0, 0, 1}

  defp request(extra \\ []) do
    %{
      timeout: 2_000,
      max_bytes: 1_000_000,
      req_options: [retry: false] ++ extra,
      private_networks: :forbid
    }
  end

  # -- a one-purpose origin ---------------------------------------------------

  # Listens on a loopback port and answers every connection with `reply`:
  # `{:ok, body}` as a PNG and closes; `{:keepalive, body}` the same but keeps
  # the connection open and reports what its next read sees
  # (`{:origin_saw, result}`: `{:error, :closed}` once the client closed);
  # `{:redirect, location}` as a 302; or `:silent` (read the request, say
  # nothing). A HEAD request gets the headers of the answer and no body. Each
  # request line and header block is sent to the test as
  # `{:request, head, sni}`.
  defp start_origin(reply, tls \\ nil) do
    test = self()
    base = [:binary, active: false, reuseaddr: true, ip: @loopback]

    {mod, listen} =
      case tls do
        nil ->
          {:ok, listen} = :gen_tcp.listen(0, base)
          {:gen_tcp, listen}

        tls_opts ->
          {:ok, listen} = :ssl.listen(0, base ++ tls_opts)
          {:ssl, listen}
      end

    {:ok, {_ip, port}} = sockname(mod, listen)
    spawn_link(fn -> accept_loop(mod, listen, reply, test) end)
    port
  end

  defp sockname(:gen_tcp, listen), do: :inet.sockname(listen)
  defp sockname(:ssl, listen), do: :ssl.sockname(listen)

  defp accept_loop(mod, listen, reply, test) do
    case accept(mod, listen) do
      {:ok, socket} ->
        pid = spawn(fn -> handle(mod, socket, reply, test) end)
        _ = mod.controlling_process(socket, pid)
        accept_loop(mod, listen, reply, test)

      {:error, _closed} ->
        :ok
    end
  end

  defp accept(:gen_tcp, listen), do: :gen_tcp.accept(listen)
  defp accept(:ssl, listen), do: :ssl.transport_accept(listen)

  defp handle(mod, socket, reply, test) do
    with {:ok, socket} <- handshake(mod, socket),
         {:ok, head} <- read_head(mod, socket, "") do
      send(test, {:request, head, sni(mod, socket)})

      respond(reply, request_method(head), mod, socket, test)
    end
  end

  defp request_method(head), do: head |> String.split(" ", parts: 2) |> hd()

  defp respond({:ok, body}, method, mod, socket, _test) do
    mod.send(socket, [png_head(body, "connection: close\r\n"), body_for(method, body)])
    mod.close(socket)
  end

  defp respond({:keepalive, body}, method, mod, socket, test) do
    mod.send(socket, [png_head(body, ""), body_for(method, body)])
    send(test, {:origin_saw, mod.recv(socket, 0, 1_000)})
    mod.close(socket)
  end

  defp respond({:redirect, location}, _method, mod, socket, _test) do
    mod.send(socket, [
      "HTTP/1.1 302 Found\r\nlocation: ",
      location,
      "\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
    ])

    mod.close(socket)
  end

  defp respond(:silent, _method, _mod, _socket, _test), do: Process.sleep(5_000)

  defp respond(:trickle, _method, mod, socket, test) do
    mod.send(socket, "HTTP/1.1 200 OK\r\ncontent-type: image/png\r\ncontent-length: 100\r\n\r\n")

    :ok =
      Enum.reduce_while(1..100, :ok, fn _, :ok ->
        Process.sleep(50)

        case mod.send(socket, "x") do
          :ok -> {:cont, :ok}
          {:error, _} -> {:halt, :ok}
        end
      end)

    send(test, :trickle_finished)
    mod.close(socket)
  end

  defp png_head(body, extra) do
    [
      "HTTP/1.1 200 OK\r\ncontent-type: image/png\r\ncontent-length: ",
      Integer.to_string(byte_size(body)),
      "\r\n",
      extra,
      "\r\n"
    ]
  end

  defp body_for("HEAD", _body), do: ""
  defp body_for(_method, body), do: body

  defp handshake(:gen_tcp, socket), do: {:ok, socket}

  defp handshake(:ssl, socket) do
    case :ssl.handshake(socket, 2_000) do
      {:ok, socket} -> {:ok, socket}
      {:error, _} -> :error
    end
  end

  defp read_head(mod, socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      with {:ok, data} <- mod.recv(socket, 0, 2_000), do: read_head(mod, socket, acc <> data)
    end
  end

  defp sni(:gen_tcp, _socket), do: nil

  defp sni(:ssl, socket) do
    case :ssl.connection_information(socket, [:sni_hostname]) do
      {:ok, [sni_hostname: name]} -> List.to_string(name)
      _ -> nil
    end
  end

  # A certificate chain whose leaf is valid for `good.example.test` only.
  defp tls_material do
    san =
      extension(
        extnID: {2, 5, 29, 17},
        critical: false,
        extnValue: [dNSName: ~c"good.example.test"]
      )

    %{server_config: server} =
      :public_key.pkix_test_data(%{
        server_chain: %{
          root: [key: {:rsa, 2048, 65_537}],
          peer: [key: {:rsa, 2048, 65_537}, extensions: [san]]
        },
        client_chain: %{root: [], peer: []}
      })

    {[cert: server[:cert], key: server[:key]], server[:cacerts]}
  end

  # -- the request ------------------------------------------------------------

  describe "pinned_get/3 over plain HTTP" do
    test "connects to the pinned address and sends the original host in the Host header" do
      port = start_origin({:ok, "png-bytes"})
      url = "http://pinned.example.test:#{port}/a%20b.png?w=1"

      assert {:ok, %{status: 200} = response} =
               ImageDownloader.pinned_get(url, @loopback, request())

      assert IO.iodata_to_binary(response.body) == "png-bytes"
      assert {"content-type", ["image/png"]} in Enum.to_list(response.headers)

      assert_receive {:request, head, _sni}
      assert head =~ "GET /a%20b.png?w=1 HTTP/1.1\r\n"
      assert head =~ ~r/\r\nhost: pinned\.example\.test:#{port}\r\n/i
    end

    test "a body past the limit is halted while it streams" do
      port = start_origin({:ok, String.duplicate("x", 100_000)})
      request = %{request() | max_bytes: 1_000}

      assert {:ok, %{status: 200} = response} =
               ImageDownloader.pinned_get(
                 "http://big.example.test:#{port}/a.png",
                 @loopback,
                 request
               )

      assert response.private[:too_large] >= 1_000

      assert response.private[:received_bytes] <= 1_000 or
               response.private[:received_bytes] == nil

      assert IO.iodata_to_binary(response.body) |> byte_size() <= 1_000
    end

    test "an origin that never answers is a timeout, not a hang" do
      port = start_origin(:silent)
      request = %{request() | timeout: 200}

      assert {:error, :timeout} =
               ImageDownloader.pinned_get(
                 "http://mute.example.test:#{port}/a.png",
                 @loopback,
                 request
               )
    end

    test "a response that keeps trickling bytes cannot renew the deadline" do
      port = start_origin(:trickle)
      request = %{request() | timeout: 300}
      started = System.monotonic_time(:millisecond)

      assert {:error, :timeout} =
               ImageDownloader.pinned_get("http://slow.test:#{port}/a", @loopback, request)

      assert System.monotonic_time(:millisecond) - started < 2_000
      assert_receive :trickle_finished, 2_000
    end

    test "a refused connection is a transport error" do
      port = start_origin({:ok, "x"})
      # An unused port: bind, learn the number, close.
      {:ok, probe} = :gen_tcp.listen(0, ip: @loopback)
      {:ok, {_ip, closed}} = :inet.sockname(probe)
      :gen_tcp.close(probe)
      assert port != closed

      assert {:error, {:transport_error, :econnrefused}} =
               ImageDownloader.pinned_get(
                 "http://gone.example.test:#{closed}/a.png",
                 @loopback,
                 request()
               )
    end
  end

  describe "the connection of a pinned request" do
    test "is closed by the client once the response is read" do
      port = start_origin({:keepalive, "png-bytes"})

      assert {:ok, %{status: 200}} =
               ImageDownloader.pinned_get(
                 "http://closing.example.test:#{port}/a.png",
                 @loopback,
                 request()
               )

      # The origin kept the connection open; its next read sees the end only
      # if the client closed its side.
      assert_receive {:origin_saw, {:error, closed}}, 3_000
      assert closed in [:closed, :econnreset]
    end

    test "is closed by the client when the body is halted at the limit" do
      port = start_origin({:keepalive, String.duplicate("x", 100_000)})
      request = %{request() | max_bytes: 1_000}

      assert {:ok, %{status: 200} = response} =
               ImageDownloader.pinned_get(
                 "http://halting.example.test:#{port}/a.png",
                 @loopback,
                 request
               )

      assert response.private[:too_large] >= 1_000
      assert_receive {:origin_saw, {:error, closed}}, 3_000
      assert closed in [:closed, :econnreset]
    end

    test "a HEAD preflight goes through the pinned connection and gets the headers" do
      port = start_origin({:keepalive, "png-bytes"})

      assert {:ok, %{status: 200} = response} =
               ImageDownloader.pinned_head(
                 "http://preflight.example.test:#{port}/a.png",
                 @loopback,
                 request()
               )

      assert response.body == ""
      assert {"content-type", ["image/png"]} in Enum.to_list(response.headers)

      assert_receive {:request, head, _sni}
      assert head =~ "HEAD /a.png HTTP/1.1\r\n"
      assert head =~ ~r/\r\nhost: preflight\.example\.test:#{port}\r\n/i
      assert_receive {:origin_saw, {:error, closed}}, 3_000
      assert closed in [:closed, :econnreset]
    end

    test "a redirect is read through the pinned connection and its target is checked again" do
      for fetch <- [&ImageDownloader.pinned_get/3, &ImageDownloader.pinned_head/3] do
        port = start_origin({:redirect, "http://169.254.169.254/latest/meta-data"})

        assert {:error, :private_address_blocked} =
                 fetch.("http://hop.example.test:#{port}/a.png", @loopback, request())

        assert_receive {:request, _head, _sni}
        # Only the first hop was connected to; the private target was not.
        refute_receive {:request, _head, _sni}, 100
      end
    end
  end

  describe "pinned_get/3 over TLS" do
    setup do
      {server_opts, cacerts} = tls_material()
      port = start_origin({:ok, "tls-bytes"}, server_opts)
      %{port: port, cacerts: cacerts}
    end

    defp trusting(cacerts), do: [connect_options: [transport_opts: [cacerts: cacerts]]]

    test "the original hostname is the SNI and the one the certificate is checked against", %{
      port: port,
      cacerts: cacerts
    } do
      request = request(trusting(cacerts))

      assert {:ok, %{status: 200} = response} =
               ImageDownloader.pinned_get(
                 "https://good.example.test:#{port}/a.png",
                 @loopback,
                 request
               )

      assert IO.iodata_to_binary(response.body) == "tls-bytes"
      assert_receive {:request, head, "good.example.test"}
      assert head =~ ~r/\r\nhost: good\.example\.test:#{port}\r\n/i
    end

    test "a certificate for another name is refused even though it chains to a trusted root", %{
      port: port,
      cacerts: cacerts
    } do
      request = request(trusting(cacerts))

      assert {:error, {:transport_error, {:tls_alert, _}}} =
               ImageDownloader.pinned_get(
                 "https://other.example.test:#{port}/a.png",
                 @loopback,
                 request
               )

      refute_receive {:request, _head, _sni}, 100
    end

    test "a certificate no trusted root signed is refused", %{port: port} do
      {_server_opts, other_roots} = tls_material()
      request = request(trusting(other_roots))

      assert {:error, {:transport_error, {:tls_alert, _}}} =
               ImageDownloader.pinned_get(
                 "https://good.example.test:#{port}/a.png",
                 @loopback,
                 request
               )
    end
  end

  describe "pinned_get/3 and the node" do
    test "fetching from many distinct hostnames starts no process and creates no atom" do
      port = start_origin({:ok, "png-bytes"})

      get = fn name ->
        ImageDownloader.pinned_get("http://#{name}:#{port}/a.png", @loopback, request())
      end

      # Warm up whatever the first request starts for good (Req, Mint, TLS).
      assert {:ok, %{status: 200}} = get.("warmup.example.test")

      atoms = :erlang.system_info(:atom_count)
      processes = :erlang.system_info(:process_count)

      for index <- 1..200 do
        assert {:ok, %{status: 200}} = get.("host-#{index}.example.test")
      end

      assert :erlang.system_info(:atom_count) - atoms <= 20
      assert :erlang.system_info(:process_count) - processes <= 20
    end
  end

  # -- the scheme -------------------------------------------------------------

  describe "download_image/2 and the scheme" do
    @stub __MODULE__

    test "an upper-case HTTP scheme is upgraded to HTTPS like a lower-case one" do
      test = self()

      Req.Test.stub(@stub, fn conn ->
        send(test, {:scheme, conn.scheme})

        conn
        |> Plug.Conn.put_resp_content_type("image/png")
        |> Plug.Conn.send_resp(200, "png-bytes")
      end)

      for url <- [
            "http://93.184.216.34/a.png",
            "HTTP://93.184.216.34/a.png",
            "Http://93.184.216.34/a.png"
          ] do
        assert {:ok, path, "image/png", 9} =
                 ImageDownloader.download_image(url,
                   private_networks: :forbid,
                   req_options: [plug: {Req.Test, @stub}]
                 )

        File.rm(path)
        assert_receive {:scheme, :https}
      end
    end
  end

  # -- the name lookup --------------------------------------------------------

  describe "the name lookup of the guard" do
    setup do
      previous = Application.get_env(:phoenix_kit_ecommerce, :image_resolver)
      previous_timeout = Application.get_env(:phoenix_kit_ecommerce, :image_dns_timeout)

      Application.put_env(
        :phoenix_kit_ecommerce,
        :image_resolver,
        PhoenixKitEcommerce.Test.StubResolver
      )

      Application.put_env(:phoenix_kit_ecommerce, :image_dns_timeout, 200)

      on_exit(fn ->
        restore(:image_resolver, previous)
        restore(:image_dns_timeout, previous_timeout)
      end)
    end

    defp restore(key, nil), do: Application.delete_env(:phoenix_kit_ecommerce, key)
    defp restore(key, value), do: Application.put_env(:phoenix_kit_ecommerce, key, value)

    defp within(ms, fun) do
      task = Task.async(fun)

      case Task.yield(task, ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        _ -> :did_not_finish
      end
    end

    test "a resolver that never answers gets the name refused, in time" do
      assert {:error, :private_address_blocked} =
               within(3_000, fn ->
                 ImageDownloader.check_url("https://slow.example.test/a.png",
                   private_networks: :forbid
                 )
               end)
    end

    test "a name answered in one family only is not vouched for" do
      assert {:error, :private_address_blocked} =
               within(3_000, fn ->
                 ImageDownloader.check_url("https://half.example.test/a.png",
                   private_networks: :forbid
                 )
               end)
    end
  end
end
