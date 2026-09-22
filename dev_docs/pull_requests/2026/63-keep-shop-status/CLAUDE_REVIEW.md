# PR #63: Keep shop_status when a Shopify sync does not carry :status

- **Author:** Tymofii Shapovalov
- **Reviewer:** Claude
- **Merged as:** `018923a`
- **Verdict:** correct as merged. No changes needed.

## Summary

`Writer.ecommerce_params/2` called
`shopify_shop_status(Map.get(change_fields, :status))` unconditionally.
An absent key reads as `nil`, which falls through to `"draft"`, so every
field apply that was not a status apply retired the product. The PR reads
`:status` with `Map.fetch/2`, the same way `maybe_put_base_price/2` already
reads `:price`.

## Checks

- **Trigger is real.** `Sync.apply_catalogue_change/2` builds
  `change_fields` only from `resolve_fields(fields, change.changes)`,
  plus `:handle`/`:product_id`. A per-field apply or an "apply all" on a
  product whose status already matches never carries `:status`.
- **Other keys are unaffected.** `vendor`, `tags` and `compare_at_price`
  go through `maybe_put_param/3`, which skips `nil`, and none of them has
  a non-nil fallback. The Shopify identity merge is guarded separately.
  `:status` was the only key with this bug.
- **The legacy source path is unaffected.** `apply_legacy_change/2`
  reduces over the applied fields only.
- **The create path keeps its `"draft"` fallback.** An unrecognised or
  missing status on a brand-new item must not become visible, and a test
  pins this.
- **Tests cover the cases that matter.** They assert that an absent status
  leaves both the `"active"` default and a non-default `"archived"`
  untouched, that a present status is written, and that an unrecognised
  status still falls back to draft.

## Findings

None.

## Validation

The `:catalogue` suite, which includes `writer_test.exs`, passes
(245 tests, 0 failures). `mix precommit` is clean.
