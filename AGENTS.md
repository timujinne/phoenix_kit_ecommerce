# AGENTS.md

This file provides guidance to AI agents working with code in this repository.

## Project Overview

PhoenixKit E-Commerce — an Elixir module for products, categories, shopping cart, checkout, shipping, and CSV imports, built as a pluggable module for the PhoenixKit framework. Supports multi-language content, dynamic product options with price modifiers, guest and authenticated carts, and integration with PhoenixKitBilling for payments. Provides admin LiveViews for managing the full e-commerce workflow and public storefront pages.

## Commands

```bash
mix deps.get                # Install dependencies
mix test                    # Run all tests
mix test test/file_test.exs # Run single test file
mix test test/file_test.exs:42  # Run specific test by line
mix format                  # Format code
mix credo --strict          # Lint / code quality (strict mode)
mix dialyzer                # Static type checking
mix docs                    # Generate documentation
mix precommit               # compile + format + credo --strict + dialyzer
mix quality                 # format + credo --strict + dialyzer
mix quality.ci              # format --check-formatted + credo --strict + dialyzer
```

## Local cross-repo development

`phoenix_kit` (and any sibling `phoenix_kit_*` dep) resolves from Hex by
default. To build or test this module against a **local checkout** of a
dependency — e.g. an unpublished core change — export `<APP>_PATH` and Mix
swaps the Hex pin for a `path:` + `override: true` dep at resolve time:

```bash
PHOENIX_KIT_PATH=../phoenix_kit mix test     # this module against local core
PHOENIX_KIT_BILLING_PATH=../phoenix_kit_billing mix test
```

The variable name is the dep's app name upper-cased with `_PATH` appended
(`:phoenix_kit` -> `PHOENIX_KIT_PATH`, `:phoenix_kit_ai` ->
`PHOENIX_KIT_AI_PATH`). Set several at once to override multiple deps. This
module's sibling overrides: `PHOENIX_KIT_BILLING_PATH`. **Unset = the
published pin**, so `mix hex.publish` and CI resolve exactly as before.
Implemented via `pk_dep/3` in `mix.exs` — never hand-edit a `phoenix_kit*`
dep into a `path:` tuple (a committed path dep ships a broken package); set
the env var instead.

## Architecture

This is a **library** (not a standalone Phoenix app) that provides e-commerce as a PhoenixKit plugin module.

### Core Schemas (all use UUIDv7 primary keys)

- **Product** — physical and digital products with multi-language title/slug/description, pricing, images, SEO fields, status workflow (draft/active/archived)
- **Category** — hierarchical categories with nesting (parent_uuid), multi-language support, per-category option schemas, position ordering
- **Cart** — shopping cart supporting guest (session-based, 30-day expiry) and user (persistent) modes, with status lifecycle (active/merged/converted/abandoned/expired)
- **CartItem** — cart line items with price snapshots, selected specs, weight tracking
- **ShippingMethod** — shipping options with weight/price constraints, geographic restrictions, free shipping thresholds, delivery estimates
- **ShopConfig** — key-value configuration store (JSONB)
- **ImportConfig** — CSV import profiles with keyword filtering, category rules, option mappings
- **ImportLog** — import job tracking with progress, row counts, error details

### Price display (units, "From", and price on request)

`PhoenixKitEcommerce.PriceDisplay` owns how a price is WRITTEN: an optional
per-language unit ("per hour", "per m²", "в час"), an optional "From"
prefix, and an optional "price on request" flag, stored under one reserved
metadata namespace `Product.metadata["_price_display"]` =
`%{"unit" => %{lang => text}, "from" => bool, "on_request" => bool}`. Free
text, not a unit vocabulary — every shop invents units the next one has
never heard of.

`"on_request"` is written **only when true**, so `build/2` produces exactly
the map it always did and an existing product does not gain a key on its
next save; `settings/1` reads a missing key as `false`.

`render/4` takes an explicit CONTEXT because the same product means
different things per page:

- `:catalog` — the asking price; may show "From" (explicit flag OR a real
  option range) and derives the amount from the option-aware range
- `:selected` — the price for the chosen options; exact, never "From"
- `:cart` / `:order` — a SNAPSHOT; exact, never "From", and the unit comes
  from the stored line, never the live product, so an edit or deletion
  cannot relabel what a customer already agreed to

**"Price on request" must be SNAPSHOTTED onto the line, not read live.**
`CartItem.from_product/3` writes `metadata["price_on_request"]` beside
`price_unit`, and `convert_cart_to_order/2` forwards it into the order's
line items. The flag only suppresses a number that still exists on the
product, so a line that lost it falls back to formatting its stored
`unit_price` — typically `0` — and renders "0.00" where the customer agreed
to "price on request": free, on a committed order. `product_uuid` is
`ON DELETE SET NULL`, so this is reachable simply by deleting a product.
The forwarding step was missed once and caught only by review; there is now
a regression test for both the cart line and the order line.

Two paths would silently erase an admin's settings and are guarded: the
CSV upsert (`merge_localized_attrs/2` replaces metadata wholesale) and the
product form (its metadata build replaces too, so the inputs are real form
fields). Absent settings render exactly what the module rendered before.

### Product Options & Dynamic Pricing

Two-level option system:
- **Global options** — defined in ShopConfig, available to all products
- **Category options** — defined per-category via `option_schema` field

Option types: text, number, boolean, select, multiselect. Price modifiers support fixed amounts and percentage adjustments.

### Contexts

- **Shop** (main module) — system config, product CRUD, category CRUD, cart management, shipping methods, import orchestration, price calculation
- **Options** — option schema management, type validation, metadata validation
- **Events** — PubSub broadcasts for real-time LiveView updates
- **Translations** — multi-language content utilities
- **SlugResolver** — multi-language slug lookup across products and categories

### Workers (Oban)

- **CSVImportWorker** — async CSV import with format detection, progress tracking, error handling (queue: `shop_import`)
- **ImageMigrationWorker** — batch image download and storage integration (queue: `shop_images`)

### Import System

Supports multiple CSV formats via `ImportFormat` behaviour:
- **Shopify** — standard Shopify product export format
- **Prom.ua** — Ukrainian marketplace format
- **Generic** — configurable column mappings

Features: automatic format detection, keyword-based filtering, category assignment rules, product upsert via slug matching.

### PubSub Topics

- Cart events — per-user and per-session broadcasts for real-time cart sync
- Product/category events — catalog change notifications
- Inventory change notifications

### How It Works

1. Parent app adds this as a dependency in `mix.exs`
2. PhoenixKit scans `.beam` files at startup and auto-discovers modules (zero config)
3. `admin_tabs/0` callback registers admin pages; PhoenixKit generates routes at compile time
4. `settings_tabs/0` registers settings under admin settings
5. `user_dashboard_tabs/0` registers "My Orders" pages in user dashboard
6. Settings are persisted via `PhoenixKit.Settings` API (DB-backed in parent app)
7. Permissions are declared via `permission_metadata/0` and checked via `Scope.has_module_access?/2`

### Storefront layout contract

Every public storefront page — catalog, category, product, cart, checkout,
confirmation — renders through core's `LayoutWrapper.app_layout`, i.e. the
HOST application's configured `layouts_module`, for guests and logged-in
visitors alike. `ShopLayouts.shop_layout/1` is the single wrapper.

Until 2026-08 this dispatched three ways: a self-contained
`shop_public_layout` for guest catalog pages (which bypassed the host
layout entirely — the bug a host app reported), the ADMIN dashboard layout
for any authenticated visitor, and `app_layout` only for guest
cart/checkout. The in-page category/filter sidebar that the dashboard
layout used to carry (`sidebar_after_shop`) now renders in the page
templates for everyone. Don't reintroduce a module-owned top-level layout:
the storefront is the host's surface.

### Storefront i18n contract

Two things must both be true for a storefront string to appear translated,
and each has failed independently:

1. **The string is wrapped.** Six public files carried zero `gettext` calls
   while three beside them were fully translated, so a trilingual shop
   rendered its product content in Estonian inside an entirely English
   frame. Flash messages and `page_title` count — they are as visible to a
   customer as anything in the markup.
2. **The backend is pointed at a locale the catalogue HAS.** The content
   language is a DIALECT (`resolve_dialect/1` returns `"ru-RU"`, `"et-EE"`,
   `"en-US"`) and core writes that into the process locale, but this module
   ships `priv/gettext/{en,ru,et}` — plain codes. **Gettext does not fall
   back from `ru-RU` to `ru`**, so every lookup misses and returns its
   msgid, which is the English source string. `Helpers.put_content_locale/1`
   resolves the dialect against the backend's known locales and is called
   from `mount/3`, which runs once per process for both the dead render and
   the connected mount.

⚠️ A page can be fully translated and completely inert at the same time —
`checkout_page.ex` was exactly that. When adding a public page, call
`put_content_locale/1` in its `mount/3` or it will render English while its
siblings translate.

`catalog_sidebar.ex` is `use Phoenix.Component`, not the module's own web
macros, so it does NOT inherit the Gettext backend those inject and declares
one explicitly. Any new component outside `web/` must do the same.

Strings that must NEVER be wrapped: `push_event` names, URL paths, route
segments, setting keys. Two of these were wrapped once and would have broken
at runtime in every non-English locale.

### Web Layer

- **Public** (8 LiveViews): ShopCatalog, CatalogCategory, CatalogProduct, CartPage, CheckoutPage, CheckoutComplete, UserOrders, UserOrderDetails
- **Admin** (16 LiveViews): Dashboard, Products, ProductForm, ProductDetail, Categories, CategoryForm, ShippingMethods, ShippingMethodForm, Carts, Settings, OptionsSettings, Imports, ImportShow, ImportConfigs, TestShop
- **Components**: ShopLayouts, ShopCards, CatalogSidebar, FilterHelpers, TranslationTabs
- **Plugs**: ShopSession (guest cart session management)
- **Routes**: `route_module/0` provides public storefront routes; admin routes auto-generated from `admin_tabs/0`

### Settings Keys

All stored via `PhoenixKit.Settings`. Keys are **`shop_`-prefixed** — the
unprefixed names this section used to list (`tax_enabled`, `tax_rate`, …)
were never what the code read.

**Behaviour**

- `shop_enabled` — module master switch (default: `false`)
- `shop_inventory_tracking` — track product inventory (default: `true`)
- `shop_allow_price_override` — allow per-product price overrides (default: `false`)

**Storefront display**

- `shop_category_name_display` — `"truncate"` (default) or `"wrap"`
- `shop_category_icon_mode` — `"none"` (default), icon rendering mode
- `shop_sidebar_show_categories` — show the category sidebar (default: `true`)
- `shop_show_cart_bar` — show the compact Shop/Cart bar on catalog pages
  (default: `true`). The storefront renders inside the HOST's layout, so a
  host whose header already links to the cart turns this off; a host whose
  header does not must leave it on, or shoppers have no way back to their
  cart.
- `shop_catalog_vocabulary` — `"products"` (default), `"services"` or
  `"mixed"`. What the storefront calls what it sells. Read through
  `PhoenixKitEcommerce.Vocabulary`, never directly. Each variant is a
  SEPARATE complete `gettext` literal, not a noun swapped into a sentence:
  Russian and Estonian inflect the noun for a case the surrounding sentence
  chooses (`товаров` vs `услуг` share neither stem nor ending), so a
  `"No %{noun} available"` template cannot be translated correctly for a noun
  the translator never saw. Adding a vocabulary means adding a clause and a
  literal to every function in that module.
- `shop_hide_zero_decimals` — render `40` rather than `40.00` when the
  fractional part is entirely zero (default: `false`). **Storefront only.**
  Invoices, receipts and credit notes call billing's `format_amount/2`
  directly and keep two decimals, which is the auditable form.

**Shipping — read through `PhoenixKitEcommerce`, never directly**

- `shop_shipping_skip_mode` — `"off"` (default, a shippable cart must carry
  a method), `"fallback"` (an order may convert without one when no active
  method covers the buyer's country) or `"always"` (never ask). Read via
  `shipping_skip_mode/0`; the skip decision itself is
  `shipping_skippable?/1`, which **must run after
  `apply_checkout_shipping_country/2`** — it is a question about the
  checkout country, which the cart does not carry until then. Skipped
  orders stamp `metadata["shipping_skipped"]` +
  `metadata["shipping_skip_reason"]`, add no shipping line and no charge.
- `shop_shipping_selection_position` — `"cart"` (default) or `"checkout"`.
  Read via `shipping_selection_position/0`. ⚠️ Under `"checkout"` the cart
  page renders **no** shipping section at all, so nothing may redirect a
  shopper there to "pick another method" — `CheckoutPage` re-enters its own
  `:shipping` step instead. A `/cart` bounce under this setting is a closed
  loop with no way out; that was a real bug.

**Storefront notifications**

- `shop_notify_cart_first_item`, `shop_notify_cart_item`,
  `shop_notify_checkout_started` — per-event toggles, all `"false"` by
  default. Read through `notify_event?/1`.
- `shop_notification_recipients` — `%{"uuids" => [...]}` (a bare list is
  rejected: core's `value_json` casts through an Ecto `:map` field). Empty
  or unset means "every shop admin". The stored list is intersected with
  current `shop.manage_carts` holders on every send — the setting is a
  snapshot of who was an operator that day, and revoking shop access has to
  stop the cart-activity feed too.

**Policy — read through `PhoenixKitEcommerce.Policy`, never directly**

Every one is **secure by default**, and every reader fails *closed* on a
settings-layer error. The module is the single source of truth so the admin
UI and the enforcement points cannot disagree about a default.

- `shop_order_lookup_policy` — `"strict"` (default) requires the session that
  placed an order to view its confirmation page; `"link"` makes the UUID
  sufficient. Only choose `"link"` if you deliberately mail order links and
  accept the URL as the credential — the page renders the billing snapshot.
- `shop_allow_raw_html_descriptions` — `false` (default) sanitizes product
  descriptions. Turning it on trusts everyone who can edit a product *or
  supply a CSV import feed* with script execution in every shopper's browser.
- `shop_allow_svg_uploads` — `false` (default) rejects SVG in the image
  importer. SVG can carry script and stored files are served inline.
- `shop_image_import_allow_private_networks` — `false` (default) blocks
  loopback/private/link-local/metadata addresses in the image importer.
- `shop_default_tax_country` — optional two-letter fallback country for tax
  when checkout supplied no address. Unset by default: charging tax against
  a guessed jurisdiction is worse than charging none.
- `shop_import_cleanup_scope` — `"auto_created"` (default) limits post-import
  cleanup to categories the import created; `"all_empty"` restores the old
  sweep that deleted *every* empty category, including deliberate placeholders.
- `shop_legacy_cookie_until` — ISO8601 cutoff after which pre-signing
  `shop_session_id` cookies stop being adopted. ⚠️ Unset means "still
  migrating"; this is the one key here where leaving the default forever is
  wrong, because nothing prunes carts so the window never self-closes.

**Consumed from billing** (owned by `phoenix_kit_billing`, read here)

- `billing_tax_enabled`, `billing_default_tax_rate`

### Cart Status Workflow

```
active → converted (checkout)
       → merged (login)
       → abandoned (inactivity)
       → expired (30 days)
```

### Product Status Workflow

```
draft → active → archived
```

### File Layout

```
lib/
├── phoenix_kit_ecommerce.ex                    # Main module (PhoenixKit.Module behaviour + context)
└── phoenix_kit_ecommerce/
    ├── mix_tasks/
    │   ├── phoenix_kit_ecommerce.install.ex    # Install mix task
    │   └── phoenix_kit_ecommerce.deduplicate_products.ex  # Dedup utility
    ├── events.ex                  # PubSub event broadcasting
    ├── translations.ex            # Multi-language utilities
    ├── slug_resolver.ex           # Multi-language slug lookup
    ├── schemas/
    │   ├── product.ex             # Product schema
    │   ├── category.ex            # Category with nesting
    │   ├── cart.ex                # Shopping cart
    │   ├── cart_item.ex           # Cart line items
    │   ├── shipping_method.ex     # Shipping options
    │   ├── shop_config.ex         # Key-value config store
    │   ├── import_config.ex       # Import profiles
    │   └── import_log.ex          # Import tracking
    ├── options/
    │   ├── options.ex             # Option management context
    │   ├── option_types.ex        # Type system & validation
    │   └── metadata_validator.ex  # Metadata validation
    ├── import/
    │   ├── import_format.ex       # Format behaviour
    │   ├── format_detector.ex     # Auto-detect CSV format
    │   ├── csv_parser.ex          # CSV parsing
    │   ├── csv_validator.ex       # CSV validation
    │   ├── csv_analyzer.ex        # CSV analysis
    │   ├── shopify_csv.ex         # Shopify format parser
    │   ├── shopify_format.ex      # Shopify format implementation
    │   ├── prom_ua_format.ex      # Prom.ua format implementation
    │   ├── product_transformer.ex # CSV row -> product
    │   ├── option_builder.ex      # Option creation from CSV
    │   └── filter.ex              # Keyword filtering
    ├── services/
    │   ├── image_downloader.ex    # Download images from URLs
    │   └── image_migration.ex     # Batch image storage
    ├── workers/
    │   ├── csv_import_worker.ex         # Oban: async CSV import
    │   └── image_migration_worker.ex    # Oban: batch image processing
    └── web/
        ├── routes.ex              # Route definitions
        ├── shop_web.ex            # Web module config
        ├── helpers.ex             # Template helpers
        ├── shop_catalog.ex        # Public: catalog page
        ├── catalog_category.ex    # Public: category browse
        ├── catalog_product.ex     # Public: product detail
        ├── cart_page.ex           # Public: cart
        ├── checkout_page.ex       # Public: checkout
        ├── checkout_complete.ex   # Public: order confirmation
        ├── user_orders.ex         # Public: order history
        ├── user_order_details.ex  # Public: order details
        ├── dashboard.ex           # Admin: overview
        ├── products.ex            # Admin: product list
        ├── product_form.ex        # Admin: product editor
        ├── product_detail.ex      # Admin: product detail
        ├── categories.ex          # Admin: category list
        ├── category_form.ex       # Admin: category editor
        ├── shipping_methods.ex    # Admin: shipping list
        ├── shipping_method_form.ex # Admin: shipping editor
        ├── carts.ex               # Admin: cart analytics
        ├── settings.ex            # Admin: settings
        ├── options_settings.ex    # Admin: global options
        ├── imports.ex             # Admin: import list
        ├── import_configs.ex      # Admin: import profiles
        ├── import_show.ex         # Admin: import details
        ├── test_shop.ex           # Admin: testing UI
        ├── option_state.ex        # Client option state
        ├── components/
        │   ├── shop_layouts.ex    # Layout wrappers
        │   ├── shop_cards.ex      # Product cards
        │   ├── catalog_sidebar.ex # Filter sidebar
        │   ├── filter_helpers.ex  # Dynamic filters
        │   └── translation_tabs.ex # Multi-lang editing
        └── plugs/
            └── shop_session.ex    # Guest cart session
```

## Permissions

The `"shop"` key is admin-area READ access. Four sub-permissions carry the
capabilities (core enforces sub-implies-base):

| Key | Covers |
|-----|--------|
| `shop.manage_catalog` | products + categories (list, form and detail pages) |
| `shop.manage_carts` | the carts admin — **read included**, the rows carry customer contact details |
| `shop.manage_settings` | settings, security policy, product options, shipping methods |
| `shop.run_imports` | CSV imports and import configurations |

Enforcement is **bundled-UI policy** and deliberately scoped: admin tabs
carry their sub-key so the sidebar hides what a holder cannot use, and
every mutating event handler re-checks through `Web.Authz` (fail-closed on
a missing scope). The public context API stays scope-less — hosts call it
from their own controllers, workers and scripts, and it cannot know whose
authority those run under. Workers are authorized at ENQUEUE by the
LiveView that starts them.

Pattern for a gated handler: the public `handle_event/3` clause matches the
event name and delegates through `Authz.authorize/3` to a private
`gated_event/3` clause holding the original body. Keeping the body in its
own clause is what stops the wrapper adding a nesting level to 47 handlers.

⚠️ **Upgrade note.** Core auto-grants a newly discovered sub-permission to
the Admin system role only. A CUSTOM role holding base `"shop"` keeps its
reads but loses every mutation until an operator re-grants — secure by
default and deliberate, but a breaking authorization change on upgrade.

## Notifications and the audit trail

`notification_types/0` declares three sub-types under `"shop"`: admin
`orders`, customer `order_confirmations`, and `imports`. They are separate
so an operator can mute the order firehose without silencing their own
receipts.

⚠️ **The audit action strings are deliberately DIFFERENT from the notify
action strings** (`shop.order_converted` vs `shop.order_placed`;
`shop.import_run_completed/failed` vs `shop.import_completed/failed`).
Core's `Activity.log/1` auto-derives notifications from registered actions,
so reusing a notify action in an audit row delivers a duplicate on top of
the explicit fan-out. A test pins this contract — keep it.

Recipients union permission holders with **Owner-role holders and `"*"`
superadmins**: neither has permission rows, so a key-only query misses the
primary operator of a default install.

## Module-owned migrations

`PhoenixKitEcommerce.Migrations` (registered via `migration_module/0`) is this
module's own versioned chain, discovered by `mix phoenix_kit.status` and
applied by `mix phoenix_kit.update`. V1 is **adoptive**: all ten shop tables
are core V135 baseline tables that core still creates, so V1 changes no shape
— it stamps a `pke_schema:<N>` COMMENT on `phoenix_kit_shop_config` and claims
future ownership. `down/1` unstamps the marker and **drops nothing**.

Two rules keep an adoptive chain honest, and both have been broken once:

1. **Every statement is parameterized by the prefix.** A hardcoded `public.`
   aborts a prefixed install, or writes into a schema this module does not own.
2. **Object names mirror core's, including how core names them per schema.**
   Core embeds the schema name in exactly five shop index names under a
   non-public prefix — the `*_uuid_idx` on `phoenix_kit_shop_cart_items`,
   `…_carts`, `…_categories`, `…_products`, `…_shipping_methods` (`pn` in
   core's `postgres/v135.ex`, `__PK_NAME_EXEMPT__` in
   `migrations/expected_schema.ex`); every other one is named identically in
   every schema. A bare name for those five does not match core's index, so
   `CREATE … IF NOT EXISTS` silently builds a duplicate.

The chain is emitted as data (`up_statements/1`, `down_statements/2`) and
`test/phoenix_kit_ecommerce/migrations_test.exs` scans it without a database —
object counts, names, the prefix rules above, and that no statement can drop or
truncate. When adding a version, extend those scans; they are the only check
that runs, since the test repo deliberately applies core's DDL only.

## Critical Conventions

- **Module key** must be consistent across all callbacks: `"shop"`
- **UUIDv7 primary keys** — all schemas use `@primary_key {:uuid, UUIDv7, autogenerate: true}` and `uuid_generate_v7()` in migrations (never `gen_random_uuid()`)
- **Oban workers** — CSV imports and image migration use Oban workers; never spawn bare Tasks for async operations
- **Centralized paths** — never hardcode URLs or route paths in LiveViews; use path helpers or `PhoenixKit.Utils.Routes.path/1` for cross-module links
- **Admin routes from `admin_tabs/0`** — all admin navigation is auto-generated by PhoenixKit Dashboard from the tabs returned by `admin_tabs/0`; do not manually add admin routes elsewhere
- **LiveViews use `PhoenixKitWeb` `:live_view`** — this module uses `use PhoenixKitWeb, :live_view` for correct admin layout integration (sidebar/header)
- **Navigation paths**: always use `PhoenixKit.Utils.Routes.path/1`, never relative paths
- **`enabled?/0`**: must rescue errors and return `false` as fallback (DB may not be available)
- **Settings via PhoenixKit Settings** — all config is stored in the PhoenixKit settings system, not in application env
- **LiveView assigns** available in admin pages: `@phoenix_kit_current_scope`, `@current_locale`, `@url_path`
- **Tab IDs**: prefixed with `:admin_shop` (main tabs) and `:admin_settings_shop` (settings tab)
- **URL paths**: `/admin/shop` (dashboard), `/admin/shop/settings` (settings), use hyphens not underscores
- **Decimal for money** — all monetary amounts use `Decimal` type; never use floats for currency
- **Billing integration** — checkout converts carts to orders via `PhoenixKitBilling`; never duplicate payment logic

## Tailwind CSS Scanning

This module implements `css_sources/0` returning `[:phoenix_kit_ecommerce]` so PhoenixKit's installer adds the correct `@source` directive to the parent's `app.css`. Without this, Tailwind purges CSS classes unique to this module's templates.

## Versioning & Releases

### Tagging & GitHub releases

Tags use **bare version numbers** (no `v` prefix):

```bash
git tag 0.1.1
git push origin 0.1.1
```

GitHub releases are created with `gh release create` using the tag as the release name. The title format is `<version> - <date>`, and the body comes from the corresponding `CHANGELOG.md` section:

```bash
gh release create 0.1.1 \
  --title "0.1.1 - 2026-03-28" \
  --notes "$(changelog body for this version)"
```

### Full release checklist

1. Update version in `mix.exs`
2. Add changelog entry in `CHANGELOG.md`
3. Run `mix precommit` — ensure zero warnings/errors before proceeding
4. Commit all changes: `"Bump version to x.y.z"`
5. Push to main and **verify the push succeeded** before tagging
6. Create and push git tag: `git tag x.y.z && git push origin x.y.z`
7. Create GitHub release: `gh release create x.y.z --title "x.y.z - YYYY-MM-DD" --notes "..."`

**IMPORTANT:** Never tag or create a release before all changes are committed and pushed. Tags are immutable pointers — tagging before pushing means the release points to the wrong commit.

## Testing

### Running tests

```bash
mix test                                        # All tests
mix test test/file_test.exs                     # Single test file
mix test test/file_test.exs:42                  # Specific test by line
```

### Test harness

The suite is two-tiered:

- **Unit tests** (schemas, changesets, pure functions) always run — no
  database required.
- **Integration tests** (tagged `:integration` via the case templates
  below) need PostgreSQL. They are auto-excluded when the database is
  unavailable, so `mix test` never hard-fails on a fresh checkout.

First-time setup (one-off):

```bash
createdb phoenix_kit_ecommerce_test
```

After that, `mix test` boots `PhoenixKitEcommerce.Test.Repo`, runs core's
versioned migrations via `PhoenixKit.Migration.ensure_current/2` (no
module-owned DDL), and uses the Ecto SQL sandbox for per-test isolation.
The test DB name is overridable via the `MIX_TEST_PARTITION` env var.

Case templates live under `test/support/`:

- **`PhoenixKitEcommerce.DataCase`** — context/schema tests; sets up the
  sandbox connection and imports Ecto query/changeset helpers.
- **`PhoenixKitEcommerce.LiveCase`** — LiveView tests; wires the test
  endpoint/router (`test_endpoint.ex` / `test_router.ex`) and conn
  helpers on top of `DataCase`.

Other support modules: `activity_log_assertions.ex` (assertion helpers),
`test_layouts.ex` (a host-consumer layout fixture), `hooks.ex`,
`test_repo.ex`. Dialyzer suppressions are tracked in
`.dialyzer_ignore.exs`.

### Deferred from the 2026-06-04 quality sweep

The sweep completed most of the initially-deferred items. **Completed:**

1. **Module-wide activity logging** — `PhoenixKitEcommerce.Activity`
   LV-layer wrapper logged on every admin mutation (product/category/
   shipping/import-config CRUD + bulk ops + import runs); PII-safe;
   covered by `test/phoenix_kit_ecommerce/activity_logging_test.exs`.
2. **`Errors` atom-dispatch module** — `PhoenixKitEcommerce.Errors.message/1`
   maps the module's atom errors to gettext-backed strings;
   `test/phoenix_kit_ecommerce/errors_test.exs` pins each.
4. **Import-config keyword cap** — `include_keywords` / `exclude_keywords`
   / `exclude_phrases` capped at 100 entries each with a changeset error.
   The hardcoded `$` price fallback was centralized as a single attribute
   (it only fires when no default currency is configured; a real currency
   still formats via `Currency.format_amount/2`).

**Still remaining (genuinely out of scope for now):**

3. **Component-migration tail** — the shipping-method form was migrated to
   core `<.input>/<.select>/<.textarea>`. The multilang **category/product
   forms** (driven by `TranslationTabs` + dynamic-option selects) and the
   **map-backed import-config form** (no changeset/`:action`) were left
   as-is — migrating them safely needs translation/validation rewiring.
5. ~~**Body-string gettext-backend migration** (from PR #4)~~ — **done**
   (commit `bce8114`). `web/shop_web.ex` now injects
   `PhoenixKitEcommerce.Gettext` for both the LiveView and component
   `__using__` blocks, and `priv/gettext/{en,et,ru}` each carry 547
   msgids. Body strings in `web/` resolve against the module catalogue,
   not the parent app's.

   Practical consequence for new code: a `gettext("…")` added anywhere
   under `web/` lands in **this module's** catalogue, so it needs
   `mix gettext.extract && mix gettext.merge priv/gettext --no-fuzzy`
   here — not in core. (Merge with `--no-fuzzy`: fuzzy entries are live
   at runtime, so a plain merge after an extraction gap ships guessed
   translations.)

## Research & Design Notes

Non-PR research / strategic-assessment docs live flat under `dev_docs/`:

- **`dev_docs/agentic_commerce_acp_research.md`** — Agentic Commerce / ACP
  assessment (2026-06-14). Triggered by the "Visa plugs into ChatGPT" news.
  Covers the Agentic Commerce Protocol (OpenAI + Stripe), what a merchant must
  implement (product feed + checkout REST endpoints + payment), how it maps onto
  this module's `Cart`/`convert_cart_to_order/2` + `phoenix_kit_billing`'s Stripe
  `Provider`, feasibility, and the **verdict: watch-item, no build yet** (build
  triggers + a proposed `phoenix_kit_acp` bridge-plugin shape are in the doc).
  Payment-leg companion: `phoenix_kit_billing/dev_docs/agentic_commerce_payments.md`.

## Pull Requests

### Commit Message Rules

Start with action verbs: `Add`, `Update`, `Fix`, `Remove`, `Merge`.

### PR Reviews

PR review files go in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/` directory. Use `{AGENT}_REVIEW.md` naming (e.g., `CLAUDE_REVIEW.md`, `GEMINI_REVIEW.md`).

### Review file format

```markdown
# Code Review: PR #<number> — <title>

**Reviewed:** <date>
**Reviewer:** Claude (claude-opus-4-6)
**PR:** <GitHub URL>
**Author:** <name> (<GitHub login>)
**Head SHA:** <commit SHA>
**Status:** <Merged | Open>

## Summary
<What the PR does>

## Issues Found
### 1. [<SEVERITY>] <title> — <FIXED if resolved>
**File:** <path> lines <range>
**Confidence:** <score>/100

## What Was Done Well
<Positive observations>

## Verdict
<Approved | Approved with fixes | Needs Work> — <reasoning>
```

Severity levels: `BUG - CRITICAL`, `BUG - HIGH`, `BUG - MEDIUM`, `NITPICK`, `OBSERVATION`

When issues are fixed in follow-up commits, append `— FIXED` to the issue title and update the Verdict section.

Additional files per PR directory:
- `README.md` — PR summary (what, why, files changed)
- `FOLLOW_UP.md` — post-merge issues, discovered bugs
- `CONTEXT.md` — alternatives considered, trade-offs

## External Dependencies

- **PhoenixKit** (`~> 1.7`) — Module behaviour, Settings API, shared components, RepoHelper, Utils (Date, UUID, Routes), Users.Auth.User, Users.Roles, PubSub.Manager
- **PhoenixKit Billing** (`~> 0.1`) — Order conversion, payment processing, billing profiles
- **Phoenix LiveView** (`~> 1.1`) — Admin and storefront LiveViews
- **Phoenix** (`~> 1.7`) — Web framework (controllers, routing)
- **Ecto SQL** (`~> 3.12`) — Database queries and schemas
- **Oban** (`~> 2.20`) — Background job processing (CSV imports, image migration)
- **UUIDv7** (`~> 1.0`) — UUIDv7 primary key generation
- **NimbleCSV** (`~> 1.2`) — CSV parsing for product imports
- **Req** (`~> 0.5`) — HTTP client for downloading product images
- **Jason** (`~> 1.4`) — JSON encoding/decoding
- **ex_doc** (`~> 0.39`, dev only) — Documentation generation
- **credo** (`~> 1.7`, dev/test) — Static analysis
- **dialyxir** (`~> 1.4`, dev/test) — Type checking
