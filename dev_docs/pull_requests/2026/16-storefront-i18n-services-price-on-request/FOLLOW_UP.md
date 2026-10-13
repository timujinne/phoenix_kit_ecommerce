# PR #16 follow-up — storefront i18n, services, price on request

Triage of `CLAUDE_REVIEW.md` against current code, by reading.

## Fixed (pre-existing)

- ~~**#1 BUG - HIGH** `shop_hide_zero_decimals` rounded the price~~ —
  `display_currency/2` trims only when `whole?/2` holds
  (`web/helpers.ex:87-108`).
- ~~**#2 / #3 BUG - MEDIUM** on-request lines rendered `0.00` on the checkout
  review step and in the "Already in cart" notice~~ — both go through
  `PriceDisplay.line_on_request?/1` (`web/catalog_product.ex:1084`; 14 call
  sites of the two predicates across `lib/`).
- ~~**#4 BUG - MEDIUM** checkout page untranslated~~ — no bare English text
  node from the review's list remains in `web/checkout_page.ex`; the order
  failure message is wrapped (`:1274`).
- ~~**#5 BUG - MEDIUM** add-to-cart failure messages untranslated~~ — the bare
  `|| "option"` is gone from `web/catalog_product.ex`.
- ~~**#6 BUG - MEDIUM** vocabulary-dependent strings bypassed `Vocabulary`~~ —
  `Vocabulary.count_found/1` (`vocabulary.ex:182`) and `showing_of/2` (`:201`);
  no `product(s)` literal remains in `lib/`.
- ~~**#7 BUG - MEDIUM** totals silently omit on-request lines~~ —
  `PriceDisplay.any_line_on_request?/1` discloses it on the cart
  (`web/cart_page.ex:757`), checkout (`web/checkout_page.ex:2412`),
  confirmation (`web/checkout_complete.ex:364`) and order details
  (`web/user_order_details.html.heex:125`).
- ~~**#8 BUG - MEDIUM** public order pages translated against core's backend~~ —
  no `PhoenixKitWeb.Gettext` call remains in the public order pages. The
  remaining runtime-form calls are in admin pages (`web/products.ex`,
  `web/categories.ex`, `web/import_show.ex`), which the review explicitly left
  out of scope.
- ~~**#9 NITPICK** identity `case` in the status toggle~~ — single `case`
  (`web/products.ex:925`).
- ~~**#10 NITPICK** `admin_edit_label` untranslated~~ — no string-literal
  `assign(:admin_edit_label, …)` remains.

## Skipped (with rationale)

- **#11 OBSERVATION** the confirmation page quotes an email subject core owns
  (`web/checkout_complete.ex:206-207`) — still so; the reviewer left it as a
  copy decision or a core API this module cannot add.
- **#12 OBSERVATION** `Vocabulary.current/0` and `hide_zero_decimals?/0` read
  settings without a rescue — not re-checked; the reviewer left it for
  consistency with the other cosmetic storefront readers.

## Open

None.
