# PR #34 follow-up — ProductSource: catalogue-backed storefront, cart and Shopify sync

Triage of `KIMI_REVIEW.md` against current code, by reading.

## Fixed (pre-existing)

- ~~#1 BUG - MEDIUM: `active_visibility/1` had no COALESCE fallback.~~
  `lib/phoenix_kit_ecommerce/product_source/catalogue/query.ex:784-791`.
- ~~#2 BUG - MEDIUM: category option_schema modifiers dropped at
  add-to-cart.~~ The catalogue reload preloads `:category`
  (`lib/phoenix_kit_ecommerce.ex:2973-2989`).
- ~~#3 IMPROVEMENT - MEDIUM: `CartItem.product_deleted?/1` was true for every
  catalogue line.~~ A line carrying `catalogue_item_uuid` is not deleted
  (`schemas/cart_item.ex:348-356`).
- ~~#5 IMPROVEMENT - MEDIUM: the catalogue adapter ignored `:product_type`.~~
  `query.ex:795-801`.
- ~~#6 IMPROVEMENT - MEDIUM: `:new_products` was dead surface.~~ The sync
  page has a "New in Shopify" panel (`web/shopify_sync.ex:136`, `:166`).
- ~~#7a: `:featured_product` preload silently dropped.~~ The featured item's
  image is resolved for the whole page by `Query.resolve_category_images/2`
  (`query.ex:557`).
- ~~#8a: catalogue search missed translated fields.~~ `query.ex:893` on
  (`jsonb_each` over `_name`/`_description`).
- ~~#12 NITPICK: `ProductSource.current/0` raised with the repo down.~~
  Rescues to Legacy (`product_source.ex:77-100`).

## Fixed (Batch 1 — 2026-10-13)

- ~~#4 IMPROVEMENT - MEDIUM: dashboard counts and the filter auto-suggest
  bypassed the adapter.~~ `count_products/1`, `count_categories/0` and
  `discover_filterable_options/0` are `ProductSource` callbacks
  (`product_source.ex:40-47`) that the dashboard and `get_config/0` use
  (`test/phoenix_kit_ecommerce/dashboard_stats_source_test.exs`).
- ~~#7b: `resolve_parent/2` ran one category read per non-root category.~~
  `list_categories/1` reads every parent the page needs in one query and
  reuses the rows already on the page
  (`product_source/catalogue.ex:93-106`, `:419-443`;
  `test/phoenix_kit_ecommerce/product_source/catalogue_categories_test.exs`,
  "preloads every parent the page needs in one query…").
- ~~#8b: catalogue search missed the SKU.~~ `query.ex:893-906`.
- ~~#9 IMPROVEMENT - LOW: the facade did not say the default order changes
  with the source.~~ `list_products/1`'s doc states both orders
  (`lib/phoenix_kit_ecommerce.ex:1155-1174`).

## Files touched

| File | Change |
|---|---|
| `lib/phoenix_kit_ecommerce/product_source.ex` | count / discover callbacks |
| `lib/phoenix_kit_ecommerce/product_source/catalogue.ex` | batched parents |
| `lib/phoenix_kit_ecommerce/product_source/catalogue/query.ex` | SKU in search |
| `lib/phoenix_kit_ecommerce.ex` | dashboard through the adapter; `list_products/1` doc |
| `test/phoenix_kit_ecommerce/product_source/catalogue_categories_test.exs` | parent query count |

## Verification

`PGUSER=maxdon mix test` — 2891 tests, 0 failures. `mix precommit` (compile `--warnings-as-errors`, format, `credo --strict`, dialyzer) — exit 0, dialyzer 0 unnecessary skips. Run on the tree that carries this file.

## Fixed (Batch 2 — 2026-10-14)

- ~~#10 (decision part): what to do with `compat/`.~~ Deprecated: every
  delegate carries `@deprecated` naming its `PhoenixKitEcommerce`
  replacement (`compat/`); README lists the replacements. Removal one
  release later.

`PGUSER=maxdon mix test` — 3099 tests, 0 failures. `mix precommit` — exit 0 (dialyzer 0 unnecessary skips). Run on the tree that carries this batch.

## Open

- **#4 (rest): `category_options/0` and `list_category_product_options/1`
  still read the shop's own tables directly**
  (`lib/phoenix_kit_ecommerce.ex:2253`, `:2317`). Their only callers are
  `ProductForm` and `CategoryForm`, which redirect to the catalogue under the
  catalogue source, but both are public functions.
- **#10 NITPICK: no `compat/` delegates for `get_config/1`,
  `get_price_range_for/1`, `category_image_url/2`** — will not be added by
  decision: `compat/` is deprecated and gains no delegate; it is removed one
  release after the deprecation ships.
- **#11 NITPICK: `list_categories_with_count/1` loads the whole filtered
  list and slices it in memory** (`lib/phoenix_kit_ecommerce.ex:1930-1943`).
- **Unverified surface: the catalogue adapter's tests run only when
  `phoenix_kit_catalogue` is resolved** (transitively through
  `phoenix_kit_warehouse`, or the path bridge); there is still no declared
  dependency or floor (AGENTS.md → TODOs).
