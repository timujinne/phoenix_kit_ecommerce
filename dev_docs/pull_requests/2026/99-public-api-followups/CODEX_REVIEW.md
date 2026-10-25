# PR #99 — public API follow-ups

Reviewed 2026-10-24 against `88a98ad`.
PR: https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/99

No new functional finding. Traced option labels through product loading,
`CartOptions`, cart responses, and the claim page, including stored-label
fallbacks for unavailable selections. Per-value reference prices use the same
pricing functions as cart additions and document that independently priced
values are not additive.

Checked the `facets: false` path, optional response schema, indexed option-pair
probes, bounded warning lists, and batch vocabulary cleanup in `after`.
Credential-bearing cart operations give up replay on supporting cores.

Validation is recorded in [the recheck](../2026-10-24-merged-prs-recheck/CODEX_REVIEW.md).
