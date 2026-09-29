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
  ["ecommerce"]["shopify"]["handle"]`.

  A product already in the catalogue (matched either way) always syncs,
  no matter what — the sync scope below never gates an item the
  catalogue already has. Only an UNMATCHED product consults the scope:
  in scope, it's recorded as an error (`"no_matching_item"`, as before —
  the operator should add it via "New in Shopify" on the sync page);
  out of scope, its absence is by design and is counted in the
  progress record's `"skipped"` field instead, with no error entry at
  all. Without this, a store that deliberately syncs a 665-product
  subset of a 2750-product catalog saw ~2215 "errors" on every run,
  drowning the handful of matched products that actually failed.

  ## Sync scope (`PhoenixKitEcommerce.Shopify.SyncScope`)

  Loaded ONCE per run (`SyncScope.get/0`, `opts[:scope]` overrides it —
  tests inject a fixed scope rather than round-tripping through
  `phoenix_kit_shop_config`), not once per product — same batch
  philosophy `currency_verdict_for/2` already uses for the currency
  guard below. `"collections"` never consults it: `CollectionSync`'s
  own `"shopify_collections_filter"` is a completely separate allowlist
  (which Shopify COLLECTIONS become categories at all), not this one
  (which unmatched Shopify PRODUCTS count as missing versus intentionally
  excluded).

  Each product is independent: a `Writer.sync_images/3` or `sync_variants/2`
  failure on one product is recorded in the run's `errors` list and the
  loop moves on to the next product — one bad product must not stop the
  other ~664. This is `CSVImportWorker`'s own per-row philosophy, not
  `CollectionSync`'s (which halts on a write failure because collection
  membership assignment is one connected pass, not independent rows —
  save a catalogue refusing an item's category, which it logs and skips).

  ## `"variants"` and the currency guard (per-domain-currency design §7.5)

  `Writer.sync_variants/2` writes per-option-value price modifiers
  straight from Shopify's variant `"price"` strings — a second
  price-writing path entirely outside `Shopify.Sync.apply_change/3`/
  `apply_changes/3`, which this worker never calls. Without its own
  guard, a store-currency switch would leave a product's base price
  frozen in the old currency right next to option modifiers freshly
  computed in the new one — worse than either being wrong alone, since
  the two halves of one price would then disagree with nothing to
  reveal it. So a `"variants"` run calls `Sync.currency_verdict/1`
  ONCE, before the per-product loop (not once per product — this is the
  same batch philosophy `apply_changes/3` uses, reusing that exact
  function rather than a second implementation of its lookup/fail-open
  rules); on a mismatch every product in the run is skipped for
  `"variants"` with `{:error, {:currency_mismatch, shop, base}}`
  recorded in its own `errors` entry, and `Writer.sync_variants/2` is
  never called at all. `"images"` and `"collections"` carry no money
  and are entirely unaffected — the lookup isn't even attempted for
  them.

  A per-product guard is checked before the currency verdict: a product
  `AdminClient` could not read every variant of
  (`AdminClient.variants_incomplete?/1` — its `"variants"` is capped at
  100 and the backfill to read the rest failed) is refused with its own
  `"variants incomplete: <reason>"` error entry and
  `Writer.sync_variants/3` is never called for it; every other product
  in the run is unaffected. A `"variants"` run asks `fetch_products/2`
  to re-read full lists only for products that match an item; an
  `"images"` run asks for none (it never reads variants).

  ## `"collections"`

  Delegates entirely to `PhoenixKitEcommerce.Shopify.CollectionSync.run/1`
  — a single unit of work (`total: 1`), whose own `{:ok, stats}` map is
  kept as the progress record's `"result"` for the sync page to display
  ("last result"); `actor_uuid` plays no part here.

  ## Progress record

  One `phoenix_kit_shop_config` row PER KIND, key `"shopify_media_sync:"
  <> kind` — three independent rows, not the single `"shopify_media_sync"`
  row this worker used before per-kind storage existed. Running
  `"variants"` no longer erases `"images"`'s last result: an operator
  who ran images, then variants, could not previously tell whether
  images had run at all, let alone whether it succeeded or found
  nothing to do.

      %{"kind" => "images" | "variants" | "collections",
        "total" => non_neg_integer(), "done" => non_neg_integer(),
        "skipped" => non_neg_integer(), "matched" => non_neg_integer(),
        "stats" => map(),
        "errors" => [%{"product" => String.t(), "reason" => String.t()}],
        "warnings" => [%{"product" => String.t(), "reason" => String.t()}],
        "started_at" => iso8601, "finished_at" => iso8601 | nil,
        "result" => map() | nil}

  `"skipped"` — unmatched Shopify products the sync scope excluded (see
  above); `"matched"` — products that found a catalogue item, whether or
  not that product's own sync had an error. `"stats"` aggregates each
  kind's own writer counts across the whole run: for `"images"`,
  `%{"downloaded" => n, "reused" => n, "attached" => n}` summed from
  every `Writer.sync_images/3` result; for `"variants"`,
  `%{"values_created" => n, "approximated" => n}` summed from every
  `Writer.sync_variants/2` result, where `"approximated"` counts products
  whose modifiers only approximate Shopify (`:fit.approximated?`) — a base
  price that merely drifted is a warning but is not counted there. It is
  `%{}` for `"collections"`, which carries its own summary under
  `"result"` instead (see below).
  `"total"`/`"done"` still count every Shopify product this run looked
  at (matched + skipped + unmatched in-scope errors), same as before.

  `"warnings"` — one entry per product whose storefront price does not
  reproduce Shopify: its modifiers only approximate a non-additive grid
  (by the rule the item asked for), or its base price no longer equals
  Shopify's cheapest variant (`Writer.sync_variants/3`'s own `:warnings`,
  see `VariantMapper`'s moduledoc). The write succeeded, so it is kept
  apart from `"errors"` rather than reported as a failure. Always `[]`
  for `"images"`/`"collections"`.

  A job in flight has `"finished_at" => nil`; a caller reading this to
  decide whether to disable a button matches `progress["kind"]` against
  the button's own kind first — `get_progress/1` already does this by
  construction (one row per kind). Every write also broadcasts on
  `topic/0` (`Manager.broadcast/2`) so the sync page's LiveView can
  update live instead of polling — mirrors `CSVImportWorker`'s own
  `shop:import:*` broadcasts; the broadcast payload is still one kind's
  progress map, unchanged, so `handle_info/2` on the receiving end only
  needs to learn to file it under its own `"kind"`.

  `get_progress/0`/`get_progress/1` fall back to the legacy single
  `"shopify_media_sync"` row for the one kind it names, so a stand that
  ran a sync before this change doesn't lose that last result the first
  time it reads progress under the new keys — nothing is ever written
  back to the legacy key again, only read from it as a fallback.

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

  require Logger
  import Ecto.Query

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
  alias PhoenixKitEcommerce.Shopify.Sync
  alias PhoenixKitEcommerce.Shopify.SyncScope

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}

  @legacy_progress_key "shopify_media_sync"
  @topic "shop:media_sync"
  @progress_interval 20
  @kinds ~w(images variants collections)

  @doc "The PubSub topic the sync page subscribes to for live progress."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  Reads every kind's current (or last) progress record — `%{"images" =>
  progress | nil, "variants" => ..., "collections" => ...}`. See this
  module's moduledoc ("Progress record") for the legacy-key fallback.

  One query for all four rows (the three per-kind keys plus the legacy
  single key) rather than `get_progress/1` called three times — each of
  which would itself issue up to two queries (the per-kind key, then the
  legacy fallback) — which would mean up to 6 round-trips for a page
  that reads this once per mount/render.
  """
  @spec get_progress() :: %{String.t() => map() | nil}
  def get_progress do
    keys = Enum.map(@kinds, &progress_key/1) ++ [@legacy_progress_key]

    rows =
      ShopConfig
      |> where([c], c.key in ^keys)
      |> repo().all()
      |> Map.new(&{&1.key, &1.value})

    Map.new(@kinds, fn kind ->
      {kind, Map.get(rows, progress_key(kind)) || legacy_progress(rows, kind)}
    end)
  end

  @doc "Reads one `kind`'s current (or last) progress record, `nil` if none exists yet."
  @spec get_progress(String.t()) :: map() | nil
  def get_progress(kind) when kind in @kinds do
    Map.fetch!(get_progress(), kind)
  end

  defp legacy_progress(rows, kind) do
    case Map.get(rows, @legacy_progress_key) do
      %{"kind" => ^kind} = value -> value
      _ -> nil
    end
  end

  defp progress_key(kind), do: @legacy_progress_key <> ":" <> kind

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
    * `:scope` — a `PhoenixKitEcommerce.Shopify.SyncScope.t()` overriding
      the default `SyncScope.get/0` lookup (tests inject a fixed scope);
      only consulted for `"images"`/`"variants"`, never `"collections"`
      (see this module's moduledoc, "Sync scope").

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
    scope = Keyword.get_lazy(opts, :scope, &SyncScope.get/0)

    with {:ok, catalogue_uuid} <- fetch_catalogue_uuid(),
         index = items_index(catalogue_uuid),
         fetch_opts = Keyword.put(opts, :complete_variants, complete_variants_for(kind, index)),
         {:ok, products} <- client.fetch_products(integration_uuid, fetch_opts) do
      total = length(products)
      started_at = start_progress(kind, total)
      opts = Keyword.put(opts, :currency_verdict, currency_verdict_for(kind, opts))

      # One shop-wide "source URL -> file uuid" index for the whole run.
      # `Writer.sync_images/3` matches against it and hands back the same
      # index plus whatever this product downloaded, so a picture shared
      # across a product line is fetched once — rebuilding it per product
      # would mean one full scan of every stored file per item.
      reuse_index =
        if kind == "images",
          do: Writer.build_reuse_index(),
          else: %{url_index: %{}, active_uuids: MapSet.new()}

      acc0 = %{
        errors: [],
        warnings: [],
        reuse_index: reuse_index,
        skipped: 0,
        matched: 0,
        stats: %{}
      }

      try do
        # `errors` stays newest-first (plain prepend) for the whole
        # loop — reversing it into display order happens exactly once,
        # in `maybe_save_progress/5`/at the end, never on a value that
        # was already reversed on a previous iteration (that would
        # scramble the order past the second error).
        {done, acc} =
          products
          |> Enum.with_index(1)
          |> Enum.reduce({0, acc0}, fn {product, position}, {_done, acc} ->
            acc = process_product(kind, product, index, scope, actor_uuid, opts, acc)
            maybe_save_progress(kind, total, position, acc, started_at)
            {position, acc}
          end)

        errors = Enum.reverse(acc.errors)
        warnings = Enum.reverse(acc.warnings)
        finish_progress(kind, total, done, acc, errors, started_at, nil)
        {:ok, %{total: total, done: done, errors: errors, warnings: warnings}}
      rescue
        exception ->
          fail_progress(kind, Exception.message(exception))
          reraise exception, __STACKTRACE__
      end
    else
      {:error, reason} = error ->
        fail_progress(kind, reason)
        error
    end
  end

  # One product, fully isolated: a writer's `{:error, _}` AND anything it
  # raises or exits with (an Ecto constraint raise, a `Map.fetch!` on an
  # unexpected payload shape, a guard on a malformed image) become that
  # product's own error entry, and the loop moves on. Without the
  # rescue, one bad product escaped `run_products/3`'s outer `rescue`,
  # marked the whole run failed, and Oban retried from product 1 — the
  # opposite of what the moduledoc promises ("one bad product must not
  # stop the other ~664").
  #
  # A product already matched to a catalogue item ALWAYS syncs — the
  # scope only decides what an UNMATCHED product means (moduledoc,
  # "Products -> items"): in scope, it's the pre-existing
  # `"no_matching_item"` error; out of scope, it's counted in `:skipped`
  # with no error at all.
  defp process_product(kind, product, index, scope, actor_uuid, opts, acc) do
    case find_item(index, product) do
      {:ok, item} ->
        acc = %{acc | matched: acc.matched + 1}
        apply_writer_isolated(kind, item, product, actor_uuid, opts, acc)

      :error ->
        if SyncScope.in_scope?(product, scope) do
          %{acc | errors: [product_error(product, "no_matching_item") | acc.errors]}
        else
          %{acc | skipped: acc.skipped + 1}
        end
    end
  end

  defp apply_writer_isolated(kind, item, product, actor_uuid, opts, acc) do
    case apply_writer(kind, item, product, actor_uuid, opts, acc.reuse_index) do
      {:ok, result} ->
        %{
          acc
          | errors: merge_writer_errors(acc.errors, product, result),
            warnings: merge_writer_warnings(acc.warnings, product, result),
            reuse_index: next_reuse_index(acc.reuse_index, result),
            stats: merge_stats(acc.stats, kind, result)
        }

      {:error, reason} ->
        %{acc | errors: [product_error(product, reason) | acc.errors]}
    end
  rescue
    exception ->
      log_product_crash(kind, product, Exception.message(exception), __STACKTRACE__)
      %{acc | errors: [product_error(product, Exception.message(exception)) | acc.errors]}
  catch
    :exit, reason ->
      message = "exit: " <> inspect(reason)
      log_product_crash(kind, product, message, __STACKTRACE__)
      %{acc | errors: [product_error(product, message) | acc.errors]}
  end

  # Sums each kind's own writer counts across the run — see the
  # moduledoc's "Progress record" for what each key means and why
  # `"collections"` never reaches here (it never calls `apply_writer/6`
  # at all; see `run_collections/1`).
  defp merge_stats(stats, "images", result) do
    Enum.reduce([downloaded: "downloaded", reused: "reused", attached: "attached"], stats, fn
      {rkey, key}, acc ->
        Map.update(acc, key, Map.get(result, rkey, 0), &(&1 + Map.get(result, rkey, 0)))
    end)
  end

  defp merge_stats(stats, "variants", result) do
    approximated = if match?(%{fit: %{approximated?: true}}, result), do: 1, else: 0

    stats
    |> Map.update(
      "values_created",
      Map.get(result, :values_created, 0),
      &(&1 + Map.get(result, :values_created, 0))
    )
    |> Map.update("approximated", approximated, &(&1 + approximated))
  end

  defp merge_stats(stats, _kind, _result), do: stats

  defp log_product_crash(kind, product, message, stacktrace) do
    key = product["handle"] || product_id_string(product) || "unknown"

    Logger.error(
      "Shopify media sync (#{kind}): product #{key} crashed — #{message}\n" <>
        Exception.format_stacktrace(stacktrace)
    )
  end

  defp next_reuse_index(reuse_index, result) do
    %{
      url_index: Map.get(result, :url_index, reuse_index.url_index),
      active_uuids: Map.get(result, :active_uuids, reuse_index.active_uuids)
    }
  end

  # `Writer.sync_images/3` reports a per-image download failure INSIDE its
  # own `{:ok, %{errors: [...]}}` — a partial success, not a product-level
  # failure (see its moduledoc: "a download failure skips that image ...
  # rather than aborting the whole product's images"). Without this, an
  # operator watching progress would never see that a specific image
  # failed to download.
  defp merge_writer_errors(errors, product, result) do
    key = product["handle"] || product_id_string(product) || "unknown"

    Enum.reduce(Map.get(result, :errors, []), errors, fn {image_id, reason}, acc ->
      [
        %{"product" => key, "reason" => "image #{image_id}: #{error_reason_string(reason)}"}
        | acc
      ]
    end)
  end

  # `Writer.sync_variants/3`'s `:warnings` — one line per product whose
  # price is approximated (see `VariantMapper`'s moduledoc). Kept apart
  # from `errors`: the product WAS written, by the rule the item asks for.
  defp merge_writer_warnings(warnings, product, result) do
    key = product["handle"] || product_id_string(product) || "unknown"

    Enum.reduce(Map.get(result, :warnings, []), warnings, fn warning, acc ->
      [%{"product" => key, "reason" => warning} | acc]
    end)
  end

  defp apply_writer("images", item, product, actor_uuid, opts, reuse_index) do
    downloader = Keyword.get(opts, :downloader, &image_downloader/3)

    Writer.sync_images(item, product,
      downloader: downloader,
      user_uuid: actor_uuid,
      url_index: reuse_index.url_index,
      active_uuids: reuse_index.active_uuids
    )
  end

  # `actor_uuid` is the creator of any attribute set/value this product
  # makes `Writer.sync_variants/3` create (entities' `created_by_uuid` is
  # NOT NULL); a `nil` actor lets that constraint error surface as this
  # product's own error rather than inventing a system uuid here.
  #
  # A product whose variant list `AdminClient` could not read in full
  # (`AdminClient.variants_incomplete?/1`) is refused outright: its
  # cheapest price may be among the variants not read, so writing price
  # modifiers now could under-price the product. `Writer.sync_variants/3`
  # is never called — the item's existing modifiers are left untouched,
  # and this product's own error names the reason so the run still
  # completes for the rest of the catalog.
  defp apply_writer("variants", item, product, actor_uuid, opts, _reuse_index) do
    if AdminClient.variants_incomplete?(product) do
      Logger.warning(
        "Shopify media sync (variants): #{product["handle"] || product_id_string(product) || "unknown"} — variant list incomplete, prices left as they are"
      )

      {:error, "variants incomplete: #{product["_variants_incomplete"]}"}
    else
      case Keyword.fetch!(opts, :currency_verdict) do
        :match ->
          Writer.sync_variants(item, product, actor_uuid: actor_uuid)

        {:mismatch, shop_currency, base_currency} ->
          {:error, {:currency_mismatch, shop_currency, base_currency}}
      end
    end
  end

  # Only `"variants"` writes money (`Writer.sync_variants/2`'s price
  # modifiers) — `"images"` never reaches this clause (`run_kind/2`'s
  # `dispatch/3` sends `"collections"` down its own path entirely), so
  # `:match` here for anything but `"variants"` isn't a real lookup, it's
  # "the guard doesn't apply to this kind at all" (this module's own
  # moduledoc). Logged ONCE for the whole run, not once per product —
  # `run_products/3` calls this exactly once, before the loop.
  defp currency_verdict_for("variants", opts) do
    # `Sync.currency_verdict/1`'s `opts[:admin_options]` is forwarded
    # verbatim to `AdminClient.fetch_shop/2`, whose OWN `opts` reads
    # `:req_options` out of it — so this worker's flat `opts[:req_options]`
    # (the same key its own `client.fetch_products/2` call takes) has to
    # be re-nested one level to satisfy that shape, not passed straight
    # through.
    admin_options = [req_options: Keyword.get(opts, :req_options, [])]
    verdict = Sync.currency_verdict(admin_options: admin_options)

    case verdict do
      {:mismatch, shop_currency, base_currency} ->
        Logger.warning(
          "Shopify media sync: skipping variants/price sync — shop currency " <>
            "#{shop_currency} does not match base currency #{base_currency} (design spec §7.5)"
        )

      :match ->
        :ok
    end

    verdict
  end

  defp currency_verdict_for(_kind, _opts), do: :match

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

        try do
          case CollectionSync.run(run_opts) do
            {:ok, result} ->
              finish_progress(
                "collections",
                1,
                1,
                collections_counts(result),
                [],
                started_at,
                result
              )

              {:ok, result}

            {:error, reason} = error ->
              fail_progress("collections", reason)
              error
          end
        rescue
          exception ->
            fail_progress("collections", Exception.message(exception))
            reraise exception, __STACKTRACE__
        end

      {:error, reason} = error ->
        fail_progress("collections", reason)
        error
    end
  end

  # `"matched"`/`"skipped"` for a `"collections"` run are over COLLECTIONS,
  # not products (the `"images"`/`"variants"` meaning of those two fields)
  # — a collection that resolved to a category, created or matched, is
  # "matched"; one dropped by the filter or because its only live match
  # is trashed is "skipped". `"stats"` carries `CollectionSync.run/1`'s
  # own counts (string-keyed, matching every other kind's `"stats"`
  # shape) so the sync page never has to reach into `"result"` for a
  # number it can show right next to `"matched"`/`"skipped"`.
  defp collections_counts(%{
         categories_created: created,
         categories_matched: matched,
         collections_skipped_by_filter: skipped_by_filter,
         collections_skipped_trashed: skipped_trashed,
         items_assigned: assigned,
         items_repositioned: repositioned,
         unmatched_products: unmatched_products
       }) do
    %{
      matched: created + matched,
      skipped: skipped_by_filter + skipped_trashed,
      stats: %{
        "categories_created" => created,
        "categories_matched" => matched,
        "collections_skipped_by_filter" => skipped_by_filter,
        "collections_skipped_trashed" => skipped_trashed,
        "items_assigned" => assigned,
        "items_repositioned" => repositioned,
        "unmatched_products" => length(unmatched_products)
      }
    }
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

  # `AdminClient.fetch_products/2` re-reads a capped product's full variant
  # list only when asked (`:complete_variants`). An "images" run never reads
  # variants; a "variants" run writes prices only for products that match an
  # item — an unmatched one is an error or a skip, never a price write.
  defp complete_variants_for("variants", index),
    do: &match?({:ok, _item}, find_item(index, &1))

  defp complete_variants_for(_kind, _index), do: false

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
  # Progress: read/write `phoenix_kit_shop_config["shopify_media_sync:" <> kind]`
  # ============================================================

  @empty_counts %{skipped: 0, matched: 0, stats: %{}}

  # `counts` bundles the three fields the sync-scope work added
  # (`:skipped`, `:matched`, `:stats`) into one argument — keeps this
  # under credo's max-arity check, and reads at every call site as
  # exactly what it is: the run's own tallies, as one unit, alongside
  # `total`/`done`/`errors`.
  defp build_progress(kind, total, done, counts, errors, started_at, finished_at, result) do
    %{
      "kind" => kind,
      "total" => total,
      "done" => done,
      "skipped" => counts.skipped,
      "matched" => counts.matched,
      "stats" => counts.stats,
      "errors" => errors,
      "warnings" => counts |> Map.get(:warnings, []) |> Enum.reverse(),
      "started_at" => started_at,
      "finished_at" => finished_at,
      "result" => result
    }
  end

  defp start_progress(kind, total) do
    started_at = iso_now()

    save_and_broadcast(
      kind,
      build_progress(kind, total, 0, @empty_counts, [], started_at, nil, nil)
    )

    started_at
  end

  # Every product would mean 665 writes on the real run; persisting (and
  # broadcasting) every `@progress_interval`th one, plus the last, keeps
  # the sync page live without hammering the DB on every row — same
  # trade-off `CSVImportWorker`'s own `@progress_interval` documents.
  # `acc.errors` is reversed here ONLY for the value that gets saved —
  # the loop's own accumulator (see `run_products/3`) stays untouched.
  defp maybe_save_progress(kind, total, done, acc, started_at)
       when rem(done, @progress_interval) == 0 or done == total do
    save_and_broadcast(
      kind,
      build_progress(kind, total, done, acc, Enum.reverse(acc.errors), started_at, nil, nil)
    )
  end

  defp maybe_save_progress(_kind, _total, _done, _acc, _started_at), do: :ok

  defp finish_progress(kind, total, done, counts, errors, started_at, result) do
    save_and_broadcast(
      kind,
      build_progress(kind, total, done, counts, errors, started_at, iso_now(), result)
    )
  end

  defp fail_progress(kind, reason) do
    now = iso_now()
    error = %{"product" => "_run", "reason" => error_reason_string(reason)}
    save_and_broadcast(kind, build_progress(kind, 0, 0, @empty_counts, [error], now, now, nil))
  end

  defp save_and_broadcast(kind, progress) do
    put_progress(kind, progress)
    Manager.broadcast(@topic, {:media_sync_progress, progress})
    progress
  end

  defp put_progress(kind, value) do
    key = progress_key(kind)

    case repo().get(ShopConfig, key) do
      nil ->
        %ShopConfig{}
        |> ShopConfig.changeset(%{key: key, value: value})
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
