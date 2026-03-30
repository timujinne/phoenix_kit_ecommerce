# PR #2 — Add compat aliases, remove LayoutWrapper, upgrade UI tables

**PR:** https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/2
**Author:** Timujeen (@timujinne)
**Merged by:** Dmitri Don (@ddon) on 2026-03-30

## What

- Add 6 compat alias modules bridging `PhoenixKit.Modules.Shop.*` -> `PhoenixKitEcommerce.*`
- Remove `LayoutWrapper.app_layout` from 14 admin LiveViews (core auto-applies layout)
- Convert 5 admin list pages to `table_default` + `table_row_menu` components
- Centralize tax rates via Billing module with Settings fallback
- Remove 65 duplicate files from old `lib/phoenix_kit/modules/shop/` namespace

## Why

After extracting e-commerce from PhoenixKit core into this standalone package, the old `PhoenixKit.Modules.Shop.*` namespace references in core needed compat bridges. Admin LiveViews were double-wrapping layout. List pages needed migration to the shared table component system.

## Files changed

22 files (+284,172 / -663 lines — inflated by accidental `erl_crash.dump`)

Key files:
- `lib/phoenix_kit_ecommerce/compat/` — 6 new compat alias modules
- `lib/phoenix_kit_ecommerce.ex` — tax rate consolidation
- `lib/phoenix_kit_ecommerce/web/{carts,categories,products,shipping_methods,import_configs}.ex` — table upgrades
- `lib/phoenix_kit_ecommerce/web/{dashboard,settings,imports,...}.ex` — LayoutWrapper removal
