# PR #81: Stock tracking switch — independent review

- Reviewer: Codex, 2026-10-11
- Reviewed merge: `680229e`; Claude review: `3fc2b2b`
- Verdict: approve with a compatibility fix.

## Findings

**BUG - MEDIUM: both new context helpers missed the compatibility shim.**
Added delegates for `stock_tracking_enabled?/0` and `warehouse_status/0`, with
an export regression test shared with the other APIs added by this PR group.

Verified the settings event's `manage_settings` authorization and success-only,
PII-free activity row. The context refuses enabling without an enabled
Warehouse, fails closed on read/probe errors and allows disabling regardless
of Warehouse state. Variable-module calls avoid hard references to optional
Warehouse APIs. Both APIs are present in the locked Warehouse dependency.

The switch's effective value reflects the setting and Warehouse availability;
this PR does not itself add stock reservation or warehouse mutation to
checkout. The disabled UI when Warehouse is unavailable is deliberate, as
Claude documented. The optional dependency's transitive catalogue packages
make catalogue integration tests run in the default suite.

Validation and the combined review report are in
[the #77 review](../77-checkout-billing-profile-form/CODEX_REVIEW.md).
