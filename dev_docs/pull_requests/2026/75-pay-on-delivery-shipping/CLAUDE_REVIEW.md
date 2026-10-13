# PR #75: Add pay-on-delivery shipping methods instead of showing them as FREE

- **Author:** Tymofii Shapovalov (timujinne)
- **Reviewer:** Claude
- **PR:** https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/75
- **Head SHA:** `f779ca0` (3 commits on `main` `1a168f1`)
- **Status:** Draft, mergeable
- **Round 2:** head `47f28bb`, **approve** — see "Round 2" at the end.
- **Round 3:** head `2dfd618`, **approve** — see "Round 3" at the end.
- **Verdict:** request changes, one small fix. The flag, the changeset,
  the order data and the translations are correct, and nothing changes
  any amount. One storefront contradiction (BUG - MEDIUM) should be fixed
  before the PR leaves draft. Everything else is optional.

## Summary

A shipping method can now be marked "paid to the carrier at their rates on
delivery" (Nova Poshta, Ukrposhta). Before this PR such a method was a
price-0 method, and the storefront called it FREE. The PR adds:

- **Flag.** `metadata["pay_on_delivery"]` on `ShippingMethod`, with no
  migration, and the predicate `ShippingMethod.pay_on_delivery?/1`. While
  the flag is on, `changeset/2` forces `price` to 0 and clears
  `free_above_amount`. The admin form sends the flag as a top-level
  `pay_on_delivery` param that the changeset merges into `metadata`, so
  other metadata keys are kept.
- **Storefront.** `present_shipping_method/2` returns `pay_on_delivery?`,
  and `free?` is never true for such a method. The cart and checkout
  method lists, both order summaries, the review step, the confirmation
  page and the user order details page say "Paid on delivery". Each
  summary adds a note that shipping is not included in the total.
- **Orders.** The shipping line gets `"pay_on_delivery"` and a
  "Carrier rates, paid on delivery" description. The order metadata gets
  `shipping_pay_on_delivery`.
- **Auto-selection.** The cheapest-method pick no longer counts the
  method's 0 as cheapest. It is ranked with the unpriced methods and is
  still picked when it is the only method.
- **Admin.** The form has a checkbox with a hint. The list shows "Paid on
  delivery" instead of a price.
- **i18n and docs.** 5 new msgids, translated for de/et/fr/ru. A new
  AGENTS.md landmine.

## Checks

- **Changeset: the flag and other metadata.** `pop_pay_on_delivery/1`
  takes the top-level param out before `cast/3`, so the flag never goes
  through a `metadata` cast that would replace the whole map.
  `put_pay_on_delivery/2` writes the key only when it is true, as a real
  boolean, and deletes it otherwise. A method that never had the flag gets
  no new key and no change. An update without the param (`:unset`) keeps
  what the metadata already holds. The core `<.checkbox>` renders a hidden
  `value="false"` input, so unchecking in the form reaches the changeset
  as `"false"` and clears the flag. Schema tests cover setting the flag,
  normalising a metadata-level `"true"`, unchecking while keeping
  `"carrier"`, and an update that does not send the flag.
- **Changeset: forced price.** `zero_pay_on_delivery_price/1` runs after
  the flag is resolved and before `validate_required(:price)`, so a
  pay-on-delivery method can be saved with the price field blank.
  `put_change` drops itself when the stored value is already 0 or nil, so
  an unrelated edit produces no diff.
- **Other write paths.** Every write goes through the changeset. The
  `toggle_active` call passes atom keys without the flag, so it is
  `:unset` and the flag stays. `reprice_shipping_methods_for_base_change/3`
  sends `price` (0 × multiplier) and no `free_above_amount`, so a
  pay-on-delivery method stays flagged and stays at 0. The compat
  delegates `create/update/change_shipping_method` and
  `present_shipping_method` already exist. The PR adds no new
  context-level public function, so `compat/shop.ex` needs no new
  delegate.
- **Totals are unchanged.** `recalculate_cart_totals!/1` still adds
  `calculate_shipping/3`, which is 0 for such a method. The PR changes no
  arithmetic. `convert_cart_to_order/2` always recalculates under the cart
  lock (`apply_checkout_shipping_country/2`) and reads a fresh
  `shipping_method` through `get_cart!/1`. So the line's flag, its 0 total
  and `order.metadata["shipping_pay_on_delivery"]` all come from one read.
  The context test checks `order.total == subtotal + tax`.
- **Line data and metadata.** Billing's `Order` stores `line_items` as
  `{:array, :map}` and `metadata` as `:map`, and only requires `"name"`
  per line, so both new keys persist as written. The same digital-only
  guard (`items_require_shipping?/1`) covers both the line and the
  metadata flag.
- **Display sites.** I searched `lib/` for `FREE`, `shipping_amount`,
  `free_for?` and the shipping line. Every storefront place that shows a
  shipping price is covered: cart list and summary, checkout list and
  summary, the review card, the confirmation page and user order details.
  The admin list and card view are covered too. Admin carts, the dashboard
  and notifications never show a shipping amount. `Notifications`
  includes only the order total. Every PubSub cart broadcast sends a cart
  from `recalculate_cart_totals!/1` (`preload ..., force: true`) or a
  `Repo.update` of a preloaded struct. So `@cart.shipping_method` is never
  `%NotLoaded{}` in the templates, and `pay_on_delivery?/1` returns
  `false` for one anyway.
- **Existing orders.** The templates match `item["pay_on_delivery"] ==
  true` and `@order.metadata["shipping_pay_on_delivery"] == true`. Orders
  without either key render as before. `nil["…"]` is nil if `metadata`
  were ever nil.
- **Auto-select.** The ranking is correct and the test is real: without
  the new clause the 0-price method wins and
  `"a pay-on-delivery method is not picked as the cheapest over a priced
  one"` fails. This is a product decision, not a defect: a shop that has
  both "Nova Poshta, pay on delivery" and a 150-unit courier will now
  pre-select the courier, so the cart opens with a shipping charge. The
  PR states this on purpose and documents it in the code comment. Worth
  telling hosts in the CHANGELOG.
- **i18n.** `default.pot` and all five `.po` files gain exactly the same
  5 msgids. `en` is empty, as usual. de/et/fr/ru are translated. There
  are no `fuzzy` flags anywhere, and the rest of the ~370-line diff per
  file only moves `#:` reference lines.
  `mix gettext.extract --check-up-to-date` passes.
- **Commits and PR body.** The author is the owner, there is no tool
  attribution, and the PR is a draft.

## Findings

### BUG - MEDIUM: the summary says "not included in this total" next to a total that still includes the old shipping fee

`lib/phoenix_kit_ecommerce/web/cart_page.ex:625-634` and `:671-678`,
`lib/phoenix_kit_ecommerce/web/checkout_page.ex:1875-1884` and
`:1917-1924`.

The new label and note follow the method's live flag
(`ShippingMethod.pay_on_delivery?(@cart.shipping_method)`). The total
beside them is the cart's stored `shipping_amount`/`total` snapshot, and
neither the cart page nor the checkout page recalculates it on mount.
`get_or_create_cart/1` (`lib/phoenix_kit_ecommerce.ex:2238`) and
`find_active_cart/1` only load the row.

Steps:

1. A shopper selects a "Nova Poshta" method priced 5.00. The cart stores
   `shipping_amount` 5.00 and `total` 30.00.
2. The admin converts that method to pay-on-delivery. The changeset sets
   its price to 0.
3. The shopper comes back to `/cart`, which can be any time in the
   30-day guest cart life.

The method is still available, so it stays selected. The summary now
shows "Shipping: Paid on delivery", "Total: 30.00", and "Shipping is not
included in this total". The checkout billing and shipping steps show
the same thing. The figure corrects itself only at review
(`preview_checkout_totals/2`) or after any quantity change, and the
order is always right because conversion recalculates. So no money is
wrong, but the page tells the buyer something false. Before this PR the
stale 5.00 was at least consistent with the stale total.

This is a realistic trigger: a carrier that a shop priced at a flat
estimate is the kind of method it would switch to pay-on-delivery.

**Fix (template-only, smallest):** show the pay-on-delivery label and the
note only while the stored amount is also 0. Otherwise fall through to
the existing amount branch, so the summary stays consistent with its
total:

```elixir
ShippingMethod.pay_on_delivery?(@cart.shipping_method) and
  Decimal.eq?(@cart.shipping_amount || Decimal.new("0"), 0)
```

The alternative is a targeted recalculation on mount when a
pay-on-delivery method has a non-zero stored amount. That corrects the
total itself, but `recalculate_cart_totals!/1` is private. A new public
wrapper would need a `compat/shop.ex` delegate (see the landmine).

Add a LiveView test: select a priced method, flip it with
`update_shipping_method(method, %{"pay_on_delivery" => "true"})`, mount
`/cart`, and assert that the summary and the total agree.

### IMPROVEMENT - MEDIUM: the admin form keeps showing a price that will not be saved

`lib/phoenix_kit_ecommerce/web/shipping_method_form.ex:176-219` and
`:224-236`.

With the box checked, the "Price" and "Free above" inputs stay editable,
and "Price" stays `required`. After a `validate` round trip they still
show what was typed, for example `3.00`, because the form reads
`changeset.params` first. On save the changeset quietly stores 0 and
`nil`. The hint explains it, but the form contradicts the hint until
save. If the admin clears the price field, which is natural for a method
that charges nothing, the browser's `required` blocks the submit.

**Fix:** while
`ShippingMethod.pay_on_delivery?(Ecto.Changeset.apply_changes(@changeset))`
is true, render both inputs `disabled`, or replace them with a short
"Paid on delivery" read-out. Disabled inputs are not submitted, the
changeset already forces both values, and `validate_required(:price)` is
satisfied by the forced 0. The form already re-renders on every change,
so no new event is needed.

### NITPICK: the `free?` guard in `present_shipping_method/2` is not tested

`lib/phoenix_kit_ecommerce.ex:5586`,
`test/phoenix_kit_ecommerce/shipping_pay_on_delivery_test.exs:32-36`.

The test's method goes through the changeset, which clears
`free_above_amount`. So `free_for?/2` is already false, and `not
pay_on_delivery? and` could be removed without the test failing. The
guard exists for a row that has both the flag and a threshold, for
example one written by SQL or an import that bypasses the changeset. Pin
it with a struct built directly:
`%ShippingMethod{price: 0, free_above_amount: 10, metadata:
%{"pay_on_delivery" => true}}`.

### NITPICK: the user order details change has no test, and its wording is doubled

`lib/phoenix_kit_ecommerce/web/user_order_details.html.heex:52-54`,
`:63-70`, `:125-131`.

The confirmation page is tested. Its twin in `UserOrderDetails` is not,
even though its template differs (it also prints the line description).
On that page the shipping row now reads "Shipping: Nova Poshta / Branch
pickup — Carrier rates, paid on delivery" on the left and "Paid on
delivery" on the right, so the same fact appears twice. It is harmless,
but a test there would also catch a future template divergence.

### NITPICK: the order-line comment promises more than billing delivers

`lib/phoenix_kit_ecommerce.ex:4287-4292`.

"so the confirmation page, emails and invoices do not print a bare 0.00"
holds for billing's HTML email tables and the invoice/receipt pages,
which print the description. It does not hold for two billing paths
(billing 0.19.1):

- `EmailDefaults.line_items_text/1` (`email_defaults.ex:220`) prints no
  description, so the plain-text part still says
  `Shipping: X x 1 @ 0 = 0`.
- Billing's admin order edit rebuilds every line from five keys only
  (`order_form.ex:143`, `:251-264`). The first admin edit drops
  `"pay_on_delivery"` (and `"type"`, already the case before this PR).
  After that, the shop's pages render the line as a product at 0.00
  under a note that still says shipping is excluded.

The PR description says billing is out of scope. Reword the comment, and
consider one more sentence in the AGENTS.md landmine: billing does not
read the flag.

### NITPICK: the `auto_select_shipping_method/2` docs still say "selects the cheapest one"

`lib/phoenix_kit_ecommerce.ex:3479-3485`. Add the pay-on-delivery
exception: a pay-on-delivery method is ranked with the unpriced methods
and is picked only when nothing priced is available. It is a public,
compat-delegated function, and this is a behaviour change.

### NITPICK: the same read is repeated in several templates

The line read `item["pay_on_delivery"] == true` appears in
`checkout_complete.ex:305` and `user_order_details.html.heex:63`. The
order read `@order.metadata["shipping_pay_on_delivery"] == true` appears
in `checkout_complete.ex:364` and `user_order_details.html.heex:125`.
The shipping-label `cond` appears three times: `cart_page.ex:625-634`,
`checkout_page.ex:1694-1701` and `:1875-1884`.

`PriceDisplay` already has `line_on_request?/1` and
`any_line_on_request?/1` for the parallel "price on request" case. A
`line_pay_on_delivery?/1` beside them would keep the read in one place.
A small shared function component for the summary label would turn the
BUG fix above into one edit instead of three.

### NITPICK: the activity log does not record the flag

`lib/phoenix_kit_ecommerce/web/shipping_method_form.ex:83-89` and
`:104-110`.

`shop.shipping_method_created/updated` records `slug` and `active`.
Turning pay-on-delivery on quietly sets the price to 0 and clears the
threshold, and an audit trail is where an operator would look for why.
Add `"pay_on_delivery" => ShippingMethod.pay_on_delivery?(method)` to
the metadata. It is not PII.

### NITPICK: flag parsing details

`lib/phoenix_kit_ecommerce/schemas/shipping_method.ex:257-292`.

- An unknown value such as `"on"` or `"yes"` is read as `false`.
- On the `:unset` path, a stored non-boolean value (`"yes"`) is deleted
  from `metadata` on the next unrelated update.

Both are fine for the bundled form, which posts `"true"`/`"false"`, and
the strictness is intended. The atom-key branch
(`Map.has_key?(attrs, :pay_on_delivery)`) has no test. Context callers
use atom keys (`%{active: …}`), so one case would pin it.

### NITPICK: the description is stored in the buyer's locale

`lib/phoenix_kit_ecommerce/price_display.ex:343`,
`lib/phoenix_kit_ecommerce.ex:4277-4278`.

`pay_on_delivery_description/0` is resolved in the converting process,
which is the buyer's locale, and frozen onto the line. This is
documented and is the only way billing can show the explanation without
a billing change. The side effect: billing admin and invoices show it in
the buyer's language, next to the hard-coded English "Shipping: <name>"
prefix. Mention only.

## Not changed, pre-existing

- The cart quantity forms (`cart_page.ex:484`) and the shipping method
  `<.form>` (`shipping_method_form.ex:132`) have no `id`. This causes the
  `missing_form_id` warnings that the new LiveView test also prints.
- The admin list labels `"Price"`/`"Delivery"` (card view) and
  `Free above …` are not wrapped in `gettext`. The shipping line name
  `"Shipping: #{name}"` is not translated either.
- A cart's stored shipping amount goes stale after any admin price edit
  until the cart is recalculated. The BUG above is the pay-on-delivery
  variant of this, which only became visible because the new label
  disagrees with the total.

## Validation

All runs used `MIX_ENV=test PGDATABASE=pkecom_test_domovych_pod PGPOOL=10`,
except the gates that need no database.

- The PR's three test files: 32 tests, 0 failures.
- Full `mix test`: 1620 tests, 0 failures (276 excluded). This matches
  the PR description.
- `mix format --check-formatted`: clean.
- `mix compile --warnings-as-errors --force`: clean.
- `mix credo --strict`: no issues (4600 mods/funs).
- `mix dialyzer`: passed (62 known skips, 0 unnecessary).
- `mix gettext.extract --check-up-to-date`: clean. No `fuzzy` in any
  catalogue.
- The working tree was unchanged after all runs.

## Verdict

**Request changes (small).** Fix the BUG - MEDIUM: either the
template-only gate on a zero stored amount, or a targeted recalculation,
plus one test. Then the PR can leave draft. The IMPROVEMENT and the
NITPICKs are optional, and they can also be done after merge. The core
of the PR is correct and the tests are real: the flag storage, the
forced price, the order snapshot, the unchanged totals, compatibility
with existing orders, and the translations.

---

## Round 2

- **Head SHA:** `47f28bb` (on top of round 1's `f779ca0`)
- **New commits:**
  - `a6923b0` Add review notes for PR #75
  - `f699908` Lock price fields in the shipping form for pay-on-delivery
    methods
  - `47f28bb` Fix pay-on-delivery label shown beside a stale shipping
    total
- **Verdict:** **approve.** Every round-1 finding is closed or explicitly
  accepted. Round 2 adds no bug. Four new nitpicks, none blocking.

### Round-1 findings: status

| Round-1 finding | Status | Where |
|---|---|---|
| BUG - MEDIUM: the label and note sat beside a stale total | **Fixed, two ways** | `PriceDisplay.cart_shipping_pay_on_delivery?/1` (`price_display.ex:162-171`) shows the label and note only while the method is flagged AND the stored amount is 0, so the summary can no longer contradict its total. `refresh_pay_on_delivery_shipping/1` (`phoenix_kit_ecommerce.ex:3418-3449`) corrects the total itself on mount (`cart_page.ex:79`, `checkout_page.ex:65`). Tests: `/cart` and `/checkout` now show 25.00, not 30.00, after the method is flipped. |
| IMPROVEMENT - MEDIUM: the form showed a price that is never saved | **Fixed** | `shipping_method_form.ex:188-192, 228`: Price and Free above are `disabled` with a forced display value. Price is no longer `required`. `@pay_on_delivery` is derived once in `assign_form/2` (`:394-399`). Test checks `disabled`/`required` before and after `render_change`. |
| The `free?` guard was untested | **Fixed** | A struct with both the flag and a threshold, built without the changeset, stays `free?: false`. |
| User order details: no test, wording doubled | **Fixed** | `PriceDisplay.line_description/1` (`:396-408`) drops the stored suffix. A test-only route `/dashboard/orders/:uuid` (`test/support/test_router.ex`) plus a test assert exactly one "paid on delivery" on the line. |
| The comment promised more than billing delivers | **Fixed** | `phoenix_kit_ecommerce.ex:4339-4343` and the AGENTS.md landmine now say billing does not read the flag: the plain-text email prints 0 and the admin order edit drops the key. |
| `auto_select_shipping_method/2` docs | **Fixed** | `:3527-3535`. |
| The same read repeated in several templates | **Fixed** | `line_pay_on_delivery?/1`, `order_shipping_pay_on_delivery?/1`, `cart_shipping_pay_on_delivery?/1` sit beside `line_on_request?/1`, and every template goes through them. The `cond` still appears three times, but each copy is a one-line helper call. |
| The activity log did not record the flag | **Fixed** | Both create and update log `"pay_on_delivery"`. A test uses `assert_activity_logged`. |
| Flag parsing details | **Partly** | The atom-key branch is now tested. `"on"`/`"yes"` → `false` is intended and stays as is. |
| The description is stored in the buyer's locale | **Accepted** | Documented in `line_description/1`. In another locale the suffix is not stripped, so it is repeated but not wrong. |

### Checks (round 2)

- **The refresh has no cost on the common path.**
  `stale_pay_on_delivery_shipping?/1` is a pure pattern match on the
  already-preloaded cart. It needs `shipping_method.uuid ==
  shipping_method_uuid`, so a leftover preload after a cleared selection
  does not count. A cart that is not stale comes back as the same struct
  with no query. The test `{:ok, ^cart}` pins that.
- **A DB write on mount.** It writes only when the cart is stale, which
  is a one-off after an admin flips a method. The disconnected render
  writes, and the connected mount then sees a fresh cart and does
  nothing. The shop's GET mounts already write (`get_or_create_cart/1`
  creates the cart, `auto_select_shipping_method/2` sets shipping), so
  this does not introduce a new pattern.
- **Concurrent conversion.** `lock_active_cart!/1` takes the cart row
  `FOR UPDATE` and rolls back `:cart_not_active` once conversion has
  flipped the status. The pages then keep the cart as loaded, and the
  summary falls back to the stored amount, which is consistent.
  - If the refresh holds the lock first, the conversion's atomic
    `active→converting` UPDATE waits. It then still matches `active` and
    recalculates under its own lock anyway.
  - There is no deadlock: both paths take the cart row first, and the
    refresh never locks product rows.
  - The same lock serializes the refresh with
    `add_to_cart`/`update_cart_item`.
- **No broadcast loop.** The refresh broadcasts `cart_updated` once, only
  after a write. Neither page's `handle_info({:cart_updated, _})` calls
  the refresh. `CartPage.assign_cart_state/2` does not, and
  `CheckoutPage.assign_cart_repriced/2` reaches `preview_checkout_totals/2`,
  which does not broadcast. Each page subscribes after its mount-time
  refresh.
- **Guests and other people's carts.** The pages pass only the cart they
  resolved from the visitor's own user or session
  (`get_or_create_cart/1`, `find_active_cart/1`). No uuid comes from
  params. The context function is scope-less like the rest of the public
  API. All it can do to any cart is recompute that cart's own totals,
  which is idempotent and corrective. The compat delegate is added
  (`compat/shop.ex:146`).
- **Disabled fields keep their values.**
  - Disabled inputs are not serialized, so `validate` and `save` send no
    price or threshold. The changeset forces 0 and `nil` while the box is
    checked.
  - `validate` always rebuilds from `socket.assigns.method`. So
    unchecking before save on an existing priced method brings back its
    stored price and threshold (not the forced 0). Unchecking on an
    existing pay-on-delivery method shows its stored 0, ready to edit.
  - The only thing lost is a price typed into a *new* method before the
    box was checked. That is expected, since the lock discards it.
  - The `value` override works: core `input/1` declares `attr :value`
    with no default and uses `assign_new(:value, …)`. So `%{value: "0"}`
    and `%{value: nil}` win over `field.value`.
- **i18n.** No new msgids. The round-2 `.po`/`.pot` diff is `#:`
  reference churn only, there are no `fuzzy` flags, and
  `gettext.extract --check-up-to-date` is clean.

### New findings (round 2)

#### NITPICK: the refresh repeats on every mount for a flagged row with a non-zero price

`phoenix_kit_ecommerce.ex:3440-3447`.

"Stale" means "flagged and stored amount ≠ 0". A row written around the
changeset with the flag set and `price > 0` breaks that assumption. Such
rows exist: round 2's own `free?` test is built for one, "SQL, an
import". The recalculation then stores the same non-zero amount again,
so every cart and checkout mount takes the row lock, writes and
broadcasts. Nothing is shown wrongly: the summary shows the stored
amount. But the write repeats on every page view.

Fix: add `Decimal.eq?(method.price || 0, 0)` to
`stale_pay_on_delivery_shipping?/1`, or compare against the computed
charge.

#### NITPICK: the " — " joiner lives in two modules

The stored description is joined in `shipping_line_description/2`
(`phoenix_kit_ecommerce.ex:4361`, `Enum.join(" — ")`). It is stripped in
`PriceDisplay.line_description/1` (`price_display.ex:404`,
`replace_suffix(" — " <> note)`). If someone changes one, the suffix
quietly stops being stripped. Build the stored description in
`PriceDisplay` too, next to its inverse.

#### NITPICK: "Price *" keeps its asterisk while the field is locked

`shipping_method_form.ex:188` hard-codes `" *"` in the label. While the
field is disabled and not required, the label still says required.
(Already true before this PR: when the field *is* required, core
`input/1` adds its own red marker, so the label reads "Price * *".)
Dropping the manual `" *"` fixes both.

#### NITPICK (process): the round-1 review is committed into the PR

`a6923b0` adds `dev_docs/pull_requests/2026/75-pay-on-delivery-shipping/CLAUDE_REVIEW.md`
with round 1's "Status: Draft" and "Verdict: request changes". If it
merges as is, `main` records a rejection for a PR it accepted. Two
options:

- Update the file with this round.
- Drop it and let the maintainer add the review after merge, as for
  #59–#71 ("Review PR #N …" commits on `main`).

### Validation (round 2)

All runs used `MIX_ENV=test PGDATABASE=pkecom_test_domovych_pod PGPOOL=10`,
except the gates that need no database.

- The PR's three test files: 42 tests, 0 failures.
- Full `mix test`: 1630 tests, 0 failures (276 excluded). This matches
  the author's figure.
- `mix format --check-formatted`, `mix compile --warnings-as-errors
  --force` and `mix gettext.extract --check-up-to-date`: clean.
- `mix credo --strict`: no issues (4612 mods/funs).
- `mix dialyzer`: passed.
- The working tree was unchanged after all runs.

### Verdict (round 2)

**Approve.** The stale-total contradiction is gone in both directions:
the label is gated on the stored amount, and the total is repaired on
mount under the cart lock. The race and broadcast behaviour hold up. The
form lock does not lose stored values. Every round-1 item is closed or
deliberately accepted. The four nitpicks above are optional; the
committed round-1 review file is the one worth sorting out before or at
merge.

---

## Round 3

- **Head SHA:** `2dfd618`, on top of round 2's `47f28bb`.
- **New commits:**
  - `ab27436`: updates the committed review file with rounds 1–2. It is
    identical to this file as of round 2.
  - `2dfd618`: "Fix round-2 review nitpicks for pay-on-delivery shipping".
- **Verdict:** **approve.** All three code nitpicks are fixed and each
  has a test that would fail without the fix. The process nitpick is
  resolved. No regressions, and nothing new found in the PR's own code.

### Round-2 findings: status

| Round-2 finding | Status | Where |
|---|---|---|
| The refresh repeated on every mount for a flagged row with a non-zero price | **Fixed** | `stale_pay_on_delivery_shipping?/1` (`phoenix_kit_ecommerce.ex:3440-3451`) now also requires `method.price == 0`. |
| The " — " joiner lived in two modules | **Fixed** | One `@line_description_joiner` in `PriceDisplay`, used by `pay_on_delivery_line_description/1` (the stored form) and its inverse `line_description/1`. |
| "Price *" kept its asterisk while locked | **Fixed** | The manual `" *"` is gone (`shipping_method_form.ex:188`). Core `input/1` now draws the only marker, and only while the field is `required`. |
| The round-1 review was committed into the PR | **Resolved** | `ab27436` brings the committed file up to round 2. If the file stays in the PR, add this round before merge so `main` records the final verdict. |

### What each fix and its test show

- **The refresh is now idempotent for every row.**
  - When a flagged method's price is 0, `calculate_cost/2` returns 0 in
    every branch. That holds with or without a stray threshold and
    whether or not the method is still available. So one recalculation
    always leaves the cart non-stale.
  - A flagged row that still has a price (written by SQL or an import) is
    now left alone. Its summary shows the stored amount, which matches
    the total, because the round-2 label gate needs a stored 0.
  - Test `"leaves a cart alone when the flagged method still has a
    price"`: it sets the flag with `Repo.update_all`, which goes around
    the changeset, then subscribes to the cart topics. It asserts `{:ok,
    ^cart}` (the same struct back, no write) and `refute_receive
    {:cart_updated, _}`.
  - The `refute_receive` checks something real. The test env starts
    `PhoenixKit.PubSub.Manager` (`test_helper.exs:151`), and other suites
    receive `Events` broadcasts (`ai_translatable_test.exs:743`). Without
    the new clause the cart comes back recalculated and the broadcast
    arrives, so both assertions fail.
- **The joiner round-trip.** The test builds the stored form with
  `pay_on_delivery_line_description/1` and strips it with
  `line_description/1`. It covers a method with a description, one
  without (strips to `""`), and a line without the flag (left unchanged).
  What gets stored is unchanged ("Branch pickup — Carrier rates, paid on
  delivery"), and the round-1 conversion test still pins it.
- **Asterisks.** The test counts `*` inside
  `label[for='shipping_method_price']`: 1 while editable, 0 after the box
  is checked. The msgid is the existing `"Price"`. The `.po`/`.pot`
  diff is only reference-line churn, and there are no `fuzzy` flags.

### Not changed, pre-existing

- `Name` (`shipping_method_form.ex:151`) still has a manual `" *"` and is
  `required`, so it reads "Name * *". The PR does not touch it. The same
  one-line fix as for Price would apply.

### Validation (round 3)

All runs used `MIX_ENV=test PGDATABASE=pkecom_test_domovych_pod PGPOOL=10`,
except the gates that need no database.

- The PR's three test files: 44 tests, 0 failures.
- Full `mix test`: 1632 tests, 0 failures (276 excluded). This matches
  the author's figure.
- `mix format --check-formatted`, `mix compile --warnings-as-errors
  --force` and `mix gettext.extract --check-up-to-date`: clean. No
  `fuzzy` in any catalogue.
- `mix credo --strict`: no issues (4614 mods/funs).
- `mix dialyzer`: passed.
- The working tree was unchanged after all runs.

### Verdict (round 3)

**Approve.** Every finding from rounds 1 and 2 is closed. The PR is
ready to leave draft once the committed review file carries this round,
if it is kept in the PR.
