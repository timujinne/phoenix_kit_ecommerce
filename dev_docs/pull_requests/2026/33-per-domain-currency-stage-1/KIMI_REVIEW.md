# Code Review: PR #33 — Per-domain currency, stage Э1: storefront conversion by provenance, frozen cart/order rates, shipping in base

**Reviewed:** 2026-09-08
**Reviewer:** Kimi Code
**PR:** https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/33
**Head SHA:** c712a68 (squash-merged)
**Status:** Merged

## Summary

The PR freezes a display currency, base currency, and FX rate onto each cart
at creation (`base_currency`/`exchange_rate` on `Cart`, `base_unit_price` on
`CartItem`), snapshots line prices through billing's `Currency.present/3`
with the frozen rate, converts shipping threshold comparisons and costs
through base currency, freezes the same triple onto orders at checkout, and
re-points storefront LiveViews at a display-currency code while admin
authoring screens explicitly use the base currency. Overall quality is high:
money is `Decimal` everywhere in the new code, conversion is applied once
per provenance rule (`:catalog`/`:selected` convert, `:cart`/`:order`
don't), the frozen-rate discipline mirrors the existing `price_on_request`
snapshot rule, the disabled-currency regression was root-caused into
billing's `present/3` rather than worked around locally, and the two new
public functions got `compat/` delegates. Findings are edge cases and
convention deviations, none blocking.

## Issues Found

### 1. [BUG - MEDIUM] `fx_refresh_if_emptied/2` crashes on `nil.code` when the currency table is emptied mid-cart
**File:** `lib/phoenix_kit_ecommerce.ex:4934`
**Confidence:** 72/100

The empty-cart clause does
`display = Billing.resolve_display_currency(Currency.get_request_currency() || cart.currency)`
and then dereferences `display.code` and `base.code` with no nil guard.
`resolve_display_currency/1` returns `nil` when the currency table has no
base row (verified in `deps/phoenix_kit_billing/lib/phoenix_kit_billing.ex:829`:
`is_nil(base) -> nil`). A cart can legitimately exist with items (currency
was configured at creation), and an admin can subsequently delete all
currencies; the next time that shopper removes their last item,
`recalculate_cart_totals!/1` raises `KeyError` on `nil.code` and the
cart-emptying action crashes. `create_cart/1` handles the same empty-table
situation gracefully (nil code → loud `validate_required(:currency)`
changeset failure), so the asymmetry is a real gap.

**Fix:** mirror `create_cart/1`'s tolerance — e.g.
`if display && base, do: %{currency: display.code, ...}, else: %{}`
(leaving the frozen triple untouched when nothing can be resolved).
Edge-case reachability keeps this at MEDIUM.

### 2. [IMPROVEMENT - MEDIUM] `validate_cart_currency/2` reads a setting directly inside the add-to-cart transaction
**File:** `lib/phoenix_kit_ecommerce.ex:2350`
**Confidence:** 78/100

It calls `Settings.get_boolean_setting("shop_enforce_product_currency", false)`
directly. AGENTS.md's convention is "Settings are read through their
wrapper, never directly… every policy reader fails *closed* on a
settings-layer error"; the other policy-style keys live behind
`PhoenixKitEcommerce.Policy`/`Vocabulary`/the main-module wrappers. This
call has no rescue, so a settings-layer failure (DB blip) aborts the whole
cart transaction with a raw raise rather than degrading to the default
(`false` = log and continue).

**Fix:** wrap it in a small policy reader (e.g.
`Policy.enforce_product_currency?/0`) that rescues to `false`, and document
the default there — that also gives the admin UI and enforcement point a
single source of truth, per the convention.

### 3. [NITPICK] Delegate without parentheses
**File:** `lib/phoenix_kit_ecommerce/compat/shop.ex:38`
**Confidence:** 90/100

`defdelegate get_base_currency, to: PhoenixKitEcommerce` is the only
delegate in the file without parentheses (`get_base_currency()`). Pure
consistency; harmless.

### 4. [NITPICK] "100% OFF" badge for a product with no price
**File:** `lib/phoenix_kit_ecommerce/price_display.ex` (`compare_at/4`, added hunk)
**Confidence:** 75/100

When `product.price` is nil and `compare_at_price` is set, `base_amount`
falls back to `Decimal.new("0")`, so the percent computes
`(compare - 0)/compare * 100 = 100` and the storefront renders a "100% OFF"
badge for a product with no price at all.

**Fix:** return `nil` when the base amount is nil/zero, same as the
on-request guard.

### 5. [NITPICK] "OFF" badge text hardcoded outside gettext
**File:** `lib/phoenix_kit_ecommerce/web/catalog_product.ex` (price section), `web/components/shop_cards.ex`
**Confidence:** 80/100

The new `{cmp.percent}% OFF` badge hardcodes the user-facing word "OFF"
outside gettext in the `:selected` branch (the `:catalog` branch already had
this pattern pre-PR, so it's an existing convention being extended rather
than introduced).

**Fix:** wrap in `gettext("%{percent}% OFF")` so it lands in this module's
catalogue.

## Explicitly acknowledged / superseded (not counted as findings)

- The committed `mix.exs` floors (`~> 2.15`, `~> 0.11`) admit no hex release
  and the restored `mix.lock` cannot resolve standalone — the commit message
  calls this out as a known, plan-sanctioned state, and a later PR
  ("buildable lockfile") fixed it on main afterward.
- The AGENTS.md landmine "raising a requirement means updating `mix.lock` in
  the same change" was technically violated here, but knowingly and
  remediated later; noted for process only.

## What looks good

- Frozen-rate discipline is consistent: `snapshot_unit_price/2`,
  `from_base/2` both go through `Currency.present/3` with
  `rate: cart.exchange_rate`, and billing's `present_frozen/4` genuinely
  skips live resolution on that path — the disabled-mid-cart-currency
  regression is structurally prevented, not just tested.
- `to_base/2` is used uniformly for every threshold comparison (eligibility,
  auto-select ranking, free-shipping, cost), and `base_total/1` sums exact
  per-line base amounts rather than dividing the twice-rounded display
  total.
- Both new public functions (`get_display_currency_code/0`,
  `get_base_currency/0`) got `compat/shop.ex` delegates.
- `errors.ex` keeps its alphabetical atom list; `:currency_mismatch` was
  extracted into all five gettext catalogues; no setting keys, route
  segments, or event names wrapped in gettext.
- `Cart.totals_changeset` casts the FX triple only for the emptied-cart
  refresh path, with the guard documented on the changeset itself.
- Admin pages read the *record's* currency via `currency_for_code/1`
  (cached lookup) instead of a mount-time default — right for historical
  orders/carts and no N+1.

## Unverified surfaces

- **New test files were not read** (names/stat only):
  `cart_fx_freeze_test.exs`, `order_fx_freeze_test.exs`,
  `shipping_fx_test.exs`, `price_display_fx_test.exs`,
  `cart_currency_enforce_test.exs`, `storefront_currency_code_test.exs`,
  `catalog_product_e4_followups_test.exs`, plus `test/support/hooks.ex`,
  `live_case.ex`, `test_router.ex`. Whether they pin the actual regressions
  (vs passing under a naive broken implementation) is unverified.
- `find_cart_item_after_add/4` in `catalog_product.ex` was not read:
  `build_cart_message/5` now dereferences `updated_cart_item.unit_price`, so
  if that lookup can return nil after a successful add, the flash path newly
  raises. Risk looks low (re-add always leaves a findable line) but it's a
  new nil-deref on a previously non-failing path.
- `format_product_price/3` in the main context now delegates formatting to
  `Helpers.format_price/2`, which formats but never converts; if any
  storefront caller passes it a display-currency code, it renders base
  amounts under a display symbol — the exact bug class this PR fixed
  elsewhere. Callers were not enumerated.
- Stage-2 note, adjacent: `cart_rate_drift/1`
  (`lib/phoenix_kit_ecommerce.ex:341`) divides by the frozen rate without a
  zero guard; unreachable via `create_cart/1` but not schema-validated, so a
  hand-migrated zero rate would raise there.
