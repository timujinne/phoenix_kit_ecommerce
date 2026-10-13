# PR #59 follow-up — Keep a failed guest confirmation email from taking the checkout with it

Triage of `CLAUDE_REVIEW.md` against current code, by reading.

## Fixed (pre-existing)

- ~~#1 IMPROVEMENT - MEDIUM: the `catch` clause threw away the stacktrace.~~
  Both clauses log `Exception.format(kind, value, __STACKTRACE__)`
  (`lib/phoenix_kit_ecommerce.ex:6014` on, the `rescue`/`catch` pair).
- ~~#2 IMPROVEMENT - MEDIUM: `Activity.log/2` let a throw through.~~ The
  wrapper now delegates to core's `PhoenixKit.Activity.log/3`
  (`lib/phoenix_kit_ecommerce/activity.ex:48-50`), which rescues and catches
  both `:exit` and `:throw`.
- ~~#3 IMPROVEMENT - MEDIUM: nothing pinned the log line.~~
  `test/phoenix_kit_ecommerce/checkout_survives_email_failure_test.exs:111`
  and `:154`.

## Fixed (Batch 1 — 2026-10-13)

- ~~Considered, not changed: a crash between commit and navigation remounts
  the checkout onto "Your cart is empty".~~ `CheckoutPage` with no active cart
  looks for an order this visitor placed in the last five minutes
  (`recent_checkout_order_uuid/1`, `lib/phoenix_kit_ecommerce.ex:5024`: the
  user, or the order's placing session for a trusted session) and sends them
  to its confirmation page, which authorizes itself
  (`test/phoenix_kit_ecommerce/web/checkout_after_conversion_test.exs`).

## Skipped (with rationale)

- **Recording the failed email in the activity trail.** The review rejected
  it: activity logging happens at the LiveView layer, and this is a context
  function.
- **The comment in expression position above `rescue`.** The review left it.

## Files touched

| File | Change |
|---|---|
| `lib/phoenix_kit_ecommerce.ex` | `recent_checkout_order_uuid/1` |
| `lib/phoenix_kit_ecommerce/web/checkout_page.ex` | mount without a cart goes to the recent order |

## Verification

`PGUSER=maxdon mix test` — 2891 tests, 0 failures. `mix precommit` (compile `--warnings-as-errors`, format, `credo --strict`, dialyzer) — exit 0, dialyzer 0 unnecessary skips. Run on the tree that carries this file.

## Open

None.
