# PR #104 — module-neutral cart API declarations

Reviewed 2026-10-24 against `88a98ad`.
PR: https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/104

No new functional finding. Checked client-token declarations against core's
executor, checkout URL credentials against core's replay redaction, and the
capability checks that retain compatibility with older Tool structs. Core also
recognizes `*_token` output names as credentials, covering the creation response.
The cart store still verifies the signed token itself before using its digest.

The shared new-row quota uses the new core function when exported and the old
name dynamically otherwise. Public problem codes preserve their wire meanings.

Validation is recorded in [the recheck](../2026-10-24-merged-prs-recheck/CODEX_REVIEW.md).
