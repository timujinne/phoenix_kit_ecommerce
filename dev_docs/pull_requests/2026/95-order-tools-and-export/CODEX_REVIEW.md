# PR #95 — order tools and export

Reviewed 2026-10-24 against `88a98ad`, including Claude's `8e6e74f` follow-up.
PR: https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/95

No new functional finding. Checked tool availability and permissions, the
separate customer-data scope, UUID/number reference validation, cursor ordering
and timestamps, independent batch results, sync revision checks, dry-run
fingerprints, and error logging. Traced exported fields back to checkout's order
line and metadata snapshots, including taxability, price on request, shipping,
and selected option labels and keys.

Claude's added option export preserves the stored selection without looking its
labels up in a changed product. The previously documented Legacy-source product
identifier limitation remains: old order lines carry the SKU, but no product UUID.

Validation is recorded in [the recheck](../2026-10-24-merged-prs-recheck/CODEX_REVIEW.md).
