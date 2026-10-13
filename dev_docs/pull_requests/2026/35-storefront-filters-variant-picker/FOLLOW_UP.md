# PR #35 follow-up — Storefront filters and variant picker on catalogue attribute sets

Triage of `KIMI_REVIEW.md` against current code, by reading.

## Fixed (pre-existing)

- ~~#1 BUG - MEDIUM: `distinct: i.uuid` ordered the listing by uuid.~~
  `filter_by_visible_categories/2` is the hidden-category subquery
  (`lib/phoenix_kit_ecommerce/product_source/catalogue/query.ex:813`).
- ~~#2 IMPROVEMENT - MEDIUM: vendor counts and the price range ignored
  hidden categories.~~ Both take `:exclude_hidden_categories`
  (`query.ex:247-258`, `:271-282`).
- ~~#3 IMPROVEMENT - MEDIUM: an unvalidated price modifier could reach
  `Decimal.new/1`.~~ The override path uses the safe `parse_decimal/1`
  (`options/options.ex:1142-1152`), and `ItemCommerce.changeset/2` validates
  every leaf.
- ~~#4 IMPROVEMENT - MEDIUM: `set_uuid_for_key/1` listed every set per
  call.~~ The set list is resolved once per facade call and passed in
  (`query.ex:870-877`).
- ~~#5 IMPROVEMENT - MEDIUM: `:language` on `add_to_cart/4` undocumented.~~
  Documented on the function (`lib/phoenix_kit_ecommerce.ex`, `add_to_cart/4`
  options).

## Fixed (Batch 1 — 2026-10-13)

- ~~#6 NITPICK: stale docstring on `attribute_set_counts/2`.~~ It describes
  what `value_label/2` does (`query.ex:302-306`).
- ~~#8 NITPICK: an unresolvable set slug left the badge active and filtered
  nothing.~~ A filter naming a deleted or renamed set matches nothing
  (`query.ex`, `filter_by_metadata/3`).
- ~~#9 NITPICK: `parse_decimal/1` accepted trailing garbage.~~ The whole value
  or nothing (`web/components/filter_helpers.ex:336-342`).

## Files touched

| File | Change |
|---|---|
| `lib/phoenix_kit_ecommerce/product_source/catalogue/query.ex` | match-nothing for an unknown set; docstring |
| `lib/phoenix_kit_ecommerce/web/components/filter_helpers.ex` | strict decimal parse |

## Verification

`PGUSER=maxdon mix test` — 2891 tests, 0 failures. `mix precommit` (compile `--warnings-as-errors`, format, `credo --strict`, dialyzer) — exit 0, dialyzer 0 unnecessary skips. Run on the tree that carries this file.

## Open

- **#7 NITPICK: a category-only filter override without `"enabled"` is
  dropped** — awaiting the maintainer's decision
  (`merge_storefront_filters/2`, `lib/phoenix_kit_ecommerce.ex:1285`; the
  entry is appended as written and `get_enabled_storefront_filters/2` then
  filters on `"enabled"`). Defaulting it to `true` and requiring the key are
  both defensible; no admin UI writes these yet.
- **Unverified surface: `handle_params/3` does not recompute facet counts
  after a filter change** (`web/shop_catalog.ex:136` on,
  `web/catalog_category.ex:160` on) — the counts shown are the mount's.
- **Unverified surface: the `compat/` delegate names its second parameter
  `product_uuid`** while the facade takes a product
  (`compat/shop.ex:138`). Naming only.
