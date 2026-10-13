# 0.5.0 release sweep follow-up (PRs #32–#46)

Triage of `GROK_REVIEW.md` against current code, by reading.

## Fixed (pre-existing)

The review fixed its findings 1–25 in the commit that shipped 0.5.0. Spot
re-checks against current code:

- ~~#2, #3: facet visibility and listing order.~~
  `lib/phoenix_kit_ecommerce/product_source/catalogue/query.ex:784-791`, `:813`.
- ~~#4: category modifiers dropped at add-to-cart.~~
  `lib/phoenix_kit_ecommerce.ex:2973-2989`.
- ~~#6, #7: empty-cart FX crash, "100% OFF" with no price.~~
  `lib/phoenix_kit_ecommerce.ex:6853-6872`, `price_display.ex:363-368`.
- ~~#17: a crash mid media-sync left the button disabled.~~
  `fail_progress/2` (`workers/shopify_media_sync_worker.ex:298`).
- ~~#18–#21, #23.~~ `enforce_product_currency?/0`
  (`lib/phoenix_kit_ecommerce.ex:592`), safe modifier parse
  (`options/options.ex:1142-1152`), `:product_type` filter
  (`query.ex:795`), hidden categories in vendor/price facets
  (`query.ex:247`, `:271`), `product_deleted?/1`
  (`schemas/cart_item.ex:348`).

"Left open" items the review listed, now resolved before this sweep:

- ~~Independent Shopify option modifiers do not reconstruct per-SKU
  prices.~~ `VariantMapper.build/2` fits a non-additive matrix under a
  `rule:` (`:never_cheaper` by default), returns a `:fit` summary and
  warnings (`shopify/variant_mapper.ex:37-75`); the worker records them.
- ~~DNS-rebinding TOCTOU on image download.~~ The vouched address is pinned
  for the request on every hop (`services/image_downloader.ex:667-731`,
  `pinned_request/2`).
- ~~`set_uuid_for_key/1` lists every attribute set per filter.~~ Resolved
  once per facade call (`query.ex:870`).
- ~~Featured-item image on catalogue categories is a silent no-op.~~
  `Query.resolve_category_images/2` (`query.ex:557`).

## Fixed (Batch 1 — 2026-10-13)

- ~~Left open: dashboard counts read the legacy tables under the catalogue
  source.~~ They go through `ProductSource` callbacks
  (`product_source.ex:40-47`;
  `test/phoenix_kit_ecommerce/dashboard_stats_source_test.exs`).
- ~~Left open: `"% OFF"` hardcoded English on the product page.~~
  `web/catalog_product.ex:947`, `:960`.

## Files touched

| File | Change |
|---|---|
| `lib/phoenix_kit_ecommerce/product_source.ex`, `lib/phoenix_kit_ecommerce.ex` | dashboard counts through the adapter |
| `lib/phoenix_kit_ecommerce/web/catalog_product.ex` | translated badge |

## Verification

`PGUSER=maxdon mix test` — 2891 tests, 0 failures. `mix precommit` (compile `--warnings-as-errors`, format, `credo --strict`, dialyzer) — exit 0, dialyzer 0 unnecessary skips. Run on the tree that carries this file.

## Open

- **Concurrent Shopify jobs of different kinds can overwrite each other's
  `data["ecommerce"]`** — awaiting the maintainer's decision. Uniqueness is
  per kind (`keys: [:kind]`,
  `lib/phoenix_kit_ecommerce/workers/shopify_media_sync_worker.ex:163-173`),
  so an `images` and a `variants` run can read-modify-write the same item.
- **Catalogue shops cannot change base currency** — awaiting the maintainer's
  decision. `reprice_for_base_change/3` refuses unless the Legacy source is
  active (`lib/phoenix_kit_ecommerce.ex:6208`).
- **Shopify variant values are created `draft`** and stay off the storefront
  until someone publishes them, while the worker reports the run as
  succeeded (`catalogue/value_resolver.ex:164-173`; the reason for `draft` is
  in that moduledoc). The sync page shows `values_created` but says nothing
  about publishing.
