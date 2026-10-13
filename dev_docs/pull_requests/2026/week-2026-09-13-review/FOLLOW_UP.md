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

## Open

- **`reprice_for_base_change/3` refuses the catalogue product source** —
  awaiting the maintainer's decision. A base-currency change on a
  catalogue-backed shop is impossible until a catalogue reprice pass exists
  (`lib/phoenix_kit_ecommerce.ex:6208`).
- **Removing `compat/`** — awaiting the maintainer's decision
  (`lib/phoenix_kit_ecommerce/compat/`, `mix.exs:19`
  `ignore_module_conflict: true`). `UserOrders` and `UserOrderDetails` are
  still reached only through that namespace: this module registers no route
  for them.
- **Two option values with the same translated label collapse in the
  catalogue picker** — awaiting the maintainer's decision
  (`product_source/catalogue/view.ex:436`, `Map.new/2` keyed by the label).
  The label is what a cart line stores as its selection, so deduplicating it
  changes the cart-line identity.
- **A "whole set applies" attachment (empty selection) renders no picker**
  and its price modifiers are unreachable. The review left it as a product
  decision: catalogue documents the empty selection as intentional.
- **`Migrations.up/1` ignores `:version`** — awaiting the maintainer's
  decision (`lib/phoenix_kit_ecommerce/migrations.ex:134-140`: it always
  applies the whole chain, while `down/1` honours `:version`). Not a finding
  of this review; recorded here because it concerns the same release train
  and no PR folder owns it.
