# PR #76 follow-up — Start checkout on the shop's country instead of a hardcoded EE

## Fixed (pre-existing)

- ~~BUG - MEDIUM (`CODEX_REVIEW.md`): `default_checkout_country/0` was missing
  from the compatibility shim.~~
  `lib/phoenix_kit_ecommerce/compat/shop.ex:33`; export pinned by
  `test/phoenix_kit_ecommerce/compat_shop_test.exs:10`.

## Not changed by the reviewer (design notes, not defects)

- `shipping_methods_country/0` lists active methods on a checkout mount when
  the cart has no shipping country. `CLAUDE_REVIEW.md` judged it not worth
  caching.

## Open

None.
