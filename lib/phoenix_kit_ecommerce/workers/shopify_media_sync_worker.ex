defmodule PhoenixKitEcommerce.Workers.ShopifyMediaSyncWorker do
  @moduledoc """
  Oban worker driving the three Block 7 catalogue writers as background
  jobs — Task 5 of `docs/superpowers/plans/2026-09-06-block7-shopify-
  media-collections.md`.

  ## Job arguments

  `%{"kind" => "images" | "variants" | "collections", "actor_uuid" =>
  uuid_or_nil}` — `kind` selects which writer runs; `actor_uuid` is the
  Storage file owner for `"images"` (ignored by the other two kinds,
  carried uniformly anyway so the sync page never has to special-case
  the enqueue call per button).

  ## Products -> items: how `"images"`/`"variants"` find their item

  Both kinds fetch every Shopify product once (`opts[:client]`, default
  `AdminClient.fetch_products/2`) and, for each one, look up the
  catalogue item it belongs to: first by `data["ecommerce"]["shopify"]
  ["product_id"]` (stringified), then — because `product_id` is only
  backfilled onto an item the first time a regular field sync applies a
  change to it (`Writer.update_from_shopify/3`; see Task 1), so plenty
  of items carry only `handle` until that has happened — by `data
  ["ecommerce"]["shopify"]["handle"]`. A product matching neither is
  recorded as an error (`"no_matching_item"`) rather than skipped
  silently.

  Each product is independent: a `Writer.sync_images/3` or `sync_variants/2`
  failure on one product is recorded in the run's `errors` list and the
  loop moves on to the next product — one bad product must not stop the
  other ~664. This is `CSVImportWorker`'s own per-row philosophy, not
  `CollectionSync`'s (which halts on a write failure because collection
  membership assignment is one connected pass, not independent rows).

  ## `"collections"`

  Delegates entirely to `PhoenixKitEcommerce.Shopify.CollectionSync.run/1`
  — a single unit of work (`total: 1`), whose own `{:ok, stats}` map is
  kept as the progress record's `"result"` for the sync page to display
  ("last result"); `actor_uuid` plays no part here.

  ## Progress record

  One `phoenix_kit_shop_config` row, key `"shopify_media_sync"`
  (deliberately singular — Task 7 runs the three kinds one at a time,
  never concurrently, so a single record naming its own `"kind"` is
  enough to know what it describes and whether that specific button
  should show as in-flight):

      %{"kind" => "images" | "variants" | "collections",
        "total" => non_neg_integer(), "done" => non_neg_integer(),
        "errors" => [%{"product" => String.t(), "reason" => String.t()}],
        "started_at" => iso8601, "finished_at" => iso8601 | nil,
        "result" => map() | nil}

  A job in flight has `"finished_at" => nil`; a caller reading this to
  decide whether to disable a button matches `progress["kind"]` against
  the button's own kind first. Every write also broadcasts on `topic/0`
  (`Manager.broadcast/2`) so the sync page's LiveView can update live
  instead of polling — mirrors `CSVImportWorker`'s own `shop:import:*`
  broadcasts.

  A no-op — `{:error, :catalogue_source_inactive}` — when
  `ProductSource.current/0` isn't `Catalogue` (checked here too, even
  though every writer this dispatches to already self-gates: fetching
  Shopify products and building the item index first would be wasted
  work under the legacy source).
  """

  use Oban.Worker,
    queue: :shop_imports,
    max_attempts: 3,
    unique: [
      # `:infinity`, not a fixed window: uniqueness must depend on job
      # STATE, not age — a real "images" run over ~665 products with HTTP
      # downloads can run well past any fixed window, after which a
      # second enqueue of the same kind would be accepted while the
      # first is still `:executing`, racing two read-modify-write passes
      # over the same items. `states:` already excludes `:completed`/
      # `:cancelled`/`:discarded`, so a FINISHED run never blocks the
      # next one.
      period: :infinity,
      keys: [:kind],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias PhoenixKit.Integrations
  alias PhoenixKit.PubSub.Manager
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce.Catalogue.Writer
  alias PhoenixKitEcommerce.ProductSource
  alias PhoenixKitEcommerce.ProductSource.Catalogue.Query
  alias PhoenixKitEcommerce.Services.ImageDownloader
  alias PhoenixKitEcommerce.ShopConfig
  alias PhoenixKitEcommerce.Shopify.AdminClient
  alias PhoenixKitEcommerce.Shopify.CollectionSync

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}

  @progress_key "shopify_media_sync"
  @topic "shop:media_sync"
  @progress_interval 20
  @kinds ~w(images variants collections)

  @doc "The PubSub topic the sync page subscribes to for live progress."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Reads the current (or last) progress record, `nil` if none exists yet."
  @spec get_progress() :: map() | nil
  def get_progress do
    case repo().get(ShopConfig, @progress_key) do
      %ShopConfig{value: value} -> value
      nil -> nil
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"kind" => kind} = args}) when kind in @kinds do
    run(kind, Map.get(args, "actor_uuid"))
  end

  @doc """
  Runs one sync `kind` directly — what `perform/1` calls with production
  defaults. `opts`:

    * `:client` — module with `fetch_products/2` (images/variants) and/or
      `fetch_collections/1`/`fetch_collection_product_ids/2`
      (collections); defaults to `AdminClient`.
    * `:downloader` — forwarded to `Writer.sync_images/3`'s own
      `opts[:downloader]`.
    * `:integration_uuid` — skips resolving the shop's Shopify connection
      (tests inject this; production always resolves it).

  Exists as a public function, separate from `perform/1`, so tests can
  exercise the real logic without going through Oban/HTTP.
  """
  @spec run(String.t(), String.t() | nil, keyword()) ::
          {:ok, map()} | {:error, :catalogue_source_inactive | term()}
  def run(kind, actor_uuid, opts \\ []) when kind in @kinds do
    if ProductSource.current() == ProductSource.Catalogue do
      case fetch_integration_uuid(opts) do
        {:ok, integration_uuid} ->
          dispatch(kind, actor_uuid, Keyword.put(opts, :integration_uuid, integration_uuid))

        {:error, reason} ->
          fail_progress(kind, reason)
          {:error, reason}
      end
    else
      {:error, :catalogue_source_inactive}
    end
  end

  defp dispatch("collections", _actor_uuid, opts), do: run_collections(opts)
  defp dispatch(kind, actor_uuid, opts), do: run_products(kind, actor_uuid, opts)

  # ============================================================
  # "images" / "variants": one product at a time, errors don't halt
  # ============================================================

  defp run_products(kind, actor_uuid, opts) do
    client = Keyword.get(opts, :client, AdminClient)
    integration_uuid = Keyword.fetch!(opts, :integration_uuid)

    with {:ok, catalogue_uuid} <- fetch_catalogue_uuid(),
         {:ok, products} <- client.fetch_products(integration_uuid, opts) do
      index = items_index(catalogue_uuid)
      total = length(products)
      started_at = start_progress(kind, total)

      # `raw_errors` stays newest-first (plain prepend) for the whole
      # loop — reversing it into display order happens exactly once,
      # in `maybe_save_progress/5`/at the end, never on a value that
      # was already reversed on a previous iteration (that would
      # scramble the order past the second error).
      {done, raw_errors} =
        products
        |> Enum.with_index(1)
        |> Enum.reduce({0, []}, fn {product, position}, {_done, raw_errors} ->
          raw_errors = process_product(kind, product, index, actor_uuid, opts, raw_errors)
          maybe_save_progress(kind, total, position, raw_errors, started_at)
          {position, raw_errors}
        end)

      errors = Enum.reverse(raw_errors)
      finish_progress(kind, total, done, errors, started_at, nil)
      {:ok, %{total: total, done: done, errors: errors}}
    else
      {:error, reason} = error ->
        fail_progress(kind, reason)
        error
    end
  end

  defp process_product(kind, product, index, actor_uuid, opts, errors) do
    case find_item(index, product) do
      {:ok, item} ->
        case apply_writer(kind, item, product, actor_uuid, opts) do
          {:ok, result} -> merge_writer_errors(errors, product, result)
          {:error, reason} -> [product_error(product, reason) | errors]
        end

      :error ->
        [product_error(product, "no_matching_item") | errors]
    end
  end

  # `Writer.sync_images/3` reports a per-image download failure INSIDE its
  # own `{:ok, %{errors: [...]}}` — a partial success, not a product-level
  # failure (see its moduledoc: "a download failure skips that image ...
  # rather than aborting the whole product's images"). Without this, an
  # operator watching progress would never see that a specific image
  # failed to download; `sync_variants/2`'s result has no `:errors` key at
  # all, so the fallback clause below is what every other kind hits.
  defp merge_writer_errors(errors, product, %{errors: inner_errors}) when inner_errors != [] do
    key = product["handle"] || product_id_string(product) || "unknown"

    Enum.reduce(inner_errors, errors, fn {image_id, reason}, acc ->
      [%{"product" => key, "reason" => "image #{image_id}: #{error_reason_string(reason)}"} | acc]
    end)
  end

  defp merge_writer_errors(errors, _product, _result), do: errors

  defp apply_writer("images", item, product, actor_uuid, opts) do
    downloader = Keyword.get(opts, :downloader, &image_downloader/3)
    Writer.sync_images(item, product, downloader: downloader, user_uuid: actor_uuid)
  end

  defp apply_writer("variants", item, product, _actor_uuid, _opts) do
    Writer.sync_variants(item, product)
  end

  defp image_downloader(url, user_uuid, opts),
    do: ImageDownloader.download_and_store(url, user_uuid, opts)

  defp product_error(product, reason) do
    key = product["handle"] || product_id_string(product) || "unknown"
    %{"product" => key, "reason" => error_reason_string(reason)}
  end

  defp error_reason_string(reason) when is_binary(reason), do: reason
  defp error_reason_string(reason), do: inspect(reason)

  # ============================================================
  # "collections": one atomic pass, delegated to CollectionSync
  # ============================================================

  defp run_collections(opts) do
    case fetch_catalogue_uuid() do
      {:ok, catalogue_uuid} ->
        started_at = start_progress("collections", 1)
        run_opts = Keyword.put(opts, :catalogue_uuid, catalogue_uuid)

        case CollectionSync.run(run_opts) do
          {:ok, result} ->
            finish_progress("collections", 1, 1, [], started_at, result)
            {:ok, result}

          {:error, reason} = error ->
            fail_progress("collections", reason)
            error
        end

      {:error, reason} = error ->
        fail_progress("collections", reason)
        error
    end
  end

  # ============================================================
  # Shopify product <-> catalogue item matching
  # ============================================================

  defp items_index(catalogue_uuid) do
    catalogue_uuid
    |> Catalogue.list_items_for_catalogue()
    |> Enum.reduce(%{by_product_id: %{}, by_handle: %{}}, &index_item/2)
  end

  defp index_item(item, acc) do
    acc
    |> index_by(
      :by_product_id,
      get_in(item.data || %{}, ["ecommerce", "shopify", "product_id"]),
      item
    )
    |> index_by(:by_handle, get_in(item.data || %{}, ["ecommerce", "shopify", "handle"]), item)
  end

  defp index_by(acc, _key, nil, _item), do: acc
  defp index_by(acc, key, value, item), do: Map.update!(acc, key, &Map.put(&1, value, item))

  defp find_item(index, product) do
    case product_id_string(product) do
      nil ->
        Map.fetch(index.by_handle, product["handle"])

      product_id ->
        case Map.fetch(index.by_product_id, product_id) do
          {:ok, item} -> {:ok, item}
          :error -> Map.fetch(index.by_handle, product["handle"])
        end
    end
  end

  defp product_id_string(%{"id" => id}) when not is_nil(id), do: to_string(id)
  defp product_id_string(_product), do: nil

  # ============================================================
  # Integration / catalogue resolution
  # ============================================================

  defp fetch_integration_uuid(opts) do
    case Keyword.get(opts, :integration_uuid) do
      uuid when is_binary(uuid) and uuid != "" -> {:ok, uuid}
      _ -> resolve_integration_uuid()
    end
  end

  defp resolve_integration_uuid do
    case Integrations.list_connections("shopify", owner: :system) do
      [%{uuid: uuid} | _rest] -> {:ok, uuid}
      [] -> {:error, :missing_shopify_connection}
    end
  end

  defp fetch_catalogue_uuid do
    case Query.catalogue_uuid() do
      nil -> {:error, :catalogue_not_found}
      uuid -> {:ok, uuid}
    end
  end

  # ============================================================
  # Progress: read/write `phoenix_kit_shop_config["shopify_media_sync"]`
  # ============================================================

  defp build_progress(kind, total, done, errors, started_at, finished_at, result) do
    %{
      "kind" => kind,
      "total" => total,
      "done" => done,
      "errors" => errors,
      "started_at" => started_at,
      "finished_at" => finished_at,
      "result" => result
    }
  end

  defp start_progress(kind, total) do
    started_at = iso_now()
    save_and_broadcast(build_progress(kind, total, 0, [], started_at, nil, nil))
    started_at
  end

  # Every product would mean 665 writes on the real run; persisting (and
  # broadcasting) every `@progress_interval`th one, plus the last, keeps
  # the sync page live without hammering the DB on every row — same
  # trade-off `CSVImportWorker`'s own `@progress_interval` documents.
  # `raw_errors` is reversed here ONLY for the value that gets saved —
  # the loop's own accumulator (see `run_products/3`) stays untouched.
  defp maybe_save_progress(kind, total, done, raw_errors, started_at)
       when rem(done, @progress_interval) == 0 or done == total do
    save_and_broadcast(
      build_progress(kind, total, done, Enum.reverse(raw_errors), started_at, nil, nil)
    )
  end

  defp maybe_save_progress(_kind, _total, _done, _raw_errors, _started_at), do: :ok

  defp finish_progress(kind, total, done, errors, started_at, result) do
    save_and_broadcast(build_progress(kind, total, done, errors, started_at, iso_now(), result))
  end

  defp fail_progress(kind, reason) do
    now = iso_now()
    error = %{"product" => "_run", "reason" => error_reason_string(reason)}
    save_and_broadcast(build_progress(kind, 0, 0, [error], now, now, nil))
  end

  defp save_and_broadcast(progress) do
    put_progress(progress)
    Manager.broadcast(@topic, {:media_sync_progress, progress})
    progress
  end

  defp put_progress(value) do
    case repo().get(ShopConfig, @progress_key) do
      nil ->
        %ShopConfig{}
        |> ShopConfig.changeset(%{key: @progress_key, value: value})
        |> repo().insert()

      config ->
        config
        |> ShopConfig.changeset(%{value: value})
        |> repo().update()
    end
  end

  defp iso_now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
