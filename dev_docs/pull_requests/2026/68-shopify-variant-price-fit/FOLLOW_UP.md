# PR #68 follow-up — Shopify variants: read every variant, fit prices, show approximations

## Fixed (pre-existing)

- ~~IMPROVEMENT - MEDIUM: `Sync.check/2` re-read capped newcomers under the
  Legacy source.~~ `lib/phoenix_kit_ecommerce/shopify/sync.ex:233-237` — the
  in-scope branch of the `:complete_variants` predicate also requires
  `ProductSource.current() == ProductSource.Catalogue`.

## Not changed by the reviewer (design notes, not defects)

- `ProductDiff.creatable?/1` matches the `":not_requested"` marker by string
  (`lib/phoenix_kit_ecommerce/shopify/product_diff.ex:277`) instead of through
  an `AdminClient` helper. Still so; both branches return `false`, so drift
  would only change a logged warning's wording.
- The base-offset note shows a signed amount without naming a direction
  (`lib/phoenix_kit_ecommerce/catalogue/shop_sections.ex:646`). Still so.

## Open

None.
