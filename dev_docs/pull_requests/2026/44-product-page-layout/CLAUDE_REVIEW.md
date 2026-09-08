# Code Review: PR #44 — Storefront product page: buy box on the first screen, description under the gallery

**Reviewed:** 2026-09-08
**Reviewer:** Claude (claude-fable-5-1)
**PR:** https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/44
**Author:** Timujeen (timujinne)
**Head SHA:** 246e45f
**Status:** Open

## Summary

Restructures `CatalogProduct.render/1`: a two-column grid (gallery | buy box) replaces the three-column one whose first column was the category sidebar; description, `body_html` and the specifications table move to full-width sections under the grid; the category navigation becomes a collapsed `<details>` panel gated by `shop_sidebar_show_categories` through a new `Helpers.sidebar_categories_enabled?/0` that `ShopCatalog` now shares; `by %{vendor}` becomes a gettext string; the "Manage Shop" msgid gets its four missing translations.

## Issues Found

### 1. [OBSERVATION] No test covered the new layout — FIXED
**File:** lib/phoenix_kit_ecommerce/web/catalog_product.ex lines 1108-1195
**Confidence:** 90/100

The first commit moved the description and specification blocks without a test asserting they still render, although the Markdown/HTML description path was the owner's stated regression concern. Fixed in 246e45f: `test/phoenix_kit_ecommerce/web/catalog_product_layout_test.exs` pins the document order (Add to Cart before the description), Markdown and sanitized-HTML rendering, the whitespace-only `body_html` guard, and the category panel honouring the setting.

### 2. [NITPICK] Setting default duplicated as a literal
**File:** lib/phoenix_kit_ecommerce/web/helpers.ex lines 203-211
**Confidence:** 60/100

`sidebar_categories_enabled?/0` carries the `"true"` default as a literal; it is now the single reader, so this is fine, only noting there is no shared constant should the default ever change.

## What Was Done Well

- Both `mount/3` paths assign `:show_categories?`, so neither the direct nor the cross-language mount can KeyError in render; `@categories` is always a list.
- The two `<.markdown>` calls were moved verbatim with the same `sanitize={not Policy.allow_raw_html_descriptions?()}` and `compact` attributes, so the sanitization policy is unchanged for Markdown and HTML content alike.
- `has_text?/1` is strictly more defensive than the previous truthiness checks (whitespace-only text no longer opens an empty block).

## Markdown/HTML regression check

No regression. Content reaches `<.markdown>` unchanged in both forms; verified by static reading of the diff and by the new LiveView test.

## Test run

`MIX_ENV=test mix test` with the database: 1060 tests, 0 failures, 131 excluded (`:catalogue`). An initial run with `PGPOOL=4` showed pool `queue_timeout` failures unrelated to the diff; `PGPOOL=20` reproduces the baseline.

## Verdict

Approved with fixes — the only finding was the missing regression test, added in a follow-up commit.
