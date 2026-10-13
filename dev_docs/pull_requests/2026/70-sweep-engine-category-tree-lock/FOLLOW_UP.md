# PR #70 follow-up — Translation sweep on phoenix_kit_ai's engine, category-tree lock, actor and activity through core

## Fixed (pre-existing)

- ~~BUG - MEDIUM: a scheduled tick overlapping a direct tick double-enqueued.~~
  `lib/phoenix_kit_ecommerce/workers/translation_sweep_worker.ex:134-146` —
  `scheduled_tick/0` schedules its successor first, then runs the tick inside
  a transaction that waits on `pg_advisory_xact_lock` under the same key the
  direct tick try-locks (`tick_lock?/0`, `:149-155`). Regression test:
  `test/phoenix_kit_ecommerce/translation_sweep_tick_lock_test.exs`.

## Not changed by the reviewer (design notes, not defects)

- The engine's fail-open reads cannot fail open inside the tick's
  transaction. Still so; the review judged a session-level lock not worth the
  machinery.
- Edit pages' browser-tab titles follow the host's header-trail convention.

## Open

None.
