# Week of 2026-09-07 → 2026-09-13 review follow-up (0.5.0 – 0.5.3)

Triage of `CLAUDE_REVIEW.md` against current code, by reading.

## Fixed (pre-existing)

The review fixed every finding in its tables (C1–C10, Q1–Q8, S1–S10, W1–W3,
I1–I6) in the commit that carried it. Spot re-checks against current code:

- ~~C1, C2.~~ `rebase_cart/1` (`lib/phoenix_kit_ecommerce.ex:3409-3411`),
  `present_shipping_method/2` (`:6960`).
- ~~C4.~~ `Helpers.schedule_fx_reload/2` (`web/helpers.ex:177`).
- ~~C8, C9.~~ `base_decimal_places/0`, `shop_fx_rate_drift_alert_pct`
  (`lib/phoenix_kit_ecommerce.ex:700`).
- ~~Q1.~~ Catch-all clauses in `FilterHelpers`
  (`web/components/filter_helpers.ex:336-348`).
- ~~Q2, Q3.~~ Translated-name search for items and categories
  (`product_source/catalogue/query.ex:893`, `:934`).
- ~~S1.~~ Unsafe link schemes dropped (`html_to_markdown.ex:47`, `:525`).
- ~~S2, S3.~~ Pinned address and a size cap enforced while streaming
  (`services/image_downloader.ex:667-731`, `:850`).
- ~~S5.~~ `sync_variants/3` forwards the job's `actor_uuid`
  (`catalogue/writer.ex:240-256`).
- ~~S8.~~ Non-additive matrices: `VariantMapper.build/2` rules and warnings
  (`shopify/variant_mapper.ex:37-75`).
- ~~S10.~~ `numeric_id/2` (`shopify/admin_client.ex:115`, `:138`).
- ~~I1.~~ The core floor is `>= 2.43.0 and < 3.0.0` (`mix.exs:118`), guarded
  by `test/core_pin_conformance_test.exs`.

## Fixed (Batch 1 — 2026-10-13)

"Left open" items the review listed:

- ~~`ProductSource.current/0` is one primary-key read per facade call.~~
  The answer is memoized per process for `:product_source_memo_ms`
  (`product_source.ex:51-100`;
  `test/phoenix_kit_ecommerce/product_source_memo_test.exs`). Not a node-wide
  cache: nothing in this package writes the row, so there is no write to
  invalidate on.
- ~~Cart and checkout mounts do not rebase a stale cart.~~ Both rebase on
  mount, before the pay-on-delivery refresh (`web/cart_page.ex:86`,
  `web/checkout_page.ex:80`), and subscribe before reading
  (`web/checkout_page.ex:71`;
  `test/phoenix_kit_ecommerce/web/cart_rebase_on_mount_test.exs`).

## Files touched

| File | Change |
|---|---|
| `lib/phoenix_kit_ecommerce/product_source.ex` | per-process memo |
| `lib/phoenix_kit_ecommerce/web/cart_page.ex`, `web/checkout_page.ex` | rebase and subscribe on mount |

## Verification

`PGUSER=maxdon mix test` — 2891 tests, 0 failures. `mix precommit` (compile `--warnings-as-errors`, format, `credo --strict`, dialyzer) — exit 0, dialyzer 0 unnecessary skips. Run on the tree that carries this file.

## Fixed (Batch 2 — 2026-10-14)

- ~~Two option values with the same translated label collapse in the
  catalogue picker.~~ A value's key is its identity: picker, add-to-cart,
  pricing and the cart line go by key, with a label snapshot
  (`selected_specs.ex`, `product_source/catalogue/view.ex`); old label
  lines display, update and convert unchanged.
- ~~A "whole set applies" attachment renders no picker.~~ An empty
  selection offers every published value of the set
  (`view.ex` `offered_value_keys/1`, `product_source/catalogue.ex`).
- ~~`Migrations.up/1` ignores `:version`.~~ It applies V1..N and stamps N,
  leaves a newer database alone, refuses a target outside the chain
  (`migrations.ex`); the shipped SQL is pinned by digest.
- ~~`UserOrders`/`UserOrderDetails` reached only through `compat/`.~~ Not
  so: core's `PhoenixKitWeb.Integration` routes `/dashboard/orders` and
  `/dashboard/orders/:uuid` to the real modules; `compat/` is deprecated.

`PGUSER=maxdon mix test` — 3099 tests, 0 failures. `mix precommit` — exit 0 (dialyzer 0 unnecessary skips). Run on the tree that carries this batch.

## Open

- **Catalogue shops cannot change base currency** — refused by decision.
  `reprice_for_base_change/3` reprices the shop's own tables only; the
  refusal now has a translated message (`Errors.message/1` on
  `{:unsupported_product_source, _}`) and `base_currency_change_supported/0`
  for a screen to ask before its confirm step. The catalogue reprice pass is
  to be built when a shop needs the change. No screen in this module offers
  the change; billing's Currencies page "set default" calls
  `set_default_currency/1`, which reprices nothing on any source.
- **Removing `compat/`** — deprecated by decision; removal (with
  `ignore_module_conflict: true` in `mix.exs`) one release after the
  deprecation ships, once each host is checked for the old names.
