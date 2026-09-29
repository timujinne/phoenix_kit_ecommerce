# PR #70: Translation sweep on phoenix_kit_ai's engine, category-tree lock, actor and activity through core

- **Author:** Max Don
- **Reviewer:** Claude
- **Merged as:** `98fd087`
- **Verdict:** correct as merged except for one race the new tick lock
  made wider. It was fixed after the merge, with a test. Two nitpicks are
  recorded and were deliberately not changed.

## Scope

- `Activity` delegates to core's `PhoenixKit.Activity.log/3` and
  `log_failed/3`, and reads the actor through `PhoenixKitWeb.Actor`. The
  core floor rises to `>= 2.38.0 and < 3.0.0`.
- `TranslationSweepWorker` becomes a source for
  `PhoenixKitAI.TranslationSweep`. The ai floor rises to `~> 0.24`.
- The category tree is locked with a transaction-scoped advisory lock
  for re-parents (single, bulk, and moves to root) and deletes, and the
  bulk broadcasts go out after the commit.
- Direct sweep ticks (Run sweep) take a transaction-scoped try-lock.
- There is a header trail (`Web.Trail`) on every shop admin page.

Checked and found correct:

- `in_category_tree/2` turns an `{:error, _}` into a rollback, and
  `update_category`/`delete_category` keep their return shapes. The
  cycle check in `Category.changeset` runs under the lock, on the
  transaction's connection.
- `reparenting?/2` normalizes `nil`/`""` and atom or string keys.
- `Activity.log/2` passes `:actor_role` through in its opts. Core
  ignores unknown keys, and the role reaches the row through the
  metadata.
- The page reads its result keys (`enqueued`, `errors`, `backed_off`,
  `batch`, `max_in_flight`) under the names the engine's `finish/3`
  records them.
- `sweep_prompts/0` admits one type when the other type's prompt fails.
  The engine counts the missing type's languages as errors.

## Findings

### BUG - MEDIUM: a scheduled tick overlapping a direct tick double-enqueues (fixed)

The engine refuses a direct tick while a scheduled one is executing
(`alone/2`), but not the other way round. Once a direct tick has passed
that check, a scheduled Oban tick can start next to it. Before this PR
the two would still have overlapped. The PR's tick lock made it worse:
it runs the whole direct tick inside one transaction, so every
`TranslateWorker` job it inserts stays invisible until it commits. The
scheduled tick's `in_flight/1` and `enqueue_all_missing/2` dedup cannot
see them. It counts none of them against the ceiling and enqueues the
same (resource, language) pairs again, which means paid model calls
twice.

**Fix:** `perform/1` now runs the tick's work under the same key,
waiting (`pg_advisory_xact_lock`), not trying. A scheduled tick that
starts during a direct one waits for the commit and then sees its jobs.
A direct tick during a scheduled one still gets `:sweep_running`. The
successor tick is scheduled *before* and *outside* that transaction, as
the engine's own `perform/1` does. The first attempt wrapped
`@engine.perform/1` whole, and the existing "schedules its successor
first even when the tick body raises" test caught the rollback of the
successor. New test: `translation_sweep_tick_lock_test.exs` "a scheduled
tick waits for a direct tick to finish".

### NITPICK: the engine's fail-open reads cannot fail open inside a transaction (not changed)

`in_flight/1` and `recently_failed/1` rescue a query error and carry on
with an empty result. Inside the tick's transaction, a Postgres error
aborts the transaction, so every later statement fails and the tick
raises instead. The only outcome is that a tick which would have
limped on now fails, and its successor is already scheduled. A
session-level lock on a checked-out connection would avoid the
transaction. It is not worth the extra machinery for an error path
that has never been seen, so it stays as it is.

### NITPICK: browser-tab titles on edit pages read "Edit" (not changed)

`page_title` also drives `<.live_title>`, so every edit page's tab says
"Edit" with no record name. Core's own admin forms follow the same
trail convention, and the header bar shows the full trail, so this
matches the host's other pages.
