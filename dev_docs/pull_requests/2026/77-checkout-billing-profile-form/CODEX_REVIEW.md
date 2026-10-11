# PRs #76, #77, #79, #80 and #81: independent review of Claude's work

- Reviewer: Codex, 2026-10-11
- Starting revision: `3fc2b2b` on `main`; working tree initially clean
- Reviewed Claude commits: `0b97f67`, `3fc2b2b`
- Verdict: Claude's billing-floor fix is correct; additional fixes were needed.

## Findings and fixes

### BUG - MEDIUM: fields hidden by the billing type still blocked checkout (#77)

`billing_changeset/1` validated the complete draft, while `clean_for_type/2`
removed inactive-type fields only after validation succeeded. A shopper who
entered an invalid company VAT number such as `12-34`, then switched to
individual, could not proceed despite completing every visible field. An
overlong individual name similarly blocked a company order with no visible
name field to correct.

Applied `clean_for_type/2` before billing's changeset runs. The full draft stays
in socket state while editing, so switching back preserves the customer's
input. Existing cleanup still prevents inactive-type fields reaching the
snapshot or saved profile. Two failing-before-fix LiveView tests now verify
successful individual snapshot checkout and saved company checkout, including
preservation of the individual draft when switching back.

### BUG - MEDIUM: shipping recovery could still strand a shopper on the cart

This is a pre-existing gap in the checkout module touched by #76/#77, rather
than a regression introduced by either PR. The review-entry recovery already
respected `shipping_selection_position`, but mount and conversion-error
handlers still redirected unavailable shipping to `/cart`. Under `checkout`
the cart has no picker. A method disabled after review, or an unavailable
selection carried into a new checkout mount, sent the shopper into that loop.

Checkout-position mounts now clear an unavailable selection and initialize
checkout normally. Conversion errors `:no_shipping_method` and
`:shipping_method_unavailable` use the existing recovery helper, clearing the
selection and reopening checkout's country-filtered picker. Cart-position
shops continue to return to their cart picker. Three regression tests cover
mount recovery, a disabled method at confirmation, and a selection cleared
after review. Both confirmation tests choose a replacement and complete the
order.

### BUG - MEDIUM: the transitional namespace missed the new public APIs

The PRs added `default_checkout_country/0`, `children/0`,
`stock_tracking_enabled?/0` and `warehouse_status/0` without delegates in
`compat/shop.ex`. Calls through `PhoenixKit.Modules.Shop` therefore failed.
Added all four delegates and a regression test checking the exported API and
the delegated cache child specs. This restores the repository's explicit
compatibility contract for these additions.

### IMPROVEMENT - MEDIUM: Claude's floor test did not guard the requirement

The existing floor test checked symbols from the resolved billing dependency.
Because `mix.lock` selects billing 0.21.0, accidentally restoring `~> 0.13`
would still pass it. Added a check of the requirement committed in `mix.exs`:
it must reject 0.19.0 and admit 0.20.0 and 0.21.0. Also assert that the shared
component exports `billing_profile_fields/1`, rather than checking only that
its module exists.

## Verified aspects

- The `~> 0.20` billing floor is correct. The existing lock resolves 0.21.0,
  so this review needs no lock change.
- Saving a profile remains inside the cart conversion transaction, with
  trusted user ownership and whitelisted form fields. Existing tests cover
  guest refusal, profile ownership, default assignment and rollback when
  shipping fails after profile creation.
- Locale setup points both e-commerce and billing's Gettext backends at the
  content locale; existing validation and label tests pass.
- The remaining PR reviews are recorded separately:
  [#76](../76-checkout-default-country/CODEX_REVIEW.md),
  [#79](../79-storefront-category-cache/CODEX_REVIEW.md),
  [#80](../80-shopify-off-by-default/CODEX_REVIEW.md),
  [#81](../81-stock-tracking-switch/CODEX_REVIEW.md).

## Validation

- Baseline full suite on `3fc2b2b`: **2062 tests, 0 failures** with Postgres
  available and catalogue integration tests running.
- Before fixes: both hidden-field tests failed; compatibility exports and
  mount/confirmation shipping recovery also failed in the focused run.
- Focused checkout/compatibility suite after the initial fixes: **40 tests,
  0 failures**.
- Expanded shipping and dependency-floor suite: **21 tests, 0 failures**.
- Final full suite: **2069 tests, 0 failures**, including database-backed
  checkout and catalogue tests.
- **`mix precommit` passed**: forced compilation with warnings as errors,
  unused-lock check, Hex audit, formatting check, strict Credo and Dialyzer.
  Dialyzer used the repository's existing ignore file.
- `git diff --check` passed. Claude's review files and `mix.lock` are unchanged.

## Version and remaining limits

Kept version **0.5.19** and added the fixes to **Unreleased**. Repository
instructions place version bumps and dated changelog entries in the release
commit; this request is a review and repair, so no release or publication was
performed. A future release should include all of #76–#81 and these fixes.

The storefront cache's documented node-local/TTL freshness and billing's
transaction-time PubSub side effects remain as described in Claude's reviews.
Neither requires a broader change for this review. Claude's review files were
preserved.
