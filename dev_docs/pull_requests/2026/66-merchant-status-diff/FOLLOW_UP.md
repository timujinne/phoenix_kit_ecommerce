# PR #66 follow-up — Diff the merchant status a sync writes, not the one the storefront shows

## Fixed (pre-existing)

- ~~IMPROVEMENT - HIGH: the regression guard did not run without a
  database.~~
  `test/phoenix_kit_ecommerce/shopify/product_diff_merchant_status_test.exs:32`
  is `use ExUnit.Case, async: true`, with the reason in the comment above it.
- ~~BUG - MEDIUM: an incoming status the apply cannot store still produced a
  change.~~ `lib/phoenix_kit_ecommerce/shopify/product_diff.ex:409-414` —
  `maybe_put_status/4` only compares an incoming value in
  `["draft", "active", "archived"]`.
- ~~NITPICK: documentation drift.~~ `product_diff.ex:20` and
  `lib/phoenix_kit_ecommerce/schemas/product.ex:14` both describe
  `merchant_status`.

## Not changed by the reviewer (design notes, not defects)

- A product Shopify considers active that the catalogue has retired reports
  no status difference. The review recorded this as intended behaviour and a
  possible future panel, not a diff change.

## Open

None.
