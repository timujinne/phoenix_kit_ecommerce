# PR #29 follow-up — slugs from the title head, regenerate_slug/3

Triage of `CLAUDE_REVIEW.md` against current code, by reading.

## Fixed (pre-existing)

- ~~**#1 BUG - MEDIUM** a projected slug collision raised
  `Ecto.ConstraintError`~~ — both slug writes go through `slug_changeset/2`,
  which names the projection pkey (`ai_translatable.ex:429`, `:500-503`,
  `:529`). The two remaining bare `Ecto.Changeset.change/2` calls (`:245`,
  `:289`) write `metadata` only.

## Skipped (with rationale)

- **#2 OBSERVATION** `unique_slug/3` checks the exact jsonb key while the
  constraint buckets by base language — deliberately not mirrored; with the
  constraint named, a mismatch is a changeset error.
- **#3 OBSERVATION** `regenerate_slug/3` writes no activity entry
  (`ai_translatable.ex:526-536` broadcasts only) — still so. Conditional on the
  bulk repair task that would supply an actor: nothing in `lib/` calls
  `regenerate_slug/3` today. Add the log when a caller with an actor lands.
- **#4–#6, #8 OBSERVATION** dry run takes the row lock; the identity tail can
  push a slug past 60; the tail source is map-order when the default language
  has no slug; head-first assumes the product name leads — recorded as
  limitations by the reviewer.
- **#7 NITPICK** the moduledoc says `regenerate_slug/2`
  (`ai_translatable.ex:17`) — still so; the `/2` head exists.

## Open

None.
