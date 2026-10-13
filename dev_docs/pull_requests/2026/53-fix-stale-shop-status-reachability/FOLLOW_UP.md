# PR #53 follow-up — Fix: catalogue-retired items with a stale shop_status stayed reachable

## Fixed (pre-existing)

- ~~BUG - HIGH: `category_view/2` never read `category.status`, so a
  soft-deleted catalogue category with a stale or absent `shop_status` stayed
  reachable by direct link.~~
  `lib/phoenix_kit_ecommerce/product_source/catalogue/view.ex:167` now takes
  `:status` from `category_status/2` (`:316`), which forces `"hidden"` for a
  deleted category before `shop_status` is consulted. The product-side fix the
  PR itself made is intact at `:277` (`product_status/2`).
- The end-to-end regression test the review could not run in its environment
  is present:
  `test/phoenix_kit_ecommerce/web/catalog_category_catalogue_status_test.exs`.
  It was not run during this triage (no `mix` runs in this pass).

## Open

None.
