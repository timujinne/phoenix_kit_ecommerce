# PR #58 follow-up — Keep Shopify ids out of catalogue copies

## Fixed (pre-existing)

- ~~NITPICK: the docs described Shopify keys that do not exist
  (`variant_ids`).~~ `lib/phoenix_kit_ecommerce/catalogue/item_commerce.ex:57-58`
  and the `duplicate_data/2` doc in
  `lib/phoenix_kit_ecommerce/catalogue/extension.ex:60` name the real keys
  (`handle`, `product_id`, `image_ids`, `set_slugs`). `grep variant_ids` over
  `lib/phoenix_kit_ecommerce/catalogue/` is empty.
- The callback itself is unchanged and correct:
  `extension.ex:67-68` drops `shopify` + `legacy_product_uuid` for an item and
  `shopify` for a category.

## Not changed by the reviewer (design notes, not defects)

- `price_modifiers`, `legacy_metadata` and `translation_fingerprints` stay on
  a copy. The review judged this correct; `duplicate_data/2` still keeps them.
- The integration test's shared `setup` builds a fixture the category test
  does not use. Recorded by the review as harmless.

## Open

None.
