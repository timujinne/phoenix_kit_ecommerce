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

### Web Layer

- **Public** (8 LiveViews): ShopCatalog, CatalogCategory, CatalogProduct, CartPage, CheckoutPage, CheckoutComplete, UserOrders, UserOrderDetails
- **Admin** (16 LiveViews): Dashboard, Products, ProductForm, ProductDetail, Categories, CategoryForm, ShippingMethods, ShippingMethodForm, Carts, Settings, OptionsSettings, Imports, ImportShow, ImportConfigs, TestShop
- **Components**: ShopLayouts, ShopCards, CatalogSidebar, FilterHelpers, TranslationTabs
- **Plugs**: ShopSession (guest cart session management)
- **Routes**: `route_module/0` provides public storefront routes; admin routes auto-generated from `admin_tabs/0`

### Settings Keys

All stored via PhoenixKit Settings with module `"shop"`:

- `tax_enabled` — enable tax calculations (default: true)
- `tax_rate` — tax rate percentage (default: 20)
- `inventory_tracking` — track product inventory (default: true)
- `allow_price_override` — allow per-product price overrides (default: false)

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
├── mix/tasks/
│   ├── phoenix_kit_ecommerce.install.ex        # Install mix task
│   └── phoenix_kit_ecommerce.deduplicate_products.ex  # Dedup utility
└── phoenix_kit/modules/shop/
    ├── shop.ex                    # Main module (PhoenixKit.Module behaviour + context)
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
