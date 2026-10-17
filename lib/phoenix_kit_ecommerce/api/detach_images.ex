defmodule PhoenixKitEcommerce.API.DetachImages do
  @moduledoc """
  `ecommerce.detach_images`: takes pictures out of a product's gallery. A
  picture is named by its file `id` or by the `url` it was attached from
  (query stripped, as `ecommerce.attach_images` stores it); exactly one of the
  two. Only a picture the product's gallery names (`data["media_order"]` and
  the featured pointer) can be removed; anything else is reported in
  `not_attached` and changes nothing, so a retry of a call that succeeded is
  `unchanged`, and another product's picture can not be reached by naming it.
  A URL is looked up among the files the gallery names (their stored source
  URL and the URLs that resolved to them), in whatever state Storage keeps
  them, never in the shop-wide index: a duplicate the product holds is found,
  and every file of the gallery that came from the URL goes. At most 50
  pictures per product and 500 per call.

  A picture leaves the product by core's removal rule for a folder
  (`ResourceFolders.detach/2`, the one the catalogue's editor uses): a link is
  dropped; a file homed in the product's folder moves to another product's
  folder that also holds it, or is trashed (never hard deleted, the media
  trash can restore it) when nothing else holds it. The gallery order follows,
  and the featured pointer is cleared when the featured picture goes, as the
  editor's remove button does; the storefront then shows the first picture
  left.

  The tool is dangerous when a row would leave its product with no picture at
  all. Removing the featured picture alone is not: replacing a main picture is
  an attach followed by a detach. A batch over `api_confirm_batch_over` rows is
  held by core's executor for every admin write tool. With `ctx.dry_run?` the
  handler returns `{:preview, preview, fingerprint}` and writes nothing.

  The danger check, the plan of the call and the write each read the gallery;
  the product is read again with its row locked, and a row whose gallery (order
  and featured pointer) is no longer the one it was planned from fails alone,
  `changed_since_planned`, with nothing released: a removal judged harmless on
  the old gallery could empty the new one without the confirmation that rule
  asks for.

  Core announces `{:phoenix_kit_file_trashed, uuid}` itself when
  `ResourceFolders.detach/2` trashes a file, and inside this tool's
  transaction that is before the commit. A subscriber that re-reads the file
  on the event can read it as still active, committed or not; core's
  `FeaturedImage` does not look a settled lookup up again on its own, so a host
  that refreshes it on this event can keep showing the stale picture until
  something else prods it. A row that is rolled back afterwards (the gallery
  could not be saved) has announced a file that is still active. Only core can
  announce later.
  """

  @compile {:no_warn_undefined,
            [PhoenixKit.Modules.Storage.ResourceFolders, PhoenixKitCatalogue.Catalogue]}

  require Logger

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.ResourceFolders
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce.API.{Batch, CatalogueWrites, Gate, Meta, PlanSupport, Rows}
  alias PhoenixKitEcommerce.Services.ImageDownloader
  alias PhoenixKitEcommerce.StorefrontCache

  @tool "ecommerce.detach_images"
  @max_images 50
  @max_total 500
  @changed_message "A gallery changed while the call was being checked. Read the product again and repeat the call."

  @doc "The most pictures one product may name in a call."
  @spec max_images() :: pos_integer()
  def max_images, do: @max_images

  @doc "Handler of the tool."
  @spec run(map(), map()) ::
          {:ok, map()} | {:preview, map(), String.t()} | Gate.refusal()
  def run(input, ctx) do
    with {:ok, catalogue_uuid, rows} <- plan_rows(input) do
      if Map.get(ctx, :dry_run?, false),
        do: preview(rows),
        else: write(rows, ctx, catalogue_uuid)
    end
  end

  defp preview(rows) do
    preview = rows |> Batch.preview() |> Batch.with_confirmation(rows)
    {:preview, preview, Batch.fingerprint(rows)}
  end

  defp write(rows, ctx, catalogue_uuid) do
    with :ok <- Batch.ensure_not_newly_dangerous(rows, ctx, @changed_message) do
      {:ok, rows |> detach(ctx, catalogue_uuid) |> Batch.render()}
    end
  end

  @doc "The `danger` check of the tool: `true` when the call needs a confirmation."
  @spec dangerous?(map(), map()) :: boolean()
  def dangerous?(input, _ctx) do
    case plan_rows(input) do
      {:ok, _catalogue_uuid, rows} -> Batch.dangerous?(rows)
      {:error, _code, _detail, _context} -> false
    end
  end

  # -- planning ---------------------------------------------------------------

  defp plan_rows(input) do
    with {:ok, catalogue_uuid} <- Gate.check(input),
         :ok <- check_total(input) do
      shopify? = PhoenixKitEcommerce.shopify_enabled?()
      loaded = Batch.load(input["items"], catalogue_uuid)
      sources = gallery_sources(loaded)

      rows =
        loaded
        |> Batch.plan(&plan_row(&1, sources, shopify?))
        |> Enum.map(&show_split/1)

      {:ok, catalogue_uuid, rows}
    end
  end

  defp check_total(input) do
    total = input["items"] |> Enum.map(&length(Map.get(&1, "images", []))) |> Enum.sum()

    if total <= @max_total do
      :ok
    else
      {:error, :validation_failed, "At most #{@max_total} pictures per call.",
       %{
         errors: [
           %{
             path: "items",
             message: "has #{total} pictures in total",
             limit: @max_total,
             allowed: nil
           }
         ]
       }}
    end
  end

  # file uuid -> the source URLs (query stripped) it answers to, for the files
  # the galleries of the rows that name a URL hold: one read for the whole call,
  # bounded by the galleries, and a URL can only ever resolve to a file of the
  # gallery it is looked up in. Any status: a gallery may still name a file
  # that has been trashed.
  defp gallery_sources(rows) do
    uuids =
      for %{item: %{} = item, input: input} <- rows,
          named_by_url?(input),
          file <- gallery(item),
          match?({:ok, _}, Ecto.UUID.cast(file)),
          uniq: true,
          do: file

    case uuids do
      [] ->
        %{}

      uuids ->
        from(f in StorageFile, where: f.uuid in ^uuids, select: {f.uuid, f.metadata})
        |> PhoenixKit.Config.get_repo().all()
        |> Map.new(fn {uuid, metadata} -> {uuid, source_keys(metadata)} end)
    end
  end

  defp named_by_url?(input),
    do: input |> Map.get("images", []) |> Enum.any?(&match?(%{"url" => _}, &1))

  defp source_keys(metadata) do
    metadata = metadata || %{}

    [metadata["source_url"] | List.wrap(metadata["source_url_aliases"])]
    |> Enum.map(&ImageDownloader.source_key/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # URL (query stripped) -> the files of this product's gallery that came from it.
  defp url_index(item, sources) do
    for file <- gallery(item), key <- Map.get(sources, file, []), reduce: %{} do
      index -> Map.update(index, key, [file], &(&1 ++ [file]))
    end
  end

  defp plan_row(%{item: item, input: input}, sources, shopify?) do
    images = Map.get(input, "images", [])

    case wanted(images, url_index(item, sources)) do
      {:ok, wanted} ->
        gallery = gallery(item)
        {remove, _not_attached} = split(wanted, gallery)

        {:ok,
         %{
           from: gallery_state(item),
           changes: %{"images" => %{"remove" => length(remove)}},
           changed?: remove != [],
           dangerous?: remove != [] and gallery -- remove == [],
           warnings: warnings(item, remove, shopify?),
           wanted: wanted
         }}

      {:error, errors} ->
        {:error, Rows.invalid(errors)}
    end
  end

  # `[{label, [file_uuid]}]`: what each named picture is called in the answer,
  # and the files it is (none when no file of the gallery came from that URL).
  defp wanted(images, url_index) do
    images
    |> Enum.with_index()
    |> Enum.map(&parse(&1, url_index))
    |> Enum.split_with(&match?({:ok, _}, &1))
    |> case do
      {parsed, []} -> {:ok, for({:ok, one} <- parsed, do: one)}
      {_parsed, errors} -> {:error, for({:error, error} <- errors, do: error)}
    end
  end

  defp parse({%{"id" => id} = image, index}, _url_index)
       when is_binary(id) and map_size(image) == 1 do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, {uuid, [uuid]}}
      :error -> {:error, PlanSupport.error("images[#{index}].id", "must be a file UUID")}
    end
  end

  defp parse({%{"url" => url} = image, _index}, url_index)
       when is_binary(url) and map_size(image) == 1 do
    key = ImageDownloader.source_key(url)
    {:ok, {key, Map.get(url_index, key, [])}}
  end

  defp parse({_image, index}, _url_index),
    do: {:error, PlanSupport.error("images[#{index}]", "give exactly one of id or url")}

  # What the gallery lets go of, in the order the call named it, and the
  # names that match no picture of it.
  defp split(wanted, gallery) do
    {held, other} =
      wanted
      |> Enum.uniq()
      |> Enum.map(fn {label, files} -> {label, Enum.filter(files, &(&1 in gallery))} end)
      |> Enum.split_with(fn {_label, files} -> files != [] end)

    {held |> Enum.flat_map(fn {_label, files} -> files end) |> Enum.uniq(),
     for({label, _files} <- other, do: label)}
  end

  defp show_split(%{plan: %{wanted: wanted}, item: item} = row) do
    {remove, not_attached} = split(wanted, gallery(item))
    %{row | extra: %{"detached" => length(remove), "not_attached" => not_attached}}
  end

  defp show_split(row), do: row

  # The Shopify media sync replaces a product's picture order and featured
  # picture, so a picture taken out of a linked product can come back.
  defp warnings(item, remove, shopify?) do
    if remove != [] and PlanSupport.shopify_sync_may_overwrite?(item, shopify?),
      do: ["shopify_sync_may_overwrite"],
      else: []
  end

  # -- detaching --------------------------------------------------------------

  defp detach(rows, ctx, catalogue_uuid) do
    rows =
      Enum.map(rows, fn
        %{plan: %{changed?: true}} = row -> detach_row_safely(row, ctx, catalogue_uuid)
        row -> row
      end)

    if Enum.any?(rows, &match?(%{result: {:ok, _}}, &1)), do: StorefrontCache.clear()
    rows
  end

  # An exception in one row must not take the answers of the rows already
  # committed with it, nor the cache clear: it is that row's storage_error.
  # Only the exception module is logged: its message can hold request values.
  defp detach_row_safely(row, ctx, catalogue_uuid) do
    detach_row(row, ctx, catalogue_uuid)
  rescue
    error -> row |> log_raised(ctx, error.__struct__) |> fail_storage()
  catch
    :exit, _reason -> row |> log_raised(ctx, :exit) |> fail_storage()
  end

  defp log_raised(row, ctx, class) do
    Logger.error(
      "[detach_images] request #{Map.get(ctx, :request_id)}: detaching raised: #{inspect(class)}"
    )

    row
  end

  defp fail_storage(row) do
    Batch.fail(
      row,
      Rows.error(:validation_failed, "The pictures could not be detached.", %{
        "reason" => "storage_error"
      })
    )
  end

  # The product is read again with its row locked: the gallery it has now, and
  # whether it is still in the shop catalogue, are what counts, not what the
  # plan read. The files are released and the gallery written in one
  # transaction, so a gallery that could not be written leaves the files where
  # they were.
  defp detach_row(%{item: item} = row, ctx, catalogue_uuid) do
    locked_result =
      CatalogueWrites.with_locked_items([item], fn locked ->
        case available(locked, item, catalogue_uuid) do
          {:ok, fresh} -> detach_from(%{row | item: fresh}, ctx)
          :error -> gone(row)
        end
      end)

    case locked_result do
      {:ok, detached} -> detached
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

  # The plan was judged on a gallery read earlier (the danger rule too): on
  # any other gallery it does not hold, and nothing is released.
  defp detach_from(%{item: item, plan: plan} = row, ctx) do
    if gallery_state(item) == plan.from,
      do: release_and_write(row, ctx),
      else: Batch.fail(row, Batch.changed_since_planned())
  end

  defp release_and_write(%{item: item, plan: plan} = row, ctx) do
    {remove, not_attached} = split(plan.wanted, gallery(item))
    {released, failed} = release(Enum.sort(remove), folder(item))

    extra = %{
      "detached" => length(released),
      "not_attached" => not_attached,
      "failed" => failed
    }

    # The plan has something to remove, so no file released means some failed.
    if released != [] do
      write_gallery(row, released, extra, ctx)
    else
      Batch.fail(
        row,
        Rows.error(:validation_failed, "No picture could be detached.", %{"images" => failed})
      )
    end
  end

  # Core's removal rule for each file, in a stable order: two calls that share
  # files lock them in the same order and can not wait on each other. A file
  # the folder does not hold (gone, or only named by the gallery) is released
  # all the same: the gallery must stop naming it.
  defp release(files, folder) do
    {released, failed} =
      Enum.reduce(files, {[], []}, fn file, {released, failed} ->
        case detach_file(file, folder) do
          {:ok, _outcome} ->
            {[file | released], failed}

          {:error, reason} ->
            Logger.error("[detach_images] detaching a file failed: " <> Meta.term_class(reason))
            {released, [file | failed]}
        end
      end)

    {Enum.reverse(released), Enum.reverse(failed)}
  end

  # Core's removal of one file; `:api_detach_file` swaps it for a function of
  # the same shape (a test seam, as `:api_image_download_opts` is for downloads).
  defp detach_file(file, folder) do
    Application.get_env(:phoenix_kit_ecommerce, :api_detach_file, &ResourceFolders.detach/2).(
      file,
      folder
    )
  end

  defp write_gallery(%{item: item, plan: plan} = row, released, extra, ctx) do
    order = media_order(item) -- released

    data = %{"media_order" => order}

    data =
      if featured(item) in released, do: Map.put(data, "featured_image_uuid", nil), else: data

    opts = [
      data_owned_keys: Map.keys(data),
      actor_uuid: Meta.actor_uuid(ctx),
      log_metadata: Meta.log_metadata(ctx, @tool),
      mode: "auto"
    ]

    case Catalogue.update_item(item, %{data: data}, opts) do
      {:ok, updated} ->
        log(updated, ctx, extra)

        %{
          row
          | item: updated,
            result: {:ok, updated},
            plan: %{plan | changes: %{"images" => %{"remove" => length(released)}}},
            extra: extra
        }

      {:error, reason} ->
        Logger.error("[detach_images] saving the gallery failed: " <> Meta.term_class(reason))
        PhoenixKit.Config.get_repo().rollback(:gallery_not_saved)
    end
  end

  # -- the gallery ------------------------------------------------------------

  defp gallery_state(item), do: %{media_order: media_order(item), featured: featured(item)}

  # The pictures a product names: its featured picture and its order.
  defp gallery(item), do: Enum.uniq(List.wrap(featured(item)) ++ media_order(item))

  defp featured(item) do
    case get_in(item.data || %{}, ["featured_image_uuid"]) do
      uuid when is_binary(uuid) -> uuid
      _ -> nil
    end
  end

  defp media_order(item) do
    case get_in(item.data || %{}, ["media_order"]) do
      list when is_list(list) -> Enum.filter(list, &is_binary/1)
      _ -> []
    end
  end

  defp folder(item) do
    case get_in(item.data || %{}, ["files_folder_uuid"]) do
      uuid when is_binary(uuid) -> uuid
      _ -> nil
    end
  end

  defp log(item, ctx, extra) do
    PhoenixKitEcommerce.Activity.log("shop.api_images_detached",
      actor_uuid: Meta.actor_uuid(ctx),
      mode: "auto",
      resource_type: "product",
      resource_uuid: item.uuid,
      metadata:
        Map.merge(Meta.log_metadata(ctx, @tool), %{
          "detached" => extra["detached"],
          "not_attached" => length(extra["not_attached"]),
          "failed" => length(extra["failed"])
        })
    )
  end
end
