# PR #57 follow-up — Keep the Shopify collection sync running when the catalogue refuses an assignment

Triage of `CLAUDE_REVIEW.md` against current code, by reading.

## Fixed (pre-existing)

- ~~#1 BUG - HIGH: a trashed category failed every later run.~~ Phase 1
  lists trashed categories too and skips a collection whose only match is in
  the trash, counted as `collections_skipped_trashed`
  (`lib/phoenix_kit_ecommerce/shopify/collection_sync.ex:64`,
  `workers/shopify_media_sync_worker.ex:637-649`).
- ~~#2 IMPROVEMENT - MEDIUM: the test did not show the run carrying on.~~
  `TrashingStub` has a second collection and the warning is captured
  (`test/phoenix_kit_ecommerce/shopify/collection_sync_test.exs`).
- ~~#3 NITPICK: the refusal match was wider than a refusal.~~
  `category_refused?/1` requires every error to sit on `:category_uuid`
  (`shopify/collection_sync.ex:486-489`).
- ~~#4 NITPICK: stale worker moduledoc.~~ It names the exception
  (`workers/shopify_media_sync_worker.ex:53-55`).

## Fixed (Batch 1 — 2026-10-13)

- ~~#5c: the skip gate probed an unrelated function
  (`permanent_delete_scope/1`), so a rename in catalogue would skip the
  trashed-category tests silently.~~ The gate probes the two functions those
  tests call, `update_item/3` and `trash_category/2`
  (`test/phoenix_kit_ecommerce/shopify/collection_sync_test.exs:227-233`). The
  sync itself calls `update_item`, so a rename there fails the ungated tests.

## Skipped (with rationale)

- **#5a: a refused item is not counted in the result map.** The review left
  it: with #1 fixed a refusal only happens between the two phases, and the
  next run skips and counts the collection.
- **#5b: a category moved to another catalogue still halts the next run.**
  The review left it and a test pins it on purpose: a handle owned by another
  catalogue is an operator conflict that should surface.

## Files touched

| File | Change |
|---|---|
| `test/phoenix_kit_ecommerce/shopify/collection_sync_test.exs` | skip gate probes the calls the tests make |

## Verification

`PGUSER=maxdon mix test` — 2891 tests, 0 failures. `mix precommit` (compile `--warnings-as-errors`, format, `credo --strict`, dialyzer) — exit 0, dialyzer 0 unnecessary skips. Run on the tree that carries this file.

## Open

None.
