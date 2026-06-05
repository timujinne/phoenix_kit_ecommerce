# Follow-up Items for PR #6

Source: [CODEX_REVIEW.md](CODEX_REVIEW.md) (Codex, 2026-06-05).

## Cleared (no change needed)

- **Dual `:changeset` + `:form` assign flow** — Codex confirmed no desync:
  `assign_form/2` derives both from the same changeset on mount/validate/
  save-error; `TranslationTabs` reads `@changeset`, the migrated core fields
  read `@form`. The multilang fields are unaffected. No action.

## Acknowledged / not changed (with rationale)

- **MED — `resolve_dialect/1` vs the broad `~> 1.7` pin.** Valid in principle,
  but **deliberately not changed**:
  - Every phoenix_kit feature module pins core as `{:phoenix_kit, "~> 1.7"}`
    by workspace convention and is expected to build against *current* core;
    tightening just this module's constraint would diverge from that.
  - The pre-fix code called `resolve_dialect/2`, which carried the same
    implicit "needs the core version that has this arity" requirement — the
    fix doesn't introduce a new class of coupling, it corrects a call that was
    already broken against current core (it was a `--warnings-as-errors` /
    dialyzer failure and a runtime `UndefinedFunctionError` on the localized
    catalog/product routes).
  - The minimum-version decision (and any pin bump) is the maintainer's to make
    at release time. Surfaced here for that call rather than changed unilaterally.

## Verification

`mix precommit` green — compile (warnings-as-errors), format, credo --strict,
dialyzer (0 errors, 0 skips). `mix test` — 185 tests, 0 failures.

## Open

None. (The MED above is surfaced for the maintainer's release-time pin
decision, not parked work.)
