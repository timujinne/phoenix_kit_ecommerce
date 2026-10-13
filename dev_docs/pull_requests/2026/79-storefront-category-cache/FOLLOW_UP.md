# PR #79 follow-up — Storefront catalog: lighter category-image query and a 60 s cache

## Fixed (pre-existing)

- ~~BUG - MEDIUM (`CODEX_REVIEW.md`): `children/0` was missing from the
  transitional namespace.~~ `lib/phoenix_kit_ecommerce/compat/shop.ex:32`;
  `test/phoenix_kit_ecommerce/compat_shop_test.exs:19` asserts it returns the
  main module's child specs.

## Not changed by the reviewer (design notes, not defects)

- Cache invalidation is node-local, and background Shopify jobs rely on the
  TTL. Both reviews record this as documented, bounded freshness.

## Open

None.
