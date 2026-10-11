# PR #79: Storefront catalog: lighter category-image query and a 60 s cache for categories and facets

- **Author:** Tymofii Shapovalov (timujinne)
- **Reviewer:** Claude
- **Merge:** `224e0c1` on `main`
- **Verdict:** approve. No bugs found; two nitpicks recorded.

## Summary

Two storefront speed-ups for the catalogue source:

- `resolve_auto_images/2` no longer ships every active item's `data` JSONB
  to pick one image per category. The image rule of `item_image/1` runs in
  SQL (a `LATERAL ... OFFSET 0` reads the two sub-values once per row) and
  `DISTINCT ON (category_uuid)` returns one row per category.
- `StorefrontCache` (a `PhoenixKit.Cache`, 60 s TTL, 2000 keys, started
  through `children/0`) holds the category list and the filter facets for
  `/shop` and the category page. It fails open when the cache process is
  absent, caches only enabled languages, and is cleared by this package's
  own writes (Events broadcasts, the bulk category change, the bulk product
  delete, `update_storefront_filters/1`, the Shopify sync).

## Findings

- **Checked, correct - the SQL matches `item_image/1`.** A non-string or
  empty `featured_image_uuid` falls through to `media_order`; a first
  element that is not a non-empty string leaves the item without an image
  in both versions. The ordering (position, then name) and
  `active_visibility/1` are kept.
- **Checked, correct - the key space is bounded.** The language comes from
  the URL, but `fetch_in_language/3` stores only enabled languages (or the
  default dialect of one), and the category list carries no language. The
  `category` struct is reduced to its `storefront_filters` before it goes
  into a key.
- **Checked, correct - nothing viewer-specific is cached.** Categories and
  facets are shared; products, the cart count and the auth state are not.
- **Checked, correct - the core floor.** `children/0`, `Cache.remember/4`,
  `max_size` and `Registry.cache_exists?/1` all predate the `>= 2.43.0`
  floor, and a floor test pins them.
- **NITPICK - the clear is node-local.** On a cluster another node serves
  its entries for up to ~66 s after an admin edit. The moduledoc says so;
  a PubSub-driven clear would fix it if it ever matters.
- **NITPICK - background Shopify jobs do not clear.** The media/variants
  worker and `CollectionSync` write catalogue items and categories and
  stay TTL-only, as documented. At 60 s this is acceptable.

## Tests

`catalogue_query_test.exs` (a differential check of the image query),
`storefront_cache_test.exs`, `storefront_cache_pages_test.exs`,
`sync_catalogue_test.exs`. The full suite passes: 2062 tests, 0 failures.
