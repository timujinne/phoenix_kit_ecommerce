defmodule PhoenixKitEcommerce.Services.PinnedAdapter do
  @moduledoc """
  A `Req` adapter that makes one HTTP/1 request over a fresh `Mint`
  connection to the address in the request URL, while the connection still
  speaks for the ORIGINAL hostname: Mint's `:hostname` option is what it
  sends as TLS SNI and verifies the certificate against.

  `ImageDownloader` resolves a name once, checks every answer against the
  private ranges and connects to that one address (see
  `ImageDownloader.pinned_request/2`). `Req`'s own way to do this
  (`connect_options: [hostname: host]`) starts a separate `Finch` pool, with
  a new atom for its name, for every distinct value and never stops it, so
  fetching from many hostnames grows the atom table and the process count
  without bound. This adapter keeps no pool: the connection lives for the
  one request and is closed after it.

  The hostname is the one in the request's `Host` header (without a port),
  which `ImageDownloader.pinned_request/2` sets next to this adapter: what the
  origin is asked for and the name its certificate must carry are the same
  thing. Options (set on the request):

    * `:receive_timeout` - deadline for the whole response in milliseconds
      (default: 15_000)
    * `:connect_options` - `:timeout` (connect, default: 30_000) and
      `:transport_opts` (e.g. `cacerts`), as `Req.Finch` reads them

  The response is read whole, or fed to an `into:` function with the same
  `{:cont, acc} | {:halt, acc}` contract as `Req.Finch`; a body that is not
  a binary or iodata and the other `:into` forms are not supported.
  """

  @default_receive_timeout 15_000
  @default_connect_timeout 30_000

  @doc """
  Runs the request; the adapter callback of `Req`. A request that carries a
  `:plug` option is answered by the plug, as `Req` does for any adapter set
  next to it (how the tests stand in for the network).
  """
  @spec run(Req.Request.t()) :: {Req.Request.t(), Req.Response.t() | Exception.t()}
  # WARNING: this clause skips the address pin and the hostname check. A
  # `plug:` option must only ever come from code (test config, the host's
  # `:api_image_download_opts`, a caller's own `Req.new` options), never from
  # input, a job argument or anything else a caller can name.
  def run(%Req.Request{options: %{plug: _plug}} = request), do: Req.Plug.run(request)

  def run(%Req.Request{} = request) do
    into = collector(request.into)
    timeout = Map.get(request.options, :receive_timeout, @default_receive_timeout)

    case connect(request) do
      {:ok, conn} ->
        try do
          conn |> exchange(request, into, timeout) |> finish(request)
        after
          Mint.HTTP.close(conn)
        end

      {:error, error} ->
        {request, normalize_error(error)}
    end
  end

  defp collector(nil), do: &collect_body/2
  defp collector(fun) when is_function(fun, 2), do: fun

  defp collector(other) do
    raise ArgumentError,
          "the pinned adapter supports no `into:` but a function, got: #{inspect(other)}"
  end

  defp collect_body({:data, chunk}, {request, response}),
    do: {:cont, {request, %{response | body: [response.body, chunk]}}}

  defp finish({:ok, {request, response}}, _request),
    do: {request, %{response | body: IO.iodata_to_binary(response.body)}}

  defp finish({:error, error}, request), do: {request, normalize_error(error)}

  # -- connecting -------------------------------------------------------------

  defp connect(%{url: url, options: options} = request) do
    scheme = if url.scheme == "https", do: :https, else: :http
    connect_options = Map.get(options, :connect_options, [])

    transport_opts =
      connect_options
      |> Keyword.get(:transport_opts, [])
      |> Keyword.put_new(
        :timeout,
        Keyword.get(connect_options, :timeout, @default_connect_timeout)
      )

    address = parse_address(url.host)

    transport_opts =
      if is_tuple(address) and tuple_size(address) == 8,
        do: Keyword.put_new(transport_opts, :inet6, true),
        else: transport_opts

    mint_opts =
      [mode: :passive, protocols: [:http1], transport_opts: transport_opts]
      |> put_hostname(pinned_hostname(request))

    Mint.HTTP.connect(scheme, address, url.port || URI.default_port(url.scheme), mint_opts)
  end

  defp parse_address(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> address
      {:error, _} -> host
    end
  end

  defp pinned_hostname(request) do
    case Req.Request.get_header(request, "host") do
      [value | _] -> value |> String.split(":", parts: 2) |> hd()
      [] -> nil
    end
  end

  defp put_hostname(opts, nil), do: opts
  defp put_hostname(opts, hostname), do: Keyword.put(opts, :hostname, hostname)

  # -- request and response ---------------------------------------------------

  defp exchange(conn, request, into, timeout) do
    method = request.method |> to_string() |> String.upcase()

    case Mint.HTTP.request(conn, method, target(request.url), headers(request), body(request)) do
      {:ok, conn, ref} ->
        state = %{ref: ref, status: nil, response: nil, acc: {request, Req.Response.new()}}
        deadline = if timeout == :infinity, do: :infinity, else: now_ms() + timeout
        await(conn, state, into, deadline)

      {:error, _conn, error} ->
        {:error, error}
    end
  end

  defp target(url) do
    path = if url.path in [nil, ""], do: "/", else: url.path
    if url.query, do: path <> "?" <> url.query, else: path
  end

  defp headers(request) do
    for {name, values} <- request.headers, value <- List.wrap(values), do: {name, value}
  end

  defp body(%{body: nil}), do: nil
  defp body(%{body: body}) when is_binary(body) or is_list(body), do: body

  defp body(_request) do
    raise ArgumentError, "the pinned adapter supports a binary or iodata request body only"
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp await(conn, state, into, deadline) do
    remaining = if deadline == :infinity, do: :infinity, else: max(deadline - now_ms(), 0)

    if remaining == 0 do
      {:error, %Mint.TransportError{reason: :timeout}}
    else
      receive_response(conn, state, into, deadline, remaining)
    end
  end

  defp receive_response(conn, state, into, deadline, remaining) do
    case Mint.HTTP.recv(conn, 0, remaining) do
      {:ok, conn, responses} ->
        case consume(responses, state, into) do
          {:more, state} -> await(conn, state, into, deadline)
          {:finished, acc} -> {:ok, acc}
        end

      # What arrived before the failure is dropped: a response cut short is
      # an error, as it is with `Req.Finch`.
      {:error, _conn, error, _responses} ->
        {:error, error}
    end
  end

  defp consume(responses, state, into) do
    Enum.reduce_while(responses, {:more, state}, fn response, {:more, state} ->
      case handle(response, state, into) do
        {:cont, state} -> {:cont, {:more, state}}
        {:finished, acc} -> {:halt, {:finished, acc}}
      end
    end)
  end

  defp handle({:status, ref, status}, %{ref: ref} = state, _into),
    do: {:cont, %{state | status: status}}

  # An informational response (100 Continue ...) is followed by the real one.
  defp handle({:headers, ref, _headers}, %{ref: ref, status: status} = state, _into)
       when status in 100..199,
       do: {:cont, %{state | status: nil}}

  # The first header block is the response's; a later one is trailers.
  defp handle({:headers, ref, headers}, %{ref: ref, response: nil} = state, _into) do
    {request, _blank} = state.acc
    response = Req.Response.new(status: state.status, headers: headers)
    {:cont, %{state | response: response, acc: {request, response}}}
  end

  defp handle({:headers, ref, _trailers}, %{ref: ref} = state, _into), do: {:cont, state}

  defp handle({:data, ref, chunk}, %{ref: ref} = state, into) do
    case into.({:data, chunk}, state.acc) do
      {:cont, acc} -> {:cont, %{state | acc: acc}}
      {:halt, acc} -> {:finished, acc}
    end
  end

  defp handle({:done, ref}, %{ref: ref} = state, _into), do: {:finished, state.acc}

  defp handle(_other, state, _into), do: {:cont, state}

  # -- errors -----------------------------------------------------------------

  defp normalize_error(%Mint.TransportError{reason: reason}),
    do: %Req.TransportError{reason: reason}

  defp normalize_error(%Mint.HTTPError{module: module, reason: reason}) do
    protocol = if module == Mint.HTTP2, do: :http2, else: :http1
    %Req.HTTPError{protocol: protocol, reason: reason}
  end

  defp normalize_error(error), do: error
end
