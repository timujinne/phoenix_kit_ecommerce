# Code Review: 0.5.0 release sweep (PRs #32–#46)

**Reviewed:** 2026-09-08
**Reviewer:** Grok (grok-4.6)
**Scope:** Everything merged on `main` after Hex 0.4.3, reviewed as the
current tree rather than PR-by-PR. Prior Kimi reviews of #32–#35 and #40
were verified against this HEAD; #36–#39, #41–#42, and #44–#46 were
reviewed fresh.
**Status:** Merged on `main`. Findings below were fixed in the follow-up
commit that ships with 0.5.0, except where marked left open.

## PRs in this release

| # | Title |
|---|---|
| 32 | Catalogue extension: Shop section and embedded schemas for `data["ecommerce"]` |
| 33 | Per-domain currency, stage Э1: conversion by provenance, frozen cart/order rates |
| 34 | ProductSource: catalogue-backed storefront, cart and Shopify sync (opt-in) |
| 35 | Storefront filters and variant picker on catalogue attribute sets |
| 36 | Shopify sync: images into Storage, variants → attribute sets, collections → categories |
| 37 | Settings page: rebuild toggle and option rows on a plain flex layout |
| 38 | Per-domain currency, stage Э2: storefront re-render on rate change, checkout drift notice |
| 39 | Per-domain currency, stage Э3: reprice the catalog on a base-currency change |
| 40 | Show product tags only on the default-language storefront |
| 41 | Gated admin edit links on storefront pages |
| 42 | Convert Shopify `body_html` to Markdown on sync |
| 43 | Standardize AGENTS.md onto the shared module skeleton |
| 44 | Storefront product page: buy box on the first screen, description under the gallery |
| 45 | AGENTS.md skeleton, buildable lockfile, and a test-helper preflight |
| 46 | Product page: 65/35 columns, description under the gallery, edit link by the cart |

## Summary

The tree is a real feature release: an opt-in catalogue product source, three
stages of per-domain currency, Shopify media/variants/collections, and a
reworked product page. Money is still `Decimal`, public LiveViews still call
`put_content_locale/1`, and the catalogue source still fails closed when the
optional package is absent. The problems were at the seams — USD sneaking
back onto catalogue items, facet queries disagreeing with the listing,
frozen FX amounts copied across cart currencies on login, and a handful of
storefront assign/render holes.

## Issues found and fixed

### 1. [BUG - MEDIUM] `"USD"` default reintroduced on catalogue items — FIXED
`ItemCommerce` stamped `default: "USD"` and the Shop section prefilled it.
Every extension-saved item in a EUR shop stored and displayed dollars, and
`View.product_view/2`'s base-currency fallback was dead. Dropped the schema
default, prefill from `get_base_currency/0` (blank if unset; rescues a
settings/DB miss so `render_component` tests do not need a sandbox), and
stopped `View.base_currency_code/0` from last-resorting to `"USD"`.

### 2. [BUG - MEDIUM] Facet/count visibility disagreed with the listing — FIXED
`active_visibility/1` required a literal `shop_status = 'active'` while the
listing used `COALESCE(..., 'active')`. An item created in catalogue admin
without the Shop section appeared in the grid and vanished from counts, the
price slider, and facets. Same COALESCE now.

### 3. [BUG - MEDIUM] Catalogue listing ordered by uuid, not position — FIXED
`filter_by_visible_categories/2` used `distinct: i.uuid`, which compiled to
`DISTINCT ON (uuid)` and prepended uuid to `ORDER BY`. Replaced with the
existing hidden-category subquery.

### 4. [BUG - MEDIUM] Category option_schema modifiers dropped at add-to-cart — FIXED
Catalogue reload in `lock_or_reload_product/2` omitted `preload: [:category]`,
so `get_option_schema_for_product/1` queried the empty legacy categories
table. The product page showed base+modifier; the cart snapshotted base.

### 5. [BUG - MEDIUM] Tags hidden on a non-canonical default dialect — FIXED
`tags_visible?/1` compared dialects. A shop whose default is `"en-GB"`
resolved the unprefixed page to `"en-US"` and hid tags on its own default
storefront. Comparison is now on `DialectMapper.extract_base/1`. The test
configures the default as `"en"` and covers `"en-GB"`.

### 6. [BUG - MEDIUM] Emptying a cart after the currency table is cleared crashed — FIXED
`fx_refresh_if_emptied/2` dereferenced `display.code` / `base.code` with no
nil guard. Mirrors `create_cart/1`: leave the frozen triple untouched.

### 7. [BUG - MEDIUM] `"100% OFF"` for a product with no price — FIXED
`compare_at/4` treated a nil asking price as zero. Nil now returns nil; a
genuine free product (`price` is zero) still computes the percent.

### 8. [BUG - HIGH] Conversion judged shipping on the display subtotal — FIXED
`get_available_shipping_methods/1` already converted to base;
`selected_shipping_method_available?/1` (the convert-time gate) did not. A
EUR cart holding a $138 product against a $130 `max_order_amount` was
excluded from the offer list but would have passed conversion on €125.45.

### 9. [BUG - HIGH] Login merge copied display amounts across cart currencies — FIXED
`merge_guest_cart/2` copied `unit_price` verbatim. A leftover USD user cart
plus a guest EUR cart mixed frames, and checkout charged the mix. New lines
now convert through the guest `base_unit_price` and re-snapshot at the user
cart's frozen rate. Also dropped a preload of the non-existent
`:payment_option` association, which crashed the merge path.

### 10. [BUG - HIGH] Open storefront tabs kept pre-reprice `product.price` — FIXED
`{:currencies_changed, _}` only refreshed `@currency`. Э3 rewrites stored
prices, so an open tab showed the old number while add-to-cart charged the
new one. Catalog, category, and product pages now reload their products
(product page also threads `:language` on refresh).

### 11. [BUG - HIGH] Product-page admin Edit vanished when the cart bar was off — FIXED
`storefront_bar/1` wrapped the Edit link in `shop_show_cart_bar`. Hosts that
turn that setting off (documented: header already links to the cart) lost
the only product Edit link. Edit now renders independently of the Shop/Cart
links. `maybe_assign_admin_edit/3` also passes `permission: "shop"`.

### 12. [BUG - HIGH] `mount_with_product/5` never assigned `:cart_count` — FIXED
The cross-language mount path rendered `@cart_count` without assigning it.
Same helper as the direct mount. Successful add-to-cart now updates
`:cart_count` (the previous `push_event("cart_updated")` had no JS hook).

### 13. [BUG - HIGH] Quantity row ignored "price on request" — FIXED
Headline used `PriceDisplay.render/4` with the product; the qty arithmetic
passed `nil` and printed `× 0.00 = 0.00`. On-request products no longer
show that arithmetic.

### 14. [BUG - HIGH] `create_from_shopify/2` stored raw HTML — FIXED
`ProductDiff` converts `body_html` to Markdown; create wrote it unchanged,
so new catalogue items reintroduced the opaque-`<p>` failure until a later
field sync. Create now converts, copies vendor/tags/compare-at, and parses
variant prices through `Decimal.parse/1` instead of `Decimal.new/1`.

### 15. [BUG - HIGH] HEAD image-URL check followed redirects without re-validation — FIXED
GET already re-validates every hop. HEAD used `Req.head/2`'s default
redirect following, so a public URL 302'ing to a private address was
probed. Same hop loop as GET.

### 16. [BUG - MEDIUM] Invalid HTML numeric entities crashed Shopify check — FIXED
`<<codepoint::utf8>>` raised on surrogates / out-of-range values.
`convert/1` now drops them.

### 17. [BUG - MEDIUM] A crash mid media-sync left the button disabled — FIXED
`perform/1` wrote `"finished_at" => nil` and had no `rescue`. An exception
after retries discarded the job but left progress open. `try/rescue` now
stamps `finished_at` via `fail_progress/2` before reraise.

### 18. [IMPROVEMENT - MEDIUM] `shop_enforce_product_currency` read directly — FIXED
Wrapped as `enforce_product_currency?/0` (fail-closed to `false`). Compat
delegate added; `get_base_currency()` parentheses fixed.

### 19. [IMPROVEMENT - MEDIUM] Unvalidated price modifiers could raise `Decimal.new/1` — FIXED
Override path now uses the existing safe `parse_decimal/1`.

### 20. [IMPROVEMENT - MEDIUM] Catalogue adapter ignored `:product_type` — FIXED
Filters `COALESCE(product_type, 'physical')`, matching `View.product_view/2`.

### 21. [IMPROVEMENT - MEDIUM] Vendor counts and price-range ignored hidden categories — FIXED
Both accept `:exclude_hidden_categories`; `aggregate_single_filter/2`
forwards it, same as attribute-set facets.

### 22. [IMPROVEMENT - MEDIUM] `cast/2` wiped unknown `data["ecommerce"]` keys — FIXED
`ItemCommerce` and `CategoryCommerce` merge the validated map over
`current`.

### 23. [IMPROVEMENT - MEDIUM] `CartItem.product_deleted?/1` lied for catalogue lines — FIXED
`metadata["catalogue_item_uuid"]` is treated as present. `product_changed?/2`
compares prices for those lines instead of returning true unconditionally.

### 24. [IMPROVEMENT - MEDIUM] Shipping methods were repriced but kept the old currency code — FIXED
`reprice_shipping_methods_for_base_change/3` now writes the new base code,
matching products.

### 25. [IMPROVEMENT - LOW] Cart page kept a stale `@currency` after empty-cart FX refresh — FIXED
`assign_cart_state/2` now re-resolves `currency_for_code(cart.currency)`.

## Left open (not blocking 0.5.0)

These are real, but they are design-sized or opt-in-catalogue-only, and
shipping a fix without a dedicated pass would be guessing:

- **Independent Shopify option modifiers do not reconstruct per-SKU prices.**
  `VariantMapper` treats modifiers as additive; Shopify prices a matrix.
  Needs a per-variant price table or a refuse/warn when reconstruction
  disagrees. Catalogue-source only.
- **Concurrent `images` + `variants` jobs can clobber `data["ecommerce"]`.**
  Uniqueness is per-kind. The LiveView already runs kinds one at a time;
  a second enqueue still races. Fix is a global lock / JSONB patch.
- **DNS-rebinding TOCTOU on image download.** `private_host?/1` resolves,
  then Req resolves again. Needs a pinned transport.
- **Shopify variant values are created `draft`.** Facets/pickers hide them
  until someone publishes. Intentional-looking, but the worker reports
  success.
- **Dashboard counts still read the legacy tables** under the catalogue
  source. The Products tab already redirects; the dashboard does not.
- **`set_uuid_for_key/1` lists every attribute set per filter.** Perf, not
  correctness.
- **Catalogue shops cannot change base currency.** `reprice_for_base_change/3`
  fail-closes unless Legacy is active — correct until a catalogue write
  pass exists.
- **Featured-item image on catalogue categories is a silent no-op.**
  Preload whitelist is `:category`/`:parent` only.
- **`"% OFF"` is hardcoded English** on the product page.

## What looks good

- Frozen FX on non-empty carts is consistent; Э2's rate re-render is the
  right tool for rate edits; checkout drift is live and does not rewrite
  the cart.
- Catalogue source is opt-in and fail-closed. No hard `PhoenixKitCatalogue`
  compile dependency.
- Filter values that reach SQL are bound. Search ILIKE is escaped, NULed,
  and capped.
- `maybe_assign_admin_edit/3` degrades on an older core without the helper.
- Image GET already re-validated redirects and blocked private ranges;
  HEAD now matches.
- Settings flex-row rebuild (PR #37) has no remaining broken-toggle markup.
