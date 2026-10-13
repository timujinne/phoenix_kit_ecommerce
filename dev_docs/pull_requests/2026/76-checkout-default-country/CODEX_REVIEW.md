# PR #76: Checkout default country — independent review

- Reviewer: Codex, 2026-10-11
- Reviewed merge: `a3a4ac9`; Claude review/fix: `0b97f67`
- Verdict: approve with a compatibility fix.

## Findings

**BUG - MEDIUM: the new public helper was absent from the compatibility shim.**
`PhoenixKit.Modules.Shop.default_checkout_country/0` raised an undefined-function
error, although repository conventions require new context APIs to be available
under the transitional namespace. Added the delegate and an export regression
test alongside the other new APIs in #79/#81.

The country resolution itself is correct for the documented precedence:
company, policy fallback, an identical single-country restriction across active
methods, then the first configured priority country, with EE as the last resort.
Case normalization, unknown codes, unrestricted methods and duplicate country
entries are covered by the existing tests. The mount call remains behind the
cart's existing shipping country, so it cannot replace an established choice.

Validation and the combined review report are in
[the #77 review](../77-checkout-billing-profile-form/CODEX_REVIEW.md).
