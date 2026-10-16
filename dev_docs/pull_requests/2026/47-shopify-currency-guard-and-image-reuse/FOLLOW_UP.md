# PR #47 follow-up — Shopify sync: currency guard and shop-wide image reuse

Triage of `CLAUDE_REVIEW.md` against current code, by reading.

## Fixed (pre-existing)

- ~~#1 NITPICK: `build_url_index/0`'s doc named a `merge_url_index/2` that
  does not exist.~~ No reference to it remains in `lib/`.

## Fixed (Batch 1 — 2026-10-13)

Not a finding of the review; found on the same path during the sweep.

- ~~A catalogue item created by the sync was labelled `USD` when the shop
  had no base currency, and the comment claimed the storefront fell back the
  same way.~~ `Writer` leaves the currency off the created item when there
  is no base (`lib/phoenix_kit_ecommerce/catalogue/writer.ex`).

## Files touched

| File | Change |
|---|---|
| `lib/phoenix_kit_ecommerce/catalogue/writer.ex` | no `USD` label without a base currency |

## Verification

`PGUSER=maxdon mix test` — 2891 tests, 0 failures. `mix precommit` (compile `--warnings-as-errors`, format, `credo --strict`, dialyzer) — exit 0, dialyzer 0 unnecessary skips. Run on the tree that carries this file.

## Fixed (Batch 2 — 2026-10-14)

- ~~Whether the sync should refuse priced creates when the shop has no base
  currency.~~ It does: `currency_verdict/1` answers `:missing_base_currency`
  before any shop lookup; creates are refused, price fields dropped from
  updates, the variants sync writes no modifier (`shopify/sync.ex`,
  `workers/shopify_media_sync_worker.ex`); the sync page shows a banner and
  disables the price actions (`web/shopify_sync.ex`). Existing damage is
  listed read-only by `mix phoenix_kit_ecommerce.list_unstamped_prices`.

`PGUSER=maxdon mix test` — 3099 tests, 0 failures. `mix precommit` — exit 0 (dialyzer 0 unnecessary skips). Run on the tree that carries this batch.

## Open

None.
