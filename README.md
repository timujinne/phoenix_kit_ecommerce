# PhoenixKitEcommerce

[![Elixir](https://img.shields.io/badge/Elixir-~%3E_1.18-4B275F)](https://elixir-lang.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

E-commerce module for [PhoenixKit](https://github.com/BeamLabEU/phoenix_kit). Products, categories, shopping cart, checkout, shipping, CSV imports, and multi-language support with real-time LiveView UI.

## Features

- **Product catalog** — physical and digital products with pricing, images, SEO fields, and draft/active/archived workflow
- **Dynamic options & pricing** — two-level option system (global + category-specific) with fixed and percentage price modifiers
- **Hierarchical categories** — nested categories with multi-language names, slugs, and per-category option schemas
- **Shopping cart** — guest (session-based) and user (persistent) carts with real-time cross-tab sync via PubSub
- **Checkout & payments** — integrated with [PhoenixKitBilling](https://github.com/BeamLabEU/phoenix_kit_billing) for order conversion and payment processing
- **Shipping methods** — weight-based and price-based constraints, geographic restrictions, free shipping thresholds, delivery estimates
- **CSV import** — automatic format detection (Shopify, Prom.ua, generic) with keyword filtering, category rules, and image migration
- **Multi-language** — localized titles, slugs, descriptions, and SEO metadata across products and categories
- **Real-time updates** — PubSub events for carts, products, categories, and inventory changes
- **Admin dashboard** — LiveViews for managing products, categories, shipping, carts, imports, and settings
- **User pages** — catalog, product detail, cart, checkout, order history, and order details
- **Auto-discovery** — implements `PhoenixKit.Module` behaviour; PhoenixKit finds it at startup with zero config

## Installation

Add `phoenix_kit_ecommerce` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:phoenix_kit_ecommerce, "~> 0.2"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

> **Note:** For development or if not yet published to Hex, you can use:
> ```elixir
> {:phoenix_kit_ecommerce, github: "BeamLabEU/phoenix_kit_ecommerce"}
> ```

PhoenixKit auto-discovers the module at startup — no additional configuration needed.

## Quick Start

1. Add the dependency to `mix.exs`
2. Run `mix deps.get`
3. Add Oban queues to `config/config.exs`:
   ```elixir
   config :my_app, Oban,
     queues: [shop_import: 5, shop_images: 5]
   ```
4. Run `mix phoenix_kit.update` to generate migrations
5. Enable the Shop module in Admin -> Modules
6. Configure shop settings at `/admin/shop/settings`

## Usage

### Products

```elixir
alias PhoenixKitEcommerce, as: Shop

# Create a product
{:ok, product} = Shop.create_product(%{
  title: "Wireless Headphones",
  slug: "wireless-headphones",
  status: "draft",
  price: Decimal.new("79.99"),
  currency: "EUR",
  product_type: "physical",
  weight_grams: 250
})

# Publish the product
{:ok, product} = Shop.update_product(product, %{status: "active"})

# Multi-language support
{:ok, product} = Shop.create_product(%{
  title: %{"en" => "Wireless Headphones", "uk" => "Бездротові навушники"},
  slug: %{"en" => "wireless-headphones", "uk" => "bezdrotovi-navushnyky"},
  price: Decimal.new("79.99"),
  currency: "EUR"
})

# Look up by slug in any language
product = Shop.get_product_by_any_slug("bezdrotovi-navushnyky")
```

### Categories

```elixir
# Create a category hierarchy
{:ok, electronics} = Shop.create_category(%{
  name: "Electronics",
  slug: "electronics",
  status: "active"
})

{:ok, audio} = Shop.create_category(%{
  name: "Audio",
  slug: "audio",
  status: "active",
  parent_uuid: electronics.uuid
})

# List categories for navigation menus
categories = Shop.list_menu_categories()
```

### Product Options & Dynamic Pricing

```elixir
# Options support fixed and percentage price modifiers
# Category-level option schema example:
option_schema = [
  %{
    "name" => "color",
    "type" => "select",
    "options" => ["Black", "White", "Red"],
    "price_modifier" => %{"Red" => %{"type" => "fixed", "amount" => "5.00"}}
  },
  %{
    "name" => "warranty",
    "type" => "select",
    "options" => ["1 Year", "3 Years"],
    "price_modifier" => %{"3 Years" => %{"type" => "percent", "amount" => "20"}}
  }
]

# Calculate final price with selected options
price = Shop.calculate_product_price(product, selected_specs)
```

### Shopping Cart

```elixir
# Get or create a cart (guest or authenticated)
{:ok, cart} = Shop.get_or_create_cart(user_uuid: user.uuid)
{:ok, cart} = Shop.get_or_create_cart(session_id: session_id)

# Add items
{:ok, cart} = Shop.add_to_cart(cart, product, %{quantity: 2, selected_specs: specs})

# Update quantity
{:ok, cart} = Shop.update_cart_item(cart, item_uuid, %{quantity: 3})

# Set shipping and payment
{:ok, cart} = Shop.set_cart_shipping(cart, shipping_method_uuid)
{:ok, cart} = Shop.set_cart_payment_option(cart, payment_option_uuid)

# Merge guest cart after login
{:ok, cart} = Shop.merge_guest_cart(session_id, user.uuid)

# Convert to order (integrates with Billing module).
# Takes the billing identity: an owned profile uuid, or guest billing data.
{:ok, order} = Shop.convert_cart_to_order(cart, billing_profile_uuid: profile.uuid)
{:ok, order} = Shop.convert_cart_to_order(cart, billing_data: %{"email" => "a@b.com"})
```

> Payments (Stripe etc.) are handled by **PhoenixKitBilling**. To configure and
> test payment providers — including running Stripe webhooks against
> `localhost` via the Stripe CLI — see **"Testing Stripe locally"** in the
> [phoenix_kit_billing README](https://github.com/BeamLabEU/phoenix_kit_billing#testing-stripe-locally).

### Shipping Methods

```elixir
{:ok, method} = Shop.create_shipping_method(%{
  name: "Standard Delivery",
  slug: "standard",
  price: Decimal.new("5.99"),
  currency: "EUR",
  free_above_amount: Decimal.new("50.00"),
  min_weight_grams: 0,
  max_weight_grams: 30000,
  estimated_days_min: 3,
  estimated_days_max: 5,
  countries_allowed: ["UA", "PL", "DE"],
  active: true
})

# Get methods available for a specific cart
methods = Shop.get_available_shipping_methods(cart)
```

### CSV Import

```elixir
# Imports are driven from the admin wizard at /admin/shop/imports, which
# uploads the file, detects the format (Shopify, Prom.ua, generic), creates
# an ImportLog and enqueues PhoenixKitEcommerce.Workers.CSVImportWorker.
#
# `start_import/2` is the state transition on an existing log, not an entry
# point that takes a path:
{:ok, log} = Shop.start_import(import_log, total_rows)

# Progress is broadcast on "shop:import:<uuid>" and rendered live at
# /admin/shop/imports/:uuid
```

### Shopify Sync

One-way, human-confirmed sync that keeps existing products current
against a connected Shopify store — **not** a product importer. It
updates products the shop already has (matched to Shopify by
handle/slug); a Shopify product with no local match is skipped. To
bring a new product in from Shopify, use [CSV Import](#csv-import)
first, then this to keep it current.

Setup (all through the UI, no environment variables):

1. **In Shopify admin**: Settings → Apps and sales channels → Develop
   apps → Create an app. Configure Admin API scopes — `read_products`
   is the only one this needs. Install the app, then reveal and copy
   its Admin API access token (shown once).
2. **In your PhoenixKit host app's admin**: Settings → Integrations →
   Add Connection → Shopify. Enter the shop domain
   (`your-store.myshopify.com`) and the access token from step 1, then
   save. Credentials are encrypted at rest by core's
   `PhoenixKit.Integrations` store — this module never sees or stores
   them itself.
   > The generic "Test Connection" button on that page reports success
   > without actually contacting Shopify (Shopify isn't one of core's
   > built-in validation strategies) — the "Check for changes" button
   > below is the real connectivity test.
3. **In the shop admin**: Shop → Shopify Sync → "Check for changes".
   Review the diff, then apply. Price-only changes under a 3x swing
   can be applied in bulk; every other change — any non-price field,
   or a >3x price swing — is applied one product at a time with an
   explicit confirmation showing exactly what will change.

Fields compared: title, description (derived from Shopify's `Body
(HTML)`), the HTML body itself, vendor, tags, status, and price (the
lowest current variant price). Not synced: new products,
categories/collections, images, variants/options, and inventory
quantity.

```elixir
alias PhoenixKitEcommerce.Shopify.Sync

# integration_uuid comes from PhoenixKit.Integrations.list_connections("shopify")
{:ok, %{changes: changes, source: source, fallback_reason: reason}} =
  Sync.check(integration_uuid)

# `source` is :admin (the full diff above) or :storefront — a price-only
# fallback used when the Admin API token was rejected, with `reason`
# saying why (e.g. :unauthorized). Always check `source` before treating
# `changes` as a complete diff.

# Apply everything that changed for one product...
{:ok, product} = Sync.apply_change(change)
# ...or only specific fields:
{:ok, product} = Sync.apply_change(change, [:price])
```

### Real-Time Events

Subscribe to shop events in your LiveViews:

```elixir
def mount(_params, _session, socket) do
  # Pick the topic that matches how the visitor is identified:
  PhoenixKitEcommerce.Events.subscribe_to_user_cart(user_uuid)
  # ...or, for a guest:
  # PhoenixKitEcommerce.Events.subscribe_to_session_cart(session_id)
  {:ok, socket}
end

def handle_info({:cart_updated, cart}, socket) do
  {:noreply, assign(socket, :cart, cart)}
end
```

### Settings

Keys are `shop_`-prefixed. (Earlier revisions of this table listed
unprefixed names that the code never read.)

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `shop_enabled` | boolean | `false` | Module master switch |
| `shop_inventory_tracking` | boolean | `true` | Track product inventory |
| `shop_allow_price_override` | boolean | `false` | Allow per-product price overrides |
| `shop_category_name_display` | string | `"truncate"` | `"truncate"` or `"wrap"` |
| `shop_category_icon_mode` | string | `"none"` | Category icon rendering |
| `shop_sidebar_show_categories` | boolean | `true` | Show the category sidebar |
| `shop_catalog_vocabulary` | string | `"products"` | `"products"`, `"services"` or `"mixed"` — what the storefront calls what you sell |
| `shop_hide_zero_decimals` | boolean | `false` | Render `40` rather than `40.00` when the fraction is all zeros. **Storefront only** |

`shop_catalog_vocabulary` exists because a shop selling colour grading reads
badly under "No products match your filters". Each option is a separately
translated set of complete sentences rather than a swapped noun — Russian and
Estonian inflect the noun for a case the sentence chooses, so a template with a
placeholder cannot be translated correctly. Read it through
`PhoenixKitEcommerce.Vocabulary`, never directly.

`shop_hide_zero_decimals` affects the **storefront only**. Invoices, receipts and
credit notes keep two decimals, which is the auditable form.

Tax comes from the Billing module (`billing_tax_enabled`,
`billing_default_tax_rate`), not from shop.

**Policy keys** — read through `PhoenixKitEcommerce.Policy`, never directly.
All are secure by default and fail *closed*; each is editable on the
E-Commerce settings page.

| Key | Default | Effect of the default |
|-----|---------|-----------------------|
| `shop_order_lookup_policy` | `"strict"` | An order page needs the session that placed it |
| `shop_allow_raw_html_descriptions` | `"false"` | Product descriptions are sanitized |
| `shop_allow_svg_uploads` | `"false"` | SVG is rejected by the image importer |
| `shop_image_import_allow_private_networks` | `"false"` | Importer refuses loopback/private addresses |
| `shop_default_tax_country` | `""` | No guessed jurisdiction; tax needs a real address |
| `shop_import_cleanup_scope` | `"auto_created"` | Cleanup only removes categories the import created |
| `shop_legacy_cookie_until` | *(unset)* | ⚠️ Pre-signing cart cookies are still adopted — set a date to close the window |

### Cart Status Workflow

| Status | Description |
|--------|-------------|
| `active` | Cart is in use |
| `merged` | Guest cart merged into user cart after login |
| `converted` | Cart converted to an order via checkout |
| `abandoned` | Cart inactive past threshold |
| `expired` | Session-based cart past 30-day expiry |

```
active → converted (checkout)
       → merged (login)
       → abandoned (inactivity)
       → expired (30 days)
```

### Permissions

The module declares permissions via `permission_metadata/0`:

- `"shop"` — access to the e-commerce admin dashboard and all sub-pages

Use `Scope.has_module_access?/2` to check permissions in your application.

### CSS Requirements

This module implements `css_sources/0` returning `[:phoenix_kit_ecommerce]`, so PhoenixKit's installer automatically adds the correct `@source` directive to your `app.css` for Tailwind scanning. No manual configuration needed.

### Order notifications — two switches, both off by default

The module registers `shop.order_placed` and `shop.order_confirmed`, but
**registering a notification type is not enough to deliver one**. Two settings
gate it, and on a fresh install both are closed:

1. **Global notifications must be on.** With `notifications_enabled` off,
   `shop.order_placed` fires into silence — no error, no log line. The module
   looks broken rather than disabled.
2. **The recipient must be opted into a channel for that type.** External
   channels are fail-closed per type, so a recipient with notifications enabled
   but no Email channel on `shop.orders` still gets nothing.

Until both are set, an order arrives with no alert of any kind and the only way
to notice is to open the admin panel. A shop running in production lost a real
customer order this way before spotting it.

Recipients are the holders of the relevant permission **unioned with Owner-role
holders and `"*"` superadmins** — neither of those has permission rows, so a
key-only query misses the primary operator of a default install.

⚠️ Note that the order-confirmation page's copy is independent of all this. It
tells guests that an account-confirmation email is on its way, which is true and
is the only mail checkout sends. It does **not** promise customers an order
confirmation, because the module does not send one.

## Architecture

```
lib/
├── phoenix_kit_ecommerce.ex                    # Main context (PhoenixKit.Module behaviour)
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
    │   ├── csv_import_worker.ex   # Oban: async CSV import
    │   └── image_migration_worker.ex # Oban: batch image processing
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

### Database Tables

| Table | Description |
|-------|-------------|
| `phoenix_kit_products` | Product catalog (UUIDv7 PK) |
| `phoenix_kit_categories` | Hierarchical categories |
| `phoenix_kit_carts` | Shopping carts (guest + user) |
| `phoenix_kit_cart_items` | Cart line items with price snapshots |
| `phoenix_kit_shipping_methods` | Shipping options and constraints |
| `phoenix_kit_shop_configs` | Key-value shop configuration |
| `phoenix_kit_import_configs` | CSV import profiles |
| `phoenix_kit_import_logs` | Import job tracking and progress |

### Routes

**Public:**

| Path | Description |
|------|-------------|
| `/shop` | Product catalog with filtering |
| `/shop/category/:slug` | Category browse |
| `/shop/product/:slug` | Product detail page |
| `/cart` | Shopping cart |
| `/checkout` | Checkout flow |
| `/checkout/complete/:uuid` | Order confirmation |

**Admin:**

| Path | Description |
|------|-------------|
| `/admin/shop` | Dashboard & statistics |
| `/admin/shop/products` | Product management |
| `/admin/shop/categories` | Category management |
| `/admin/shop/shipping` | Shipping methods |
| `/admin/shop/carts` | Cart analytics |
| `/admin/shop/imports` | CSV import jobs |
| `/admin/shop/shopify-sync` | Shopify catalog sync |
| `/admin/shop/settings` | Shop configuration |
| `/admin/shop/settings/options` | Global option schemas |
| `/admin/shop/settings/import-configs` | Import profiles |

All public routes support localized variants via `public_live_locale_routes/0`.

## Development

```bash
mix deps.get       # Install dependencies
mix test           # Run tests
mix format         # Format code
mix credo --strict # Static analysis (strict mode)
mix dialyzer       # Type checking
mix docs           # Generate documentation
mix precommit      # Compile + format + credo + dialyzer
mix quality        # Format + credo + dialyzer
```

### Testing

The suite has unit tests (always run, no DB) and integration tests
(tagged `:integration`, auto-excluded when PostgreSQL is unavailable).
Run the integration tests after a one-off database create:

```bash
createdb phoenix_kit_ecommerce_test   # one-time setup
mix test                              # boots Test.Repo, runs core migrations, sandboxes per test
```

Case templates live in `test/support/`: `PhoenixKitEcommerce.DataCase`
(context/schema tests) and `PhoenixKitEcommerce.LiveCase` (LiveView
tests). The test repo runs core's versioned migrations via
`PhoenixKit.Migration.ensure_current/2` — no module-owned DDL.

## Troubleshooting

### Shop not appearing in admin
- Verify the module is enabled in Admin -> Modules
- Ensure the module is listed as a dependency in the parent app's `mix.exs`
- Check that `enabled?/0` is not returning `false` (requires database access)

### CSV imports not processing
- Ensure Oban is configured with `shop_import` and `shop_images` queues
- Check Oban dashboard for failed jobs
- Review import logs at `/admin/shop/imports` for error details

### Guest cart not persisting
- Verify `ShopSession` plug is included in your router pipeline
- Check that session cookies are configured correctly

### Images not downloading during import
- Ensure `shop_images` Oban queue is running
- Check that `download_images` is enabled in the import config
- Review image migration worker logs for HTTP errors

## License

MIT -- see [LICENSE](LICENSE) for details.
