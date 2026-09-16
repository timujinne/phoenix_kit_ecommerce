# Code Review: PR #57 — Keep the Shopify collection sync running when the catalogue refuses an assignment

**Reviewed:** 2026-09-15
**Reviewer:** Claude (claude-opus-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/57
**Author:** Max Don
**Merge SHA:** 1c8e21b (squash)
**Status:** Merged

## Summary

`CollectionSync.run/1` resolves its target categories (phase 1), fetches every
collection's product list, then assigns items (phase 2). A category trashed
between the two made `Catalogue.update_item/3` refuse the write, and the whole
run halted on that one item. The PR catches a changeset carrying a
`:category_uuid` error in `with_assignment/7`, logs a warning, leaves the item
where it is and continues. It adds a test that trashes the category from inside
the stub client, skipped against a catalogue that predates the refusal.

The refusal-handling itself is correct. Catalogue's `check_item_category/2`
refuses with a `:category_uuid` error in exactly the cases the PR means
(trashed, other catalogue), and the item's `foreign_key_constraint(:category_uuid)`
covers a category deleted outright, so the same branch catches all three. But
the PR's stated recovery path, "the next run resolves its categories afresh",
does not hold.

## Findings

### 1. BUG - HIGH — a trashed category fails every later run (fixed)

`resolve_categories/2` lists categories with
`list_categories_metadata_for_catalogue/2` in its default `:active` mode, which
drops trashed rows. On the run after a trash, the collection matches nothing
live, so `create_matched_category/6` inserts a new category with
`slug: %{primary => handle}`. The trashed category still owns that slug.
Catalogue's `sync_cat_category_slugs` trigger never looks at `status`, and the
projection's PK is `(lang, value)`, global across catalogues. The insert fails
`unique_constraint(:slug)`, `resolve_categories/2` halts, and the sync returns
`{:error, changeset}` on **every** run until someone empties the trash.

That is true whether or not the trash happened mid-run: trashing any category
that corresponds to an allowed collection breaks collection sync permanently.
The PR turns one failed run into a run that succeeds followed by an indefinite
series of failures, while documenting the opposite.

**Fix:** phase 1 now lists every category (`mode: :deleted`) and splits live
from trashed. A collection with no live match but a trashed one (same
slug-then-name rule as `find_category/4`) is skipped the way a filtered-out
collection is: logged, counted in the new `collections_skipped_trashed` result
key, its products never fetched, and the survivors re-indexed 0.. so positions
carry no gap. Re-creating the category was never an option. It would revive
what an operator removed, and it cannot succeed anyway. Restoring the category
brings the collection back on the next run. The `mode` option has existed since
catalogue 0.1.11, so no floor is needed.

Proved with the old lib: the new test "a collection whose category is in the
trash is skipped, not re-created" fails against `1c8e21b`'s `collection_sync.ex`
(see Verification).

### 2. IMPROVEMENT - MEDIUM — the test did not show the run carrying on (fixed)

The PR's fixture had one collection and one item, so it could not tell "skipped
the item and kept going" from "stopped after it with `{:ok, _}`". Its warning
also printed into the test output without being asserted.
`TrashingStub` now has a second collection, whose item is walked after the
refused one. The test asserts that item is assigned, and it captures and matches
the warning. The stub trashes through `Process.delete/1`, so it fires at most
once. The same stub drives the new test for finding 1.

### 3. NITPICK — the refusal match was wider than a refusal (fixed)

`Keyword.has_key?(errors, :category_uuid)` skipped a changeset that carried a
category error **and** any other error, silently dropping the other one.
`category_refused?/1` now requires every error to sit on `:category_uuid`.
Anything else halts, as before. In practice the sync writes only
`category_uuid` and `position`, so the mixed case is unlikely, but the fix is
one line.

### 4. NITPICK — stale worker moduledoc (fixed)

`ShopifyMediaSyncWorker`'s moduledoc still said `CollectionSync` "halts on a
write failure". It now names the exception.

### 5. On record, not changed

- **A refused item is not counted in the result map.** It exists only as a
  `Logger.warning`. With finding 1 fixed, a refusal happens only in the window
  between phase 1 and phase 2. The next run skips the trashed collection
  outright and counts it. A per-item counter would widen the five-element
  accumulator in every `assign_products/2` clause for a race the next run
  already reports.
- **A category moved to another catalogue still halts the next run.** Its slug
  still collides on create. This is pre-existing and deliberately pinned by
  "a create-path slug collision returns an error tuple instead of crashing": a
  collection whose handle belongs to another catalogue is an operator conflict
  that should surface, not be skipped.
- **The skip gate probes an unrelated function.**
  `function_exported?(Catalogue, :permanent_delete_scope, 1)` stands in for
  "refuses trashed categories". Nothing better is exported, and with no
  catalogue floor a capability probe is the only option. A rename in catalogue
  would quietly skip the test, not fail it.

## Verification

- `:catalogue` suite via the path bridge (`PHOENIX_KIT_CATALOGUE_PATH`,
  `PHOENIX_KIT_ENTITIES_PATH`): **219 tests, 0 failures**. `mix.lock` restored
  and `priv/media` removed afterwards.
- The two new tests against the PR's original `collection_sync.ex` (`1c8e21b`):
  **1 failure, "a collection whose category is in the trash is skipped, not
  re-created"** — finding 1 reproduced. The mid-run test passes there, as
  expected: it is the PR's own case.
- `mix precommit`: **passed** (format, `--warnings-as-errors`, credo --strict,
  dialyzer — 62 errors, all pre-existing entries in `.dialyzer_ignore.exs`).
- Full `mix test`: **1427 tests, 0 failures**.
