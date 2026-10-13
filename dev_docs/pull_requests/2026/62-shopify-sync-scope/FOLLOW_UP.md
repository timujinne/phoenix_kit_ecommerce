# PR #62 follow-up — Shopify sync scope, per-kind progress, New in Shopify

Triage of `CLAUDE_REVIEW.md` against current code, by reading.

## Fixed (pre-existing)

- ~~IMPROVEMENT - MEDIUM: saving the sync scope wrote no activity row.~~
  `shop.shopify_sync_scope_saved` (`lib/phoenix_kit_ecommerce/web/shopify_sync.ex:354`).
- ~~BUG - MEDIUM: a non-string tag or product-type entry crashed
  `SyncScope.get/0`.~~ `normalize_list/1` keeps binaries only
  (`shopify/sync_scope.ex:238-246`).
- ~~NITPICK: "Nothing new" shown for a run that matched nothing.~~
  `nothing_new?` also needs a match (`web/shopify_sync.ex:1313`).
- ~~NITPICK: template-local `status` binding in the media panel.~~ Built in
  `render/1` as `@media_sync_rows` (`web/shopify_sync.ex:1255`, `:2037`).

## Fixed (Batch 1 — 2026-10-13)

- ~~Not changed, pre-existing: a job killed mid-run left its kind's button
  disabled until another run finished.~~ A kind is "in flight" only while its
  progress record is unfinished AND an incomplete Oban job of that kind exists
  (`workers/shopify_media_sync_worker.ex:238`, `web/shopify_sync.ex:1222`); a
  record without a job reads "Interrupted" and the button works
  (`web/shopify_sync.ex:2616`;
  `test/phoenix_kit_ecommerce/web/shopify_sync_media_panel_test.exs`).

## Skipped (with rationale)

- **NITPICK: `ProductDiff.parse_tags/1` reads an unknown shape as `[]`**
  (`shopify/product_diff.ex:449-453`). The review left it: the Admin REST API
  always sends a string and every diff still needs an operator to apply it.

## Files touched

| File | Change |
|---|---|
| `lib/phoenix_kit_ecommerce/workers/shopify_media_sync_worker.ex` | `incomplete_kinds/0` |
| `lib/phoenix_kit_ecommerce/web/shopify_sync.ex` | in-flight rule, "Interrupted" state |

## Verification

`PGUSER=maxdon mix test` — 2891 tests, 0 failures. `mix precommit` (compile `--warnings-as-errors`, format, `credo --strict`, dialyzer) — exit 0, dialyzer 0 unnecessary skips. Run on the tree that carries this file.

## Open

None.
