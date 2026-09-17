# Code Review: PR #58 — Keep Shopify ids out of catalogue copies

**Reviewed:** 2026-09-17
**Reviewer:** Claude (claude-opus-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/58
**Author:** Max Don
**Merge SHA:** 76b665c (squash)
**Status:** Merged

## Summary

`phoenix_kit_catalogue` now copies items, categories and whole catalogues, and
asks each extension what a copy keeps through the optional
`duplicate_data/2` callback (`PhoenixKitCatalogue.Extensions.duplicate_data/2`).
The PR implements it on `Catalogue.Extension`: an item copy drops
`data["ecommerce"]["shopify"]` and `legacy_product_uuid`; a category copy drops
`shopify` (the `collection_id` the collection sync writes). It adds pure tests
and a `:catalogue`-tagged integration test that skips on a catalogue older than
the hook.

The change is correct. Checked against the real consumers:

- **Item matching.** `CollectionSync` indexes items by
  `["shopify"]["product_id"]`; `ShopifyMediaSyncWorker` matches by `product_id`
  then `handle`. Both live under `shopify`, so a copy can no longer be synced
  as a second instance of the same product.
- **Category matching.** `CollectionSync.find_category/4` matches by primary
  slug, then name — not by `collection_id` — so keeping the id would not have
  mis-matched a copy, but dropping it keeps the copy from claiming a collection
  it isn't linked to. Correct either way.
- **Callback contract.** Catalogue passes only the namespace map (string keys,
  as read from JSONB), accepts a map or `nil`, asks disabled extensions too,
  and drops the namespace on a raise. `Map.drop`/`Map.delete` on string keys
  match that. `kind == :catalogue` rows skip the hook, and a whole-catalogue
  copy routes its items/categories through `:item`/`:category`.
- **Featured item.** The moduledoc's claim that a copied category's
  `featured_item_uuid` is re-pointed by the catalogue holds:
  `Duplication.duplicate_category/2` runs `remap_copies!/1` over the copied
  rows' data after the copy.
- **Form saves.** `ItemCommerce.cast/2` and `CategoryCommerce.cast/2` merge over
  `current`, so a later save of the copy writes `shopify: %{}` back (schema
  default) and nothing more.

## Findings

### 1. NITPICK — the docs described Shopify keys that don't exist (fixed)

The new `duplicate_data/2` doc said an item copy drops "the Shopify product,
variant ids and handle", echoing the `# handle, product_id, variant_ids` comment
on `ItemCommerce`'s `shopify` field. Nothing writes `variant_ids`; the sub-map
actually carries `product_id`, `handle`, `image_ids` (media sync) and
`set_slugs` (variant sync). Both comments now name the real keys, and the unit
test's fixture uses `image_ids`/`set_slugs` instead of the phantom
`variant_ids`, so it pins that the sync's bookkeeping leaves with the link.

### 2. NITPICK — kept keys that might look like links (no change)

- `price_modifiers` stays while `shopify.set_slugs` goes. The copy keeps its
  attached sets (catalogue copies attachments), and `set_slugs` only drives
  detaching stale sets on a Shopify re-sync — which a copy with no
  `product_id`/`handle` never receives. Keeping the prices is right.
- `legacy_metadata` (the `_option_slots`/`_image_mappings` snapshot
  `View.legacy_metadata/3` renders from) stays: it is display data, nothing
  matches rows by it.
- `translation_fingerprints` stays. The copy's names are suffixed "(copy)", so
  its fingerprints are stale on their own, which is the truthful state.

### 3. NITPICK — integration setup builds an unused fixture (no change)

The category test builds its own catalogue/category/item, so the shared
`setup` row is dead weight for it. Cheap and harmless; not worth splitting the
module.

## Validation

`mix precommit`, `mix test`, and the `:catalogue` suite via the path bridge
(`PHOENIX_KIT_CATALOGUE_PATH` / `PHOENIX_KIT_ENTITIES_PATH`), which runs the new
integration test against the current catalogue checkout.
