# PR #118 — build the shop chain on a fresh core 3.x database

Reviewed 2026-11-11 against `main` at `31f5342`.
Author: Max Don (`mdon`).
PR: https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/118
Merge: `bf6546a`; subsequent fixes included in this review.

Applied the Ecto review skill. Checked the migration entry point, billing's
resolved 0.25.0 chain, version and prefix handling, existing migration digests,
and the test harness's ordering of required and optional migration chains.

No additional code defect found in this PR. `up/1` ensures billing's payment
options exist before the shop adds its foreign key. The SQL-only
`up_statements/2` remains independent of billing's chain, preserving shipped
digests and the test harness's explicit chain ordering. Re-running the entry
point leaves deleted merchant seeds deleted. The existing integration tests
exercise a fresh prefixed schema with no billing tables and each target version.

The engineering guide still claimed that core always creates the baseline shop
tables, and its overview listed the obsolete core and billing requirements.
Corrected those descriptions to match core 2.x/3.x ownership and `mix.exs`.
No shipped SQL changed.

Validation and the findings from newer stock and email commits are recorded in
[the recent-changes review](../2026-11-11-recent-changes/CODEX_REVIEW.md) and its
[follow-up](../2026-11-11-recent-changes/FOLLOW_UP.md).
