# PR #30 follow-up — module-owned V1 migration chain

Triage of `CLAUDE_REVIEW.md` against current code, by reading.

## Fixed (pre-existing)

- ~~**#1 BUG - MEDIUM** five `*_uuid_idx` names dropped core's schema-name
  embedding~~ — `indexes/2` (`migrations.ex:754`) routes the five through
  `exempt_unique_idx/5` (`:848`, `:885`, `:910`, `:953`, `:960`, defined at
  `:974`); `test/phoenix_kit_ecommerce/migrations_test.exs:111` checks a
  foreign prefix.
- ~~**#4 NITPICK** the chain was undocumented outside its moduledoc~~ —
  `AGENTS.md` has a "Database & migrations" section (`:645`) covering it.

## Skipped (with rationale)

- **#2 OBSERVATION** `up/1` ignores the `:version` option
  (`migrations.ex:135-140`) — still so, and the chain now has a V2, which is
  when the reviewer suggested revisiting. Consequence as the review states it:
  an old generated file replayed on a fresh database applies and stamps the
  current version; every statement is idempotent, so nothing breaks. Kept as
  the reviewer left it (the billing template's shape).
- **#3 NITPICK** `validated_prefix/1` raises `FunctionClauseError` for a
  non-binary prefix — unreached from core's call sites; left by the reviewer.

## Open

None.
