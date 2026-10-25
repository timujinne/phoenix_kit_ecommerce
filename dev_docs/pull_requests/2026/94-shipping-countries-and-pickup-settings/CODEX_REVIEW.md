# PR #94 — shipping country lists and pickup point settings

Reviewed 2026-10-24 against `88a98ad`, including later shipping-service changes.
PR: https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/94

No new functional finding. Checked country normalization, all-invalid and NULL
lists, overlap rejection, case-insensitive availability, provider-country
intersection, checkout defaults, hidden empty form inputs, and preservation of
stored country selections. Traced pickup point fields through dependent city
selection, asynchronous lookup, stale-result cancellation, selection validation,
and the settings changeset. Mutating admin events retain their capability gate.

Carrier integration discovery and cache invalidation follow the shop toggle.
`checkout_countries/0` retains its conservative `:all` answer for an unrestricted
method; actual method availability separately enforces excluded countries.

Validation is recorded in [the recheck](../2026-10-24-merged-prs-recheck/CODEX_REVIEW.md).
