# PR #15 follow-up — core version floor

Triage of `CLAUDE_REVIEW.md` against current code, by reading.

## Fixed (pre-existing)

- ~~**#1 BUG - HIGH** the billing floor `~> 0.1` admitted releases the code
  cannot run against~~ — superseded: `mix.exs:147` now requires
  `phoenix_kit_billing ~> 0.20`, and core is `>= 2.43.0 and < 3.0.0`
  (`mix.exs:118`).
- ~~**#2 IMPROVEMENT - MEDIUM** nothing in the suite could catch a low floor~~ —
  `test/phoenix_kit_ecommerce/dependency_floor_test.exs` exists and asserts
  against the resolved dependencies.

## Skipped (with rationale)

- **#3 NITPICK** the dep comment counted files instead of naming them — the
  reviewer left it; the floor and its comment have since been rewritten.

## Open

None.
