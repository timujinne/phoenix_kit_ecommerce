# Code Review: PR #47 — Shopify sync: refuse to write prices from a store in another currency, and reuse images shop-wide

**Reviewed:** 2026-09-09
**Reviewer:** Claude (claude-sonnet-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/47
**Author:** Tymofii Shapovalov (timujinne)
**Merge SHA:** 6093d87
**Status:** Merged

## Summary

Two independent fixes stacked on the catalogue-source Shopify sync path:

1. **Shop-wide image reuse.** `Catalogue.Writer.sync_images/3`'s "already downloaded?" lookup was scoped to files linked to the one product being synced. Shopify shops routinely reuse one image `src` across an entire product line, so a 665-product live run re-downloaded 582 already-stored images. The lookup now matches any active Storage file in the shop by `metadata["source_url"]`, and `ShopifyMediaSyncWorker` builds that index once per run (`Writer.build_url_index/0`) rather than once per product, threading it forward as each product's downloads grow it.
2. **Currency guard (per-domain-currency design §7.5).** `Shopify.Sync.apply_change/3`/`apply_changes/3` now look up the connected store's own currency (`AdminClient.fetch_shop/2`) once per batch and refuse to write `:price`/`:compare_at_price` — or refuse a whole create, or a whole `sync_variants/2` price-modifier pass in `ShopifyMediaSyncWorker` — when it disagrees with the base currency. A currency *mismatch* logs at `warning` (an admin decision); a failed *lookup* logs at `error` and fails open, so a rotted token can't silently disable the guard without a trace. `Catalogue.Writer.create_from_shopify/2` also labels every newly-created item with the base currency.

Also folded in: converting `body_html` to Markdown on the create path (previously only the update/diff path normalized it, so a freshly created item's description printed literal `**`), and extracting the new currency-mismatch flash through gettext across all five locales.

## Verification

- Read every changed file with surrounding context (not just hunks); cross-checked each commit-message claim against the actual diff — all held up, including the specific ones that are easy to get subtly wrong: `resolve_priced_fields/3`'s "only refuse if *every* requested field was a price field" branching, `currency_verdict/1`'s three-way fold of match/no-connection/lookup-failure into `:match`, the `req_options` → `admin_options` re-nesting in the worker, and that `"collections"` never reaches the currency lookup at all.
- `mix precommit` (format, `compile --warnings-as-errors`, `credo --strict`, dialyzer) — clean.
- `mix test` — 961 tests, 0 failures.
- Confirmed the msgid `"Could not update %{title}'s %{field}: the store is now in %{shop_currency}..."` actually landed in all five `priv/gettext/*/LC_MESSAGES/default.po` catalogues with real (non-fuzzy) translations, per the repo's own i18n regression rule (PR #26).
- Ran the suite a second time with the optional `phoenix_kit_catalogue`/`phoenix_kit_entities` path deps enabled (`PHOENIX_KIT_CATALOGUE_PATH`/`PHOENIX_KIT_ENTITIES_PATH`) to actually exercise the `:catalogue`-tagged tests this PR's core logic lives behind (`writer_images_test.exs`'s `url_index` reuse test, `sync_currency_test.exs`'s create-label and mismatch tests, `writer_test.exs`'s create-path Markdown test). That run hit 99 failures, all `undefined_column "slug"` on `phoenix_kit_cat_items`/`phoenix_kit_cat_categories` — reverted the PR's files to the pre-merge commit (a6cee99) with the same env vars and got the identical failure on 6 of the same tests, confirming this is a pre-existing local schema drift between this workspace's `phoenix_kit_catalogue` checkout and its own migrations, not something PR #47 introduced. Restored the working tree afterward (`git status` clean).

## Issues Found

### 1. [NITPICK] Stale doc reference to a function that no longer exists — FIXED
**File:** lib/phoenix_kit_ecommerce/catalogue/writer.ex, `build_url_index/0`'s `@doc`
**Confidence:** 95/100

The doc for `build_url_index/0` said *"`merge_url_index/2` folds the files a product just downloaded into it"* — but the merge is inline (`Map.merge(url_index, fresh_urls)` in `do_sync_images/3`) and no `merge_url_index/2` function exists anywhere in the module. Harmless (nothing calls it), but it would send a future reader looking for a function that isn't there. Fixed: the doc now points at `sync_images/3`'s own `:url_index` result key instead of the phantom function name.

## What Was Done Well

- The currency guard is genuinely field-scoped, not change-scoped: a change that touches both `:title` and `:price` still writes the title on a mismatch, only the price is dropped — verified by reading `resolve_priced_fields/3` against its three branches (no price field requested / some-but-not-all-fields-priced / all-fields-priced) and the integration test at `shopify_sync_test.exs` that asserts the flash *and* that the price stays untouched.
- The fail-open lookup-failure path is deliberately distinguished from the fail-closed mismatch path at the log level (`warning` vs `error`), with the reasoning spelled out in a comment tracing back to an actual operational risk (an operator who tunes out currency-guard warnings would never notice the guard went inert). This is the kind of judgment call that's easy to get backwards, and it's right here.
- A second, easy-to-miss price-writing path (`ShopifyMediaSyncWorker`'s `"variants"` kind, which calls `Writer.sync_variants/2` directly and bypasses `Sync.apply_change/3` entirely) was caught and guarded in a follow-up commit rather than left as a gap — the commit history shows this was caught by a prior review pass on the same PR, and it stayed fixed here.
- The shop-wide image index is built once per run and threaded through the reduce accumulator rather than rebuilt per product or per-item-scoped, with the perf rationale (2900 rows, no `source_url` index, would be one full scan per product) stated up front — and locked in by a test that asserts a second product reusing the same `src` triggers zero downloader calls.
- Every one of the PR's own narrative claims (the 665/582 live-run numbers, "collections never attempts the lookup", "the USD fallback matches View's own fallback", the five-locale i18n extraction) checked out against the actual code and tests on inspection — nothing oversold.

## Gate

`mix precommit` and `mix test` both clean (see Verification). No release was requested for this task — review only.
