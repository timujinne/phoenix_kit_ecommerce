# Code Review: PR #35 — Storefront filters and variant picker on catalogue attribute sets

**Reviewed:** 2026-09-08
**Reviewer:** Kimi Code
**PR:** https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/35
**Head SHA:** f3a4107 (squash-merged)
**Status:** Merged

## Summary

The PR adds storefront facet filtering over `phoenix_kit_catalogue`
attribute sets (`attribute_set` filter type + `metadata_option` alias),
per-category `storefront_filters` overrides, per-language set/value labels,
a Shopify-string→value-slug resolver, and threads the shopper's language
into the cart's product reload so translated price modifiers actually apply.
Overall quality is high: every filter param reaching Ecto is bound (`?|`
array ops, parameterized fragments, escaped+capped ILIKE), no
`String.to_atom` anywhere, money stays `Decimal`, all three touched public
LiveViews keep `put_content_locale/1` in `mount/3`, and the compat shim was
updated for the widened `get_enabled_storefront_filters/2`. The new tests
pin real contracts (translated-label pricing end-to-end through
`add_to_cart`, merge ordering, stale-default dropping). Findings are mostly
consistency/perf gaps plus one pre-existing ordering bug in a touched file
that this PR's feature relies on.

## Issues Found

### 1. [BUG - MEDIUM] `filter_by_visible_categories` uses `distinct: i.uuid`, defeating the listing's position/name ordering
**File:** `lib/phoenix_kit_ecommerce/product_source/catalogue/query.ex:517-526`
**Confidence:** 85/100

Verified with Ecto's planner: the query compiles to
`SELECT DISTINCT ON (i0."uuid") ... ORDER BY i0."uuid", i0."position", i0."name"`
— Postgres-valid (no crash), but Ecto prepends `uuid` to the `ORDER BY`, so
every catalogue-source listing with `exclude_hidden_categories: true` (the
global catalog page, `shop_catalog.ex:70`) is ordered by uuid, not
position/name. The `distinct` is also unnecessary: the left join to one
category row per `category_uuid` can never duplicate an item. *Note:* this
code was introduced in PR #34, not this PR — but this PR's facet work builds
on the same listing path, and the PR's own `exclude_hidden_categories/2`
(query.ex:392-404) uses the correct `NOT IN` subquery shape.

**Fix:** drop `distinct: i.uuid`, or rewrite as the same subquery pattern
used in `attribute_set_counts`.

### 2. [IMPROVEMENT - MEDIUM] Facet scope inconsistency: fixed for `attribute_set` but not `vendor`/`price_range`
**File:** `lib/phoenix_kit_ecommerce/product_source/catalogue/query.ex:189-234` + `product_source/catalogue.ex:159-166`
**Confidence:** 85/100

`Query.vendor_counts/1` and `Query.price_range/1` accept no
`:exclude_hidden_categories`, so on the global catalog page (listing scoped
with `exclude_hidden_categories: true`) the vendor counts and price-slider
bounds can exceed what the listing shows — exactly the "counts outrun the
listing" bug the commit message says was fixed for attribute sets.

**Fix:** accept and forward the flag in both functions.

### 3. [IMPROVEMENT - MEDIUM] Unvalidated `price_modifiers` values can reach `Decimal.new/1` and raise
**File:** `lib/phoenix_kit_ecommerce/catalogue/item_commerce.ex:44` → `product_source/catalogue/view.ex:272-282` → `options/options.ex:~1063-1081`
**Confidence:** 72/100

`ItemCommerce` casts `price_modifiers` as a bare `:map` with no numeric
validation; `View.price_modifiers_from_sets` copies the values verbatim into
`metadata["_price_modifiers"]`; a discovered spec is built with
`allow_override: true`, so the selected value routes through
`parse_modifier_value` → `Decimal.new(value)`, which raises `ArgumentError`
on a non-numeric string. Reachability is narrow — `has_nonzero_modifiers?/1`
safe-parses, so the garbage entry must coexist with one numeric non-zero
entry in the same set — but then one shopper click crashes the product
page/add-to-cart.

**Fix:** make `parse_modifier_value`/`get_custom_price_modifier` use the
safe parse (log + zero) like its siblings, or validate numeric-ness in
`ItemCommerce.changeset/2`.

### 4. [IMPROVEMENT - MEDIUM] `set_uuid_for_key/1` read amplification per render
**File:** `lib/phoenix_kit_ecommerce/product_source/catalogue/query.ex:577-586`
**Confidence:** 80/100

`set_uuid_for_key/1` runs a full `AttributeSets.list_sets()` filtered in
Elixir on *every* call: once per `metadata_filters` entry, once per
`attribute_set_counts`, once per `set_label`, plus one `get_set/2` per
distinct set in `set_display_names`. A catalog render with 3 attribute-set
filters issues roughly 9+ full entities reads before any facet SQL runs.

**Fix:** resolve the filter config's slugs → set uuids once per render (in
`aggregate_filter_values`/`load_filter_data`) and thread the map down.

### 5. [IMPROVEMENT - MEDIUM] Translated-pricing fix is opt-in per call: omitting `:language` silently mis-prices
**File:** `lib/phoenix_kit_ecommerce.ex:2403-2419`
**Confidence:** 72/100

`lock_or_reload_product(:built, nil)` reloads with untranslated labels, so a
host that fetches a product with `language: "fr-FR"` but calls the public
`add_to_cart(cart, product, qty, selected_specs: ...)` without `language:`
gets a line at base price — no error, and validation passes against the
stale mount-time product. The only in-repo caller (`CatalogProduct`) passes
it correctly; the risk is the public facade contract for hosts.

**Fix:** document `:language` as required-with-`selected_specs` on the
catalogue source in `add_to_cart/4`'s doc, or derive it from the product
when absent.

### 6. [NITPICK] Stale docstring on `attribute_set_counts`
**File:** `query.ex:243-247`
**Confidence:** 90/100

Still says the `:language` option "covers the plain value label" with fuller
resolution being "Block 5's remaining work", but `value_label/2` (373-386)
already does the full `Multilang.get_language_data/2` resolution with
dialect fallback.

### 7. [NITPICK] Category-only filter override without `"enabled"` silently dropped
**File:** `lib/phoenix_kit_ecommerce.ex` `merge_storefront_filters/2`
**Confidence:** 75/100

A category-only override appended "as they are" but missing `"enabled"` is
silently dropped by `get_enabled_storefront_filters`'s
`Enum.filter(& &1["enabled"])`, so a hand-written
`data["ecommerce"]["storefront_filters"]` entry without `enabled` never
renders and never errors. Default `"enabled" => true` for appended filters,
or document the requirement (no admin UI writes these yet).

### 8. [NITPICK] Unresolvable set slug leaves the badge active but filters nothing
**File:** `query.ex:556-558`
**Confidence:** 78/100

`filter_by_metadata` returns the query unchanged when the set slug doesn't
resolve (deleted/renamed set): the sidebar badge still counts the filter as
active while it filters nothing. A match-nothing clause would keep the
listing honest with the UI state.

### 9. [NITPICK] `parse_decimal` accepts trailing garbage
**File:** `web/components/filter_helpers.ex:280-286`
**Confidence:** 88/100

`{decimal, _} -> decimal`, so `?price_min=10abc` silently becomes 10.
Harmless, but `{decimal, ""}` would be stricter.

## What looks good

- **Input safety:** all user-supplied filter values reach SQL as bound
  parameters (`type(^slugs, {:array, :string})` with `?|`, pinned
  fragments); ILIKE search escapes `\`, `%`, `_`, strips NULs, caps at 100
  chars; no atom conversion of input.
- **Money discipline:** `Decimal` throughout; the price-range fix
  (`restrict_to_offered_values`, shared `apply_percent/2`, numeric
  `Decimal.min/max`) addresses advertised-vs-charged divergence.
- **Language threading:** the `lock_or_reload_product/2` fix is pinned by an
  end-to-end test asserting the fr-FR cart line is priced off a modifier
  keyed by the *translated* label — a naive regression would fail it.
- **Tests** assert exact contracts (sort order with explicit tie-break, the
  nil-position crash fix, draft values excluded from facets, prefixed
  `catalogue_set_` keys).
- **Conventions:** new settings event goes through
  `Authz.authorize`/`gated_event`; new strings gettext-wrapped and extracted
  to all five locales; `put_content_locale/1` in every touched public mount;
  compat delegates updated for new arities.

## Unverified surfaces

- All `:catalogue`-tagged tests cannot run in this checkout (no declared
  `phoenix_kit_catalogue`/`phoenix_kit_entities` deps); the new facet query,
  `ValueResolver`, and translated-label view paths are verified only by
  reading.
- `PhoenixKitCatalogue` API behavior
  (`AttributeSets.resolve_for_item/2` shape/failure modes, `get_set/2` owner
  gating, `resolve_for_items/1` return shape feeding the
  `%{"sets" => ...}` pattern match) is taken on faith from usage; a
  non-`%{sets: ...}` result with a non-nil language would raise
  `FunctionClauseError`.
- Pre-existing (not this PR), flagged for whoever owns them: the
  `DISTINCT ON` ordering issue (finding 1, introduced in #34);
  `handle_params` never recomputes facet counts after filter changes; the
  `compat/shop.ex:127` `add_to_cart(cart, product_uuid, ...)` delegate names
  a uuid param the facade has no clause for (introduced in 04df005).
