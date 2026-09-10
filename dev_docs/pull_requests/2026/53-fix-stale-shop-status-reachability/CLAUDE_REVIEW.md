# Code Review: PR #53 — Fix: catalogue-retired items with a stale shop_status stayed reachable

**Reviewed:** 2026-09-10
**Reviewer:** Claude (claude-sonnet-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/53
**Author:** Tymofii Shapovalov (timujinne)
**Merge SHA:** b631ee1
**Status:** Merged

## Summary

`View.product_status/2` consulted `shop_status` first and only fell back to
`item.status` when it was absent/unrecognized, so a catalogue item retired via
`item.status` (`"inactive"`, `"discontinued"`, `"deleted"`) with a stale,
left-over `shop_status: "active"` still derived `"active"` — reachable and
purchasable at its storefront URL, add-to-cart, and cart→order conversion
alike, all of which funnel through this same derivation. Live symptom: "Wall
Mounted Fairy Face Planter Shelf" (status `inactive`, `shop_status` `active`)
served 200 with add-to-cart working. The fix reorders: `item.status` is checked
FIRST — any non-active catalogue status forces `"archived"` unconditionally —
and `shop_status` is only consulted once the catalogue item is itself active,
so it can only restrict visibility further, never resurrect a retired item.

## Verification

- Read `product_source/catalogue/view.ex` in full and all four touched/added
  test files.
- Traced every funnel path `product_status/2` (via `product_view/2`) actually
  reaches: storefront mount, `add_to_cart` (`lock_or_reload_product` →
  `get_product/2`), and checkout conversion
  (`validate_catalogue_products_active/1`, called on locked rows inside the
  conversion transaction) — all three re-derive status fresh through the fixed
  function.
- Confirmed the new check (`item.status != "active"` forces `"archived"`) is
  negative/conservative and correctly covers every current AND future
  non-active value — no allow-list gap like the sibling category-side bug this
  review found (see Issue #1 below).
- Confirmed the `filter_by_status("active")` vs. `active_visibility/1`
  agreement regression test genuinely exercises both functions against the
  same fixture and would fail on divergence.
- Confirmed pre-existing cart lines are handled: `validate_catalogue_products_active/1`
  re-checks status at conversion time inside the transaction, so a cart line
  added before retirement cannot convert.
- **Checked for the category-side twin of this exact bug** — the commit's own
  "Live symptom" paragraph notes three discontinued items were coincidentally
  saved only because their categories happened to carry `shop_status: hidden`,
  an unrelated, coincidental gate; their own product status was equally broken
  before this fix. That phrasing implies category status derivation might carry
  the identical precedence flaw, unfixed. It does — see Issue #1.
- `mix precommit` and `mix test` clean after the fix below (part of the
  combined #49–#53 gate run).

## Issues Found

### 1. [BUG - HIGH] The identical stale-status bug exists on the category side and was not fixed by this PR — FIXED
**File:** lib/phoenix_kit_ecommerce/product_source/catalogue/view.ex, `category_view/2`
**Confidence:** 100/100

`category_view/2` computed `status: Map.get(ecommerce, "shop_status") || "active"`
— unlike the just-fixed `product_status/2`, this never read `category.status` at
all, not even as a fallback. A catalogue category soft-deleted at the catalogue
level (`category.status == "deleted"`, the category domain's only non-active
value) with a stale or absent `shop_status` resolved to `"active"`.

Verified the reachability path has no other guard: `Query.get_category/1` is a
single fetch by uuid with no status filter of any kind; the
`get_category_by_slug_localized/3` → `build_category/2` → `category_view/2`
chain is the same; `CatalogCategory.do_mount/3` gates only on the resolved
status being literally `"hidden"` — a deleted-but-not-explicitly-hidden
category's derived `"active"`/`"unlisted"` sails straight through and the page
renders normally, listing whatever products the (correctly-excluded-from-
listings) category still has, and linking to a page that renders. The listing
path (`Query.filter_by_category_status/2`) already guards this exact case —
`where([c], c.status != "deleted")`, with a comment stating the intent
explicitly ("a soft-deleted catalogue category can never be resurrected by a
stray shop_status") — but that guard was never carried into the single-category
read path.

This is the same class of bug just fixed for products in this same PR, in the
same file, left unfixed one function down. No test existed for a deleted
category's page reachability.

Fixed: `category_view/2`'s `:status` field now goes through a new
`category_status/2` that mirrors `product_status/2`'s precedence — `category.status
== "deleted"` forces `"hidden"` unconditionally (the resolved value
`CatalogCategory.do_mount/3` actually redirects on), and `shop_status` is only
consulted once the catalogue category is not deleted. Added regression tests:
`catalogue_view_test.exs` (unit-level, matrix over shop_status × deleted vs.
active catalogue status) and a new
`test/phoenix_kit_ecommerce/web/catalog_category_catalogue_status_test.exs`
mirroring the product-side `catalog_product_catalogue_status_test.exs` end to
end through a real `phoenix_kit_cat_categories` row soft-deleted via
`Catalogue.trash_category/2`. The end-to-end file is `:catalogue`-tagged and
requires a fully-migrated catalogue test database; it could not be run to
completion in this review environment (shared test DB predates the local
catalogue checkout's `slug` column, and this environment has no privilege to
create/migrate a fresh one) — the unit-level `catalogue_view_test.exs` coverage
of the same fix ran and passed.

## What Was Done Well

- The precedence fix itself (checking `item.status` first, `shop_status` only
  as a further restriction) is exactly right and matches the existing
  absent-shop_status fallback's own precedent, so it reads as a natural
  tightening rather than a new rule.
- The regression test pinning `filter_by_status("active")` against
  `active_visibility/1` on a no-shop_status fixture is a good "future
  regression fails a test instead of only showing up as a live count mismatch"
  guard, and it was actually placed correctly (same fixture, both call sites).

## Gate

`mix precommit` clean; `mix test` 1048 tests / 0 failures (201 excluded) after
the fix above (see combined #49–#53 gate run). The end-to-end category
reachability test is present but unverified in this environment for the DB-
migration reason noted in Issue #1 — flagged for whoever next has a fully
migrated `phoenix_kit_catalogue` test database available.
