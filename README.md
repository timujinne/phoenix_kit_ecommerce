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
    {:phoenix_kit_ecommerce, "~> 0.1.0"}
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
alias PhoenixKit.Modules.Shop

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

# Convert to order (integrates with Billing module)
{:ok, order} = Shop.convert_cart_to_order(cart)
```

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
# Import products from CSV (Shopify, Prom.ua, or generic format)
{:ok, log} = Shop.start_import(file_path, import_config)

# Import runs asynchronously via Oban worker
# Track progress in real-time at /admin/shop/imports/:uuid
```

### Real-Time Events

Subscribe to shop events in your LiveViews:

```elixir
def mount(_params, _session, socket) do
  PhoenixKit.Modules.Shop.Events.subscribe_cart(user_uuid)
  {:ok, socket}
end

def handle_info({:cart_updated, cart}, socket) do
  {:noreply, assign(socket, :cart, cart)}
end
```

### Settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `tax_enabled` | boolean | `true` | Enable tax calculations |
| `tax_rate` | number | `20` | Tax rate percentage |
| `inventory_tracking` | boolean | `true` | Track product inventory |
| `allow_price_override` | boolean | `false` | Allow per-product price overrides |

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

## Architecture

```
lib/
├── mix/tasks/
│   ├── phoenix_kit_ecommerce.install.ex        # Install mix task
│   └── phoenix_kit_ecommerce.deduplicate_products.ex  # Dedup utility
└── phoenix_kit/modules/shop/
    ├── shop.ex                    # Main context (PhoenixKit.Module behaviour)
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
