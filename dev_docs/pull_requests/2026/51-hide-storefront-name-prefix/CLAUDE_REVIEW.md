# Code Review: PR #51 — Hide a configurable storefront name prefix at display time

**Reviewed:** 2026-09-10
**Reviewer:** Claude (claude-sonnet-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/51
**Author:** Tymofii Shapovalov (timujinne)
**Merge SHA:** 703aefe
**Status:** Merged

## Summary

Adds `shop_name_prefixes` (comma-separated, empty by default, e.g.
"3D Printed, 3D") stripped from product/category names at STOREFRONT DISPLAY
TIME only, via `NamePrefix.strip/1` and `Translations.get_display/3` — never at
the stored-name level, since re-syncs from Shopify own these names and must
never be fought by a cosmetic rename. This PR's own history shows an in-flight
review found the prefix reappearing at cart/checkout/confirmation (which render
a snapshotted `product_title`/`"name"` string directly, never through
`get_display/3`) and fixed four sites (`cart_page.ex`, `checkout_page.ex`,
`checkout_complete.ex`, `user_order_details.html.heex`). It also switched prefix
matching from first-configured-wins to longest-applicable-wins and added the
em-dash to the separator set.

## Verification

- Read `name_prefix.ex`, `translations.ex`, and all ten touched web files in
  full.
- Grepped the whole `lib/phoenix_kit_ecommerce/web/` tree for every remaining
  raw `Translations.get(..., :title/:name, ...)` call and every direct
  `product_title`/`item["name"]` access, hunting for a missed storefront site.
  Every remaining raw call site is admin-only or the Shopify diff/apply path
  (correctly excluded by design); every storefront call site routes through
  `get_display/3`; cart/checkout/confirmation/order-history snapshot fields are
  each stripped at their one render site.
- Checked `notifications.ex`'s `product_name/1` (admin "New cart
  started"/"Added to cart" messages) — intentionally still raw, since these go
  only to admins, never the buyer. Its own comment ("shows the same name a
  shopper saw") is now mildly stale (a shopper with a prefix configured sees
  the *stripped* name) but the actual admin-raw behavior is correct by design —
  not filed as a finding, just noted.
- Verified the longest-match algorithm (`strip_longest`/`strip_one`/
  `boundary?`) picks the max by prefix length over the FULL candidate set, not
  first-found, so `"3D, 3D Printed"` vs `"3D Printed, 3D"` configuration order
  can't change the outcome; the boundary check correctly rejects a partial-word
  match ("3D Printedstuff").
- Confirmed no double-strip or write-path leakage: Shopify diff/sync and
  category name-matching tests assert raw values; admin index/edit/detail
  pages assert raw names too.
- Confirmed settings normalization (trim, drop blank entries from
  double-commas, rejoin) is correct and tested.
- Confirmed no `gettext()` wrap around the setting key/value — only UI copy.
- `mix precommit` and `mix test` clean (part of the combined #49–#53 gate run).

## Issues Found

None. No bugs survived scrutiny — the PR's own in-flight review round already
caught and fixed the real gap (cart/checkout/confirmation snapshots).

## What Was Done Well

- The longest-applicable-wins rewrite is a genuine correctness fix over
  first-configured-wins, not just a preference — it removes a real
  configuration-order footgun ("3D, 3D Printed" leaving a dangling "Printed
  Costume Masks" fragment).
- Coverage of the snapshot-vs-live distinction is exactly right: the PR is
  careful that the STORED snapshot string is never rewritten (so a re-sync from
  Shopify can never diverge from a cosmetic rename), while every render path a
  shopper can see is covered.

## Gate

`mix precommit` and `mix test` both clean (see combined #49–#53 gate run).
