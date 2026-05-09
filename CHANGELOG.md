# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## 0.1.5 - 2026-05-09

### Fixed
- Mark `PhoenixKit.Modules.Shop` compat module as `@moduledoc false` to silence ex_doc warnings about `defdelegate` pointing at hidden `@impl PhoenixKit.Module` callbacks. Docs-only change; no behavioural difference.

### Added
- Broaden i18n test coverage to iterate `admin_tabs/0 ++ settings_tabs/0 ++ user_dashboard_tabs/0` (was admin-only). Add direct `Gettext.gettext(EcommerceGettext, ...)` assertions independent of `Tab.localized_label/1`.

## 0.1.4 - 2026-05-08

### Added
- Per-module Gettext backend (`PhoenixKitEcommerce.Gettext`) with `en`/`ru`/`et` catalogues for all admin sidebar tab labels. Requires `phoenix_kit` release that ships the `gettext_backend` Tab API ([BeamLabEU/phoenix_kit#522](https://github.com/BeamLabEU/phoenix_kit/pull/522)); on older releases tabs render raw English (graceful degradation).

## 0.1.3 - 2026-04-06

### Added
- Add `version/0` callback to display package version on modules page

### Changed
- Remove deprecated `select-bordered` class for daisyUI 5 compatibility
- Expand compat module with full delegation list
- Add `elixirc_options: [ignore_module_conflict: true]` for umbrella compatibility

### Fixed
- Fix compilation errors after core changes

## 0.1.2 - 2026-03-30

### Added

- Compat alias modules (`lib/phoenix_kit_ecommerce/compat/`) bridging old `PhoenixKit.Modules.Shop.*` namespace to `PhoenixKitEcommerce.*` for backward compatibility
- Billing module as single source of truth for tax rates with Settings fallback

### Changed

- Remove explicit `LayoutWrapper.app_layout` from 14 admin LiveViews (core now auto-applies admin layout; kept in `shop_layouts.ex` for public storefront)
- Convert 5 admin list pages (carts, categories, products, shipping methods, import configs) to `table_default` + `table_row_menu` components
- Remove 65 duplicate files from old `lib/phoenix_kit/modules/shop/` namespace and 2 duplicate mix tasks

### Fixed

- Add admin authorization check (`Scope.admin?/1`) to individual category delete, matching bulk operations
- Replace raw `<tr><td>` empty-state rows with proper `table_default` components in shipping methods and import configs
- Fix weight formatting in shipping methods to use `Float.round/2` for precision consistency with carts

## 0.1.1 - 2026-03-29

### Changed

- Restructure from `lib/phoenix_kit/modules/shop/` to `lib/phoenix_kit_ecommerce/` matching standard extracted-repo convention
- Rename all modules from `PhoenixKit.Modules.Shop.*` to `PhoenixKitEcommerce.*`
- Update billing references from `PhoenixKit.Modules.Billing.*` to `PhoenixKitBilling.*`
- Move mix tasks to `lib/phoenix_kit_ecommerce/mix_tasks/`
- Add `:mix` to dialyzer PLT apps for clean dialyzer runs

### Fixed

- Fix 33 nesting depth violations (max depth 2) by extracting helper functions and using `with` chains
- Fix 11 cyclomatic complexity violations (max 9) by splitting large functions into multi-clause helpers
- Fix 25 alias ordering issues across all modules
- Fix dead code in `get_mapped_image/4` where `|| current_image` could never trigger
- Add `elixirc_paths/1`, `aliases/0` (quality/precommit) to mix.exs matching sibling conventions

### Added

- Comprehensive README with features, installation, usage examples, architecture, and troubleshooting
- AGENTS.md for AI agent guidance
- CHANGELOG.md for release tracking
- MIT LICENSE file

## 0.1.0 - 2026-03-29

### Added

- Initial e-commerce module with PhoenixKit.Module behaviour
- Product catalog with physical and digital product support
- Multi-language content (titles, slugs, descriptions, SEO fields)
- Hierarchical categories with nesting and per-category option schemas
- Dynamic product options with fixed and percentage price modifiers
- Shopping cart with guest (session-based) and user (persistent) modes
- Cart real-time sync across tabs via PubSub
- Checkout flow with PhoenixKitBilling integration for order conversion
- Shipping methods with weight/price constraints and geographic restrictions
- CSV import system with automatic format detection (Shopify, Prom.ua, generic)
- Oban workers for async CSV imports and image migration
- Admin dashboard with product, category, shipping, cart, and import management
- Public storefront pages (catalog, category, product detail, cart, checkout)
- User order history and order detail pages
- Import configuration profiles with keyword filtering and category rules
- Product deduplication mix task
