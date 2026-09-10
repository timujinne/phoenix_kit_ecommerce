defmodule PhoenixKitEcommerce.Services.ImageDownloader do
  @moduledoc """
  Service for downloading images from external URLs and storing them in the Storage module.

  Handles HTTP download with proper error handling, content type detection,
  and integration with PhoenixKit.Modules.Storage for persistent storage.

  ## Usage

      # Download and store a single image
      {:ok, file_uuid} = ImageDownloader.download_and_store(url, user_uuid)

      # Download with options
      {:ok, file_uuid} = ImageDownloader.download_and_store(url, user_uuid, timeout: 30_000)

      # Batch download multiple images
      results = ImageDownloader.download_batch(urls, user_uuid)
      # => [{url, {:ok, file_uuid}}, {url, {:error, reason}}, ...]

  """

  require Logger

  alias PhoenixKit.Modules.Storage
  alias PhoenixKitEcommerce.Policy

  @default_timeout 30_000
  # 50 MB max
  @max_file_size 50 * 1024 * 1024
  @allowed_content_types ~w(image/jpeg image/png image/gif image/webp)

  # SVG is an XML document that can carry script, and stored files are
  # served inline with their stored MIME type — so an accepted SVG is a
  # stored-XSS channel independent of the description sanitizer. Off by
  # default; `shop_allow_svg_uploads` re-enables it for shops that need
  # vector assets and trust their import sources.
  @svg_content_type "image/svg+xml"

  @doc """
  Downloads an image from a URL to a temporary file.

  Returns `{:ok, temp_path, content_type, size}` on success.

  ## Options

    * `:timeout` - HTTP request timeout in milliseconds (default: 30_000)

  ## Examples

      iex> download_image("https://example.com/image.jpg")
      {:ok, "/tmp/phx_img_abc123", "image/jpeg", 12345}

      iex> download_image("https://example.com/404.jpg")
      {:error, :not_found}

  """
  @spec download_image(String.t(), keyword()) ::
          {:ok, String.t(), String.t(), non_neg_integer()} | {:error, atom() | String.t()}
  def download_image(url, opts \\ []) when is_binary(url) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with {:ok, url} <- validate_url(url),
         {:ok, response} <- do_http_request(url, timeout),
         {:ok, content_type} <- extract_content_type(response),
         :ok <- validate_content_type(content_type),
         :ok <- validate_size(response.body),
         {:ok, temp_path} <- write_temp_file(response.body, content_type) do
      {:ok, temp_path, content_type, byte_size(response.body)}
    end
  end

  @doc """
  Downloads an image from a URL and stores it in the Storage module.

  Returns `{:ok, file_uuid}` where file_uuid is a UUID that can be used to reference
  the stored file.

  ## Options

    * `:timeout` - HTTP request timeout in milliseconds (default: 30_000)
    * `:metadata` - Additional metadata to store with the file

  ## Examples

      iex> download_and_store("https://cdn.shopify.com/image.jpg", user_uuid)
      {:ok, "018f1234-5678-7890-abcd-ef1234567890"}

      iex> download_and_store("https://example.com/404.jpg", user_uuid)
      {:error, :not_found}

  """
  @spec download_and_store(String.t(), String.t() | nil, keyword()) ::
          {:ok, String.t()} | {:error, atom() | String.t()}
  def download_and_store(url, user_uuid, opts \\ []) when is_binary(url) do
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, temp_path, content_type, size} <- download_image(url, opts) do
      # Check for global deduplication by file hash AND original filename
      file_checksum = calculate_file_hash(temp_path)
      filename = extract_filename_from_url(url, content_type)

      case find_existing_file(file_checksum, filename) do
        %{uuid: existing_uuid} = _existing_file ->
          # File with same content and name already exists - reuse it
          Logger.info(
            "[ImageDownloader] Reusing existing file #{existing_uuid} for URL #{url} (checksum: #{file_checksum}, filename: #{filename})"
          )

          cleanup_temp_file(temp_path)
          {:ok, existing_uuid}

        nil ->
          # No existing file matches - store new file
          Logger.info(
            "[ImageDownloader] Storing new file from URL #{url}, temp_path=#{temp_path}, size=#{size}"
          )

          store_new_file(temp_path, filename, content_type, size, user_uuid, url, metadata)
      end
    end
  end

  # Store a new file after verifying it exists
  defp store_new_file(temp_path, filename, content_type, size, user_uuid, url, metadata) do
    if File.exists?(temp_path) do
      result =
        Storage.store_file(temp_path,
          filename: filename,
          content_type: content_type,
          size_bytes: size,
          user_uuid: user_uuid,
          metadata: Map.merge(metadata, %{"source_url" => url})
        )

      Logger.info("[ImageDownloader] Storage result: #{inspect(result)}")
      cleanup_temp_file(temp_path)
      handle_storage_result(result)
    else
      Logger.error("[ImageDownloader] Temp file disappeared before storage: #{temp_path}")
      {:error, :temp_file_missing}
    end
  end

  defp handle_storage_result({:ok, file}) do
    Logger.info("[ImageDownloader] Successfully stored file with ID: #{file.uuid}")
    {:ok, file.uuid}
  end

  defp handle_storage_result({:error, reason}) do
    Logger.error("[ImageDownloader] Storage failed: #{inspect(reason)}")
    {:error, reason}
  end

  # Find existing file by checksum AND original filename
  defp find_existing_file(file_checksum, filename) do
    import Ecto.Query

    repo = PhoenixKit.Config.get_repo()

    query =
      from(f in PhoenixKit.Modules.Storage.File,
        where: f.file_checksum == ^file_checksum and f.original_file_name == ^filename,
        limit: 1
      )

    repo.one(query)
  end

  # Calculate SHA256 hash of file content
  defp calculate_file_hash(file_path) do
    Elixir.File.stream!(file_path, 2048)
    |> Enum.reduce(:crypto.hash_init(:sha256), fn chunk, acc ->
      :crypto.hash_update(acc, chunk)
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  @doc """
  Downloads and stores multiple images in batch.

  Returns a list of tuples `{url, result}` where result is either
  `{:ok, file_uuid}` or `{:error, reason}`.

  ## Options

    * `:timeout` - HTTP request timeout for each image (default: 30_000)
    * `:concurrency` - Number of concurrent downloads (default: 5)
    * `:on_progress` - Callback function called after each download: `fn(url, result, index, total) -> :ok end`

  ## Examples

      iex> download_batch(["url1", "url2", "url3"], user_uuid)
      [{"url1", {:ok, "uuid-1"}}, {"url2", {:ok, "uuid-2"}}, {"url3", {:error, :timeout}}]

  """
  @spec download_batch([String.t()], String.t() | nil, keyword()) ::
          [{String.t(), {:ok, String.t()} | {:error, atom() | String.t()}}]
  def download_batch(urls, user_uuid, opts \\ []) when is_list(urls) do
    concurrency = Keyword.get(opts, :concurrency, 5)
    on_progress = Keyword.get(opts, :on_progress)
    total = length(urls)

    # Create indexed list to preserve URL even on task crash
    indexed_urls = Enum.with_index(urls, 1)

    indexed_urls
    |> Task.async_stream(
      fn {url, index} ->
        result = download_and_store(url, user_uuid, opts)

        if on_progress do
          on_progress.(url, result, index, total)
        end

        {index, url, result}
      end,
      max_concurrency: concurrency,
      timeout: Keyword.get(opts, :timeout, @default_timeout) + 5_000,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip(indexed_urls)
    |> Enum.map(fn
      {{:ok, {_index, url, result}}, _original} ->
        {url, result}

      {{:exit, reason}, {url, _index}} ->
        # Recover URL from original indexed list when task exits
        Logger.warning("Task exited for URL #{url}: #{inspect(reason)}")
        {url, {:error, {:task_exit, reason}}}
    end)
  end

  @doc """
  Validates URLs are accessible before batch download.

  Performs HEAD requests to verify URLs are accessible and return valid
  image content types. Returns a tuple of `{valid_urls, invalid_urls}`.

  ## Options

    * `:timeout` - HTTP request timeout in milliseconds (default: 5_000)
    * `:concurrency` - Number of concurrent validations (default: 10)

  ## Examples

      iex> validate_urls(["https://example.com/image.jpg", "https://example.com/404.jpg"])
      {["https://example.com/image.jpg"], ["https://example.com/404.jpg"]}

  """
  @spec validate_urls([String.t()], keyword()) :: {[String.t()], [String.t()]}
  def validate_urls(urls, opts \\ []) when is_list(urls) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    concurrency = Keyword.get(opts, :concurrency, 10)

    results =
      urls
      |> Task.async_stream(
        fn url -> {url, valid_image_url?(url, timeout)} end,
        max_concurrency: concurrency,
        timeout: timeout + 2_000,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, {url, true}} -> {:valid, url}
        {:ok, {url, false}} -> {:invalid, url}
        {:exit, _reason} -> {:timeout, nil}
      end)
      |> Enum.reject(fn {_status, url} -> is_nil(url) end)

    valid = for {:valid, url} <- results, do: url
    invalid = for {:invalid, url} <- results, do: url

    {valid, invalid}
  end

  @doc """
  Checks if a URL points to a valid image that can be downloaded.

  Performs a HEAD request to verify the URL is accessible and returns
  an image content type.

  ## Examples

      iex> valid_image_url?("https://example.com/image.jpg")
      true

      iex> valid_image_url?("https://example.com/document.pdf")
      false

  """
  @spec valid_image_url?(String.t()) :: boolean()
  def valid_image_url?(url) when is_binary(url) do
    valid_image_url?(url, 5_000)
  end

  @spec valid_image_url?(String.t(), non_neg_integer()) :: boolean()
  defp valid_image_url?(url, timeout) when is_binary(url) do
    case validate_url(url) do
      {:ok, url} ->
        case head_request(url, timeout) do
          {:ok, %{status: status, headers: headers}} when status in 200..299 ->
            content_type = get_header_value(headers, "content-type")
            validate_content_type(content_type) == :ok

          _ ->
            false
        end

      _ ->
        false
    end
  end

  # Private functions

  defp validate_url(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] ->
        {:error, :invalid_scheme}

      is_nil(uri.host) or uri.host == "" ->
        {:error, :invalid_host}

      not Policy.image_import_allow_private_networks?() and private_host?(uri.host) ->
        {:error, :private_address_blocked}

      true ->
        # Upgrade HTTP to HTTPS for security
        url =
          if uri.scheme == "http",
            do: String.replace_prefix(url, "http://", "https://"),
            else: url

        {:ok, url}
    end
  end

  @doc false
  # Whether a host resolves into a network range the importer must not
  # reach. Checking scheme and non-empty host only made this a working
  # SSRF: a CSV row pointing at http://127.0.0.1:5432/ or the cloud
  # metadata address made the server fetch it and store the response,
  # which is a port scanner and a credential reader for anyone who can
  # upload an import file.
  #
  # Both the literal and the resolved addresses are checked, so a
  # public hostname with a private A record does not slip through.
  # Off by default only via `shop_image_import_allow_private_networks`,
  # for shops importing from a genuinely internal image host.
  def private_host?(host) do
    host = String.trim_trailing(host, ".")

    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} ->
        private_address?(address)

      {:error, _} ->
        # Not a literal — resolve and check every answer. Fail CLOSED on a
        # resolution error: a name we cannot resolve is not a name we can
        # vouch for.
        resolved_privately?(String.to_charlist(host))
    end
  end

  # BOTH address families are resolved, and the host is blocked if any
  # answer is private.
  #
  # Querying only `:inet` made this fail closed on every IPv6-only image
  # host: `getaddrs(host, :inet)` returns `{:error, :nxdomain}` for a name
  # with only AAAA records, which the error branch reads as "cannot vouch
  # for it" and blocks. Legitimate imports from v6-only CDNs stopped
  # working, and it was the guard rather than the network that stopped
  # them. Only a name that resolves in NEITHER family is unvouchable.
  #
  # Checking both is also strictly safer than checking one: a host with a
  # public A record and a private AAAA record was previously waved through
  # on the strength of the record the resolver happened to be asked for.
  defp resolved_privately?(host) do
    answers =
      Enum.flat_map([:inet, :inet6], fn family ->
        case :inet.getaddrs(host, family) do
          {:ok, addresses} -> addresses
          {:error, _} -> []
        end
      end)

    answers == [] or Enum.any?(answers, &private_address?/1)
  end

  # IPv4-mapped and IPv4-compatible IPv6 forms decode to the same host.
  #
  # `::ffff:127.0.0.1` parses to `{0,0,0,0,0,65535,32512,1}`, which matched
  # none of the IPv4 clauses below — so every private address had a working
  # bypass simply by writing it in mapped form. Verified against this
  # module before the fix: `::ffff:127.0.0.1`, `::ffff:169.254.169.254` and
  # `::ffff:10.0.0.5` all returned false. Unfold to the embedded IPv4 and
  # re-check.
  defp private_address?({0, 0, 0, 0, 0, 0xFFFF, g, h}), do: private_address?(unfold_v4(g, h))

  defp private_address?({0, 0, 0, 0, 0, 0, g, h}) when g > 0 or h > 1,
    do: private_address?(unfold_v4(g, h))

  # Loopback, RFC1918, link-local (incl. 169.254.169.254 metadata),
  # carrier-grade NAT, and the various reserved ranges.
  defp private_address?({127, _, _, _}), do: true
  defp private_address?({10, _, _, _}), do: true
  defp private_address?({192, 168, _, _}), do: true
  defp private_address?({169, 254, _, _}), do: true
  defp private_address?({172, b, _, _}) when b >= 16 and b <= 31, do: true
  defp private_address?({100, b, _, _}) when b >= 64 and b <= 127, do: true
  defp private_address?({0, _, _, _}), do: true
  defp private_address?({a, _, _, _}) when a >= 224, do: true
  defp private_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private_address?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp private_address?({a, _, _, _, _, _, _, _}) when a in 0xFC00..0xFDFF, do: true
  defp private_address?({a, _, _, _, _, _, _, _}) when a in 0xFE80..0xFEBF, do: true
  defp private_address?(_), do: false

  defp unfold_v4(g, h), do: {div(g, 256), rem(g, 256), div(h, 256), rem(h, 256)}

  # Follow redirects MANUALLY so every hop is re-validated.
  #
  # `Req`'s own `max_redirects` follows them internally, so only the
  # original URL was ever checked: a public URL redirecting to
  # `http://169.254.169.254/...` or `http://127.0.0.1:5432/` was fetched
  # with no re-check, and the http->https upgrade in `validate_url/1`
  # applied only to the first URL. The `{301, 302} -> :redirect_loop`
  # clause below was a dead branch that only made sense if Req did not
  # auto-follow — which is the tell that this was never intended.
  @max_redirects 5

  defp do_http_request(url, timeout), do: do_http_request(url, timeout, @max_redirects)

  defp do_http_request(_url, _timeout, 0), do: {:error, :too_many_redirects}

  defp do_http_request(url, timeout, hops_left) do
    opts = request_opts(timeout)

    case Req.get(url, opts) do
      {:ok, %{status: status} = response} when status in [301, 302, 303, 307, 308] ->
        follow_redirect(response, url, timeout, hops_left, &do_http_request/3)

      other ->
        handle_http_response(other)
    end
  end

  # HEAD preflight used to call `Req.head/2` with default redirect
  # following, so only the first URL was private-range checked. Same hop
  # loop as GET: `redirect: false`, re-validate every Location.
  defp head_request(url, timeout), do: head_request(url, timeout, @max_redirects)
  defp head_request(_url, _timeout, 0), do: {:error, :too_many_redirects}

  defp head_request(url, timeout, hops_left) do
    case Req.head(url, request_opts(timeout)) do
      {:ok, %{status: status} = response} when status in [301, 302, 303, 307, 308] ->
        follow_redirect(response, url, timeout, hops_left, &head_request/3)

      other ->
        other
    end
  end

  defp request_opts(timeout) do
    [
      receive_timeout: timeout,
      redirect: false,
      headers: [
        {"user-agent", "PhoenixKit/1.0 (Image Downloader)"},
        {"accept", "image/*"}
      ]
    ]
  end

  defp follow_redirect(response, from_url, timeout, hops_left, continue) do
    location =
      response.headers
      |> Map.new(fn {k, v} -> {String.downcase(k), v} end)
      |> Map.get("location")
      |> List.wrap()
      |> List.first()

    case location do
      nil ->
        {:error, :invalid_redirect}

      location ->
        # Resolve relative Locations against the URL we just fetched, then
        # put the target through the SAME validation as the original —
        # scheme, host, and the private-range check.
        target = from_url |> URI.merge(location) |> URI.to_string()

        case validate_url(target) do
          {:ok, safe_url} -> continue.(safe_url, timeout, hops_left - 1)
          {:error, _} = error -> error
        end
    end
  end

  defp handle_http_response({:ok, %{status: 200} = response}), do: {:ok, response}

  defp handle_http_response({:ok, %{status: status}}) when status in [301, 302],
    do: {:error, :redirect_loop}

  defp handle_http_response({:ok, %{status: 404}}), do: {:error, :not_found}
  defp handle_http_response({:ok, %{status: 403}}), do: {:error, :forbidden}
  defp handle_http_response({:ok, %{status: 429}}), do: {:error, :rate_limited}

  defp handle_http_response({:ok, %{status: status}}) when status >= 500,
    do: {:error, :server_error}

  defp handle_http_response({:ok, %{status: status}}), do: {:error, {:http_error, status}}

  defp handle_http_response({:error, %Req.TransportError{reason: :timeout}}),
    do: {:error, :timeout}

  defp handle_http_response({:error, %Req.TransportError{reason: reason}}),
    do: {:error, {:transport_error, reason}}

  defp handle_http_response({:error, reason}), do: {:error, {:request_failed, reason}}

  defp extract_content_type(%{headers: headers}) do
    case get_header_value(headers, "content-type") do
      nil ->
        {:error, :missing_content_type}

      content_type ->
        # Extract just the MIME type, ignoring charset or other parameters
        mime_type =
          content_type
          |> String.split(";")
          |> List.first()
          |> String.trim()
          |> String.downcase()

        {:ok, mime_type}
    end
  end

  defp get_header_value(headers, key) do
    key_lower = String.downcase(key)

    headers
    |> Enum.find(fn {k, _v} -> String.downcase(k) == key_lower end)
    |> case do
      {_, value} when is_list(value) -> List.first(value)
      {_, value} -> value
      nil -> nil
    end
  end

  defp validate_content_type(content_type) when content_type in @allowed_content_types, do: :ok

  defp validate_content_type(@svg_content_type) do
    if Policy.allow_svg_uploads?() do
      :ok
    else
      {:error, {:invalid_content_type, @svg_content_type}}
    end
  end

  defp validate_content_type(content_type) do
    Logger.warning("Invalid content type for image download: #{content_type}")
    {:error, {:invalid_content_type, content_type}}
  end

  defp validate_size(body) when byte_size(body) <= @max_file_size, do: :ok

  defp validate_size(body) do
    size_mb = Float.round(byte_size(body) / 1024 / 1024, 2)

    {:error,
     {:file_too_large, "#{size_mb} MB exceeds limit of #{@max_file_size / 1024 / 1024} MB"}}
  end

  defp write_temp_file(body, content_type) do
    ext = content_type_to_extension(content_type)
    temp_path = generate_temp_path(ext)

    case File.write(temp_path, body) do
      :ok -> {:ok, temp_path}
      {:error, reason} -> {:error, {:write_failed, reason}}
    end
  end

  defp generate_temp_path(ext) do
    random = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    Path.join(System.tmp_dir!(), "phx_img_#{random}.#{ext}")
  end

  defp extract_filename_from_url(url, content_type) do
    uri = URI.parse(url)

    # Try to get filename from path
    base_name =
      case uri.path do
        nil ->
          "image"

        path ->
          path
          |> Path.basename()
          |> String.split("?")
          |> List.first()
          |> case do
            "" -> "image"
            name -> Path.rootname(name)
          end
      end

    # Ensure proper extension
    ext = content_type_to_extension(content_type)
    "#{base_name}.#{ext}"
  end

  defp content_type_to_extension(content_type) do
    case content_type do
      "image/jpeg" -> "jpg"
      "image/png" -> "png"
      "image/gif" -> "gif"
      "image/webp" -> "webp"
      "image/svg+xml" -> "svg"
      _ -> "jpg"
    end
  end

  defp cleanup_temp_file(temp_path) do
    case File.rm(temp_path) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to cleanup temp file #{temp_path}: #{inspect(reason)}")
        :ok
    end
  end
end
