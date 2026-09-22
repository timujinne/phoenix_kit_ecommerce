# PR #62: Shopify sync scope, per-kind progress, New in Shopify

- **Author:** Tymofii Shapovalov
- **Reviewer:** Claude
- **Merged as:** `c4d4ff0`
- **Verdict:** sound. Three post-merge fixes, no blockers.

## Summary

This PR adds `Shopify.SyncScope`, a `phoenix_kit_shop_config` allowlist (by
tags and product types) that decides what an **unmatched** Shopify product
means. The media worker counts an out-of-scope product as `"skipped"`
instead of raising a `no_matching_item` error. `Sync.check/2` offers only
in-scope products as create-`Change`s. Media-sync progress is now stored in
one row per kind (`shopify_media_sync:<kind>`), and reads fall back to the
old single key. The sync page gains a scope form, a status block for each
kind, and a "New in Shopify" panel.

Checked and correct:

- Matched products are never scoped, in the worker or in `check/2`.
- The Admin REST client requests both `tags` and `product_type`
  (`@product_fields`), so a filtered scope does not mark everything out of
  scope.
- `merge_stats/3` keys match what `Writer.sync_images/3` returns
  (`downloaded`/`reused`/`attached`) and what `sync_variants/2` returns
  (`values_created`).
- Every broadcast payload carries `"kind"`, so the narrowed
  `handle_info({:media_sync_progress, %{"kind" => _}})` clause cannot miss.
- All new write events (`save_sync_scope`, `request_apply_new_row`/`_all`,
  and their confirm) go through `Authz.authorize(:run_imports)`. The
  confirm step looks the change up again by handle in the current assigns.
- Currency verdict is resolved once per new-product batch and reused.

## Findings

### IMPROVEMENT - MEDIUM: saving the sync scope wrote no activity row (fixed)

`save_sync_scope` changes which Shopify products the worker and `check/2`
consider. It is an admin settings change, but it was the only mutation on
the page that did not log, which breaks the "activity logging at the
LiveView layer" convention.

**Fix:** it now logs `shop.shopify_sync_scope_saved` on `{:ok, _}`, with
metadata `mode`/`tags`/`product_types` (no PII). The metadata is asserted
by the round-trip test, and the denied-permission test refutes the row.

### BUG - MEDIUM: a non-string tag or product-type entry crashed `SyncScope.get/0` (fixed)

`normalize_list/1` ran `to_string/1` on every list entry. A map or a nested
list, from a hand-edited config row or a tampered
`sync_scope[tags][][x]=…` submit, raised `Protocol.UndefinedError`. That
contradicts the moduledoc ("never raises on a missing or malformed stored
value"). `get/0` runs on every sync-page mount, every `Sync.check/2` and
every media-sync run, so one persisted bad entry would have taken down all
three.

**Fix:** non-binary entries are now filtered out. A test was added that
stores mixed garbage and reads back only the valid strings.

### NITPICK: "Nothing new — all images already present" shown for a run that matched nothing (fixed)

`nothing_new?` only checked `downloaded == 0` and "no errors". A run where
the scope skipped every product also downloads 0, so it claimed all images
were present when it had looked at none.

**Fix:** it now also requires `matched > 0`. A test was added.

### NITPICK: template-local `<% status = … %>` in the media panel `:for` (fixed)

A HEEx local binding opts the block out of change tracking. The per-kind
status is now built in `render/1` as `@media_sync_rows`
(`{kind, label, status}`), and the template iterates over that.

### NITPICK: `ProductDiff.parse_tags/1` widened for new shapes (not changed)

- A list input is now returned untrimmed.
- Any other shape now reads as `[]`. Before, it raised. For the tag
  *diff*, this means a malformed Shopify `tags` payload would propose
  clearing local tags instead of crashing the check.

The Admin REST API always sends a string, and every diff still needs an
operator to apply it, so I left this alone. It is recorded here in case a
GraphQL source is ever added.

### Not changed, pre-existing

A job killed mid-run leaves its kind's row at `"finished_at" => nil`, so
that kind's button stays disabled until another run finishes. Per-kind
storage makes this narrower than before (only that kind is stuck). The
behaviour is unchanged by this PR.

## Validation

- `mix precommit` is clean.
- `mix test`: 1458 tests, 0 failures.
- The `:catalogue` suite via the path bridge: 245 tests, 0 failures. This
  was run before the fixes, and the fixes touch only the web layer and
  `SyncScope`.
