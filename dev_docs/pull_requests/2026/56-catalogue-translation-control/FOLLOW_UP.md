# PR #56 follow-up — Catalogue translation control

Triage of `CLAUDE_REVIEW.md` against current code, by reading.

## Fixed (pre-existing)

- ~~#1 BUG - MEDIUM: the feature ignored the catalogue product source.~~
  `translations_supported?/0`
  (`lib/phoenix_kit_ecommerce.ex:1135-1136`) gates the adapters, the tick, the
  page and the settings toggle.
- ~~#2 IMPROVEMENT - MEDIUM: the page reloaded on every AI translation event
  from any module.~~ Only a terminal event for a shop resource reloads
  (`web/translations.ex:1321-1327`).
- ~~#3 IMPROVEMENT - MEDIUM: `enable_system/0` could crash on sweep
  scheduling.~~ `recover_translation_sweep/0`
  (`lib/phoenix_kit_ecommerce.ex:214`).
- ~~#4 IMPROVEMENT - MEDIUM: persistently failing candidates starved the
  sweep.~~ The sweep's chain and budget moved to
  `PhoenixKitAI.TranslationSweep`, which leaves a pair that failed in the last
  24 hours out of the candidates (`recently_failed/1` in `phoenix_kit_ai`).
- ~~#5 NITPICK: the PubSub live-status test could not fail.~~ Asserts on the
  row.
- ~~#6 NITPICK: the tick was scheduled on the dead render.~~ Connected mount
  only.
- ~~#11 NITPICK: AGENTS.md not updated.~~ Updated.
- ~~#12 BUG - MEDIUM (test harness): a second Oban broke the `:catalogue`
  media-panel suite.~~ It uses the suite-wide instance.

## Fixed (Batch 1 — 2026-10-13)

- ~~#8 NITPICK: the backfill's blankness test lacked the trim its hash
  uses.~~ Both queries pass the same trim characters
  (`mix_tasks/phoenix_kit_ecommerce.backfill_translation_fingerprints.ex:251-253`).
- ~~#9 NITPICK: client `uuids` on the bulk verbs were not cast.~~
  `cast_uuids/1` (`web/translations.ex:618-630`, `:847`;
  `test/phoenix_kit_ecommerce/web/translations_test.exs`).

## Skipped (with rationale)

- **#7 NITPICK: the sweep worker runs on `default`.** The review kept it and
  documented the exception in AGENTS.md.
- **#10 NITPICK: `unknown` fields are not write-protected.** The review
  recorded it as the design's own table, not a defect.

## Files touched

| File | Change |
|---|---|
| `lib/phoenix_kit_ecommerce/mix_tasks/phoenix_kit_ecommerce.backfill_translation_fingerprints.ex` | trim in the presence test |
| `lib/phoenix_kit_ecommerce/web/translations.ex` | uuids cast |

## Verification

`PGUSER=maxdon mix test` — 2891 tests, 0 failures. `mix precommit` (compile `--warnings-as-errors`, format, `credo --strict`, dialyzer) — exit 0, dialyzer 0 unnecessary skips. Run on the tree that carries this file.

## Open

None.
