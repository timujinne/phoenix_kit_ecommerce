# Code Review: PR #34 — ProductSource: catalogue-backed storefront, cart and Shopify sync (opt-in switch)

**Reviewed:** 2026-09-08
**Reviewer:** Kimi Code
**PR:** https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/34
**Head SHA:** cbed3a4 (squash-merged)
**Status:** Merged

## Summary

The PR introduces a `ProductSource` behaviour with two adapters — `Legacy`
(the existing shop tables, moved verbatim) and `Catalogue` (reads
`phoenix_kit_catalogue` items and projects them into hand-built
`%Product{}`/`%Category{}` view-structs) — switched by a
`shop_product_source` key in `phoenix_kit_shop_config`, defaulting to Legacy
and failing closed when `phoenix_kit_catalogue` isn't loaded. The cart
learns a second line identity (`metadata["catalogue_item_uuid"]` with
`product_uuid` nil), checkout validation splits legacy/catalogue lines,
Shopify sync writes through a new `Catalogue.Writer` under the catalogue
source, and admin write surfaces are gated with `:read_only_view` refusals
plus redirects to `/admin/catalogue`. The core design is sound and unusually
well-documented. The weaknesses are at the seams: a few read paths still
bypass the adapter, the two adapters' filter/visibility semantics drift in a
couple of places, and the catalogue half of the test suite only runs in an
env-var-gated fork setup, so none of it executes in this repo's default
`mix test`.

## Issues Found

### 1. [BUG - MEDIUM] `active_visibility/1` has no COALESCE fallback — counts/facets disagree with the listing
**File:** `lib/phoenix_kit_ecommerce/product_source/catalogue/query.ex:500-507`
**Confidence:** 85/100

`active_visibility/1` requires `data->'ecommerce'->>'shop_status' = 'active'`
with **no COALESCE fallback**, while `filter_by_status(query, "active")`
(lines 477-484, driving the actual storefront listing) uses
`COALESCE(..., 'active')` and `View.product_status/2` treats a missing
`shop_status` as active when `item.status == "active"`. A catalogue item
created directly in catalogue admin (outside the Shop extension section,
which defaults `shop_status`) appears in the storefront grid but is silently
excluded from `product_counts_by_category/0`, `price_range/1`,
`vendor_counts/1` and `attribute_set_counts/2`. Result: category counts show
0 and the price slider/facets ignore products the listing visibly contains.

**Fix:** use the same `COALESCE(..., 'active')` fragment in
`active_visibility/1`, and add a query test with an item lacking the key
(current tests only pin the listing fallback,
`catalogue_query_test.exs:108`).

### 2. [BUG - MEDIUM] Category-level option_schema price modifiers silently drop at add-to-cart under the catalogue source
**File:** `lib/phoenix_kit_ecommerce.ex:2415` + `lib/phoenix_kit_ecommerce/options/options.ex:334-346,265-277`
**Confidence:** 78/100

`lock_or_reload_product/2` reloads a catalogue view-struct via
`ProductSource.current().get_product(uuid, language: language)` **without**
`preload: [:category]`, then `calculate_product_price/2` →
`get_option_schema_for_product/1` hits the `%{category_uuid: uuid}` clause
(category association is `NotLoaded`, not a `%Category{}`), and
`get_category_options(uuid)` queries the **legacy**
`phoenix_kit_shop_categories` table — empty under the catalogue source — so
category-level `option_schema` price modifiers (writable via
`CategoryCommerce`) apply on the product page (which preloads `:category`,
`catalog_product.ex:177`) but silently drop out at add-to-cart. The page
shows base+modifier; the cart line snapshots base.

**Fix:** pass `preload: [:category]` in the catalogue reload, or route
`get_category_options/1`'s uuid lookup through `ProductSource.current()`.
(Real-world frequency: low unless operators use category option_schema with
price modifiers — the attribute-set path via `_price_modifiers` in metadata
works fine.)

### 3. [IMPROVEMENT - MEDIUM] `CartItem.product_deleted?/1` returns true for every catalogue-backed line
**File:** `lib/phoenix_kit_ecommerce/schemas/cart_item.ex:281,324`
**Confidence:** 90/100

`product_deleted?/1` returns `true` for **every** catalogue-backed cart line
(`product_uuid` is nil by design), and `product_changed?/2`'s
`product_uuid: nil` clause also fires unconditionally. Nothing in `lib/`
calls these today (only the schema's own test), so it's latent — but the
predicates' contracts now lie for catalogue lines, and the pre-existing test
at `cart_item_test.exs:81` still pins the old meaning.

**Fix:** treat `metadata["catalogue_item_uuid"]` presence as "not deleted"
(resolve via the current source), or rename/document the predicates as
legacy-only.

### 4. [IMPROVEMENT - MEDIUM] Admin dashboard counts and filter auto-suggest bypass the adapter
**File:** `lib/phoenix_kit_ecommerce.ex:896-915` (`discover_filterable_options`), `4683-4700` (`count_products*`/`count_categories` behind `get_dashboard_stats/0` and `get_config/0`), `1726-1735` (`category_options/0`), `1789-1826` (`list_category_product_options/1`)
**Confidence:** 90/100

These read the legacy tables directly. Under the catalogue source the admin
Dashboard (`web/dashboard.ex:17`) shows zero/stale counts while the Products
tab beside it lists catalogue items, and the filter-settings auto-suggest
comes from a table nothing reads anymore.

**Fix:** route counts through the adapter (the behaviour would need a stats
callback) or label the dashboard as legacy-only while the switch is on.

### 5. [IMPROVEMENT - MEDIUM] Catalogue adapter ignores the `:product_type` filter
**File:** `lib/phoenix_kit_ecommerce/product_source/catalogue/query.ex:461-470`
**Confidence:** 85/100

`apply_item_filters/2` has no `:product_type` clause; `Legacy` filters it
(`legacy.ex:251-252`) and the admin Products page exposes a type filter
(`products.ex` passes `product_type: socket.assigns.type_filter`). Under the
catalogue source the filter silently no-ops instead of narrowing.

**Fix:** filter on `data->'ecommerce'->>'product_type'` (View maps it from
the same key), or hide the filter UI when the catalogue source is active.

### 6. [IMPROVEMENT - MEDIUM] `:new_products` in `Shopify.Sync.check/2` is dead surface
**File:** `lib/phoenix_kit_ecommerce/shopify/sync.ex:105-116` vs `lib/phoenix_kit_ecommerce/web/shopify_sync.ex`
**Confidence:** 85/100

`check/2` now returns `:new_products` (create-`Change`s that
`apply_change/2` dispatches to `Writer.create_from_shopify/2`), but the
ShopifySync LiveView — untouched by this PR — never reads that key, so the
create path is reachable only from tests.

**Fix:** wire `:new_products` into the sync UI or drop it from `check/2`'s
return until a consumer exists; as merged it's dead surface that looks
usable.

### 7. [IMPROVEMENT - MEDIUM] `:featured_product` preload silently dropped; parent resolution is N+1
**File:** `lib/phoenix_kit_ecommerce/web/shop_catalog.ex:47,428` + `product_source/catalogue.ex:329-331,354-356`
**Confidence:** 80/100

The catalogue adapter's `:preload` whitelist recognizes only
`:category`/`:parent`; the storefront's
`list_active_categories(preload: [:parent, :featured_product])` silently
drops `:featured_product`, so `Category.get_image_url/2`'s featured-product
fallback can never fire for a view-struct — catalogue categories without a
direct `image_uuid` render no card image even when `featured_item_uuid` is
set (`View.category_view/2` maps it but nothing resolves it). Relatedly,
`resolve_parent/2` does one `Query.get_category/1` (each internally
re-resolving `catalogue_uuid()` via `list_catalogues/0`) per non-root
category — a small N+1 on every catalog mount.

**Fix:** batch-resolve parents (a `list_categories_by_uuids/1` call like
products' `maybe_categories_by_uuid/1`) and either resolve
`featured_item_uuid` in `category_image_url/2` or document the drop.

### 8. [IMPROVEMENT - LOW] Catalogue search misses SKU and translated fields
**File:** `lib/phoenix_kit_ecommerce/product_source/catalogue/query.ex:605-621` vs `legacy.ex:335-365`
**Confidence:** 85/100

Catalogue search covers `name`/`description` columns and tags only; legacy
additionally searches SKU (`metadata->>'sku'`) and every language of the
localized fields via `jsonb_each_text`. A storefront search that matches a
translated title or a SKU under Legacy misses under Catalogue.

**Fix:** extend the fragment to `jsonb_each_text(i.data)` language blobs and
`data->'ecommerce'->>'sku'`.

### 9. [IMPROVEMENT - LOW] Default ordering flips between adapters
**File:** `query.ex:74` vs `legacy.ex:32`
**Confidence:** 90/100

Default ordering changes from `desc: inserted_at` (Legacy) to
`asc: position, asc: name` (Catalogue). Documented in `Query`'s moduledoc
but the facade's `list_products/1` doc doesn't mention that the switch
changes default ordering of the admin Products page and any unsorted
listing. Likely intentional (catalogue has a `position` column); flagging
the silent behavior flip.

### 10. [NITPICK] New facade functions without compat delegates
**File:** `lib/phoenix_kit_ecommerce/compat/shop.ex`
**Confidence:** 85/100

New public facade functions `get_config/1`, `get_price_range_for/1`,
`category_image_url/2` got no delegates, against the file's own maintenance
note ("re-audit the delegate list whenever the public API changes"). No live
consumer can call them through the compat namespace today, so this is
hygiene.

### 11. [NITPICK] `list_categories_with_count/1` slices in memory for both adapters
**File:** `lib/phoenix_kit_ecommerce.ex:1446-1459`
**Confidence:** 90/100

It now loads the full filtered category list and slices in memory for
**both** adapters (legacy was SQL `LIMIT/OFFSET`). Fine at realistic
category counts; a pathological install regresses, and `total` is now
`length/1` of a fully-loaded list.

### 12. [NITPICK] `ProductSource.current/0` raises when the repo is down
**File:** `lib/phoenix_kit_ecommerce/product_source.ex:58-65`
**Confidence:** 72/100

`ProductSource.current/0` does an unrescued `repo().get(ShopConfig, key)`
per call and is reachable from `ai_translatables/0`, a duck-typed discovery
callback; unlike `enabled?/0` (which rescues to `false` exactly because the
DB may be unavailable), a repo-down discovery pass raises. Fail-closed
direction is right; adding a rescue → Legacy would match the module's own
convention. (Speculative: depends on when `phoenix_kit_ai` enumerates
translatables.)

## What looks good

- The switch is fail-closed in both directions: absent/unknown key or
  missing optional dep → Legacy. Per-call read (no cache lag) is documented
  as a deliberate trade-off.
- View-struct write guards (`update_product`/`delete_product`/
  `update_category`/`delete_category`/`ensure_featured_product` refusing
  `:built`, admin forms redirecting, save paths handling
  `{:error, :read_only_view}` explicitly) close the "write into a table
  nothing reads" hole thoroughly.
- Cart correctness: dual identity (`product_uuid` vs
  `metadata["catalogue_item_uuid"]`) is threaded through add, dedup,
  guest-cart merge, and checkout validation; `price_on_request`/
  `price_unit`/currency stay snapshot-based; order line items carry
  `catalogue_item_uuid` forward. The language-threaded reload so
  `_price_modifiers` keys match the shopper's locale is a subtle catch done
  right.
- `Writer.update_from_shopify/3`'s re-merge of `current_ecommerce` over the
  cast result (preserving `legacy_metadata`), the never-replace-`shopify`-
  submap merge, and image re-use-by-`source_url` are careful.
- Tests pin real contracts (delegation equivalence vs Legacy, `:built`
  refusal mutations, catalogue scoping, prefixed set keys), not just happy
  paths.

## Unverified surfaces

- The entire `phoenix_kit_catalogue` API surface
  (`Catalogue.get_item_by_slug/3` option handling — `catalogue_opts/1`
  forwards arbitrary facade opts minus `:preload`, which could raise on
  unknown keys; `AttributeSets.resolve_for_items/2` shapes; the
  `inner_lateral` fragment join in `attribute_set_counts/2`). The dep isn't
  declared here and every `:catalogue`-tagged test is excluded from this
  repo's default run, so the whole Catalogue adapter is unexercised in CI as
  committed — worth a CI job with the env paths set, or the drift findings
  above will regress invisibly.
- Whether core or any sibling actually calls the new facade functions
  through `compat/` (finding 10 is precautionary).
