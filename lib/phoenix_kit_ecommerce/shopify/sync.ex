defmodule PhoenixKitEcommerce.Shopify.Sync do
  @moduledoc """
  Orchestrates a Shopify → local product sync: fetch, diff, and selectively
  apply confirmed changes.

  This is the domain layer only — no LiveView/UI wiring here (see
  `PhoenixKitEcommerce.Shopify.Provider` moduledoc for why "Test Connection"
  doesn't exercise this; that's this module's job instead, via `check/2`).

  ## Catalogue source (Block 3, "sync 6a")

  When `ProductSource.current/0` is `Catalogue`, `apply_change/2` writes
  through `PhoenixKitEcommerce.Catalogue.Writer` into the matched
  catalogue item instead of `Shop.update_product/2` (which refuses a
  view-struct outright — see `Product`/`update_product/2`'s own
  moduledoc), and `check/2` additionally surfaces unmatched Shopify
  handles as create-`Change`s (`ProductDiff.new_product_changes/3`) under
  `:new_products`, which `apply_change/2`/`apply_changes/2` dispatch to
  `Writer.create_from_shopify/2`. Under the legacy source `:new_products`
  is always `[]` — creating products there stays the CSV importer's job.

  ## Currency guard (per-domain-currency design §7.5)

  `apply_change/3`/`apply_changes/3` compare the connected Shopify
  store's OWN currency (`AdminClient.fetch_shop/2`) against the shop's
  base currency before writing any PRICE field (`:price`,
  `:compare_at_price`) — never before writing anything else. On a
  mismatch the price fields are dropped from what gets applied (an
  otherwise-eligible non-price field on the SAME change, e.g. `:title`,
  still gets written) and a `Logger.warning/1` names both currencies; a
  change whose ONLY requested fields were price fields returns
  `{:error, {:currency_mismatch, shop_currency, base_currency}}` instead
  of a silent no-op success.

  A create-`Change` (`create?: true`) is guarded too, but ALL-OR-NOTHING
  rather than field-by-field: `Writer.create_from_shopify/2` writes a
  price unconditionally (there is no `fields`/`changes` to filter it out
  of), so on a mismatch the whole create is refused —
  `{:error, {:currency_mismatch, shop_currency, base_currency}}`, item
  never created — rather than creating it without a price or with a
  wrong one. This is the WORSE case, not a safer one: an update at
  least leaves an existing, correct price alone; a create would mint a
  brand-new record whose price is wrong from the moment it exists,
  labelled with the base currency by `Writer` itself (§4.6), with no
  prior value anywhere to reveal the error.

  The shop lookup itself happens ONCE per `apply_changes/3` call (a
  batch of N products, one lookup, not N — see `currency_verdict/1`),
  not once per `apply_change/3` (a single call is its own batch of one).
  A lookup failure (no Shopify connection, network, bad credentials)
  never blocks a sync that was otherwise working: it logs one
  `Logger.warning/1` and proceeds exactly as if the guard were absent —
  see `currency_verdict/1`'s own doc for why this fails in the
  OTHER direction from the mismatch case above.

  ## Single-product check (`check_one/3`)

  `check_one/3` is the single-product counterpart to `check/2`, meant
  for a future per-product admin panel that shouldn't have to pull the
  whole catalog through `check/2` just to look at one item. It looks up
  the ONE local product, reads its Shopify link
  (`metadata["_shopify"]["product_id"]`), fetches that ONE Shopify
  product by id (`AdminClient.fetch_product/3` — no pagination, no
  bulk fetch), and diffs the pair with the exact same
  `ProductDiff.diff/4` `check/2` uses. There is deliberately no
  storefront fallback here (unlike `check/2`'s `Source.fetch/2`): that
  fallback exists so a broken Admin token still surfaces SOME diff for
  a full catalog sync; for exactly one product a caller is better served
  by the real failure (`{:error, reason}`, straight from
  `AdminClient.fetch_product/3`) than a silently narrower price-only
  result.

  ## Precomputed currency verdict, for a caller applying several fields per action

  `apply_change/3`/`apply_changes/3` accept `opts[:currency_verdict]` —
  a `currency_verdict/1` result the caller already computed. When given,
  it is used AS-IS and `opts[:admin_options]`/the shop lookup are never
  consulted for that call; when absent (every call site before this
  option existed), behavior is unchanged: `currency_verdict/1` is still
  computed fresh. This exists for a caller that applies several fields
  of the SAME product as separate `apply_change/3` calls within one
  operator action (e.g. a per-product review panel with a checkbox per
  field, "apply" clicked once) — without it, each call pays for its own
  live `AdminClient.fetch_shop/2` request, `apply_changes/3`'s own
  batch of N already avoids the same cost across N *products*, but the
  price of one product's worth of separate field-clicks was still N
  Shopify hits. A keyword option (over, say, a table of a `-1`/wider
  `apply_change/4`) was chosen because it composes with the EXISTING
  `opts` `apply_change/3`/`apply_changes/3` already take, needs no new
  arity, and reads at the call site as exactly what it is — an
  already-known answer to the same question `currency_verdict/1` itself
  answers.
  """

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}

  require Logger

  alias PhoenixKit.Integrations
  alias PhoenixKitCatalogue.Catalogue, as: CatalogueApi
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Catalogue.Writer
  alias PhoenixKitEcommerce.ProductSource
  alias PhoenixKitEcommerce.ProductSource.Catalogue.View, as: CatalogueView
  alias PhoenixKitEcommerce.Shopify.AdminClient
  alias PhoenixKitEcommerce.Shopify.ProductDiff
  alias PhoenixKitEcommerce.Shopify.ProductDiff.Change
  alias PhoenixKitEcommerce.Shopify.Source
  alias PhoenixKitEcommerce.Translations

  @localized_fields [:title, :body_html, :description]

  # The two fields the per-domain-currency design (§7.5) forbids writing
  # on a shop-currency mismatch — see `resolve_priced_fields/3`.
  @price_fields [:price, :compare_at_price]

  @doc """
  Fetches Shopify products for `integration_uuid` via `Source.fetch/2`
  (Admin API primary, public storefront fallback — see that module's
  moduledoc for the fallback/abort rules), diffs them against the local
  catalog, and returns the changes an operator can review.

  The result carries `:source` (`:admin` or `:storefront`) and
  `:fallback_reason` alongside `:changes` — a caller MUST branch on
  `:source` before presenting the result as a complete diff. A
  `:storefront` result only ever contains price changes (see
  `Source`/`StorefrontClient`), because the Admin API rejected the
  connection's credentials; `:fallback_reason` carries why (e.g.
  `:unauthorized`). Treating it as a full diff would report "no changes"
  for text fields that were never actually compared.

  `:total_shopify_products` is the raw count of products `Source.fetch/2`
  returned, BEFORE matching against the local catalog — i.e. it includes
  Shopify products with no local counterpart, which never appear in
  `:changes` (see this module's own moduledoc: matching a product with no
  local counterpart is the CSV importer's job, not this sync's).

  `:matched_local_products` is `ProductDiff.matched_count/3` on the same
  input — how many local products a Shopify handle actually matched,
  independent of whether that match has any field difference (a product
  identical to its Shopify counterpart is matched but contributes no
  `Change`). `:total_shopify_products` and `:matched_local_products`
  together are what "coverage" actually means: matched / Shopify total.
  Neither `length(:changes)` (which undercounts — a matched, identical
  product isn't a change) nor the local catalog's total size (which
  overcounts — a local product with no Shopify counterpart at all still
  isn't part of what this check could ever see) is that number. Both
  fields are additive — they do not change `:changes`'/`:source`'s
  meaning, and `:total_shopify_products` on its own says nothing about
  coverage without `:matched_local_products` alongside it.

  On the `:storefront` fallback path, `:total_shopify_products` counts
  only products the public storefront serves (published to the Online
  Store) — a narrower population than the Admin API's full catalog, and
  not comparable to it. A caller computing a coverage percentage from
  these two fields MUST do so only when `:source == :admin`.

  `opts[:base_locale]` is the locale read for matching/diffing localized
  fields, defaulting to `Translations.default_language/0` — pass it
  explicitly to keep a call free of that default's database access
  (e.g. in tests), same reason `ProductDiff.diff/4` takes it. The rest
  of `opts` (`:admin_options`, `:storefront_options`) is forwarded to
  `Source.fetch/2`.
  """
  @spec check(String.t(), keyword()) ::
          {:ok,
           %{
             changes: [Change.t()],
             new_products: [Change.t()],
             source: :admin | :storefront,
             fallback_reason: term() | nil,
             total_shopify_products: non_neg_integer(),
             matched_local_products: non_neg_integer()
           }}
          | {:error, term()}
  def check(integration_uuid, opts \\ []) do
    {base_locale, source_opts} =
      Keyword.pop_lazy(opts, :base_locale, &Translations.default_language/0)

    with {:ok, %{source: source, products: products, only: only, fallback_reason: reason}} <-
           Source.fetch(integration_uuid, source_opts) do
      local_products = Shop.list_products()
      changes = ProductDiff.diff(local_products, products, base_locale, only: only)
      matched = ProductDiff.matched_count(local_products, products, base_locale)
      new_products = new_product_changes(local_products, products, base_locale, source)

      {:ok,
       %{
         changes: changes,
         new_products: new_products,
         source: source,
         fallback_reason: reason,
         total_shopify_products: length(products),
         matched_local_products: matched
       }}
    end
  end

  # New-handle creation is a catalogue-source-only path (see this module's
  # moduledoc) and only meaningful against a complete Admin API listing —
  # the `:storefront` fallback only ever carries price data for products it
  # ALREADY matched by handle (see `check/2`'s own moduledoc), so treating
  # its unmatched remainder as "new in Shopify" would be wrong for a
  # completely different reason than the legacy source's.
  defp new_product_changes(local_products, products, base_locale, :admin) do
    if ProductSource.current() == ProductSource.Catalogue do
      ProductDiff.new_product_changes(local_products, products, base_locale)
    else
      []
    end
  end

  defp new_product_changes(_local_products, _products, _base_locale, :storefront), do: []

  @doc """
  Checks ONE local product against its matched Shopify product — see
  this module's moduledoc ("Single-product check") for why this exists
  alongside `check/2` and how the two differ.

  `item_uuid` is looked up via `Shop.get_product/2` (whichever adapter
  `ProductSource.current/0` picks, same as everywhere else in this
  facade) — no local product at that uuid is `{:error, :not_found}`.
  Its Shopify link is read from `product.metadata["_shopify"]
  ["product_id"]`, the same sub-map `ProductDiff`'s own handle-matching
  reads `["handle"]` from (see that module's moduledoc); a product with
  no such link is `{:error, :not_linked}`. There is no slug/handle
  fallback the way `check/2`'s bulk diff has — a single product with no
  known Shopify id has nothing to fetch by id in the first place.

  The linked id is then fetched with `AdminClient.fetch_product/3`; a
  404 there (`:not_found` — the id no longer exists in Shopify) is
  translated to `{:error, :not_found_in_shopify}` so it isn't confused
  with the LOCAL lookup's own `:not_found` above. Any other
  `AdminClient.fetch_product/3` error (`:unauthorized`, `:rate_limited`,
  a transport error, …) is returned as-is.

  The single local/remote pair is then diffed with the same
  `ProductDiff.diff/4` `check/2` uses, over every comparable field
  (`ProductDiff.comparable_fields/0` — the Admin API, the only source
  here, always carries all of them). `diff/4` still matches by handle
  (`product.metadata["_shopify"]["handle"]` vs.
  `shopify_product["handle"]`) — a product renamed on Shopify's side is
  fetched correctly (by id) but won't match its own now-stale local
  handle, and reports no changes rather than the rename itself; this is
  inherited from reusing `diff/4` unchanged, not special-cased here.

  Returns `{:ok, %{changes: [Change.t()], source: :admin}}` —
  `:changes` is `[]`, never omitted, when nothing differs. `:source` is
  always `:admin` (this function has no storefront fallback — see the
  moduledoc) and exists only so the result shares `check/2`'s own
  `:source` key, letting a future panel reuse rendering code without
  branching on which check produced it; deliberately NOT carrying
  `check/2`'s other keys (`:new_products`, `:fallback_reason`,
  `:total_shopify_products`, `:matched_local_products`) since none of
  them mean anything for a single product. Every `Change` in `:changes`
  is a regular (non-`create?`) `Change`, so it can be handed straight to
  `apply_change/3`/`apply_changes/3` exactly like one from `check/2`.

  `opts[:base_locale]` and `opts[:admin_options]` are the same options
  `check/2` takes, forwarded the same way.
  """
  @spec check_one(String.t(), String.t(), keyword()) ::
          {:ok, %{changes: [Change.t()], source: :admin}}
          | {:error, :not_found | :not_linked | :not_found_in_shopify | term()}
  def check_one(integration_uuid, item_uuid, opts \\ []) do
    base_locale = Keyword.get_lazy(opts, :base_locale, &Translations.default_language/0)
    admin_options = Keyword.get(opts, :admin_options, [])

    with {:ok, product} <- fetch_local_product(item_uuid),
         {:ok, product_id} <- linked_shopify_product_id(product),
         {:ok, shopify_product} <-
           fetch_one_shopify_product(integration_uuid, product_id, admin_options) do
      changes = ProductDiff.diff([product], [shopify_product], base_locale)
      {:ok, %{changes: changes, source: :admin}}
    end
  end

  defp fetch_local_product(item_uuid) do
    case Shop.get_product(item_uuid) do
      nil -> {:error, :not_found}
      product -> {:ok, product}
    end
  end

  defp linked_shopify_product_id(product) do
    case get_in(product.metadata || %{}, ["_shopify", "product_id"]) do
      id when is_binary(id) and id != "" -> {:ok, id}
      id when is_integer(id) -> {:ok, id}
      _ -> {:error, :not_linked}
    end
  end

  defp fetch_one_shopify_product(integration_uuid, product_id, admin_options) do
    case AdminClient.fetch_product(integration_uuid, product_id, admin_options) do
      {:ok, shopify_product} -> {:ok, shopify_product}
      {:error, :not_found} -> {:error, :not_found_in_shopify}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Applies fields from `change` to its product.

  `fields` is `:all` (every field in `change.changes`) or an explicit list
  of field atoms — only fields present in BOTH `change.changes` and
  `fields` are written, everything else on the product is left untouched.
  Localized fields (`title`, `body_html`, `description`) are merged into
  `change.base_locale` only (the locale `ProductDiff.diff/4` matched and
  compared this change against) — other languages already on the product
  are preserved. This is why `base_locale` lives on the `Change` struct
  rather than being re-read here: a change diffed against one locale must
  be applied into that same locale, not whatever the default happens to
  be at apply time.

  A create-`Change` (`create?: true`, from `check/2`'s `:new_products` —
  catalogue source only) ignores `fields` entirely: there is no existing
  product to apply a subset of fields onto, so the whole
  `change.shopify_product` payload goes to `Writer.create_from_shopify/2`.

  Under the legacy source, a regular `Change` still writes through
  `Shop.update_product/2`, unchanged from before. Under the catalogue
  source, it writes through `PhoenixKitEcommerce.Catalogue.Writer.
  update_from_shopify/3` into the matched item instead — `change.
  product_uuid` is the item's own uuid (see `ProductSource.Catalogue.
  View.product_view/2`: a catalogue view-struct's `:uuid` IS the item's),
  so it's fetched with `PhoenixKitCatalogue.Catalogue.get_item!/1`, not
  `Shop.get_product!/1` (which would hand back a read-only view-struct
  `Shop.update_product/2` refuses).

  Before writing, `:price`/`:compare_at_price` are subject to the
  currency guard (this module's moduledoc, §7.5): on a shop-currency
  mismatch they are dropped from `fields_to_apply` (a non-price field on
  the same change still gets written) and, if that was the only thing
  `fields` asked for, this returns `{:error, {:currency_mismatch,
  shop_currency, base_currency}}` instead of a silent no-op success. A
  create-`Change` is subject to the same guard too, but all-or-nothing —
  see the moduledoc for why a create can't be partially refused the way
  an update can.

  `opts[:admin_options]` forwards to `AdminClient.fetch_shop/2` for the
  currency-guard lookup (e.g. `req_options:` to stub the transport in
  tests) — the same option name `check/2` already uses for its own Admin
  API call. `opts[:currency_verdict]` — a `currency_verdict/1` result the
  caller already computed — skips that lookup entirely and uses it
  as-is instead; see this module's moduledoc ("Precomputed currency
  verdict") for why and when a caller would pass it.
  """
  @spec apply_change(Change.t(), :all | [atom()], keyword()) ::
          {:ok, PhoenixKitEcommerce.Product.t()} | {:error, Ecto.Changeset.t() | term()}
  def apply_change(change, fields \\ :all, opts \\ [])

  def apply_change(%Change{create?: true} = change, _fields, opts) do
    create_change(change, resolve_verdict(opts))
  end

  def apply_change(%Change{} = change, fields, opts) do
    do_apply_change(change, fields, resolve_verdict(opts))
  end

  # `opts[:currency_verdict]`, when given, IS the answer
  # `currency_verdict/1` would otherwise compute — used as-is, with no
  # further lookup. `Keyword.fetch/2`, not `Keyword.get/3`, so an
  # explicit `currency_verdict: nil` (never a real return value of
  # `currency_verdict/1`) is not mistaken for "not given" and silently
  # replaced by a fresh lookup.
  defp resolve_verdict(opts) do
    case Keyword.fetch(opts, :currency_verdict) do
      {:ok, verdict} -> verdict
      :error -> currency_verdict(opts)
    end
  end

  # A create writes a price UNCONDITIONALLY (`Writer.create_from_shopify/2`
  # always sets `base_price` from the cheapest variant — there is no
  # `fields`/`changes` to filter it out of, unlike an update). On a
  # mismatch this is the WORSE case, not the safer one: an update at
  # least leaves an existing, correct price alone, while a create would
  # mint a brand-new record whose price is wrong from the moment it
  # exists, labelled with the base currency by `Writer` itself, with no
  # prior value anywhere to reveal the error. So the whole create is
  # refused — never partially, e.g. "create it without a price" — a
  # product with the right title and images but a wrong price is not a
  # partial success.
  defp create_change(%Change{} = change, :match) do
    case Writer.create_from_shopify(change.shopify_product, change.base_locale) do
      {:ok, item} -> {:ok, CatalogueView.product_view(item)}
      error -> error
    end
  end

  defp create_change(%Change{} = change, {:mismatch, shop_currency, base_currency}) do
    log_create_refusal(change.handle, shop_currency, base_currency)
    {:error, {:currency_mismatch, shop_currency, base_currency}}
  end

  defp do_apply_change(%Change{} = change, fields, verdict) do
    case resolve_priced_fields(fields, change.changes, verdict) do
      {:error, {shop_currency, base_currency}} ->
        {:error, {:currency_mismatch, shop_currency, base_currency}}

      {:ok, fields_to_apply} ->
        if ProductSource.current() == ProductSource.Catalogue do
          apply_catalogue_change(change, fields_to_apply)
        else
          apply_legacy_change(change, fields_to_apply)
        end
    end
  end

  defp apply_legacy_change(%Change{} = change, fields) do
    product = Shop.get_product!(change.product_uuid)
    base_locale = change.base_locale
    fields_to_apply = resolve_fields(fields, change.changes)

    attrs =
      Enum.reduce(fields_to_apply, %{}, fn field, acc ->
        %{incoming: incoming} = Map.fetch!(change.changes, field)
        Map.merge(acc, build_attr(product, field, incoming, base_locale))
      end)

    Shop.update_product(product, attrs)
  end

  defp apply_catalogue_change(%Change{} = change, fields) do
    item = CatalogueApi.get_item!(change.product_uuid)
    base_locale = change.base_locale
    fields_to_apply = resolve_fields(fields, change.changes)

    change_fields =
      fields_to_apply
      |> Enum.reduce(%{}, fn field, acc ->
        %{incoming: incoming} = Map.fetch!(change.changes, field)
        Map.put(acc, field, incoming)
      end)
      |> Map.put(:handle, change.handle)
      |> maybe_put_product_id(change.product_id)

    case Writer.update_from_shopify(item, change_fields, base_locale) do
      {:ok, item} -> {:ok, CatalogueView.product_view(item)}
      error -> error
    end
  end

  # `change.product_id` is carried on every `Change` regardless of `fields`
  # (see `ProductDiff.Change`'s moduledoc) — this backfills
  # `data["ecommerce"]["shopify"]["product_id"]` on every applied change,
  # not just ones that happened to touch a comparable field.
  defp maybe_put_product_id(change_fields, nil), do: change_fields

  defp maybe_put_product_id(change_fields, product_id),
    do: Map.put(change_fields, :product_id, product_id)

  @doc """
  Applies `fields` to every change in `changes`, partitioning them by outcome.

  A changeset failure on one product doesn't stop the rest from being
  attempted. Returns `%{succeeded: [Change.t()], failed: [Change.t()]}`,
  each preserving the input order — so a caller can drop `succeeded` and
  keep offering `failed` for retry instead of reporting them as done.

  The currency guard's shop lookup (this module's moduledoc, §7.5) runs
  ONCE for the whole batch, not once per change in `changes` — see
  `currency_verdict/1`. `opts[:admin_options]` is the same option
  `apply_change/3` takes for that lookup, and `opts[:currency_verdict]`
  the same escape hatch — when given, this skips the lookup entirely
  (still once, not per-change either way) and uses it as-is, same as
  `apply_change/3`.
  """
  @spec apply_changes([Change.t()], :all | [atom()], keyword()) :: %{
          succeeded: [Change.t()],
          failed: [Change.t()]
        }
  def apply_changes(changes, fields \\ :all, opts \\ []) do
    verdict = resolve_verdict(opts)

    %{succeeded: succeeded, failed: failed} =
      Enum.reduce(changes, %{succeeded: [], failed: []}, fn change, acc ->
        case apply_change_with_verdict(change, fields, verdict) do
          {:ok, _product} -> %{acc | succeeded: [change | acc.succeeded]}
          {:error, _changeset} -> %{acc | failed: [change | acc.failed]}
        end
      end)

    %{succeeded: Enum.reverse(succeeded), failed: Enum.reverse(failed)}
  end

  defp apply_change_with_verdict(%Change{create?: true} = change, _fields, verdict),
    do: create_change(change, verdict)

  defp apply_change_with_verdict(%Change{} = change, fields, verdict),
    do: do_apply_change(change, fields, verdict)

  @doc """
  Looks up the connected Shopify store's own currency and compares it
  against the base currency (§7.5) — public so `Workers.ShopifyMediaSyncWorker`
  (the variants/prices media sync, a second price-writing path that
  bypasses `apply_change/3`/`apply_changes/3` entirely) can reuse this
  exact lookup and fail-open policy instead of re-implementing it.

  `:match` covers three cases identically, on purpose: currencies
  actually agree, no Shopify connection exists at all (nothing to
  mismatch against), and the lookup failed (fail OPEN — an unreachable
  Shopify must never stop a sync that was otherwise working, logged once
  as a warning). `opts[:admin_options]` forwards to `AdminClient.fetch_shop/2`
  (e.g. `req_options:` to stub the transport in tests).

  Re-resolves the connected Shopify integration on every call rather
  than accepting one as a parameter — safe only because this codebase
  supports exactly one Shopify connection everywhere (`Provider`,
  `Shop.list_connections("shopify", owner: :system)` elsewhere all make
  the same assumption); a caller batching many writes still gets the
  ONE-lookup-per-batch behaviour described above, but a caller with more
  than one connection to compare against would need a different
  function, not another argument to this one.
  """
  @spec currency_verdict(keyword()) :: :match | {:mismatch, String.t(), String.t()}
  def currency_verdict(opts \\ []) do
    case shopify_integration_uuid() do
      nil ->
        :match

      uuid ->
        admin_options = Keyword.get(opts, :admin_options, [])

        case AdminClient.fetch_shop(uuid, admin_options) do
          {:ok, %{"currency" => shop_currency}} when is_binary(shop_currency) ->
            compare_currency(shop_currency)

          {:ok, _shop} ->
            log_lookup_failure(:missing_currency)

          {:error, reason} ->
            log_lookup_failure(reason)
        end
    end
  end

  defp shopify_integration_uuid do
    case Integrations.list_connections("shopify", owner: :system) do
      [%{uuid: uuid} | _rest] -> uuid
      [] -> nil
    end
  end

  # Case-folded on both sides — insurance, not a fix: every code this
  # shop deals with is an upper-case ISO 4217 code today (Shopify's own
  # `shop.currency` and `PhoenixKitBilling.Currency.code` alike), but a
  # comparison this consequential shouldn't depend on that staying true
  # forever.
  defp compare_currency(shop_currency) do
    case base_currency_code() do
      nil ->
        :match

      base ->
        if String.upcase(base) == String.upcase(shop_currency) do
          :match
        else
          {:mismatch, shop_currency, base}
        end
    end
  end

  defp base_currency_code do
    case Shop.get_base_currency() do
      %{code: code} -> code
      nil -> nil
    end
  end

  # A mismatch is an admin decision and logs at `warning` (see
  # `log_price_refusal/3`). A failed LOOKUP is not: a rotted access
  # token, a revoked app or a renamed shop domain leaves this guard
  # fail-open for every price write until someone notices, and there is
  # no other signal that it stopped protecting anything — so the branch
  # that means "something is broken" logs at `error`, while the two that
  # mean "there is nothing to check here" stay at `warning`.
  defp log_lookup_failure(:missing_currency) do
    Logger.warning(
      "Shopify sync: the shop response carried no currency — " <>
        "proceeding without the currency guard"
    )

    :match
  end

  defp log_lookup_failure(reason) do
    Logger.error(
      "Shopify sync: could not reach the shop to verify its currency " <>
        "(#{inspect(reason)}) — proceeding without the currency guard, and " <>
        "every price this sync writes is unchecked until this is fixed"
    )

    :match
  end

  # Strips `@price_fields` from what `fields` would otherwise resolve to
  # against `changes` (see `resolve_fields/2`) on a mismatch — reusing
  # that same resolution rather than adding a parallel one, since a
  # pre-filtered list is safe to hand back into it (`resolve_fields/2`
  # on an already-filtered list is idempotent).
  #
  # `{:ok, fields}` — nothing to refuse (no price field was requested),
  # or a price field was refused but something else survives to apply.
  # `{:error, {shop, base}}` only when EVERY field this change would
  # have applied was a price field — there's nothing left to write, so
  # this reports the refusal as this call's own error instead of a
  # silent, empty "success".
  defp resolve_priced_fields(fields, changes, :match), do: {:ok, resolve_fields(fields, changes)}

  defp resolve_priced_fields(fields, changes, {:mismatch, shop, base}) do
    resolved = resolve_fields(fields, changes)
    priced = Enum.filter(resolved, &(&1 in @price_fields))

    case resolved -- priced do
      _remaining when priced == [] ->
        {:ok, resolved}

      [] ->
        log_price_refusal(priced, shop, base)
        {:error, {shop, base}}

      remaining ->
        log_price_refusal(priced, shop, base)
        {:ok, remaining}
    end
  end

  # `:warning`, not `:error` — a store switching currency is an admin
  # decision, not a system fault, and a host that pages on error-level
  # logs would page someone for a state no incident response can fix.
  defp log_price_refusal(fields, shop_currency, base_currency) do
    Logger.warning(
      "Shopify sync: refusing to write #{inspect(fields)} — shop currency " <>
        "#{shop_currency} does not match base currency #{base_currency} (design spec §7.5)"
    )
  end

  defp log_create_refusal(handle, shop_currency, base_currency) do
    Logger.warning(
      "Shopify sync: refusing to create #{inspect(handle)} — shop currency " <>
        "#{shop_currency} does not match base currency #{base_currency} (design spec §7.5)"
    )
  end

  defp resolve_fields(:all, changes), do: Map.keys(changes)

  defp resolve_fields(fields, changes) when is_list(fields) do
    Enum.filter(fields, &Map.has_key?(changes, &1))
  end

  defp build_attr(product, field, incoming, base_locale) when field in @localized_fields do
    Translations.changeset_attrs(product, field, base_locale, incoming)
  end

  defp build_attr(_product, field, incoming, _base_locale) do
    %{field => incoming}
  end
end
