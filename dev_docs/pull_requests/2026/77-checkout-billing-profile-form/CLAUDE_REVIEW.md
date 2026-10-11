# PR #77: Use billing's profile form in checkout and offer to save the billing profile

- **Author:** Tymofii Shapovalov (timujinne)
- **Reviewer:** Claude
- **Merge:** `a3bfb9b` on `main`
- **Verdict:** approve with one fix, applied on `main`.

## Summary

Checkout's billing step now renders billing's shared
`BillingProfileFields` over `BillingProfile.fields_changeset/3` (type
switch, middle name, second address line, state, company details) and
drops the hand-written required checks. A logged-in shopper typing new
details gets a ticked "Save as a billing profile" box.
`convert_cart_to_order/2` takes `save_billing_profile: true` and creates
the profile inside the conversion transaction, so an invalid profile rolls
the whole conversion back with `{:billing_profile_invalid, changeset}`.
`put_content_locale/1` now sets billing's Gettext backend too.

## Findings

- **BUG - MEDIUM - the billing floor was still `~> 0.13`.** The PR notes
  in AGENTS.md that the floor "is raised when that is published", but it
  never got raised. Billing 0.20.0 (published 2026-10-10) is the first
  release with `BillingProfileFields`, `fields_changeset/3` and
  `form_fields/0`. A host resolving 0.13-0.19 compiles this module (with
  an undefined-module warning) and then fails at runtime the moment a
  shopper opens checkout. `mix.lock` was already at 0.21.0, so nothing in
  this repo noticed.
  **Fixed:** floor raised to `~> 0.20` in `mix.exs` (with the reason),
  AGENTS.md updated, and a `dependency_floor_test.exs` case pins the
  component, both changeset functions and `PhoenixKitBilling.Gettext`.
- **Checked, correct - the save is not forgeable.** The profile is saved
  only when the resolved user equals the `:user_uuid` the caller passed, a
  guest never owns one, a `billing_profile_uuid` wins over the flag, and
  `billing_profile_attrs/1` takes only billing's `form_fields/0` (minus
  `name`), so a form value cannot set `user_uuid`, `is_default` or
  `metadata`.
- **Checked, correct - a blank form cannot fail the order.** The checkout
  saves only when `billing_collected?` is true, i.e. the form passed
  validation. `use_new_profile` and `prefill_from_selected_profile` reset
  it, so a stale flag does not survive switching to a saved profile.
- **Checked, correct - a blank country is kept blank** (billing's schema
  would default it to `"EE"`), both in the form and in the context.
- **NITPICK - `Billing.create_billing_profile/2` side effects** (any
  PubSub or activity it emits) run inside the conversion transaction and
  are not undone if a later step rolls back. That is billing's behaviour
  and cannot be fixed here; the checkout's own activity row is written
  only after the `{:ok, order}` result.

## Tests

`checkout_billing_profile_test.exs` and `save_billing_profile_test.exs`
cover the form, the live validation, the save box, the rollback and the
hint. Together with the new floor test: 57 tests, 0 failures.
