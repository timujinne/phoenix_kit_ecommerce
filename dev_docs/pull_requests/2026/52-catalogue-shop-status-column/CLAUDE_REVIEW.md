# Code Review: PR #52 — catalogue: surface shop status as its own column

**Reviewed:** 2026-09-10
**Reviewer:** Claude (claude-sonnet-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/52
**Author:** Tymofii Shapovalov (timujinne)
**Merge SHA:** 014e79a
**Status:** Merged

## Summary

Adds a "Shop status" column to the catalogue admin's item/category lists via the
duck-typed extension-column slot (catalogue PR #103, unreleased upstream at the
time), surfacing `data["ecommerce"]["shop_status"]` next to the catalogue's own
`status` without synchronizing the two — they mean genuinely different things.
The PR's own history shows two review rounds: narrowing the warning badge from
"any disagreement" (22.6%/90% false-positive rate on live data) to only the one
real hazard — the shop reporting "active" while the catalogue doesn't, which is
excluded from listings but still reachable by direct link — and fixing the
category predicate from an allow-list shape (`shop_key == "active"`) to the
correct block-list shape (`shop_key != "hidden"`) matching
`CatalogCategory.do_mount/3`'s actual gate.

## Verification

- Read `catalogue/extension.ex` and `catalogue/shop_status_column.ex` (~309
  lines) in full, plus both test files.
- Re-derived the actual visibility/reachability logic from the real call sites
  (`CatalogProduct.do_mount/3`, `CatalogCategory.do_mount/3`,
  `Query.active_visibility/1`) rather than trusting the commit narrative.
- Cross-checked this PR's item-side warning predicate against **PR #53**
  (`b631ee1`, merged 15 seconds later, same author), which rewrote
  `View.product_status/2` to check `item.status` FIRST and force `"archived"`
  on any non-active catalogue status, unconditionally, regardless of
  `shop_status`. This closes the exact leak class the item-side "contradiction"
  badge exists to catch — see Issue #1.
- Verified the badge-color matrices are exhaustive over actually-reachable
  `(status, default?)` pairs, the "(default)" fallback still mirrors
  `product_status/2`/`category_view/2`'s real fallback behavior, duck-typing has
  no compile-time `PhoenixKitCatalogue` reference, and the gettext diffs are
  mechanical.
- `mix precommit` and `mix test` clean after the fix below (part of the
  combined #49–#53 gate run).

## Issues Found

### 1. [BUG - MEDIUM] Item-side "contradiction" warning is stale as of HEAD — invalidated by PR #53's own fix, 15 seconds later — FIXED
**File:** lib/phoenix_kit_ecommerce/catalogue/shop_status_column.ex, `render_item/1`
**Confidence:** 95/100

At the time this PR was written, `View.product_status/2` consulted
`shop_status` first, so an explicit `shop_status: "active"` could override a
non-active `item.status` and make the item reachable by direct link despite
being excluded from listings — the real leak this badge correctly caught.
**PR #53**, committed 15 seconds later by the same author, rewrote
`product_status/2` to check `item.status` FIRST unconditionally — closing that
exact leak. Traced through `CatalogProduct.do_mount/3` (redirects on any
resolved status `!= "active"`) and the listing query's `active_visibility/1`:
both now use the identical resolved-status predicate. For items, the
listing-exclusion condition and the direct-page-reachability condition are now
the same, so **no item-side contradiction can occur any more**.

Left as-is, the column would keep raising the warning badge — and the now-false
text "excluded from listings but may still be reachable by direct link" — for
any item with a non-active catalogue status and a leftover
`shop_status: "active"`, which is precisely the pattern PR #53's own bug report
says is real and common among retired items ("Wall Mounted Fairy Face Planter
Shelf": inactive/active). That reintroduces exactly the false-positive noise
the PR's own second review round was written to eliminate, just scoped
narrower.

Fixed: `render_item/1`'s `contradiction` is now always `false`, with a comment
explaining why (PR #53 closed the leak at the source). The moduledoc's "one
case that warrants a warning" section is rewritten to describe the category-
only warning that remains valid; the item side still shows the raw
catalogue/shop disagreement (for the admin's own information) but never flags
it as a hazard. Updated both test files: the two "WARNS" item tests now assert
no warning, the exhaustive item matrix test now asserts `contradiction` is
always `false`, and the shared "contradiction hint" test moved to a category
fixture (the only remaining case that can exercise it).

## What Was Done Well

- The category-side predicate (`shop_key != "hidden" and not catalogue_ok?`) is
  unaffected by the item-side fix and remains correct — `category_view/2` still
  has no dependency on `c.status` (see PR #53's review for the category-side
  twin bug this predicate correctly anticipates but doesn't itself fix).
- The moduledoc is unusually explicit about *why* item and category use
  different predicate shapes (allow-list page vs. block-list page), which is
  what made tracing the now-stale item predicate straightforward.
- The exhaustive-matrix test methodology (4×4 items, 2×4 categories over the
  real value sets) is exactly the right shape to catch this kind of precedence
  bug — it's what caught the category allow-list mistake in this same PR's
  in-flight review.

## Gate

`mix precommit` and `mix test` both clean after the fix (see combined #49–#53
gate run).
