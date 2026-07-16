# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## 0.1.11 - 2026-07-16

### Added
- **Admin i18n wave.** All 12 admin LiveViews (carts, categories, category
  form, dashboard, import show, imports, product detail, product form,
  products, settings, shipping method form, shipping methods) are now
  fully gettext-wrapped, using the module-owned `PhoenixKitEcommerce.Gettext`
  backend consistently (replacing leftover `PhoenixKitWeb.Gettext` calls).
  The `ru`/`et` catalogs were extended from 483 to 2,500+ msgids.

### Fixed
- **Gaps in the i18n wave above, found in post-merge review.** The
  product-form Translations tab (title/slug/description/SEO field labels
  and placeholders), several product-form help strings, the products-list
  empty state, the CSV-import confirm-step summary, an import-details
  notice, and a category-option delete confirmation were left unwrapped
  and rendered in English regardless of locale — not caught by
  `mix gettext.extract --check-up-to-date`, since that check only verifies
  already-wrapped calls, not coverage. All wrapped and translated
  (en/ru/et).
- **Cart and shipping-method page-header counts pluralize correctly.**
  `carts.ex` and `shipping_methods.ex` used plain `gettext` for their
  "%{count} ... total/configured" headers instead of `ngettext`, so the
  Russian translation hardcoded a genitive-plural noun regardless of
  count — rendering "1 корзин всего" / "1 методов настроено" at
  `count = 1`. Converted to `ngettext`, matching the categories/products
  pattern, with correct 3-form ru and 2-form et translations.
- Corrected 12 catalog entries gettext's fuzzy-matcher mis-filled from an
  unrelated adjacent label while merging the strings above (e.g. "No
  products found" pre-filled with the Russian/Estonian translation of "No
  categories found").

See `dev_docs/pull_requests/2026/11-admin-i18n-wave/CLAUDE_REVIEW.md` for
the full review.

## 0.1.10 - 2026-07-12

### Fixed
- **Search terms are escaped before hitting ILIKE.** User input flowed
  into the `%term%` pattern raw, so `%`/`_`/`\` acted as wildcards on a
  route open to unauthenticated visitors: searching `100%` matched every
  product containing "100", an SKU search for `AB_100` also matched
  `ABX100`, and a term ending in `\` silently corrupted the pattern into
  requiring a literal `%`. Terms are now length-capped (100 chars),
  NUL-stripped (a crafted `%00` raised `Postgrex.Error`), and
  LIKE-escaped in one choke point (`search_like_pattern/1`) shared by the
  product, category, and admin-cart search filters. The cap also closes a
  cheap unauthenticated seq-scan amplifier (unbounded multi-KB patterns
  against six ILIKE evaluations per row, two of them `jsonb_each_text`
  expansions).
- **Category pages now show a filters-aware zero-result state.** With an
  active search (or price/vendor filter) matching nothing, the category
  page claimed "No products in this category — check back soon" even
  though the category has products; it now says the filters matched
  nothing and offers a clear-filters affordance, matching the main
  catalog page. Both the guest and authenticated layouts share one
  `category_empty_state` component now.
- Documented (code comment) the cross-release ordering limitation of
  `merge_missing_builtin_filters/1`'s below-minimum positioning scheme:
  it holds within one merge pass; a hypothetical second sidebar-leading
  built-in added in a future release should renormalize positions on
  save instead of extending the scheme.

## 0.1.9 - 2026-07-11

### Added
- **Storefront product search.** A new built-in `search` filter type lets
  customers search the public catalog (main page and category pages) by
  product name, description, SKU (`metadata->>'sku'`), and tags — matching
  in any configured language. Renders as a search box at the top of the
  storefront filter sidebar, driven by a `?search=` URL param so results
  are shareable and survive navigation. Enabled by default for new
  installs; existing installs discover it on the Settings page (merged in
  disabled via `merge_missing_builtin_filters/1`) and enable it with one
  toggle.
- Context: `list_products/1` `:search` now also matches SKU and tags
  (previously title/description only), so admin product search finds
  products by article number too.

### Fixed
- **Storefront search no longer raises `ambiguous_column`.** The `:search`
  SQL fragment referenced unqualified `title`/`description` columns, which
  turn ambiguous the moment `:exclude_hidden_categories` joins the
  categories table — the exact combination every public catalog query
  uses. Columns are now bound through the product binding. Pinned by a
  regression test.
- **`merge_missing_builtin_filters/1` no longer collides positions.** A
  saved config from before `search` existed can already hold another
  filter at the same default position (e.g. `price` at `0`); the merged-in
  filter now sorts strictly below every saved filter's position instead of
  reusing its default position outright, so it renders first once enabled
  as intended, even on upgraded installs.

## 0.1.8 - 2026-06-08

### Added
- Developer tooling: `pk_dep/3` in `mix.exs` resolves any `phoenix_kit*` dependency from a local checkout when `<APP>_PATH` is exported (e.g. `PHOENIX_KIT_PATH=../phoenix_kit mix test`), for cross-repo development. Unset — the default — keeps the published Hex pin, so `mix hex.publish` and CI resolve exactly as before. A set-but-blank value (`PHOENIX_KIT_PATH=`) is also treated as unset rather than producing a broken `path: ""` dep. Documented in `AGENTS.md`.

### Changed
- Refresh dependency lock: `phoenix_kit` 1.7.131 → 1.7.133 and `phoenix_kit_billing` 0.4.0 → 0.5.0, plus transitive bumps (`bandit` 1.11.1 → 1.12.0, `etcher` 0.6.5 → 0.6.6, `fresco` 0.6.3 → 0.7.1, `req` 0.5.18 → 0.6.1, `spitfire` 0.3.12 → 0.3.13, `tesla` 1.18.3 → 1.20.0). Declared dependency requirements are unchanged; no library or migration code changed.

## 0.1.7 - 2026-06-05

### Changed
- Migrate the category and product admin forms to core form components. Non-translatable scalar fields (status, product_type, vendor, price/compare_at/cost, position) and the changeset-backed selects (`parent_uuid`, `featured_product_uuid`, `category_uuid`) now render through core `<.input>`/`<.select>`. An `assign_form/2` helper keeps `:changeset` (consumed by the multilang `TranslationTabs` fields) and `:form = to_form(changeset)` in sync, so inline validation errors render on `validate`. Translatable fields, dynamic-option selects, and the option/media machinery are intentionally left as-is.
- Route web body strings through the module's own `PhoenixKitEcommerce.Gettext` backend (was the parent app's `PhoenixKitWeb.Gettext`). Generic UI-chrome strings are still resolved against core to keep its vetted translations; shop-domain strings resolve in-module and ship `et`/`ru` catalogues (correct 2-form/3-form plurals).

### Fixed
- Inline validation errors now render on the migrated `<.select>` fields, via the `phoenix_kit` 1.7.131 core `Select` component (it now maps `field.errors` like `<.input>` does).

### Dependencies
- Bump `phoenix_kit` 1.7.130 → 1.7.131 (core `<.select>` surfaces `field.errors`) and `etcher` 0.5.5 → 0.6.5.

## 0.1.6 - 2026-06-04

### Fixed
- Order `tax_rate` persisted as `0` on cart→order conversion. `build_order_attrs/3` hardcoded a `0` rate while `tax_amount` was computed from the live rate, so every order recorded a 0% rate — breaking receipts, tax reports, and refund math that derive the percentage from the order. Now uses `get_tax_rate(cart)` (single source of truth). Pinned by an end-to-end regression test.
- `unique_constraint` names for `ShippingMethod` (`:slug`) and `ImportConfig` (`:name`, `:uuid`) did not match the actual DB indexes, so duplicate inserts raised `Ecto.ConstraintError` instead of returning `{:error, changeset}`. Pinned to the real index names.
- No-billing tax fallback applied the configured `billing_default_tax_rate` even when `billing_tax_enabled` was `false`; now gated on the enabled flag, matching the `PhoenixKitBilling`-loaded path.
- `DialectMapper.resolve_dialect/2` → `/1` after the `phoenix_kit` upgrade dropped the 2-arity form, restoring a clean `--warnings-as-errors` build.

### Added
- `PhoenixKitEcommerce.Activity` — PII-safe LiveView-layer activity-logging wrapper around `PhoenixKit.Activity`. Logs admin mutations (products incl. bulk, categories, shipping methods, import configs/runs) and never crashes the caller (no-ops when core's `PhoenixKit.Activity` is absent; rescues DB errors).
- `PhoenixKitEcommerce.Errors` — central gettext-backed mapping from error atoms to user-facing strings (`PhoenixKitEcommerce.Gettext` backend). Wired into the `:cart_not_active` and `:unknown_format` paths.
- Test harness: `DataCase`/`LiveCase`, test endpoint/router/layouts, schema via `PhoenixKit.Migration.ensure_current/2`, and full schema/context/LiveView coverage (6 → 183 tests).

### Changed
- Cap `include_keywords`/`exclude_keywords`/`exclude_phrases` import filters at 100 entries each with a friendly changeset error (was unbounded).
- Centralize the nil-currency `$` fallback as a single documented module attribute.
- Migrate the shipping-method form to core components (`<.input>`/`<.select>`/`<.textarea>` with `assign_form/2`) for inline validation errors.
- Log a warning on `billing_default_tax_rate` parse failure instead of silently falling back to `0`.
- Refresh `mix.lock` for the upgraded `phoenix_kit` and related dependencies.

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
