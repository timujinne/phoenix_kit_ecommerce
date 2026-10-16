# PR #90 — Shopify prices need a base currency, one Shopify sync at a time, whole-set values, option values by key, versioned `up/1`, compat deprecated

**Author:** Max Don · **Merged:** `9b5dbf0` · **Reviewed:** 2026-10-14, not yet released (0.5.24 is the last version on Hex)

Scope: `Migrations.up/1` + `up_statements/2` (`:version`), the `compat/` deprecations,
`Shopify.Sync.currency_verdict/1` and the `:missing_base_currency` refusal, the
Shopify sync page's price gating, `ShopifyMediaSyncWorker` uniqueness across kinds
and its `perform/1` snooze, whole-set attribute values (`mark_whole_set_values`,
`Query.published_value_slugs/1`), option values identified by key
(`SelectedSpecs`, `View.legacy_metadata/3`, cart matching, order lines),
`base_currency_change_supported/0`, and the `list_unstamped_prices` task.

## Findings

No BUG-level findings. The PR is large (53 files, ~2k lines outside the gettext
catalogues) and its seams hold; each area was traced against its callers.

### NITPICK — an orphaned `executing` job makes every later run snooze

`earlier_run_executing?/1` snoozes while any earlier job of the worker is in
state `executing`. A job killed mid-run (deploy, node loss) stays `executing`
until Oban's Lifeline plugin rescues it; on a host without Lifeline every new
Shopify sync then snoozes every 30 s indefinitely. Not a regression: the old
per-kind uniqueness already refused the *enqueue* in the same state
(`states: [..., :executing]`), so the operator was blocked either way, and the
page's `incomplete_kinds/0` guard already names the situation. Left as is;
rescuing orphans is the host's Oban configuration, not this module's.

### IMPROVEMENT - MEDIUM — no CHANGELOG entry for the PR

#90 changes behaviour hosts see (Shopify price writes refused without a base
currency, a single Shopify sync at a time, catalogue option values keyed, cart
lines gaining a `selection` snapshot, orders gaining `selected_spec_keys`,
`up/1` honouring `:version`, `compat/` deprecated). Added an `## Unreleased`
entry so the release commit has the material; no version bump.

## Checked, no change needed

- **`Migrations.up/1`.** `up(version: N)` runs V1..VN and stamps N; a database
  already past N is skipped, and with no `:version` the SQL is byte-identical
  to before (pinned by hash in `migrations_test.exs`). A target outside
  `1..current_version/0` raises before any write. `down/1` still drops nothing.
- **`currency_verdict/1` ordering.** The base is read before the shop lookup,
  so a missing base never fails open and never costs an Admin API call. Every
  consumer matches the new `:missing_base_currency` arm: `Sync.create_change/2`,
  `do_apply_change/3`, `ShopifyMediaSyncWorker` (variants skip + log) and the
  page's `flash_new_products_failure/3` / `apply_error_flash/3`.
- **Sync page gating.** Row, section, selection, everything and new-product
  requests all go through `price_blocked?/2` or `drop_unwritable_price_fields/2`,
  and `Sync` refuses the write regardless, so a stale `base_currency_missing?`
  assign cannot write a price. After "apply everything" a price row is kept
  rather than reported as synced.
- **Worker uniqueness.** `fields: [:queue, :worker]` with no `:keys` is valid
  Oban (`keys` only applies with `:args`). The `perform/1` tie-break
  (`attempted_at`, then `id`) cannot deadlock: a snoozed job is `scheduled`, not
  `executing`, so two jobs can never wait on each other.
- **Option values by key.** Every `selected_specs` reader goes through
  `SelectedSpecs` (cart page, checkout, order line, order description, product
  page); nothing prices an existing line from its selection (the only
  `calculate_product_price/2` callers are the product page and the two
  add-to-cart paths). `find_cart_item_by_specs/4` never merges a keyed
  selection onto an unkeyed line, and the guest→user cart merge passes the
  line's own shape. `retained_specs/3` now survives a language switch because
  keys are the same in every language.
- **Whole-set values.** `published_value_slugs/1` is one query per batch and
  none when no set is whole-set; drafts are excluded, as the facets do.
- **`list_unstamped_prices`.** Read-only, no-ops without catalogue, lists
  every status.

## Verification

- `mix test`: 3099 tests, 0 failures.
- `:catalogue`-tagged suite: 366 tests, 0 failures (run through
  `PHOENIX_KIT_WAREHOUSE_PATH=../phoenix_kit_warehouse MIX_ENV=test`; the
  catalogue + entities path bridge no longer resolves against the Hex
  warehouse pin, which requires `phoenix_kit_catalogue ~> 0.18` while the
  checkout is 0.48.1).
