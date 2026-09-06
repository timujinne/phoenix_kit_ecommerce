# Code Review: PR #31 — Currency hygiene: carts require a currency, no USD literals, base currency substituted once at creation

**Reviewed:** 2026-09-05
**Reviewer:** Claude (claude-opus-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/31
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** 3d116a5a4734a84e2041adf2f13b965689727414 (merge 3779322)
**Status:** Merged

## Summary

`Cart.changeset/2` and `CartItem.changeset/2` now require `:currency`;
`Cart`, `CartItem`, `Product` and `ShippingMethod` drop their
`default: "USD"` field defaults; `get_default_currency_code/0` returns
`nil` instead of `"USD"` when Billing has no default currency; and a new
`maybe_set_default_currency/1` substitutes the shop's base currency once,
in `create_product/1` and `create_shipping_method/1`, so every creation
path — admin forms and the CSV/Shopify importer alike — is covered from a
single place. The shipping-method form's two `"USD"` literals are removed.

The direction is right and the context-level placement of the fallback is
the correct call. Two of the mechanisms, though, do not do what the PR
says they do — verified against the database, not read off the diff.

## Issues Found

### 1. [BUG - HIGH] The `"USD"` literal was not removed, only pushed down into the column default — FIXED
**File:** `lib/phoenix_kit_ecommerce/schemas/{cart,cart_item,product,shipping_method}.ex`, `lib/phoenix_kit_ecommerce/migrations.ex`
**Confidence:** 100/100

The PR's premise — *"their `:currency` column allows NULL (verified
against the stand DB), so nothing in the schema forced a real value either
way"* — checked the column's NULL-ability but not its DEFAULT. All four
shop tables declare one, in core's baseline and in this module's own V1
chain:

```
            table_name             | column_default            | is_nullable
-----------------------------------+---------------------------+------------
 phoenix_kit_shop_carts            | 'USD'::character varying  | YES
 phoenix_kit_shop_cart_items       | 'USD'::character varying  | YES
 phoenix_kit_shop_products         | 'USD'::character varying  | YES
 phoenix_kit_shop_shipping_methods | 'USD'::character varying  | YES
```

Removing the *schema* default made this reachable rather than harmless.
`maybe_set_default_currency/1` puts `currency => nil` when no default
currency is configured; `%Product{}.currency` is now also `nil`, so Ecto
records **no change**, omits the column from the `INSERT`, and Postgres
substitutes `'USD'`. Measured, against the test database, with the
currency table emptied:

```
STRUCT currency after create_product:          nil
DB     currency after create_product:          [["USD"]]
STRUCT currency after create_shipping_method:  nil
DB     currency after create_shipping_method:  [["USD"]]
```

So the shop that the PR is specifically about — one with no default
currency — still silently stores `"USD"`, and the struct handed back to
the caller now *disagrees with its own row* (before the PR they at least
agreed). §7.3/N3 is unmet on exactly the two paths the PR rewrote.

**Fix:** `PhoenixKitEcommerce.Migrations` V2 — `ALTER COLUMN "currency"
DROP DEFAULT` on all four tables. This is the chain's first deliberate
divergence from core's shape, and the moduledoc says so. Existing rows are
untouched (a shop that stores `"USD"` today keeps storing it — that is its
history); only inserts that name no currency now land as NULL, which is
what "no default currency is configured" honestly means. `down/1` restores
the defaults.

Two consequences worth recording:

* `migrations_test.exs`'s destructive-statement scan refused a bare
  `DROP`. It now matches on the object kind that follows — every DROP that
  can lose data or structure is still refused; `DROP DEFAULT` /
  `DROP NOT NULL` are not.
* `test_helper.exs` never ran the module chain ("No module-owned DDL"),
  which was true while V1 was purely adoptive and is not true of V2. It
  now applies `up_statements/1` after core's migrations, so the test
  database has the shape a migrated host has.

### 2. [BUG - HIGH] `create_cart/1` can now fail, and both storefront call sites hard-match `{:ok, cart}` — FIXED
**File:** `lib/phoenix_kit_ecommerce/web/cart_page.ex` line 59, `lib/phoenix_kit_ecommerce/web/catalog_product.ex` line 459
**Confidence:** 100/100

`validate_required([:currency])` plus a `nil`-returning
`get_default_currency_code/0` gives `create_cart/1` a failure mode it never
had. Its only two callers were written when it could not fail:

```elixir
{:ok, cart} = Shop.get_or_create_cart(user_uuid: user_uuid, session_id: session_id)
```

A shop with no default currency therefore answers **every** cart-page
request, and every add-to-cart, with a `MatchError` — a 500 for the
shopper, not the loud-but-controlled failure the PR intended. This state is
not hypothetical: `web/products.ex` carries a `@default_currency_symbol
"$"` fallback and `web/helpers.ex` documents "no default currency
configured at all", so the module explicitly supports it elsewhere.

**Fix:** both call sites handle `{:error, _}` and take the exact exit the
disabled-shop gate already takes — an "The shop is currently unavailable"
flash, and on the cart page a redirect to the host root. Pinned by
`test/phoenix_kit_ecommerce/regression/cart_without_default_currency_test.exs`,
which raises the `MatchError` against the pre-fix code.

### 3. [BUG - MEDIUM] The review-fix comment justifies the change with a validation that does not run — FIXED
**File:** `lib/phoenix_kit_ecommerce/web/shipping_method_form.ex` lines 28–31
**Confidence:** 100/100

> `ShippingMethod.changeset/2`'s own `validate_length(:currency, is: 3)`
> then rejects it loudly rather than silently seeding the form with "USD".

It does not. `validate_length/3` skips `nil`, and the hidden input submits
`""`, which is an Ecto empty value — never cast, never validated. Nothing
is rejected; the method simply saves with no currency (and, before issue 1
was fixed, with `'USD'` in the row). The behaviour is defensible — it is
just not the behaviour the comment claims, and the claim is the entire
stated justification for dropping the literal.

**Fix:** the comment now describes what actually happens and why storing no
currency is the right record for a shop that has configured none.

### 4. [NITPICK] Stale schema doc — FIXED
**File:** `lib/phoenix_kit_ecommerce/schemas/product.ex` line 20

`- currency - ISO currency code (default: USD)` outlived the default it
documents.

### 5. [NITPICK] Stale comment on `validate_cart_currency/2` — FIXED
**File:** `lib/phoenix_kit_ecommerce.ex` lines 2076–2081

"usually the schema's `"USD"` default … the importers never set the field"
— the importers now do, via `create_product/1`. Reworded to name what the
mismatch actually is: a legacy row.

### 6. [OBSERVATION] `maybe_set_default_currency/1` raises on a keyword list — NOT FIXED
**File:** `lib/phoenix_kit_ecommerce.ex` lines 910–920

`MetadataValidator.normalize_product_attrs/1`, one line above, has an
explicit `def normalize_product_attrs(attrs), do: attrs` clause for
non-maps, so a keyword list reaches `Map.has_key?/2` and raises
`BadMapError`. No caller passes one today (every `create_product/1` and
`create_shipping_method/1` call site passes a map; only `create_cart/1`
takes a keyword list), so this is left alone deliberately — a guard for a
shape nothing produces is a branch no test can exercise.

## What Was Done Well

* **Matching the incoming map's key style before adding the fallback.**
  `Ecto.Changeset.cast/3` raises on a mixed-key map and the callers
  genuinely disagree (string-keyed LiveView params, atom-keyed
  `ProductTransformer` output). This is a real trap, spotted and handled.
* **Putting the fallback in the context, not the forms.** A form-only fix
  would have silently regressed the CSV/Shopify importer to `nil` — the PR
  says so explicitly and it is right.
* **Ordering `validate_required` before the `nil`-returning getter**, so an
  empty catalogue produces a changeset error rather than a NULL reaching
  the database.
* **The gettext discipline** on the follow-up commit: a full
  `extract --merge`, with the diff read closely enough to state that the
  only content change was the one new msgid.

## Verdict

**Approved with fixes.** The intent and the placement of the fallback are
right, and the changeset-level work on `Cart`/`CartItem` is correct as
shipped. But the PR verified its two central claims by reading the schema
rather than the database: the `"USD"` literal survived in the column
default, and the "loud failure" it introduced reached the storefront as a
`MatchError`. Both are fixed post-merge, with a V2 migration and
regression tests that fail against the merged code.
