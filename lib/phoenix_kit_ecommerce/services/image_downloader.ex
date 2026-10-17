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
  alias PhoenixKit.Modules.Storage.Sniff
  alias PhoenixKitEcommerce.Policy
  alias PhoenixKitEcommerce.Services.ImageFingerprint
  alias PhoenixKitEcommerce.Services.PinnedAdapter

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

  # The most of a remote-supplied value (a response header) that reaches a
  # log line.
  @max_logged_chars 80

  @doc """
  Downloads an image from a URL to a temporary file.

  Returns `{:ok, temp_path, content_type, size}` on success.

  ## Options

    * `:timeout` - HTTP request timeout in milliseconds (default: 30_000)
    * `:max_bytes` - size limit for the response body (default: 50 MB).
      A `content-length` above it is refused before any body is read,
      and a body that grows past it while streaming is halted where it
      stands — the whole file is never buffered first.
    * `:req_options` - extra `Req` options merged into every request
      (tests inject a `plug:` adapter here)
    * `:private_networks` - `:policy` (default: the shop's
      `shop_image_import_allow_private_networks` setting decides) or
      `:forbid` (loopback, private and link-local addresses are refused
      whatever the setting says, on the first URL and on every redirect;
      the admin API always passes it)
    * `:require_raster` - `true` also reads the downloaded bytes
      (`PhoenixKit.Modules.Storage.Sniff`) and refuses a body that is not a
      raster image of the type the server declared, with
      `{:error, :content_mismatch}`: HTML served as `image/png`, and an SVG
      whatever the shop's SVG setting says (default: `false`; the admin API
      passes `true`)

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
    max_bytes = Keyword.get(opts, :max_bytes, @max_file_size)

    private_networks = Keyword.get(opts, :private_networks, :policy)

    request = %{
      timeout: timeout,
      max_bytes: max_bytes,
      req_options: Keyword.get(opts, :req_options, []),
      private_networks: private_networks
    }

    with {:ok, url, pin} <- validate_url(url, private_networks),
         {:ok, response} <- do_http_request(url, pin, request),
         {:ok, content_type} <- extract_content_type(response),
         :ok <- validate_content_type(content_type),
         :ok <- validate_size(response, max_bytes),
         body = IO.iodata_to_binary(response.body),
         {:ok, temp_path} <- write_temp_file(body, content_type),
         :ok <- check_content(temp_path, content_type, opts) do
      {:ok, temp_path, content_type, byte_size(body)}
    end
  end

  # With `require_raster: true` the bytes must be a raster image, and the one
  # the declared type says: a Content-Type is the remote server's claim.
  defp check_content(temp_path, content_type, opts) do
    if Keyword.get(opts, :require_raster, false) and not raster_of_type?(temp_path, content_type) do
      cleanup_temp_file(temp_path)
      {:error, :content_mismatch}
    else
      :ok
    end
  end

  defp raster_of_type?(path, content_type) do
    case Sniff.sniff(path) do
      {:ok, %{format: format, mime: mime}} -> mime == content_type and Sniff.raster?(format)
      _unknown -> false
    end
  end

  @doc """
  Downloads an image from a URL and stores it in the Storage module.

  Returns `{:ok, file_uuid}` where file_uuid is a UUID that can be used to reference
  the stored file.

  An existing ACTIVE file is reused instead of storing a second one:

    1. the same bytes under the same file name (SHA-256 and
       `original_file_name`);
    2. failing that, the same picture — a re-encoded, re-saved or
       downscaled copy — among the files this module imported (they carry
       `metadata["source_url"]`): candidates by `ImageFingerprint.match/2`
       against their `metadata["image_fingerprint"]`, closest first, then
       the earliest stored; the first of the best three whose original
       also passes `ImageFingerprint.same_picture?/2` wins.

  A trashed file is never picked by either step. If the bytes are new to
  both steps but core's own per-uploader dedup in `Storage.store_file/2`
  answers with a trashed copy of them, that copy is restored: it is the
  only row holding the picture the import asks for.

  An imported file that is reused records `url` in
  `metadata["source_url_aliases"]` (query stripped, see `source_key/1`)
  unless it is already its own `source_url`, so `Catalogue.Writer`'s URL
  index reuses it for that URL next time without a download. A newly
  stored file carries its fingerprint in `metadata["image_fingerprint"]`.

  Step 2 reads the fingerprint of every imported image once per download
  that step 1 did not answer — linear in the library (about 25 ms of CPU
  for 3,000 images), fine for a shop's library, not meant for millions —
  and reads a candidate's original from Storage only when its fingerprint
  matches.

  ## Options

    * `:timeout` - HTTP request timeout in milliseconds (default: 30_000)
    * `:metadata` - Additional metadata to store with the file
    * `:near_duplicates` - `false` skips step 2 and the fingerprint
      (default: `true`)
    * `:redact_query` - `true` logs and stores the URL without its query
      string, fragment and credentials (`source_key/1`) after the request has been made with the full
      URL, so a signed URL's credential reaches neither the log nor the
      file's `source_url` metadata (default: `false`; the admin API passes
      `true`)

  ## Examples

      iex> download_and_store("https://cdn.shopify.com/image.jpg", user_uuid)
      {:ok, "018f1234-5678-7890-abcd-ef1234567890"}

      iex> download_and_store("https://example.com/404.jpg", user_uuid)
      {:error, :not_found}

  """
  @spec download_and_store(String.t(), String.t() | nil, keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def download_and_store(url, user_uuid, opts \\ []) when is_binary(url) do
    metadata = Keyword.get(opts, :metadata, %{})

    with {:ok, temp_path, content_type, size} <- download_image(url, opts) do
      # The request above used the full URL. From here on the URL is only
      # logged and remembered. What is remembered is the redacted form when
      # asked to be; what is logged then carries no path either, which can
      # hold a signed token as well as the query can.
      logged = log_url(url, opts)
      url = stored_url(url, opts)
      file_checksum = calculate_file_hash(temp_path)
      filename = extract_filename_from_url(url, content_type)

      case find_existing_file(file_checksum, filename) do
        %{uuid: existing_uuid} ->
          Logger.info(
            "[ImageDownloader] Reusing #{existing_uuid} for #{logged}: same bytes and name (checksum: #{file_checksum})"
          )

          reuse(existing_uuid, {url, logged}, temp_path)

        nil ->
          download = %{
            url: url,
            logged: logged,
            temp_path: temp_path,
            filename: filename,
            content_type: content_type,
            size: size
          }

          reuse_same_picture_or_store(download, user_uuid, metadata, opts)
      end
    end
  end

  defp reuse_same_picture_or_store(download, user_uuid, metadata, opts) do
    %{url: url, logged: logged, temp_path: temp_path, size: size} = download
    fingerprint = fingerprint(temp_path, opts)

    case find_near_duplicate(fingerprint, temp_path) do
      {existing_uuid, distances} ->
        Logger.info(
          "[ImageDownloader] Reusing #{existing_uuid} for #{logged}: same picture (#{inspect(distances)})"
        )

        reuse(existing_uuid, {url, logged}, temp_path)

      nil ->
        Logger.info(
          "[ImageDownloader] Storing new file from URL #{logged}, temp_path=#{temp_path}, size=#{size}"
        )

        store_new_file(
          temp_path,
          download.filename,
          download.content_type,
          size,
          user_uuid,
          url,
          put_fingerprint(metadata, fingerprint)
        )
    end
  end

  defp reuse(file_uuid, {url, logged}, temp_path) do
    remember_source_url(file_uuid, url, logged)
    cleanup_temp_file(temp_path)
    {:ok, file_uuid}
  end

  @doc """
  The form a download URL is matched in: the URL with its query string
  (Shopify's `?v=<timestamp>`), its fragment and any `user:password@` part
  removed. `nil` for anything that is not a string.
  """
  @spec source_key(term()) :: String.t() | nil
  def source_key(url) when is_binary(url) do
    uri = URI.parse(url)

    URI.to_string(%URI{uri | query: nil, fragment: nil, userinfo: nil, authority: nil})
  end

  def source_key(_url), do: nil

  @doc """
  Stamps `metadata["image_fingerprint"]` on imported images stored before
  fingerprints existed, or under an older fingerprint version — active
  image files carrying `metadata["source_url"]` — so step 2 of
  `download_and_store/3` can match against them. Reads each original from
  Storage once; walks every such file in one call.

  Returns `%{fingerprinted: n, failed: n}`. A file that cannot be read or
  fingerprinted is left as it is, logged and counted; running it again
  retries only what is still missing.
  """
  @spec backfill_fingerprints() :: %{fingerprinted: non_neg_integer(), failed: non_neg_integer()}
  def backfill_fingerprints do
    import Ecto.Query

    current = ImageFingerprint.version() <> ":%"

    from(f in PhoenixKit.Modules.Storage.File,
      where:
        f.status == "active" and f.file_type == "image" and
          fragment("(?->>'source_url') IS NOT NULL", f.metadata) and
          fragment("coalesce(?->>'image_fingerprint', '') NOT LIKE ?", f.metadata, ^current),
      order_by: [asc: f.inserted_at, asc: f.uuid],
      select: f.uuid
    )
    |> PhoenixKit.Config.get_repo().all()
    |> Enum.reduce(%{fingerprinted: 0, failed: 0}, fn uuid, acc ->
      case fingerprint_stored(uuid) do
        :ok ->
          Map.update!(acc, :fingerprinted, &(&1 + 1))

        {:error, reason} ->
          Logger.warning("[ImageDownloader] Could not fingerprint #{uuid}: #{inspect(reason)}")
          Map.update!(acc, :failed, &(&1 + 1))
      end
    end)
  end

  defp fingerprint_stored(uuid) do
    with {:ok, path, _file} <- Storage.retrieve_file(uuid) do
      result = ImageFingerprint.compute(path)
      cleanup_temp_file(path)

      with {:ok, fingerprint} <- result,
           {:ok, _file} <-
             Storage.update_file_metadata(uuid, &Map.put(&1, "image_fingerprint", fingerprint)) do
        :ok
      end
    end
  end

  defp fingerprint(temp_path, opts) do
    if Keyword.get(opts, :near_duplicates, true) do
      case ImageFingerprint.compute(temp_path) do
        {:ok, fingerprint} ->
          fingerprint

        {:error, :multiple_frames} ->
          nil

        {:error, reason} ->
          # Loud on purpose: without a fingerprint the near-duplicate check
          # is off for this download (ImageMagick missing, an unreadable
          # format), and copies get stored again.
          Logger.warning(
            "[ImageDownloader] No fingerprint for #{temp_path}, near-duplicate check skipped: #{inspect(reason)}"
          )

          nil
      end
    end
  end

  defp put_fingerprint(metadata, nil), do: metadata

  defp put_fingerprint(metadata, fingerprint),
    do: Map.put(metadata, "image_fingerprint", fingerprint)

  # The closest confirmed match among active imported images —
  # `{uuid, distances}`. Candidates are the fingerprint matches, closest
  # first, ties to the earliest stored, then the lowest uuid; the first of
  # them (at most `@confirm_attempts`) whose original passes
  # `ImageFingerprint.same_picture?/2` against the download wins.
  @confirm_attempts 3

  defp find_near_duplicate(nil, _temp_path), do: nil

  defp find_near_duplicate(fingerprint, temp_path) do
    import Ecto.Query

    from(f in PhoenixKit.Modules.Storage.File,
      where:
        f.status == "active" and
          fragment("(?->>'source_url') IS NOT NULL", f.metadata) and
          fragment(
            "(?->>'image_fingerprint') LIKE ?",
            f.metadata,
            ^(ImageFingerprint.version() <> ":%")
          ),
      select: {f.uuid, f.inserted_at, fragment("?->>'image_fingerprint'", f.metadata)}
    )
    |> PhoenixKit.Config.get_repo().all()
    |> Enum.flat_map(fn {uuid, inserted_at, candidate} ->
      case ImageFingerprint.match(fingerprint, candidate) do
        {:ok, %{bits: bits, mean_color: mean} = distances} ->
          [{{bits, mean, DateTime.to_unix(inserted_at, :microsecond), uuid}, {uuid, distances}}]

        :nomatch ->
          []
      end
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.take(@confirm_attempts)
    |> Enum.find_value(fn {_rank, {uuid, _distances} = found} ->
      if same_picture_as_stored?(temp_path, uuid), do: found
    end)
  end

  # Step 2 against the stored original. A candidate that cannot be read is
  # not reused — storing one more copy is the safe side.
  defp same_picture_as_stored?(temp_path, file_uuid) do
    case Storage.retrieve_file(file_uuid) do
      {:ok, stored_path, _file} ->
        same? = ImageFingerprint.same_picture?(temp_path, stored_path)
        cleanup_temp_file(stored_path)

        unless same?,
          do:
            Logger.info("[ImageDownloader] #{file_uuid} matches by fingerprint only, not reused")

        same?

      {:error, reason} ->
        Logger.warning(
          "[ImageDownloader] Could not read #{file_uuid} to confirm: #{inspect(reason)}"
        )

        false
    end
  end

  # Records `url` on the imported file it was resolved to, unless that file
  # already answers to it. A file without a download source is left alone:
  # nothing reads aliases off it. Best effort — a failure here costs one
  # download later, never the reuse itself.
  defp remember_source_url(file_uuid, url, logged) do
    key = source_key(url)

    result =
      Storage.update_file_metadata(file_uuid, fn metadata ->
        aliases = metadata["source_url_aliases"] || []
        own = source_key(metadata["source_url"])

        if is_nil(own) or key == own or key in aliases do
          :unchanged
        else
          Map.put(metadata, "source_url_aliases", aliases ++ [key])
        end
      end)

    with {:error, reason} <- result do
      Logger.warning(
        "[ImageDownloader] Could not record #{logged} on #{file_uuid}: #{inspect(reason)}"
      )
    end
  rescue
    e ->
      Logger.warning(
        "[ImageDownloader] Could not record #{logged} on #{file_uuid}: #{inspect(e)}"
      )
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

      Logger.info("[ImageDownloader] Storage result: #{storage_outcome(result)}")
      cleanup_temp_file(temp_path)
      handle_storage_result(result)
    else
      Logger.error("[ImageDownloader] Temp file disappeared before storage: #{temp_path}")
      {:error, :temp_file_missing}
    end
  end

  # Core's per-uploader dedup answers with an existing row of the same
  # bytes whatever its status; a trashed one is brought back (see
  # `download_and_store/3`).
  defp handle_storage_result({:ok, %{status: "trashed"} = file}) do
    # Into no folder — core's rule for trashed bytes uploaded again: they
    # are wanted where they are being used now, not back where they were
    # removed from. `:not_trashed` means another upload restored it first.
    case Storage.restore_file_into(file, nil) do
      {:ok, restored} ->
        Logger.info("[ImageDownloader] Restored trashed file #{restored.uuid} for the same bytes")
        {:ok, restored.uuid}

      {:error, :not_trashed} ->
        case Storage.get_file(file.uuid) do
          %{status: "active"} ->
            {:ok, file.uuid}

          _gone ->
            Logger.error("[ImageDownloader] Trashed duplicate #{file.uuid} vanished mid-restore")
            {:error, {:trashed_duplicate, file.uuid}}
        end
    end
  end

  defp handle_storage_result({:ok, file}) do
    Logger.info("[ImageDownloader] Successfully stored file with ID: #{file.uuid}")
    {:ok, file.uuid}
  end

  defp handle_storage_result({:error, reason}) do
    Logger.error("[ImageDownloader] Storage failed: #{loggable_storage_error(reason)}")
    {:error, reason}
  end

  # The stored file carries the source URL in its metadata, so neither the
  # file nor a changeset over it is logged whole: only what happened.
  defp storage_outcome({:ok, %{uuid: uuid, status: status}}), do: "ok #{uuid} (#{status})"
  defp storage_outcome({:ok, _file}), do: "ok"
  defp storage_outcome({:error, reason}), do: "error: " <> loggable_storage_error(reason)

  defp loggable_storage_error(%Ecto.Changeset{errors: errors}), do: inspect(errors)
  defp loggable_storage_error(reason), do: inspect(reason)

  # Find an active file with the same checksum AND original filename. A
  # trashed copy is not a file to reuse: attaching it would show a picture
  # that is on its way out of Storage.
  defp find_existing_file(file_checksum, filename) do
    import Ecto.Query

    repo = PhoenixKit.Config.get_repo()

    query =
      from(f in PhoenixKit.Modules.Storage.File,
        where:
          f.file_checksum == ^file_checksum and f.original_file_name == ^filename and
            f.status == "active",
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
        result = guarded_download(url, user_uuid, opts)

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
        Logger.warning("Task exited for URL #{log_url(url, opts)}: #{inspect(reason)}")
        {url, {:error, {:task_exit, reason}}}
    end)
  end

  # One URL's work never takes the caller down: the batch's tasks are linked
  # to it, and a crash report of a task prints its arguments - the URL, with
  # a signed query string in it. Only the shape of the failure is logged.
  defp guarded_download(url, user_uuid, opts) do
    download_and_store(url, user_uuid, opts)
  rescue
    exception ->
      Logger.error("[ImageDownloader] Download crashed: #{inspect(exception.__struct__)}")
      {:error, :download_failed}
  catch
    kind, _reason ->
      Logger.error("[ImageDownloader] Download crashed: #{kind}")
      {:error, :download_failed}
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
    case validate_url(url, :policy) do
      {:ok, url, pin} ->
        case head_request(url, pin, %{timeout: timeout, req_options: []}) do
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

  @doc """
  Checks a URL without fetching it: the scheme is http(s), the host exists,
  and the host resolves only into public addresses. A name lookup is made;
  no HTTP request is.

  Takes `:private_networks` like `download_image/2`.
  """
  @spec check_url(String.t(), keyword()) :: :ok | {:error, atom()}
  def check_url(url, opts \\ []) when is_binary(url) do
    case validate_url(url, Keyword.get(opts, :private_networks, :policy)) do
      {:ok, _url, _pin} -> :ok
      {:error, _reason} = error -> error
    end
  end

  # Private functions

  # Returns `{:ok, url, pin}`: `pin` is the ONE resolved public address
  # the request must connect to (see `pinned_request/2`), or `nil` when
  # no pinning is needed (a literal-IP host, or private networks are
  # allowed by policy so there is nothing to defend).
  defp validate_url(url, private_networks) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] ->
        {:error, :invalid_scheme}

      is_nil(uri.host) or uri.host == "" ->
        {:error, :invalid_host}

      # `URI.parse/1` is lenient; a space, a non-ASCII character or a `|` in
      # the URL is not something the request can be built from.
      match?({:error, _}, URI.new(url)) ->
        {:error, :invalid_url}

      true ->
        # Upgrade HTTP to HTTPS for security. The scheme is case-insensitive
        # (`URI.parse/1` lowercases it), so the prefix is matched that way.
        url =
          if uri.scheme == "http",
            do: Regex.replace(~r/\Ahttp:\/\//i, url, "https://"),
            else: url

        with {:ok, pin} <- pin_for(uri.host, private_networks) do
          {:ok, url, pin}
        end
    end
  end

  defp pin_for(host, private_networks) do
    if private_networks != :forbid and Policy.image_import_allow_private_networks?() do
      {:ok, nil}
    else
      case resolve_public_address(host) do
        {:ok, pin} -> {:ok, pin}
        :error -> {:error, :private_address_blocked}
      end
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
  def private_host?(host), do: resolve_public_address(host) == :error

  @doc false
  # The resolved public address a connection to `host` must use, or `:error`
  # (see `resolve_public_address/1` below for the shapes). Strict: unlike the
  # importer's own `validate_url/1` it never consults
  # `shop_image_import_allow_private_networks`, so other outbound fetches
  # (the Shopify storefront's redirect hops) can share the guard without
  # inheriting that opt-out.
  @spec public_address(String.t()) :: {:ok, :inet.ip_address() | nil} | :error
  def public_address(host), do: resolve_public_address(host)

  # Resolves `host` ONCE and hands back the address the connection must
  # use: `{:ok, nil}` for a public literal (nothing to pin — the literal
  # is the address), `{:ok, address}` for a name whose every answer is
  # public, `:error` when any answer is private or the name does not
  # resolve at all.
  #
  # Checking the name here and then letting the HTTP client resolve it
  # AGAIN is a DNS-rebinding hole: a hostile resolver answers the guard's
  # lookup with a public address and the client's lookup, a moment later,
  # with 169.254.169.254. The address returned here is what the request
  # actually connects to (`pinned_request/2`), so the guard and the
  # connection can never disagree.
  defp resolve_public_address(host) do
    host = String.trim_trailing(host, ".")
    charlist = String.to_charlist(host)

    case :inet.parse_address(charlist) do
      {:ok, address} ->
        if private_address?(address), do: :error, else: {:ok, nil}

      {:error, _} ->
        # Not a literal — resolve and check every answer. Fail CLOSED on a
        # resolution error: a name we cannot resolve is not a name we can
        # vouch for.
        charlist |> resolve_all() |> vouch_for_answers()
    end
  end

  defp vouch_for_answers([]), do: :error

  defp vouch_for_answers(answers) do
    if Enum.any?(answers, &private_address?/1), do: :error, else: {:ok, hd(answers)}
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
  #
  # Each lookup has a deadline (`@dns_timeout`): `:inet.getaddrs/2` waits as
  # long as the authoritative server cares to, and the guard runs in the
  # caller's own process (also when a call only plans, `check_url/2`). A
  # family that does not answer in time fails the whole name closed: its
  # records are unknown, so the name cannot be vouched for.
  @dns_timeout 3_000

  defp resolve_all(host) do
    resolver = Application.get_env(:phoenix_kit_ecommerce, :image_resolver, :inet)
    timeout = Application.get_env(:phoenix_kit_ecommerce, :image_dns_timeout, @dns_timeout)

    results =
      Task.async_stream(
        [:inet, :inet6],
        fn family -> lookup(resolver, host, family, timeout) end,
        timeout: timeout,
        on_timeout: :kill_task,
        ordered: true
      )
      |> Enum.to_list()

    if Enum.all?(results, &match?({:ok, _}, &1)),
      do: Enum.flat_map(results, fn {:ok, answers} -> answers end),
      else: []
  end

  defp lookup(resolver, host, family, timeout) do
    case resolver.getaddrs(host, family, timeout) do
      {:ok, addresses} -> addresses
      {:error, _} -> []
    end
  end

  @doc false
  # Rewrites `url` to connect to the already-validated `address` while the
  # ORIGINAL hostname keeps doing everything a hostname does: the explicit
  # `host` header is what the origin routes on (Mint would otherwise derive
  # it from the IP literal in the URL), and `PinnedAdapter` sends the same
  # name as TLS SNI and verifies the certificate against it. The port is kept
  # in the header only when it is not the scheme's default, which is what
  # Mint's own default host header does.
  #
  # The request does NOT go through `connect_options: [hostname: host]`:
  # `Req` starts a `Finch` pool, with a new atom for its name, for every
  # distinct value and never stops it, so every hostname an API caller can
  # name would stay in the node for good.
  #
  # `nil` means "no pin" (see `validate_url/2`) and returns the URL and
  # options untouched.
  @spec pinned_request(String.t(), :inet.ip_address() | nil) :: {String.t(), keyword()}
  def pinned_request(url, nil), do: {url, []}

  def pinned_request(url, address) when is_tuple(address) do
    # `parse/1`, not `new!/1`: a URL that cannot be parsed strictly never
    # gets here (`validate_url/2` refuses it), and this function must not be
    # the place that raises. Only `host` is replaced; `to_string/1` builds
    # the authority from it.
    uri = URI.parse(url)
    ip = address |> :inet.ntoa() |> to_string()
    pinned_url = URI.to_string(%{uri | host: ip})

    host_header =
      if uri.port in [nil, URI.default_port(uri.scheme)],
        do: uri.host,
        else: "#{uri.host}:#{uri.port}"

    {pinned_url, [adapter: PinnedAdapter, headers: [{"host", host_header}]]}
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

  # The other IPv6 forms that carry an IPv4 address reach it through a
  # translator or a relay the host may have: SIIT (`::ffff:0:a.b.c.d`), NAT64
  # (`64:ff9b::a.b.c.d`) and 6to4 (`2002:<IPv4>::`). The IPv4 rule below
  # decides, on the embedded address. The local-use NAT64 prefix
  # (`64:ff9b:1::/48`) is never a public destination.
  defp private_address?({0, 0, 0, 0, 0xFFFF, 0, g, h}), do: private_address?(unfold_v4(g, h))
  defp private_address?({0x64, 0xFF9B, 0, 0, 0, 0, g, h}), do: private_address?(unfold_v4(g, h))
  defp private_address?({0x64, 0xFF9B, 1, _, _, _, _, _}), do: true
  defp private_address?({0x2002, g, h, _, _, _, _, _}), do: private_address?(unfold_v4(g, h))

  # Loopback, RFC1918, link-local (incl. 169.254.169.254 metadata),
  # carrier-grade NAT, and the various reserved ranges.
  defp private_address?({127, _, _, _}), do: true
  defp private_address?({10, _, _, _}), do: true
  defp private_address?({192, 168, _, _}), do: true
  defp private_address?({169, 254, _, _}), do: true
  defp private_address?({172, b, _, _}) when b >= 16 and b <= 31, do: true
  defp private_address?({100, b, _, _}) when b >= 64 and b <= 127, do: true
  defp private_address?({192, 0, 0, _}), do: true
  defp private_address?({192, 0, 2, _}), do: true
  defp private_address?({198, 51, 100, _}), do: true
  defp private_address?({203, 0, 113, _}), do: true
  defp private_address?({198, b, _, _}) when b in 18..19, do: true
  defp private_address?({0, _, _, _}), do: true
  defp private_address?({a, _, _, _}) when a >= 224, do: true
  defp private_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private_address?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp private_address?({a, _, _, _, _, _, _, _}) when a in 0xFC00..0xFDFF, do: true
  defp private_address?({a, _, _, _, _, _, _, _}) when a in 0xFE80..0xFEBF, do: true
  defp private_address?({a, _, _, _, _, _, _, _}) when a in 0xFEC0..0xFEFF, do: true
  # Multicast (ff00::/8) is never a unicast destination. The rest are ranges
  # no public host lives in: the discard prefix (100::/64), Teredo
  # (2001::/32, a tunnel whose server is reached over IPv4), benchmarking
  # (2001:2::/48) and the documentation prefixes (2001:db8::/32, 3fff::/20).
  defp private_address?({a, _, _, _, _, _, _, _}) when a in 0xFF00..0xFFFF, do: true
  defp private_address?({0x100, 0, 0, 0, _, _, _, _}), do: true
  defp private_address?({0x2001, 0, _, _, _, _, _, _}), do: true
  defp private_address?({0x2001, 2, 0, _, _, _, _, _}), do: true
  defp private_address?({0x2001, 0xDB8, _, _, _, _, _, _}), do: true
  defp private_address?({0x3FFF, b, _, _, _, _, _, _}) when b <= 0x0FFF, do: true
  defp private_address?(_), do: false

  defp unfold_v4(g, h), do: {div(g, 256), rem(g, 256), div(h, 256), rem(h, 256)}

  # Follow redirects MANUALLY so every hop is re-validated.
  #
  # `Req`'s own `max_redirects` follows them internally, so only the
  # original URL was ever checked: a public URL redirecting to
  # `http://169.254.169.254/...` or `http://127.0.0.1:5432/` was fetched
  # with no re-check, and the http->https upgrade in `validate_url/2`
  # applied only to the first URL. The `{301, 302} -> :redirect_loop`
  # clause below was a dead branch that only made sense if Req did not
  # auto-follow — which is the tell that this was never intended.
  @max_redirects 5

  defp do_http_request(url, pin, request), do: do_http_request(url, pin, request, @max_redirects)

  @doc false
  # The request step with the pin already resolved, hops and all; the
  # connection tests drive it with a loopback pin, which `validate_url/2`
  # would never hand out.
  @spec pinned_get(String.t(), :inet.ip_address() | nil, map()) ::
          {:ok, Req.Response.t()} | {:error, term()}
  def pinned_get(url, pin, request), do: do_http_request(url, pin, request)

  @doc false
  # `pinned_get/3` for the HEAD preflight.
  @spec pinned_head(String.t(), :inet.ip_address() | nil, map()) ::
          {:ok, Req.Response.t()} | {:error, term()}
  def pinned_head(url, pin, request), do: head_request(url, pin, request)

  defp do_http_request(_url, _pin, _request, 0), do: {:error, :too_many_redirects}

  defp do_http_request(url, pin, request, hops_left) do
    {pinned_url, pin_opts} = pinned_request(url, pin)
    opts = request_opts(request, pin_opts) ++ [into: body_collector(request.max_bytes)]

    case Req.get(pinned_url, opts) do
      {:ok, %{status: status} = response} when status in [301, 302, 303, 307, 308] ->
        follow_redirect(response, url, request, hops_left, &do_http_request/4)

      other ->
        handle_http_response(other)
    end
  end

  # HEAD preflight used to call `Req.head/2` with default redirect
  # following, so only the first URL was private-range checked. Same hop
  # loop as GET: `redirect: false`, re-validate every Location.
  defp head_request(url, pin, request), do: head_request(url, pin, request, @max_redirects)
  defp head_request(_url, _pin, _request, 0), do: {:error, :too_many_redirects}

  defp head_request(url, pin, request, hops_left) do
    {pinned_url, pin_opts} = pinned_request(url, pin)

    case Req.head(pinned_url, request_opts(request, pin_opts)) do
      {:ok, %{status: status} = response} when status in [301, 302, 303, 307, 308] ->
        follow_redirect(response, url, request, hops_left, &head_request/4)

      other ->
        other
    end
  end

  defp request_opts(request, pin_opts) do
    base = [
      receive_timeout: request.timeout,
      redirect: false,
      # Req's default retries a 429/503 after the origin's `Retry-After`,
      # uncapped: a hostile origin could park the caller for as long as it likes.
      retry: false,
      headers: [
        {"user-agent", "PhoenixKit/1.0 (Image Downloader)"},
        {"accept", "image/*"}
      ]
    ]

    base
    |> merge_req_opts(pin_opts)
    |> merge_req_opts(request.req_options)
  end

  defp merge_req_opts(opts, extra) do
    Keyword.merge(opts, extra, fn
      :headers, existing, added -> existing ++ added
      _key, _existing, added -> added
    end)
  end

  # Streams the response body in, bounding it as it arrives. The body is
  # accumulated as iodata under `response.body`; the byte count lives in
  # `response.private` so the same collector serves every hop. The
  # response is halted — the connection dropped, nothing more read — the
  # moment either the declared `content-length` or the bytes actually
  # received pass `max_bytes`: buffering the whole file first and
  # checking its size afterwards let an oversized (or endless) response
  # occupy memory up to whatever the origin felt like sending.
  defp body_collector(max_bytes) do
    fn {:data, chunk}, {req, resp} ->
      received = Map.get(resp.private, :received_bytes, 0) + byte_size(chunk)
      declared = declared_content_length(resp)

      if received > max_bytes or (is_integer(declared) and declared > max_bytes) do
        {:halt, {req, Req.Response.put_private(resp, :too_large, max(received, declared || 0))}}
      else
        resp =
          resp
          |> Req.Response.put_private(:received_bytes, received)
          |> Map.update!(:body, &[&1, chunk])

        {:cont, {req, resp}}
      end
    end
  end

  defp declared_content_length(%{headers: headers}) do
    with value when is_binary(value) <- get_header_value(headers, "content-length"),
         {length, ""} <- Integer.parse(String.trim(value)) do
      length
    else
      _ -> nil
    end
  end

  defp follow_redirect(response, from_url, request, hops_left, continue) do
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
        # scheme, host, and the private-range check — which also pins the
        # hop's own resolved address, exactly like the first request.
        target = from_url |> URI.merge(location) |> URI.to_string()

        case validate_url(target, Map.get(request, :private_networks, :policy)) do
          {:ok, safe_url, pin} -> continue.(safe_url, pin, request, hops_left - 1)
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
    Logger.warning("Invalid content type for image download: #{loggable(content_type)}")
    {:error, {:invalid_content_type, content_type}}
  end

  # A remote-supplied value for a log line: printable ASCII only, cut short.
  defp loggable(value) do
    value
    |> to_string()
    |> String.replace(~r/[^\x20-\x7E]/, "?")
    |> String.slice(0, @max_logged_chars)
  end

  # The streaming collector already halted an oversized body; this turns
  # that mark (or a `content-length` past the limit on a response whose
  # body never streamed at all) into the size error.
  defp validate_size(response, max_bytes) do
    declared = declared_content_length(response)

    cond do
      is_integer(response.private[:too_large]) ->
        file_too_large(response.private[:too_large], max_bytes)

      is_integer(declared) and declared > max_bytes ->
        file_too_large(declared, max_bytes)

      true ->
        :ok
    end
  end

  defp file_too_large(bytes, max_bytes) do
    size_mb = Float.round(bytes / 1024 / 1024, 2)
    {:error, {:file_too_large, "#{size_mb} MB exceeds limit of #{max_bytes / 1024 / 1024} MB"}}
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

  # `original_file_name` is a varchar(255): a long last path segment must
  # not reach the insert.
  @max_filename_base_chars 120

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
            name -> name |> Path.rootname() |> String.slice(0, @max_filename_base_chars)
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

  # The form of a URL that may be remembered: in stored metadata and in the
  # reuse index.
  defp stored_url(url, opts) do
    if Keyword.get(opts, :redact_query, false), do: source_key(url), else: url
  end

  # The form of a URL that may appear in a log line. When redacting, the path
  # goes as well as the query: a signed token can sit in a path segment.
  defp log_url(url, opts) do
    if Keyword.get(opts, :redact_query, false), do: without_path(url), else: url
  end

  defp without_path(url) do
    uri = URI.parse(url)
    port = if uri.port in [nil, URI.default_port(uri.scheme)], do: "", else: ":#{uri.port}"
    "#{uri.scheme}://#{uri.host}#{port}/..."
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
