# PRs #106, #107 — new-order notification link, shopper-chosen delivery service

**Merged:** `d0e58ec` (#106), `df5d476` (#107) · **Reviewed:** 2026-10-22, after 0.6.0 (not yet released)

Open draft #108 (cart line picture supplied by the host) is not covered: a draft is not reviewed
until it is ready.

| PR | What | Size |
|---|---|---|
| #106 | The "New order" admin notification links to the order's Billing page; a buyer who is also an operator keeps it | 2 files |
| #107 | A calculated shipping method offers several services; the shopper picks one in the checkout picker (`set_cart_shipping_service/2`, `cart.metadata["shipping_service"]`) | 27 files |

Method: every changed `lib/` file was read against the code around it and the `AGENTS.md`
invariants. Claims were checked against their producers: billing's `enabled?/0` and
`Paths.order_detail/1` (billing 0.22), the services cache key (`Shipping.fingerprint/1` includes
`ctx.service`, so the lists are cached per service in effect), every remaining reader of
`shipping_config(method).service` (all are default-service reads that are correct for a method, none
is a cart read), the new gettext entries in all six catalogues (translated, no fuzzy), and the picker's
event clauses (`choose_service` validates the key against `snapshot.choices`, then the context
re-validates it against the provider; the catch-all `handle_event/3` is still last).

## Findings

### IMPROVEMENT - MEDIUM — #107 the snapshot asked the carrier for the service list twice during an outage
`shipping_quote_snapshot/2` first looks the cart's service up (`shipping_service/3`, keyed by the
service in effect) and then called `allowed_shipping_services/2` for `choices`, a second listing under
another cache key whenever the shopper's service is not the default. When the first listing failed
(timeout, crash), the second ran into the same failure: the lookup timeout (and the with-credentials
retry) was waited out twice on every cart change, and a timeout under a caller-set timeout is never
cached. There is nothing to choose from when the listing failed, so the second call bought nothing.
**Fixed:** `snapshot_choices/3` answers `[]` for any failed listing except `:unknown_service` (the
case that deliberately lists the way out). Test in `service_choice_test.exs` counts the provider's
`services` calls (2 before, 1 after).

### IMPROVEMENT - MEDIUM — #106 the Billing link can lead an operator to a page they may not open
The recipients are holders of `shop.manage_carts` (plus Owner and `"*"`); the link is now
`PhoenixKitBilling.Paths.order_detail/1`, which the billing admin gates behind its own module key. A
custom role with shop access and no billing access gets a notification that ends in a denied page,
where the carts list used to open. **Not fixed:** the notification carries one link for every
recipient, and a per-recipient link needs a permission check that also understands the Owner and `"*"`
holders (they have no permission rows); splitting the fan-out for it is more machinery than the
mismatch deserves. On record so an operator of such a role knows why.

### IMPROVEMENT - MEDIUM — #107 `set_cart_shipping_service/2` calls the carrier inside the cart-row transaction
`store_shipping_service/2` lists the provider's services (up to two calls: without and, for a
credentialed provider, with credentials, each bounded by `@shipping_lookup_timeout`) while it holds the
cart row lock and a pool connection. The docstring says so and the destination setters already work
the same way, so it is consistent; a slow carrier delays a second tab or a webhook on the same cart by
a timeout. **Not fixed:** reading the list before the transaction and re-checking inside it would
double the code for a cart that has one shopper.

### NITPICK — #107 a new method ticks every offered service
When the provider is chosen in the method form the state starts with `services: []` and
`pick_services/2` ticks everything the carrier lists (before: the first service). A shop owner who
adds a method and saves without reading the card now offers every service to the buyer. Intended by
the PR (the hint under the checkboxes says what one tick means) and not changed.

## Checked and clean

- **#106** the buyer is no longer filtered out of the admin fan-out; `admin_recipients/1` only holds
  operators, so a buyer without shop access still gets only their own message; `Billing.enabled?/0`
  rescues to `false`, so the fallback to the carts list is also the failure path; the two audit/notify
  action strings are untouched.
- **#107** `effective_service_key/2` is the only way a cart reads its service (request, order
  metadata, snapshot, lookups); a stale choice falls back to the default and its destination is cut to
  the locality in the request (`request_destination/2`) and in the order (`destination_in_effect/2`);
  `set_cart_shipping_service/2` takes the cart lock first, answers an unchanged choice without a
  broadcast, and drops the quote when the service really changes; the method switch keeps the choice
  only for the same provider and the same allowed services (order-sensitive, so it errs on dropping);
  `MethodConfig` reads the older `"service"`-only block as a list of one and `MethodParams` still writes
  `"service"` (the first) beside `"services"`, so a rollback of the code reads the new rows; the form
  posts a hidden empty entry so unticking everything is a value, and `posted_services/2` leaves the
  state alone for a post that has no `services` key; `ensure_method/1` includes the service in effect in
  its hash so the picker resets when the service changes.

## Gate

See `FOLLOW_UP.md`.
