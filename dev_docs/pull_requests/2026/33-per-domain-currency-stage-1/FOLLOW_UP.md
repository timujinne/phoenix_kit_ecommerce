# PR #33 follow-up — Per-domain currency, stage Э1

Triage of `KIMI_REVIEW.md` against current code, by reading.

## Fixed (pre-existing)

- ~~#1 BUG - MEDIUM: `fx_refresh_if_emptied/2` crashed on `nil.code` when
  the currency table was emptied mid-cart.~~ Guarded
  (`lib/phoenix_kit_ecommerce.ex:6853-6872`).
- ~~#2 IMPROVEMENT - MEDIUM: `shop_enforce_product_currency` read directly
  inside the add-to-cart transaction.~~ `enforce_product_currency?/0`
  rescues to `false` (`lib/phoenix_kit_ecommerce.ex:592-598`).
- ~~#3 NITPICK: delegate without parentheses.~~
  `lib/phoenix_kit_ecommerce/compat/shop.ex:42`.
- ~~#4 NITPICK: "100% OFF" for a product with no price.~~ A nil asking price
  returns no badge (`price_display.ex:363-368`).
- ~~Unverified surface: `format_product_price/3` fed a display-currency
  code.~~ No storefront caller remains; only the `compat/` delegate
  references it.

## Fixed (Batch 1 — 2026-10-13)

- ~~#5 NITPICK: the "OFF" badge was hardcoded English.~~
  `gettext("%{percent}% OFF", …)` on the product page
  (`web/catalog_product.ex:947`, `:960`) and translated in every locale.
- ~~Stage-2 note: `cart_rate_drift/1` divided by the frozen rate with no zero
  guard.~~ A cart frozen at a non-positive rate reports no drift
  (`lib/phoenix_kit_ecommerce.ex:764-775`;
  `test/phoenix_kit_ecommerce/cart_fx_drift_test.exs`, "a cart frozen at a
  zero rate…").

## Skipped (with rationale)

- **`mix.exs` floors that admitted no Hex release / lock not updated in the
  same change.** The review recorded both as acknowledged and remediated by a
  later PR; the floor is `>= 2.43.0 and < 3.0.0` today (`mix.exs:118`).

## Files touched

| File | Change |
|---|---|
| `lib/phoenix_kit_ecommerce.ex` | zero-rate guard in `cart_rate_drift/1` |
| `lib/phoenix_kit_ecommerce/web/catalog_product.ex` | translated badge |
| `test/phoenix_kit_ecommerce/cart_fx_drift_test.exs` | zero-rate test |

## Verification

`PGUSER=maxdon mix test` — 2891 tests, 0 failures. `mix precommit` (compile `--warnings-as-errors`, format, `credo --strict`, dialyzer) — exit 0, dialyzer 0 unnecessary skips. Run on the tree that carries this file.

## Fixed (Batch 2 — 2026-10-14)

- ~~Changing the base currency on a catalogue-backed shop: an untranslated,
  generic refusal.~~ Refused by decision, with an honest translated message
  and a pre-check (`base_currency_change_supported/0`,
  `lib/phoenix_kit_ecommerce.ex`; `errors.ex`). The reprice pass itself
  stays open below.

`PGUSER=maxdon mix test` — 3099 tests, 0 failures. `mix precommit` — exit 0 (dialyzer 0 unnecessary skips). Run on the tree that carries this batch.

## Open

- **`build_cart_message/5` dereferences the line `find_cart_item_after_add/4`
  returned, with no nil guard**
  (`lib/phoenix_kit_ecommerce/web/catalog_product.ex:747-754`, `:763-772`).
  The lookup matches on `selected_specs` exactly as the page sent them; if the
  stored line's specs ever differ from that map, the add succeeds and the
  flash raises. Not reproduced.
- **Catalogue shops cannot change base currency** — refused by decision.
  `reprice_for_base_change/3` reprices the shop's own tables only; the
  refusal now has a translated message (`Errors.message/1` on
  `{:unsupported_product_source, _}`) and `base_currency_change_supported/0`
  for a screen to ask before its confirm step. The catalogue reprice pass is
  to be built when a shop needs the change. No screen in this module offers
  the change; billing's Currencies page "set default" calls
  `set_default_currency/1`, which reprices nothing on any source.
