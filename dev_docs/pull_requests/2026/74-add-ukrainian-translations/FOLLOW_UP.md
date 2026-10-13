# PR #74 follow-up — Add Ukrainian (uk) translations

## Fixed (pre-existing)

All round-1 and round-2 findings were closed inside the PR; re-verified
against the current tree:

- ~~BUG - MEDIUM: four plural entries hard-coded "1".~~
  `priv/gettext/uk/LC_MESSAGES/default.po:140`, `:148`, `:156`, `:4334` — each
  `msgstr[0]` carries `%{count}`. Guarded by
  `test/phoenix_kit_ecommerce/i18n_test.exs:213`.
- ~~IMPROVEMENT - MEDIUM: `#,` flags missing.~~ The catalogue carries
  `elixir-autogen` flags (1226 entries).
- ~~IMPROVEMENT - MEDIUM: «Переоцінити».~~ No `переоцін` form remains in the
  catalogue.
- ~~Post-merge (`CLAUDE_POST_MERGE_REVIEW.md`): `uk` was five msgids short of
  the template after #75.~~ `uk` and `default.pot` both hold 1229 msgids; the
  five pay-on-delivery strings are translated; guarded by
  `i18n_test.exs:185` ("carries every msgid in the template").
- ~~NITPICK: the new test sat under the fuzzy test's comment.~~ Closed in
  round 3.

## Open

None.
