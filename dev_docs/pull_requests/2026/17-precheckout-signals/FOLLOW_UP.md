# PR #17 follow-up — Pre-checkout signals and shipping-skip modes

Triage of `CLAUDE_REVIEW.md` against current code, by reading.

## Fixed (pre-existing)

- ~~#1 BUG - HIGH: checkout dead-ended under `position: "checkout"`.~~
  `reject_invalid_shipping_selection/1`
  (`lib/phoenix_kit_ecommerce/web/checkout_page.ex:1025`).
- ~~#2 BUG - MEDIUM: the blocked shipping step had no exit.~~
  `.shipping_back_button` in every state (`web/checkout_page.ex:1974`,
  `:1989`).
- ~~#3 BUG - MEDIUM: `mix precommit` was red as merged.~~ Green (see
  Verification).
- ~~#4 BUG - MEDIUM: two settings with no way to set them.~~
  `#shop-shipping-modes-card` (`web/settings.ex:427`).
- ~~#5 BUG - MEDIUM: step indicator blank on `:shipping`.~~ Fixed in
  `render/1`.
- ~~#6 BUG - MEDIUM: Continue accepted a method not on offer.~~
  `web/checkout_page.ex:1969`.
- ~~#7 BUG - MEDIUM: the shipping step could clear the cart's country.~~
  `apply_billing_country/2` writes a non-empty binary only
  (`web/checkout_page.ex:957-964`).
- ~~#8 BUG - MEDIUM: undisclosed scope and dependency.~~ CHANGELOG entries
  written; the dependency is documented in AGENTS.md → Overview.
- ~~#9 BUG - MEDIUM: the recipient list was a snapshot.~~ Intersected with
  current `shop.manage_carts` holders on every send (`notifications.ex`,
  `shop_recipients/0`).
- ~~#11 OBSERVATION: German transliteration applied to every language.~~
  `Product.slugify/2` goes through core's `PhoenixKit.Utils.Slug` with the
  language (`schemas/product.ex:45`, `:332`); the module's own table is gone.

## Fixed (Batch 1 — 2026-10-13)

- ~~#10 BUG - LOW: `hreflang_links` (and `canonical_url`) were assigned and
  rendered nowhere.~~ The contract is now written down and tested: the
  storefront assigns `og`, `canonical_url` and `hreflang_links`, core's root
  layout reads `og` only (its canonical link comes from `og.url`), and a host
  renders the other two in its own root layout — `README.md:378` on and
  AGENTS.md → Conventions. The test root layout renders all three
  (`test/support/test_layouts.ex`) and
  `test/phoenix_kit_ecommerce/web/storefront_head_tags_test.exs` asserts each
  on the catalog, category and product pages. `hreflang` is still not emitted
  under core's own root layout — see Open.
- ~~#12 NITPICK: two tests double-fired the notification they asserted
  on.~~ Both assert on `add_to_cart/3` alone
  (`test/phoenix_kit_ecommerce/notifications_test.exs`).

## Skipped (with rationale)

- **#13 NITPICK: `notify_event?/1` has no catch-all clause**
  (`lib/phoenix_kit_ecommerce.ex:578`). The review left it: an internal API
  failing loudly on an unknown key, and both call sites are literals.
- **#14 OBSERVATION: `items_count == item.quantity` as "first item".** The
  review left it: it can mislabel once per cart at most.

## Files touched

| File | Change |
|---|---|
| `test/support/test_layouts.ex` | root layout renders the three SEO assigns |
| `test/phoenix_kit_ecommerce/web/storefront_head_tags_test.exs` | new |
| `README.md`, `AGENTS.md` | the host's part of the contract |
| `test/phoenix_kit_ecommerce/notifications_test.exs` | single send per assertion |

## Verification

`PGUSER=maxdon mix test` — 2891 tests, 0 failures. `mix precommit` (compile `--warnings-as-errors`, format, `credo --strict`, dialyzer) — exit 0, dialyzer 0 unnecessary skips. Run on the tree that carries this file.

## Open

- **#10 (rest): core's root layout does not render `hreflang_links`**, so a
  host on core's root layout emits no language alternates. That is a
  `phoenix_kit` change (`lib/phoenix_kit_web/components/layouts/root.html.heex`
  reads `og` only); this module can only document it.
