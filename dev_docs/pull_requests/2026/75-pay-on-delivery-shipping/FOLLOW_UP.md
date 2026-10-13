# PR #75 follow-up — Pay-on-delivery shipping methods

Triage of `CLAUDE_REVIEW.md` (three rounds) and
`CLAUDE_POST_MERGE_REVIEW.md` against current code, by reading.

## Fixed (pre-existing)

- ~~Round 1 BUG - MEDIUM: "not included in this total" beside a total that
  still included the old fee.~~ `cart_shipping_pay_on_delivery?/1` needs a
  stored 0, and `refresh_pay_on_delivery_shipping/1` corrects the total on
  mount (`lib/phoenix_kit_ecommerce.ex:3823`, `web/cart_page.ex:86`,
  `web/checkout_page.ex:80`).
- ~~Round 1 IMPROVEMENT and nitpicks (locked price fields, `free?` guard
  test, doubled wording, comment, `auto_select_shipping_method/2` docs,
  repeated read, flag in the activity log).~~ All closed in rounds 2–3 as
  the review's own status tables record; `PriceDisplay` holds the helpers.
- ~~Round 2: refresh repeated on every mount for a flagged row with a
  price.~~ `stale_pay_on_delivery_shipping?/1`
  (`lib/phoenix_kit_ecommerce.ex:3845-3858`).
- ~~Round 2: the " — " joiner lived in two modules.~~
  `@line_description_joiner` (`price_display.ex:62`, `:401`, `:420`).
- ~~Round 2: "Price *" kept its asterisk while locked.~~ Removed.
- ~~Post-merge BUG - MEDIUM: `uk` lacked the five #75 strings.~~ Translated;
  "carries every msgid in the template"
  (`test/phoenix_kit_ecommerce/i18n_test.exs:185`).
- ~~Pre-existing: the shipping method form had no `id`.~~
  `id="shipping-method-form"` (`web/shipping_method_form.ex:196-198`).

## Fixed (Batch 1 — 2026-10-13)

- ~~Pre-existing: the admin list labels "Price" / "Delivery" / "Free above"
  were not translated.~~ Wrapped (`web/shipping_methods.ex`).
- ~~Pre-existing: the order's shipping line name `"Shipping: #{name}"` was
  not translated.~~ `gettext("Shipping: %{method}", …)`, resolved in the
  locale of the process converting the cart — the buyer's — like the line's
  description (`lib/phoenix_kit_ecommerce.ex:5519-5521`;
  `test/phoenix_kit_ecommerce/web/admin_copy_i18n_test.exs`, "an order's
  shipping line is named in the buyer's locale").
- ~~Round 3, pre-existing: "Name * *" on the shipping method form.~~ The
  manual marker is gone (`web/shipping_method_form.ex`).
- ~~Pre-existing: the cart quantity forms had no `id`.~~
  `id={"cart-quantity-form-#{item.uuid}"}` (`web/cart_page.ex:540`;
  asserted in `test/phoenix_kit_ecommerce/web/public_event_fallback_test.exs`).

## Skipped (with rationale)

- **The description is stored in the buyer's locale** — accepted by the
  review and documented on `PriceDisplay.line_description/1`.
- **`"on"` / `"yes"` read as `false` by the flag parser** — the review
  recorded it as intended.
- **Billing's plain-text email prints the line as 0.00 and its admin order
  edit drops the key** — the review placed the fix in `phoenix_kit_billing`;
  recorded in AGENTS.md → Landmines.

## Files touched

| File | Change |
|---|---|
| `lib/phoenix_kit_ecommerce.ex` | translated shipping line name |
| `lib/phoenix_kit_ecommerce/web/shipping_methods.ex`, `web/shipping_method_form.ex` | translated labels, single required marker |
| `lib/phoenix_kit_ecommerce/web/cart_page.ex` | quantity form id |
| `priv/gettext/*` | new msgids, all locales |

## Verification

`PGUSER=maxdon mix test` — 2891 tests, 0 failures. `mix precommit` (compile `--warnings-as-errors`, format, `credo --strict`, dialyzer) — exit 0, dialyzer 0 unnecessary skips. Run on the tree that carries this file.

## Open

- **A cart's stored shipping amount goes stale after an admin edits the
  method's price**, until something recalculates the cart. Only the
  pay-on-delivery flip is corrected on mount
  (`refresh_pay_on_delivery_shipping/1`,
  `lib/phoenix_kit_ecommerce.ex:3823-3858`); an ordinary price change is not.
