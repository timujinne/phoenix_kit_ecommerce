defmodule PhoenixKitEcommerce.API.AttachImages do
  @moduledoc """
  `ecommerce.attach_images`: attaches pictures, given by URL, to products.
  It uses the importer's downloader, with its size limit, its
  content-type check and its near-duplicate reuse, and **always** with the
  private-network guard on: an API caller is not the shop's own CSV import,
  so `shop_image_import_allow_private_networks` does not apply to it. The
  downloaded bytes must also be a raster picture of the declared type (PNG,
  JPEG, GIF or WebP), so HTML served as `image/png` is refused, and an SVG is
  refused whatever the shop's SVG setting says.

  A picture whose URL (query stripped) is already stored is reused without a
  download. New pictures are appended after the ones the product has; a
  picture marked `"featured": true` becomes the featured one, and a product
  with no featured picture gets its first new one. At most 20 pictures per
  call, each at most `max_image_bytes/0` (10 MB, a fifth of the importer's
  own default). The call is synchronous. A signed URL's query string is a
  credential: the downloader is told to redact it (and any fragment) from its
  log lines and from the `source_url` it stores, and no answer repeats it. A
  URL with credentials in it (`user:password@host`) is refused.

  The downloads happen before a product is locked. A product trashed or moved
  meanwhile (or a row that fails) leaves its downloaded pictures in Storage with
  no owner, where the media orphan count shows them until a later call with the
  same URL reuses them; a stored picture that was trashed since it was looked
  up is not attached. The worst case of one call is about 12 seconds of name
  checks and 100 seconds of downloads, close to the 120 second idempotency lease
  of core, so a retry of a call that was slow can run beside the first one (the
  stored URLs are reused, nothing is stored twice).

  With `ctx.dry_run?` the URLs are checked (scheme, host, resolution into a
  private range) and nothing is fetched or stored. The tool has no `danger`
  rule, so `requires_confirmation` of the preview is core's row threshold alone.

  The catalogue logs the attachment as an ordinary item update by the key's
  owner; the module adds its own entry, `shop.api_images_attached`, which
  carries the API metadata (tool, key prefix, request id) and the counts.
  """

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Attachments}

  require Logger

  alias PhoenixKitCatalogue.Attachments
  alias PhoenixKitEcommerce.API.{Batch, CatalogueWrites, Gate, Meta, PlanSupport, Rows}
  alias PhoenixKitEcommerce.Catalogue.Writer
  alias PhoenixKitEcommerce.Services.ImageDownloader
  alias PhoenixKitEcommerce.StorefrontCache

  @tool "ecommerce.attach_images"
  @max_images 20
  @max_image_bytes 10 * 1024 * 1024
  @max_reason_chars 80
  @url_check_concurrency 5

  @doc "The most pictures one call may attach."
  @spec max_images() :: pos_integer()
  def max_images, do: @max_images

  @doc "The most bytes one downloaded picture may have."
  @spec max_image_bytes() :: pos_integer()
  def max_image_bytes, do: @max_image_bytes

  @doc """
  Rate-limit units of one call: one per picture asked for, at least one and
  at most `max_images/0` (a call over that limit is refused anyway, and must
  not be charged more than a full one). It is the tool's `cost` on a core that has the field: core's default rule
  prices a write by rows (`max(1, ceil(rows / 50))`), which would make a call
  that downloads up to 20 pictures cost one unit.

  Called with the raw, unvalidated input (the limiter runs before the
  validator), so it accepts anything.
  """
  @spec cost(term()) :: pos_integer()
  def cost(%{"items" => rows}) when is_list(rows) do
    rows
    |> Enum.map(fn
      %{"images" => images} when is_list(images) -> length(images)
      _row -> 0
    end)
    |> Enum.sum()
    |> min(@max_images)
    |> max(1)
  end

  def cost(_input), do: 1

  @doc "Handler of the tool."
  @spec run(map(), map()) ::
          {:ok, map()} | {:preview, map(), String.t()} | Gate.refusal()
  def run(input, ctx) do
    with {:ok, catalogue_uuid} <- Gate.check(input),
         :ok <- check_total(input) do
      shopify? = PhoenixKitEcommerce.shopify_enabled?()
      rows = input["items"] |> Batch.load(catalogue_uuid) |> Batch.plan(&plan_row(&1, shopify?))

      if Map.get(ctx, :dry_run?, false) do
        {:preview, rows |> Batch.preview() |> Batch.with_confirmation(rows),
         Batch.fingerprint(rows)}
      else
        {:ok, rows |> attach(ctx, catalogue_uuid) |> Batch.render()}
      end
    end
  end

  defp check_total(input) do
    total = input["items"] |> Enum.map(&length(Map.get(&1, "images", []))) |> Enum.sum()

    if total <= @max_images do
      :ok
    else
      {:error, :validation_failed, "At most #{@max_images} images per call.",
       %{
         errors: [
           %{
             path: "items",
             message: "has #{total} images in total",
             limit: @max_images,
             allowed: nil
           }
         ]
       }}
    end
  end

  # -- planning ---------------------------------------------------------------

  defp plan_row(%{item: item, input: input}, shopify?) do
    images = Map.get(input, "images", [])

    errors = featured_errors(images) ++ url_errors(images)

    if errors == [] do
      existing = existing_order(item)

      {:ok,
       %{
         from: %{media_order: existing},
         changes: %{"images" => %{"add" => length(images)}},
         changed?: images != [],
         dangerous?: false,
         warnings: warnings(item, images, shopify?),
         images: images
       }}
    else
      {:error, Rows.invalid(errors)}
    end
  end

  # The Shopify media sync replaces a product's picture order and featured
  # picture, so what this tool attaches to a linked product can be undone.
  defp warnings(item, images, shopify?) do
    if images != [] and PlanSupport.shopify_sync_may_overwrite?(item, shopify?),
      do: ["shopify_sync_may_overwrite"],
      else: []
  end

  defp featured_errors(images) do
    if Enum.count(images, &(&1["featured"] == true)) > 1,
      do: [PlanSupport.error("images", "at most one image can be featured")],
      else: []
  end

  # Each URL's name lookup has a deadline of its own (`ImageDownloader`), and
  # they run `@url_check_concurrency` at a time: a slow resolver holds the call
  # for at most ceil(urls / 5) deadlines (4 of 3 s for the 20 URLs a call may
  # have), not for one per picture.
  defp url_errors(images) do
    images
    |> Enum.with_index()
    |> Task.async_stream(&url_error/1,
      max_concurrency: @url_check_concurrency,
      timeout: :infinity,
      ordered: true
    )
    |> Enum.flat_map(fn {:ok, errors} -> errors end)
  end

  defp url_error({%{"url" => url}, index}) do
    path = "images[#{index}].url"

    if is_binary(url) and URI.parse(url).userinfo != nil do
      [PlanSupport.error(path, "must not contain credentials (user:password@)")]
    else
      case ImageDownloader.check_url(url, private_networks: :forbid) do
        :ok -> []
        {:error, reason} -> [PlanSupport.error(path, reason_text(reason))]
      end
    end
  end

  defp url_error({_image, index}),
    do: [PlanSupport.error("images[#{index}].url", "is required")]

  # -- attaching --------------------------------------------------------------

  defp attach(rows, ctx, catalogue_uuid) do
    user_uuid = Meta.actor_uuid(ctx)
    index = reuse_index(rows)
    downloaded = download_missing(rows, index, user_uuid)

    rows =
      Enum.map(rows, fn
        %{plan: %{changed?: true}} = row ->
          attach_row_safely(row, {index, downloaded}, {user_uuid, catalogue_uuid}, ctx)

        row ->
          row
      end)

    # After the rows are committed: a page rendered between the clear and the
    # commit would put the old pictures back into the cache.
    if Enum.any?(rows, &match?(%{result: {:ok, _}}, &1)), do: StorefrontCache.clear()
    rows
  end

  # URL -> file uuid for the pictures of this call only (at most 20 keys).
  defp reuse_index(rows) do
    keys =
      for %{plan: %{changed?: true, images: images}} <- rows,
          %{"url" => url} <- images,
          uniq: true,
          do: ImageDownloader.source_key(url)

    case keys do
      [] -> %{}
      keys -> Writer.build_reuse_index(keys).url_index
    end
  end

  # The URLs of every row that are not stored yet, downloaded in one
  # concurrent batch, so rows do not wait for each other and a URL given for
  # two products is fetched once. `%{url => {:ok, file_uuid} | {:error, reason}}`.
  defp download_missing(rows, url_index, user_uuid) do
    urls =
      for %{plan: %{changed?: true, images: images}} <- rows,
          %{"url" => url} <- images,
          not Map.has_key?(url_index, ImageDownloader.source_key(url)),
          uniq: true,
          do: url

    urls |> ImageDownloader.download_batch(user_uuid, download_opts()) |> Map.new()
  end

  # An exception in one row (a driver error that is not an `{:error, _}`) must
  # not take the answers of the rows already committed with it, nor the cache
  # clear: it is that row's storage_error, like the `{:error, _}` of `store/7`.
  # Only the exception module is logged: its message can hold request values.
  defp attach_row_safely(row, lookups, ids, ctx) do
    attach_row(row, lookups, ids, ctx)
  rescue
    error -> row |> log_raised(ctx, error.__struct__) |> fail_storage()
  catch
    :exit, _reason -> row |> log_raised(ctx, :exit) |> fail_storage()
  end

  defp log_raised(row, ctx, class) do
    Logger.error(
      "[attach_images] request #{Map.get(ctx, :request_id)}: attaching raised: #{inspect(class)}"
    )

    row
  end

  defp fail_storage(row) do
    Batch.fail(
      row,
      Rows.error(:validation_failed, "The pictures could not be attached.", %{
        "reason" => "storage_error"
      })
    )
  end

  # The downloads can take a minute and a half, so the product is read again
  # now, with its row locked, and must still be in the shop catalogue and out
  # of the trash: the pictures it has, and whether it may take new ones, are
  # what they are at this moment, not at planning time. The lock is held until
  # the pictures are attached, so a trash or a move waits for them.
  defp attach_row(%{item: item} = row, lookups, {user_uuid, catalogue_uuid}, ctx) do
    locked_result =
      CatalogueWrites.with_locked_items([item], fn locked ->
        case available(locked, item, catalogue_uuid) do
          {:ok, fresh} -> attach_to(%{row | item: fresh}, lookups, user_uuid, ctx)
          :error -> gone(row)
        end
      end)

    case locked_result do
      {:ok, attached} -> attached
      # The transaction did not commit (a rollback inside it), so nothing of
      # this row was kept.
      {:error, error} -> Batch.fail(row, error)
    end
  end

  defp available(locked, item, catalogue_uuid) do
    with {:ok, fresh} <- Map.fetch(locked, item.uuid),
         true <- Batch.available?(fresh, catalogue_uuid) do
      {:ok, fresh}
    else
      _gone -> :error
    end
  end

  defp gone(row),
    do: Batch.fail(row, Rows.error(:not_found, "The product is no longer in the shop catalogue."))

  defp attach_to(%{item: item, plan: plan} = row, lookups, user_uuid, ctx) do
    {resolved, failures} = plan.images |> resolve(lookups) |> drop_unavailable()

    existing = existing_order(item)
    new = resolved |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Kernel.--(existing)
    featured = featured_uuid(plan.images, resolved, item, new)
    reused = Enum.count(resolved, &(elem(&1, 2) == :reused))

    extra = %{
      "attached" => length(new),
      "reused" => reused,
      "downloaded" => length(resolved) - reused,
      "failed" => failures
    }

    change? = new != [] or featured_changes?(featured, item)

    cond do
      change? ->
        store(row, {existing, new}, featured, user_uuid, extra, ctx)

      failures != [] ->
        Batch.fail(
          row,
          Rows.error(:validation_failed, "No picture could be fetched.", %{"images" => failures})
        )

      true ->
        %{row | plan: %{plan | changed?: false}, extra: extra}
    end
  end

  defp store(%{item: item, plan: plan} = row, {existing, new}, featured, user_uuid, extra, ctx) do
    opts = [featured: featured, order: existing ++ new, actor_uuid: user_uuid]

    case Attachments.attach_files(item, new, opts) do
      {:ok, updated} ->
        log(updated, ctx, extra)
        changes = %{"images" => %{"add" => length(new)}}

        %{
          row
          | item: updated,
            result: {:ok, updated},
            plan: %{plan | changes: changes},
            extra: extra
        }

      {:error, reason} ->
        # The term can carry driver text or constraint names, so the log gets
        # its shape only; the answer gets a fixed sentence.
        Logger.error(
          "[attach_images] request #{Map.get(ctx, :request_id)}: attach_files failed: " <>
            Meta.term_class(reason)
        )

        fail_storage(row)
    end
  end

  # `[{url, file_uuid, :reused | :downloaded}]` in the order given, and the
  # failures as JSON-ready maps. A URL already stored (query stripped) is
  # reused; the rest were downloaded for the whole call.
  defp resolve(images, {url_index, downloaded}) do
    {ok, failed} =
      images
      |> Enum.map(& &1["url"])
      |> Enum.reduce({[], []}, fn url, {ok, failed} ->
        case lookup(url, url_index, downloaded) do
          {:ok, uuid, how} ->
            {[{url, uuid, how} | ok], failed}

          {:error, reason} ->
            {ok,
             [
               %{"url" => ImageDownloader.source_key(url), "reason" => reason_text(reason)}
               | failed
             ]}
        end
      end)

    {Enum.reverse(ok), Enum.reverse(failed)}
  end

  # The stored pictures were looked up before the downloads, which can take a
  # minute and a half; one trashed since then is not attached. One query for
  # the reused ones, made with the product's row locked.
  defp drop_unavailable({resolved, failures}) do
    reused = for {_url, uuid, :reused} <- resolved, uniq: true, do: uuid

    active =
      case reused do
        [] -> MapSet.new()
        uuids -> uuids |> Writer.active_file_uuids() |> MapSet.new()
      end

    {kept, dropped} =
      Enum.split_with(resolved, fn {_url, uuid, how} -> how != :reused or uuid in active end)

    gone =
      for {url, _uuid, _how} <- dropped,
          do: %{
            "url" => ImageDownloader.source_key(url),
            "reason" => "the stored picture is no longer available"
          }

    {kept, failures ++ gone}
  end

  defp lookup(url, url_index, downloaded) do
    case Map.fetch(url_index, ImageDownloader.source_key(url)) do
      {:ok, uuid} ->
        {:ok, uuid, :reused}

      :error ->
        case Map.get(downloaded, url) do
          {:ok, uuid} -> {:ok, uuid, :downloaded}
          {:error, reason} -> {:error, reason}
          nil -> {:error, :unknown}
        end
    end
  end

  defp download_opts do
    [
      timeout: 15_000,
      concurrency: 4,
      max_bytes: @max_image_bytes,
      private_networks: :forbid,
      require_raster: true,
      redact_query: true
    ] ++ Application.get_env(:phoenix_kit_ecommerce, :api_image_download_opts, [])
  end

  # The picture marked featured, if its file is known; else, when the product
  # has no featured picture yet, the first new one; else nothing changes.
  defp featured_uuid(images, resolved, item, new) do
    flagged_url =
      Enum.find_value(images, fn image -> if image["featured"] == true, do: image["url"] end)

    flagged =
      flagged_url &&
        Enum.find_value(resolved, fn {url, uuid, _how} -> if url == flagged_url, do: uuid end)

    cond do
      flagged -> flagged
      is_nil(current_featured(item)) -> List.first(new)
      true -> nil
    end
  end

  defp featured_changes?(featured, item),
    do: not is_nil(featured) and featured != current_featured(item)

  defp current_featured(item), do: get_in(item.data || %{}, ["featured_image_uuid"])

  defp existing_order(item) do
    case get_in(item.data || %{}, ["media_order"]) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp log(item, ctx, extra) do
    PhoenixKitEcommerce.Activity.log("shop.api_images_attached",
      actor_uuid: Meta.actor_uuid(ctx),
      mode: "auto",
      resource_type: "product",
      resource_uuid: item.uuid,
      metadata:
        Map.merge(Meta.log_metadata(ctx, @tool), %{
          "attached" => extra["attached"],
          "reused" => extra["reused"],
          "downloaded" => extra["downloaded"],
          "failed" => length(extra["failed"])
        })
    )
  end

  defp reason_text(:private_address_blocked),
    do: "the address is private, does not resolve, or the name lookup did not answer in time"

  defp reason_text(:invalid_scheme), do: "only http and https URLs are accepted"
  defp reason_text(:invalid_host), do: "the URL has no host"

  defp reason_text(:invalid_url),
    do:
      "the URL contains characters that must be percent-encoded (a host name with " <>
        "non-ASCII letters is written in punycode)"

  defp reason_text(:content_mismatch),
    do: "the file is not a PNG, JPEG, GIF or WebP picture of the type the server declared"

  defp reason_text(:timeout), do: "the download timed out"
  defp reason_text(:not_found), do: "the server answered 404"
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp reason_text({:invalid_content_type, type}) when is_binary(type),
    do: "not an accepted image type: #{media_type(type)}"

  defp reason_text({:invalid_content_type, _type}), do: "not an accepted image type"
  defp reason_text({:file_too_large, message}) when is_binary(message), do: message
  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(_reason), do: "the picture could not be fetched"

  # The media type before any parameter, cut short: the header is the remote
  # server's and can be as long and as odd as it likes.
  defp media_type(header) do
    header
    |> String.split(";", parts: 2)
    |> hd()
    |> String.trim()
    |> String.replace(~r/[^\x20-\x7E]/, "?")
    |> String.slice(0, @max_reason_chars)
  end
end
