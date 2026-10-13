# PR #80: Shopify off by default — independent review

- Reviewer: Codex, 2026-10-11
- Reviewed merge: `44b2a2c`; Claude review: `3fc2b2b`
- Verdict: approve; no additional defect found.

Checked the settings wrapper, provider callbacks, UI gate, V3 SQL and the
integration-row producer in core. Missing or failing settings reads disable
Shopify. The upgrade detects existing Shopify integration rows or linked
catalogue/legacy products and inserts an enabled setting only when none
exists. Explicit false values survive; the SQL uses the validated prefix,
guards optional tables and is idempotent. Rollback preserves the setting.

The integration tests exercise fresh installs, existing connections, both
product sources, explicit overrides, repeated execution and a schema without
the optional product tables. No token or connection is deleted by the toggle.

The changelog correctly tells upgrading hosts to run `mix phoenix_kit.update`:
skipping V3 can hide the existing Shopify integration until it is enabled
manually. This remains an upgrade requirement.

Validation and the combined review report are in
[the #77 review](../77-checkout-billing-profile-form/CODEX_REVIEW.md).
