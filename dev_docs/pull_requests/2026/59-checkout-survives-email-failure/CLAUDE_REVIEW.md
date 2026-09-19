# Code Review: PR #59 — Keep a failed guest confirmation email from taking the checkout with it

**Reviewed:** 2026-09-18
**Reviewer:** Claude (claude-opus-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/59
**Author:** Tymofii Shapovalov
**Merge SHA:** 8d8bdef (squash)
**Status:** Merged

## Summary

`do_convert_cart_to_order/2` runs three steps after the conversion transaction
commits — `maybe_send_guest_confirmation/1`, `log_order_converted/1`,
`Notifications.order_placed/1`. The first was unguarded despite the comment
above it claiming otherwise, so a raise on the mail path (seen in production:
an active DB template made core's `Content.resolve/5` raise `KeyError` on every
send) skipped the other two AND killed the checkout LiveView, which remounted,
found no active cart and told the shopper their cart was empty — after the
order had committed.

The PR wraps the function body in `rescue`/`catch`, logs at `error`, returns
`:ok`, and adds five regression tests.

**The change is correct and lands in the right place.** Checked:

- **Scope of the guard.** The whole body, including the `Auth.get_user/1` read
  above the send. Deliberate and right: a pool timeout there kills the
  LiveView exactly the way the mail failure did.
- **Placement.** The context function, not the caller. `CheckoutPage`'s
  `handle_order_result({:ok, order}, socket)` only assigns and
  `push_navigate`s, so there is nothing left to harden at the LiveView layer,
  and the guard also protects the non-LiveView callers (`convert_cart_to_order/2`
  is public and re-exported through `compat/shop.ex`).
- **Still outside the transaction.** The three steps run in the `{:ok, {:ok,
  order}}` branch after `repo().transaction/1` returns, so nothing here can
  roll back a committed order. Unchanged by this PR, still true.
- **The tests are not tautological.** Traced the stub through
  `Auth.deliver_user_confirmation_instructions/2` →
  `UserNotifier.deliver_templated/5` → `Content.resolve/5`, which calls
  `Provider.current().get_active_template_by_name/1` and then
  `render_template/3` — so both providers really do fire on the path under
  test. The run's own log output confirms it (`RaisingProvider.render_template/3`
  → `Content.resolve/5` → `maybe_send_guest_confirmation/1`). `async: false`
  plus ExUnit running sync modules after all async ones makes the
  `Application.put_env(:phoenix_kit, :email_provider, …)` swap safe.
- **The sibling steps' own guards.** `Notifications.order_placed/1` runs inside
  `safely/1` (rescue + catch, both kinds). `Activity.log/2` rescues and catches
  `:exit`. See finding 2 — the PR's claim is *nearly* right, and the gap is in
  the same three-line block.
- **Return value.** The rescue returns `:ok`, the call site is `_ = …`, and the
  conversion still answers `{:ok, order}`. `@type log_result` already admits
  `:ok`.

No BUG-severity findings. Three improvements applied.

## Findings

### 1. IMPROVEMENT - MEDIUM — the `catch` clause threw away the stacktrace (fixed)

`rescue` logged `Exception.format(:error, error, __STACKTRACE__)`; `catch`
logged `"#{inspect(kind)} #{inspect(value)}"`. For the exact case the clause
was added for — a throw or an exit from below the mail path — that produces
`:throw :mailer_gone` and nothing else: no module, no line, no sender. The
whole argument for `Logger.error` here is that an operator has to act on it,
and an operator cannot act on a bare atom.

`__STACKTRACE__` is available in `catch` too, and `Exception.format/3` takes
`:throw` and `:exit` as its kind. Both clauses now format identically. The
throw test asserts on `"(throw) :mailer_gone"` and on
`"PhoenixKit.Email.Content.resolve/5"`, so the location is pinned, not just the
value.

### 2. IMPROVEMENT - MEDIUM — `Activity.log/2` still let a throw through (fixed)

The commit message's reasoning is "Activity.log and Notifications.order_placed
already rescue their own failures; this closes the one remaining hole". That is
right for raises and exits, and not right for throws:
`Notifications.safely/1` catches `kind, value`; `PhoenixKitEcommerce.Activity.log/2`
caught only `:exit, _reason`. Its own `@doc` promises it "rescues/catches any
failure so the calling LiveView event handler can't crash on a logging error",
which was therefore not true — and the second of the three post-commit steps is
precisely that call.

This is the same argument the PR itself makes for adding `catch` to the mail
path ("a raise is not the only way…"), applied one line further down. The
wrapper now catches every kind: `:exit` stays silent (unchanged — a dead pool
is not worth a line), anything else is logged at `warning` like the rest of the
wrapper and swallowed. Core's own `PhoenixKit.Activity.log/1` has the same
`:exit`-only shape, so the widening is defence in depth rather than a duplicate
of an upstream guard.

Not directly unit-tested: nothing in the activity path throws today, so
exercising it would mean injecting a mock for a branch whose whole purpose is
the unforeseen. The behaviour is the one `Notifications.safely/1` already
ships and its `:exit` sibling is unchanged.

### 3. IMPROVEMENT - MEDIUM — nothing pinned the log line (fixed)

The PR argues at length that `Logger.error` (against `warning` everywhere else
in the module) is the deliberate compensating control for swallowing the
failure: the shopper walks away with an account that cannot confirm itself and
this line is the only trace. Nothing asserted it. Deleting the `Logger.error`
call, or downgrading it to `debug`, left all five tests green — i.e. the
compensating control was the one part of the fix with no coverage, which is the
same shape of gap that shipped the original bug.

The raise test now asserts `[error]` and the message; the throw test asserts
the formatted kind and the origin frame.

## Considered and deliberately not changed

- **The remount-onto-an-empty-cart behaviour itself.** `CheckoutPage.do_mount/3`
  still answers a converted cart with `find_active_cart/1 == nil` → "Your cart
  is empty" → `/cart`, so *any* future crash between commit and navigation
  reproduces the shopper-facing symptom. Sending them to
  `/checkout/complete/:uuid` instead would mean looking up the session's most
  recent converted cart and its order on every checkout mount, inventing a
  staleness window (otherwise a shopper who comes back next week to shop is
  shown last week's receipt), and re-deciding it against
  `shop_order_lookup_policy`. That is a design change to the checkout entry
  point, not a fix to this PR, and the risk of showing the wrong order to the
  wrong person is real. Recorded here so the residual is on file.
- **Recording the failure in the activity trail** (`Activity.log_failed/3` with
  a `shop.guest_confirmation_failed` action), so an operator sees it in the
  admin UI instead of in logs nobody reads. Rejected: activity logging happens
  at the LiveView layer in this module, never inside context functions
  (`AGENTS.md`, `Activity`'s moduledoc), and this is a context function. Doing
  it properly means a new registered action and a decision about the audit-vs-
  notify action-string split — a feature, not a review fix.
- **The comment sitting in expression position** above `rescue` (after the
  `case`, inside the body). Unusual to read, but it is documenting the clause
  immediately below it and moving it changes nothing.

## Validation

`mix precommit` (compile --warnings-as-errors + format + credo --strict +
dialyzer) and the full `mix test` suite against `phoenix_kit_ecommerce_test`,
including the five tests this PR added.
