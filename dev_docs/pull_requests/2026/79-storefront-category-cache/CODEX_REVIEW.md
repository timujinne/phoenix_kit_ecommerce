# PR #79: Storefront cache and category-image query — independent review

- Reviewer: Codex, 2026-10-11
- Reviewed merge: `224e0c1`; Claude review: `3fc2b2b`
- Verdict: approve with a compatibility fix; no additional query/cache bug found.

## Findings

**BUG - MEDIUM: `children/0` was missing from the transitional namespace.**
Added `PhoenixKit.Modules.Shop.children/0` and verified that it returns the
same cache child specs as the main module. Core's normal discovery uses the
main module; the fix maintains the documented shim contract.

The SQL image projection follows the old first-image rule, filters active
visibility and retains category/position/name ordering. Its result carries
only one image-bearing row per category. Existing integration tests compare
the query with the original Elixir selection across malformed image metadata
and visibility cases.

The cached category and facet values contain no customer identity. Keys carry
the product source, relevant options and facet language; URL-supplied locales
outside the enabled language set bypass storage. Core's `remember/4` computes
misses in the caller, guards fills with a cache generation and preserves
computation exceptions. Cache absence falls back to direct loading.

**NITPICK, retained:** invalidation is node-local; external catalogue writes,
background sync jobs and language changes rely on the approximately one-minute
TTL. This is documented, bounded freshness rather than an authorization issue.
No cluster-wide invalidation was added.

Validation and the combined review report are in
[the #77 review](../77-checkout-billing-profile-form/CODEX_REVIEW.md).
