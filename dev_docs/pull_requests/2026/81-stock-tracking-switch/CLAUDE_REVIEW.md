# PR #81: Add a Stock tracking switch that needs the Warehouse module

- **Author:** Tymofii Shapovalov (timujinne)
- **Reviewer:** Claude
- **Merge:** `680229e` on `main`
- **Verdict:** approve. No bugs found; two nitpicks recorded.

## Summary

A "Stock tracking" card on the settings page: `shop_stock_tracking_enabled`
(default off) takes effect only while `phoenix_kit_warehouse` is installed
and enabled. `StockTracking` reaches Warehouse through variable-module calls
behind `Code.ensure_loaded?/1`, so a host without the package compiles
unchanged. The switch is greyed out per Warehouse state with a hint and a
link; the server refuses turning it on while Warehouse is missing or off.
`phoenix_kit_warehouse ~> 0.5` joins `mix.exs` as an optional dependency.

## Findings

- **Checked, correct - authorization.** The event goes through
  `Authz.authorize(socket, :manage_settings, ...)`, and a test pins that
  `manage_catalog` alone cannot flip it. The refusal lives in
  `StockTracking.set_enabled/1`, not only in the disabled checkbox.
- **Checked, correct - the Warehouse floor.** `enabled?/0` and
  `StockLedger.default_location_uuid/0` exist since warehouse 0.1.0, so
  `~> 0.5` is safe. The admin links (`/admin/modules?tab=...`,
  `/admin/settings/warehouse`, `/admin/warehouse`) match the paths core
  and Warehouse register, and go through `Routes.path/1`.
- **Checked, correct - the audit row.** `shop.stock_tracking_changed`
  carries only the new boolean and is logged on the `{:ok, _}` branch.
- **NITPICK - the stored key can outlive its effect.** With the setting on
  and Warehouse later disabled the card shows "off" and disabled, so an
  operator cannot clear the stored key until Warehouse is back. This is the
  documented design (the effective state is the AND of three things).
- **NITPICK - the optional dependency changes the default test run.**
  `phoenix_kit_warehouse` brings `phoenix_kit_catalogue` and
  `phoenix_kit_entities` in from Hex, so the `:catalogue` tests now run in
  a plain `mix test`. The PR documents it; the suite is green with them.

## Tests

`stock_tracking_test.exs`, `settings_stock_tracking_test.exs`, an
`authz_test.exs` case, and a fake Warehouse in `test/support`. Gettext
catalogues for all six languages carry the new strings. The full suite
passes: 2062 tests, 0 failures.
