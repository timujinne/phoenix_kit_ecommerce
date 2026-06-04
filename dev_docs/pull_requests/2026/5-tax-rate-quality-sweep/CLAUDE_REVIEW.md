# Code Review: PR #5 — Fix order tax_rate bug + quality sweep (test harness, 120 tests)

**Author:** Max Don (max@don.ee)
**Merged:** 2026-06-04 (merge commit `8c70ac8`)
**Reviewer:** Claude Opus 4.8 (1M context)
**Review date:** 2026-06-04

---

## Summary

PR #5 fixes the `tax_rate = 0` cart→order bug, corrects three unique-constraint
names to match the real DB indexes, and adds a full DB + LiveView test harness
(6 → 183 tests) plus two new support modules (`Activity`, `Errors`). At merge time
`mix precommit` was green.

This review re-verified the merged code on `main` and applied a set of safe,
clearly-correct fixes (see **Fixed in this review**). What could not be fixed
without a larger or riskier change is recorded under **Deferred**.

**Follow-up commit:** the fixes and this document landed on `main` in commit
`9187103` ("Post-merge fixes for PR #5 review + review doc"), pushed
`17e634e..9187103`.

**Verification of this review's changes:** `mix compile --warnings-as-errors`,
`mix format --check-formatted`, and `mix credo --strict` are all clean. The
runnable (non-DB) suite passes — `38 tests, 0 failures`; the 145 DB-tagged tests
require Postgres and were excluded in this environment.

---

## Assessment of the PR's own changes

| Change | Verdict |
|---|---|
| `tax_rate` fix (`get_tax_rate(cart)` instead of `Decimal.new(0)`) | **Correct.** `tax_rate` and `tax_amount` both key off `cart.shipping_country`, so they stay internally consistent. Pinned by a real end-to-end regression test (`regression/tax_rate_test.exs`) plus a tax-disabled counterpart. |
| Constraint-name fixes (`ShippingMethod`, `ImportConfig`) | **Correct.** Duplicate inserts now return `{:error, changeset}` instead of raising `Ecto.ConstraintError`. |
| `PhoenixKitEcommerce.Activity` | **Good design.** Rescues `Postgrex.Error`/`DBConnection.OwnershipError`, never crashes the caller, PII-safe, logs at the LV layer (not in contexts). |
| Import keyword-list cap + centralized currency-symbol fallback | **Correct, low-risk.** |
| Shipping-form core-component migration (`assign_form/2`, `<.input>`) | **Clean.** |
| `PhoenixKitEcommerce.Errors` | Correct in isolation, but **was unused** — see finding 1. |

---

## Findings

### 1. `PhoenixKitEcommerce.Errors` shipped with zero call sites — **partially fixed**

The module defines 30 gettext-backed atom→message mappings with 32 tests, but at
review time **nothing in `lib/` called `Errors.message/1`**. The atom-returning
error paths still emitted hardcoded, untranslated English.

- **Fixed:** wired `Errors.message/1` into the two cleanest atom sites where the
  canonical message matches intent and the only change is gaining i18n:
  - `web/checkout_page.ex` — `{:error, :cart_not_active}` (flash + `:error_message`).
  - `web/imports.ex` — `{:error, :unknown_format}` upload path.
- **Not changed (intentional):**
  - Admin delete sites (`products.ex`, `categories.ex`, `shipping_methods.ex`)
    return `{:error, %Ecto.Changeset{}}`, **not** an atom — routing those through
    `Errors.message/1` would hit the catch-all and surface
    `"Unexpected error: #Ecto.Changeset<...>"`, worse than the current generic
    string. Left as-is.
  - `checkout_page.ex` `:no_shipping_method` keeps its action-specific
    *"Please select a shipping method"* (a different meaning from the module's
    generic *"No shipping method is available."*).
  - `catalog_product.ex` `get_user_friendly_error_message/2` uses a separate,
    detail-interpolating atom set (`:out_of_stock`, `:insufficient_stock`, …) not
    present in `Errors`; merging the two is a follow-up, not a drop-in.

Broader adoption is incremental and should track new atom contracts as they appear.

### 2. Tax fallback ignored `billing_tax_enabled?` — **fixed**

`get_tax_rate/1` never checks the enabled flag; it relies on the billing module
returning 0 when tax is disabled. That holds when `PhoenixKitBilling` is loaded
(confirmed by the tax-disabled regression test), but the **fallback branch**
(`PhoenixKitBilling` absent) read `billing_default_tax_rate` unconditionally — so
a deployment without the billing module would apply tax even with
`billing_tax_enabled = "false"`, given a configured default rate and a non-nil
`shipping_country`. Same gap in `billing_tax_rate_percent/0`.

- **Fixed:** both fallbacks are now gated on `billing_tax_enabled?()`, mirroring
  the billing-loaded behaviour. Refactored the parse logic into
  `fallback_tax_rate/0` and `fallback_tax_rate_percent/0` to keep nesting within
  credo's depth limit.

### 3. `--warnings-as-errors` broken on `main` by the later lib upgrade — **fixed**

Not from PR #5: the subsequent "Libs upgraded" commit (`17e634e`) bumped
`phoenix_kit`, whose `DialectMapper.resolve_dialect/2` collapsed to
`resolve_dialect/1`. Two callers still passed the old `nil` second arg, so
`main` no longer compiled under `--warnings-as-errors` (which `mix precommit`
enforces).

- **Fixed:** dropped the obsolete `nil` arg at both sites
  (`web/helpers.ex:55`, `web/catalog_product.ex:1258`). The new `/1` absorbs the
  old fallback internally, so the call is semantically equivalent. Build is clean
  again.

### 4. Order tax basis can diverge from the persisted order country — **deferred**

In `build_order_attrs/3`, the order's `shipping_country` comes from
`get_shipping_country/3` (billing profile → `billing_data` → cart), but
`tax_rate`/`tax_amount` are derived from `cart.shipping_country`. If a guest's
billing country differs from the cart's (or the cart country is nil while
`billing_data` supplies one), the order records a country and a tax that disagree.
The flat-rate model (any non-nil country ⇒ same rate) limits the practical impact
to the nil-vs-present case.

**Deferred** because a correct fix means recomputing `tax_amount` (not just the
rate) from the *resolved* country at conversion time — otherwise the rate and the
amount would be inconsistent, reintroducing a variant of the original bug. Needs a
deliberate design pass, not a one-liner.

### 5. DB queries — and writes — in `mount/3` — **deferred (pre-existing)**

`mount/3` runs twice (HTTP render + WS connect). Several admin LVs query
unconditionally in mount (`carts.ex`, `shipping_methods.ex`, `dashboard.ex`,
`imports.ex`); `import_configs.ex` additionally runs **writes**
(`ensure_default_import_config/0`, `ensure_prom_ua_import_config/0`) — doubled
seeding attempts per page load. This predates PR #5 (original module extraction).

**Deferred:** the correct fix moves data loading to `handle_params/3` and pulls
seeding out of the LV lifecycle (or guards it behind `connected?/1`). That is a
cross-cutting change across ~5 LiveViews and is not covered by the runnable
(non-DB) tests, so it warrants its own focused PR with the DB suite green.

### 6. The no-billing fallback branch is untested — **noted**

Because `PhoenixKitBilling` is always loaded in the test env,
`Code.ensure_loaded?(PhoenixKitBilling)` is always true, so the `else` branches of
`billing_tax_rate/0`, `billing_tax_rate_percent/0`, and `billing_tax_enabled?/0`
— including the parse-failure `Logger.warning` paths and the enabled-gate added in
finding 2 — are never exercised. Hard to test without unloading the dependency.
Left as a known coverage gap.

---

## Fixed in this review

| # | Fix | Files |
|---|---|---|
| 2 | Gate the no-billing tax fallback on `billing_tax_enabled?`; extract `fallback_tax_rate/0` + `fallback_tax_rate_percent/0` | `lib/phoenix_kit_ecommerce.ex` |
| 3 | Migrate `DialectMapper.resolve_dialect/2` → `/1` (restores `--warnings-as-errors`) | `web/helpers.ex`, `web/catalog_product.ex` |
| 1 | Wire `Errors.message/1` into the `:cart_not_active` and `:unknown_format` atom paths | `web/checkout_page.ex`, `web/imports.ex` |

## Deferred (recorded, not changed)

- **4** — order tax basis vs. persisted country (needs recompute-on-resolved-country design).
- **5** — DB queries/writes in `mount/3` (cross-cutting `handle_params` refactor; pre-existing).
- **6** — no-billing fallback branch is structurally untestable in this env.
- Broader `Errors` adoption beyond the two wired sites (incremental).
