# PR #77 follow-up — Use billing's profile form in checkout and offer to save the billing profile

## Fixed (pre-existing)

- ~~BUG - MEDIUM (Claude): the billing floor was still `~> 0.13`.~~
  `mix.exs:147` is `~> 0.20`.
- ~~IMPROVEMENT - MEDIUM (Codex): the floor test did not guard the
  requirement.~~ `test/phoenix_kit_ecommerce/dependency_floor_test.exs:121-122`
  checks the committed requirement rejects 0.19.0 and admits 0.20.0, and
  `:103` asserts `billing_profile_fields/1` is exported.
- ~~BUG - MEDIUM (Codex): fields hidden by the billing type still blocked
  checkout.~~ `lib/phoenix_kit_ecommerce/web/checkout_page.ex:472-476` —
  `billing_changeset/1` applies `clean_for_type/2` before billing's changeset
  runs.
- ~~BUG - MEDIUM (Codex): shipping recovery could strand a shopper on the
  cart.~~ `checkout_page.ex:96-98` clears an outgrown selection on a
  checkout-position mount; `:1141` and `:1157` route `:no_shipping_method` and
  `:shipping_method_unavailable` through `reject_invalid_shipping_selection`.
- ~~BUG - MEDIUM (Codex): the transitional namespace missed the new public
  APIs.~~ `lib/phoenix_kit_ecommerce/compat/shop.ex:32-35`.

## Not changed by the reviewer (design notes, not defects)

- `Billing.create_billing_profile/2` side effects run inside the conversion
  transaction. Both reviews record this as billing's behaviour, not fixable in
  this module.

## Open

None.
