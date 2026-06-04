# Follow-up Items for PR #3

Triaged against `main` on 2026-06-04 as part of the quality sweep.
Reviews: `CLAUDE_REVIEW.md` (Claude Sonnet 4.6), `MISTRAL_REVIEW.md`,
`PINCER_REVIEW.md` (all 2026-04-06). The three reviews overlap; findings
are consolidated by topic and re-verified against current code.

## Fixed (this sweep — 2026-06-04)

- ~~**`ignore_module_conflict: true` lacks a why/when-to-remove comment**~~
  (CLAUDE Medium / "Action item #1", MISTRAL §4, PINCER) — `mix.exs:13-19`
  now carries a multi-line comment that explains the option exists because
  `compat/shop.ex` intentionally redefines the core
  `PhoenixKit.Modules.Shop` namespace during the migration, and states the
  removal condition ("drop this once core no longer ships the old
  `PhoenixKit.Modules.Shop` namespace — then delete compat/shop.ex too").
  This is exactly the inline-comment + cleanup-plan the review asked for.
  Commit *"Add test infrastructure (DataCase, LiveCase, Test endpoint/
  router)"* (`62b5667`).
- ~~**`compat/shop.ex` has no marker for when the delegate list was last
  synced against the public API**~~ (CLAUDE Low / "Action item", MISTRAL
  §2) — `lib/phoenix_kit_ecommerce/compat/shop.ex:1-16` now opens with a
  "TRANSITIONAL DELEGATE SHIM — not a real module home" banner plus a
  MAINTENANCE NOTE instructing maintainers to re-audit the `defdelegate`
  list against the `PhoenixKitEcommerce` public API whenever that API
  changes (new public functions need a delegate; removed ones must be
  dropped). This is the re-audit marker the review requested. Commit
  *"Address PR review follow-ups (tax logging, compat marker)"*
  (`102acb9`).

## Fixed (pre-existing)

- ~~**`status_badge` → `import_status_badge` rename (compilation fix)**~~
  (CLAUDE §1) — verified correct in
  `lib/phoenix_kit_ecommerce/web/imports.ex`; the private helper no longer
  shadows the imported `Badge.status_badge/1`. Was the substance of the
  PR; nothing to change.
- ~~**`version/0` behaviour callback via `Application.spec/2`**~~
  (CLAUDE §4, PINCER, MISTRAL §1) — verified in
  `lib/phoenix_kit_ecommerce.ex`; reads `:vsn`, `to_string/1`s the
  charlist, guards `nil`. Idiomatic and correct as merged.

## Skipped / Deferred (with rationale)

Max is away and granted full autonomy for this sweep. The items below are
non-actionable observations or style preferences; none is a correctness
bug.

- **`defdelegate` gives no compile-time completeness guarantee**
  (CLAUDE §2 "Concern") — accurate but inherent to `defdelegate`; the
  review itself classified the risk as "acceptable" for transitional
  code, and dialyzer (run in `mix precommit`) catches stale delegates.
  The MAINTENANCE NOTE added above is the practical mitigation. No code
  change warranted.
- **`version/0` fallback `"0.0.0"` could be confused with a real
  version** (CLAUDE "Info") — the review's own note says it "matches the
  documented behaviour default" and is "not blocking". Left as-is to match
  the `PhoenixKit.Module` default.
- **CountryData alias changed and reverted within the branch (history
  noise)** (CLAUDE "PR history") — a git-history observation, not a code
  defect. The final state is correct (`PhoenixKit.Utils.CountryData` in
  `checkout_page.ex`); nothing to change.
- **`select` class still present after `select-bordered` removal**
  (PINCER §1) — daisyUI 5 handles the bare `select` class; the C0 visual
  baseline renders correctly. Cosmetic, no change.

## Files touched

| File | Change |
|------|--------|
| `mix.exs` | Expanded the `ignore_module_conflict: true` comment with rationale + removal condition |
| `lib/phoenix_kit_ecommerce/compat/shop.ex` | Added transitional-shim banner + re-audit MAINTENANCE NOTE |

## Verification

`mix precommit` green — compile (warnings-as-errors), `mix format`,
`credo --strict`, and `dialyzer` (0 errors; "Unnecessary Skips: 1" is a
stale `.dialyzer_ignore.exs` entry, not a failure). `mix test` — 126
tests, 0 failures.

## Open

None.
