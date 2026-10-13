# PR #80: Shopify sync is off by default and fails closed (#78)

- **Author:** Tymofii Shapovalov (timujinne)
- **Reviewer:** Claude
- **Merge:** `44b2a2c` on `main`
- **Verdict:** approve. No bugs found; one upgrade note recorded.

## Summary

`shopify_enabled?/0` now defaults to `false`, and a failing settings read
answers `false` instead of `true`. So that an install already using
Shopify does not lose its sync, the migration chain gains V3: one
idempotent `DO` block that inserts `shop_shopify_enabled = "true"` only when
the row is missing and Shopify is configured (a Shopify integration row, a
catalogue item with `data.ecommerce.shopify.product_id`, or a legacy
product with `metadata._shopify.product_id`). It never overwrites a row,
and a missing catalogue or products table counts as "no ids".
`down/1` leaves the row alone. The settings read goes through a small test
seam (`:shopify_setting_reader`).

## Findings

- **Checked, correct - V3 follows the chain rules.** It is parameterised by
  the prefix (`validated_prefix/1`), idempotent (`ON CONFLICT DO NOTHING`
  behind an `EXISTS` guard), and cannot drop or truncate; the migrations
  scan covers it. The `to_regclass/1` + `EXECUTE` pair keeps a schema
  without `phoenix_kit_cat_items` from failing.
- **Checked, correct - the moved tests.** The two Shopify provider tests
  deleted from `module_callbacks_test.exs` now live in
  `shopify_toggle_test.exs`, run with the setting on, with the same
  assertions, and an off-state case was added.
- **NOTE (upgrade) - a host that never runs `mix phoenix_kit.update` loses
  the Shopify tab and provider silently.** V3 is the only thing that keeps
  the old behaviour, and it runs with the chain. This is inherent to
  flipping a default; it goes into the CHANGELOG entry so the release notes
  say so.
- **NITPICK - fail closed at boot.** `integration_providers/0` and
  `required_integrations/0` are asked while the host starts; a settings
  read that fails then now yields no Shopify provider until the toggle
  clears the provider cache. Before, it yielded one. That is the intended
  trade for a fail-closed read.

## Tests

`shopify_default_upgrade_test.exs` (upgrade matrix, including the empty
legacy id), `shopify_enabled_read_error_test.exs`, `shopify_toggle_test.exs`,
`migrations_test.exs`. The full suite passes.
