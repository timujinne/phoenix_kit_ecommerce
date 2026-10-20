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
- **Public read API** — full-text product search (PostgreSQL, per language, typo-tolerant with `pg_trgm`), product cards, category tree and similar products for AI agents and scripts, as REST and MCP tools of PhoenixKit core (needs a core with the machine API; off until `api_public_enabled` is on)
- **Public cart API** — seven anonymous *write* tools that let a buyer's AI agent fill a cart and hand it to the site's checkout through a one-time link; no order, payment or address passes through the API (same switch, `api_public_enabled`)
- **Auto-discovery** — implements `PhoenixKit.Module` behaviour; PhoenixKit finds it at startup with zero config

## Installation

Add `phoenix_kit_ecommerce` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:phoenix_kit_ecommerce, "~> 0.5.0"}
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
     queues: [shop_imports: 5, shop_search: 2]
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

`selected_specs` is `%{option_key => value}`. For a product of the shop's own
tables the value is the option value as typed. For a catalogue-backed product
it is the attribute-set value's **key** (its slug), the same in every
language — `product.metadata["_option_values"]` lists the keys on offer and
`PhoenixKitEcommerce.SelectedSpecs.value_label/3` gives the label to show.
A cart line stores the key and a snapshot of that label; read a line's
selection with `PhoenixKitEcommerce.SelectedSpecs.labels/1`.

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

### Public API: search and product tools

With PhoenixKit core's machine API switched on (`api_public_enabled`), this module offers five read-only
search and product tools to anonymous callers (the cart tools, which write, are described below), over REST (`POST /api/public/v1/<tool>`) and MCP (`/mcp/public`):

| Tool | What it does |
|---|---|
| `shop.search_products` | Search by words, category branch, price, options, vendor and sale status; facets; exact count; cursor paging |
| `shop.search_products_batch` | Up to 20 searches in one call (one rate-limit unit each) |
| `shop.get_products` | Full cards for up to 50 ids (one rate-limit unit per ten ids); a discontinued product is a three-field stub; hidden or unknown ids are `not_found` |
| `shop.list_categories` | The active categories as a tree with product counts |
| `shop.similar_products` | Products in the same category or sharing an option value or tag |

```bash
curl -s -X POST https://shop.example.com/api/public/v1/shop.search_products \
  -H 'content-type: application/json' \
  -d '{"q": "ceramic vase", "price_max": 30, "sort": "price_asc", "limit": 5}'
```

What a caller sees is decided by one rule (`PhoenixKitEcommerce.API.Visibility`): draft, inactive,
deleted products and products in hidden or deleted categories are never shown (every product and
card is read live); discontinued or archived ones appear only as a stub in `shop.get_products`.
The counts and facets come from the search index and can lag a change by the reindex delay (a few
seconds and the queue, or until the nightly rebuild if the job fails), so for that time they can
include a product the items no longer show, and a query only that product matches answers `count: 1`
with no items. The category counts of `shop.list_categories` come from the index too, and a
sub-category under an unlisted middle category counts towards its listed ancestor's search but not
towards that ancestor's `total_count`. Enabling the shop queues a rebuild; enabling a language does not, so call `PhoenixKitEcommerce.Search.Jobs.enqueue_rebuild/0` or wait for the nightly one (03:40). Prices come in the language and
currency of the domain the request came to (a host maps domains with
`config :phoenix_kit, :api_request_context, {Mod, :fun}`); `language` and `currency` inputs override.

Search reads `phoenix_kit_shop_search_index`, kept fresh by `PhoenixKitEcommerce.Search.Subscriber`
(catalogue and shop PubSub events, through Oban jobs on the `shop_search` queue) and rebuilt every
night (`oban_crons/0`; `mix phoenix_kit.update` adds the queue and the cron entry to the host's
Oban config). Without the `pg_trgm` extension search still works and only skips the typo fallback.

`/api/shop/v1` and `/mcp/shop` were the paths of these tools before core made its public API
module-neutral. They are still served, as deprecated aliases of `/api/public/v1` and `/mcp/public`
(every answer on them carries a `Deprecation` header and a `Link` to the canonical path), until core
3.0.0 removes them. Point clients at the canonical paths. The tool names (`shop.*`) do not change.

### Public API: cart tools

The same switch (`api_public_enabled`) also turns on seven anonymous **write** tools. They create
cart rows, can send the owner a notification and mint checkout links, so decide on purpose whether
to switch the public API on. They never take an order, a payment or an address: the buyer finishes
on the site's own checkout.

| Tool | What it does |
|---|---|
| `shop.create_cart` | Returns a cart token; writes nothing |
| `shop.get_cart` | The cart: lines, totals, shipping choice and a `revision` |
| `shop.set_cart_items` | Sets lines to final quantities in one transaction, per-line errors, `expected_revision`, `dry_run` |
| `shop.clear_cart` | Empties the cart; asks for confirmation when it has lines (offered only when core carries the confirmation gate) |
| `shop.get_shipping_options` | Shipping methods for a country |
| `shop.set_shipping` | Chooses one of them |
| `shop.get_checkout_link` | A one-time link to the checkout hand-off page |

- **Token and row.** A cart token is 32 random bytes plus a short MAC, signed with the host's
  `secret_key_base` and never stored. It is this module's *client token*: the cart tools declare
  `cart_token` as their `client_token`, so core hashes it into the caller's identity for the rate
  limit, the idempotency scope and the confirmation of `shop.clear_cart`, and redacts it from stored
  replays; `shop.get_checkout_link` declares its `url` (the claim link) as a credential. The cart row
  is created by the first write only, under core's shared new-rows limits, per client network and
  global (`session_id` starts with `api:`). Against a core older than the module-neutral API the
  tools declare neither field and that core finds the token by its name.
- **Hand-off.** The link opens `/checkout/claim/:token` (no locale prefix). A GET shows the cart and
  consumes nothing; the buyer's confirmation (a CSRF `POST`) consumes it once and moves the cart to
  the buyer's browser session, replaces the cart already there, or merges into it. The old token then
  answers `cart_locked`. The claim page marks itself as not to be tracked by the web analytics module
  (`PhoenixKitWebAnalytics.Plug.skip/1`, when the installed version has it), and the V5 migration step
  also adds `/checkout/claim/*` to `web_analytics_exclude_paths` if the analytics tables existed when
  it ran; if analytics was installed later, add that pattern yourself. **The claim token is part of
  the request path, and this module cannot keep it out of your logs:** the path is written before
  any controller runs, by the endpoint's request logger (`Plug.Telemetry`, the `GET /checkout/claim/...`
  line) and by core's `RequestTimer` (a `START` line at debug and an `END` line at info, both with
  the path; it is part of the `:phoenix_kit_auto_setup` pipeline the claim route goes through). The
  `Parameters:` line is already `[FILTERED]` by core's `filter_parameters`, which covers parameters
  and not the path. Anyone who can read the log can open a live link before the buyer, for up to
  `api_checkout_claim_ttl_minutes`, so drop these lines in the host with a primary `:logger` filter,
  which covers all three at once:

  ```elixir
  defmodule MyApp.ClaimLogFilter do
    @moduledoc false
    def filter(%{msg: {:string, text}}, _extra) do
      if text |> IO.chardata_to_string() |> String.contains?("/checkout/claim/"),
        do: :stop,
        else: :ignore
    end

    def filter(_event, _extra), do: :ignore
  end

  # In MyApp.Application.start/2, before the supervisor starts:
  :logger.add_primary_filter(:claim_token, {&MyApp.ClaimLogFilter.filter/2, []})
  ```

  Keep the link lifetime short (the default is 30 minutes). A fix at the source belongs to core
  (skipping the path in `RequestTimer`) and to the host's endpoint (`Plug.Telemetry`'s `log:` option
  can return `false` for these paths).
- **Errors.** `PhoenixKitEcommerce.api_problems/0` declares the codes `cart_not_found` (404),
  `cart_locked` (409), `unsupported_source` (422) and `insufficient_stock` (422), with the advice
  MCP gives an agent after each; they were core's own before modules could declare codes.
- **Notifications.** An API write sends at most one message ("via assistant") through the two
  existing cart notification actions and toggles, capped per cart and globally per hour.
- **Settings** (E-Commerce settings page, "Assistant carts" card): `api_cart_idle_days` (7),
  `api_checkout_claim_ttl_minutes` (30), `api_signal_per_cart_per_hour` (3),
  `api_signal_global_per_hour` (30).
- **Cron.** `oban_crons/0` adds an hourly sweep of idle `api:` carts, a daily deletion of
  abandoned `api:` carts (with their lines) and a daily prune of used or expired claims (seven days
  after a hand-off the old token stops answering `cart_locked`: it reads as an empty open cart, or
  `cart_not_found` if the cart was merged); general cart expiry is unchanged. Run `mix phoenix_kit.update`: it applies migration V5 (`phoenix_kit_shop_cart_claims`)
  and writes the cron entries into the host's Oban crontab.

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

### Admin API tools

On a `phoenix_kit` core that ships the admin API (the tool registry), this
module offers five admin tools over REST, and over MCP where the core also
provides it, for an accounting system, a script or an AI agent. Shopify is not
needed: on a shop without it, the API is how an outside system feeds the
product list.

| Tool | Does | Scope |
|---|---|---|
| `ecommerce.get_prices` | prices, option prices, visibility | `ecommerce.prices:read` |
| `ecommerce.set_prices` | price, compare-at price, option prices | `ecommerce.prices:write` |
| `ecommerce.set_availability` | visibility, made to order | `ecommerce.availability:write` |
| `ecommerce.attach_images` | pictures by URL, at most 20 per call | `ecommerce.images:write` |
| `ecommerce.detach_images` | takes pictures out of a gallery, by file id or by the URL they came from | `ecommerce.images:write` |

The key owner needs `shop` to read prices, and both `shop.manage_catalog`
and `catalogue` to use a write tool, including a dry run. Catalogue access
is checked against the owner's current roles on every call; a confirmation
does not preserve a permission that has since been revoked.

They work on the catalogue product source only; on the legacy source (or with
a `phoenix_kit_catalogue` that predates the admin API) they answer
`unsupported_source`. A price move of more than `api_confirm_price_change_pct`
percent (an option price is measured against the product's current price;
default 30, set on the E-Commerce settings page by a user who also
holds core's `api` permission) is held for confirmation first, and so is any
batch larger than core's `api_confirm_batch_over`. The price threshold checks
the base price and each option modifier independently; their changes are not
combined into a customer selection's total. `detach_images` is held when
a row would leave a product with no picture at all (the main picture alone is
not held: replacing it is an attach followed by a detach); a picture shared
with another product stays with it, and one nothing else holds goes to the
media trash, not out of Storage; at most 50 pictures per product and 500 per
call. A dry run (`dry_run: true`) of a write tool answers `requires_confirmation`
(whether the real call would be held, by the tool's rule if it has one, or the
batch size) and `confirmation_rules` (the thresholds that applied); it never
creates a confirmation code. Keys, scopes and the switch are on core's
Settings → API page.

A `validation_failed` answer with `context.reason` `database_error`,
`storage_error` or `unexpected` is not a problem with the request and is worth
retrying; any other `validation_failed` should be fixed first.

The module also offers the `shop_order` kind to Warehouse, so a shop order can
be the basis of a goods issue. This needs the Warehouse module 0.5.3 or later,
the first release where modules can declare source kinds.

### Shopify Sync

One-way, human-confirmed sync that keeps existing products current
against a connected Shopify store — **not** a product importer. It
updates products the shop already has (matched to Shopify by
handle/slug); a Shopify product with no local match is skipped. To
bring a new product in from Shopify, use [CSV Import](#csv-import)
first, then this to keep it current.

Setup (all through the UI, no environment variables). Shopify sync is
off by default: first turn on **Enable Shopify sync** in Shop → Settings.
Until then the Shopify option is not offered under Settings →
Integrations, and the sync page and its sidebar entry are hidden.

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
   Differences are grouped into one collapsed section per field —
   Prices, Titles, Descriptions, HTML texts, Tags, Statuses, Vendors —
   each showing how many products differ on it. Expand a section to
   list them, 25 rows to a page; expand a row for a word-level diff of
   what actually changed inside the text.

   Apply at whichever scope fits: a single field of one product, every
   product in one section, a checkbox selection within the current
   page, or everything at once. Each is confirmed in a dialog that
   states the count and the field before anything is written.

   **Extreme price changes (a swing beyond 3x) are excluded from every
   bulk scope** and must be applied per row, where the product and its
   badge are in front of you. Nothing is written without an explicit
   confirmation.

Fields compared: title, description (derived from Shopify's `Body
(HTML)`), the HTML body itself, vendor, tags, status, and price (the
lowest current variant price). Not synced: new products,
categories/collections, images, variants/options, and inventory
quantity.

**Base currency first.** While the shop has no base currency, the sync
writes no price and adds no product: an amount stored with no currency
would be read as whatever the base later becomes. The sync page shows a
banner linking to the currency settings and disables the price actions;
titles, descriptions, tags, images and collections still sync. To find
prices written before a base existed (read-only — it stamps nothing):

```bash
mix phoenix_kit_ecommerce.list_unstamped_prices
```

**One background sync at a time.** The images, variants and collections
syncs share one queue slot: starting one while another is queued or
running is refused and the page names the one in progress.

```elixir
alias PhoenixKitEcommerce.Shopify.Sync

# integration_uuid comes from PhoenixKit.Integrations.list_connections("shopify")
{:ok,
 %{
   changes: changes,
   source: source,
   fallback_reason: reason,
   total_shopify_products: total_shopify_products,
   matched_local_products: matched_local_products
 }} = Sync.check(integration_uuid)

# `source` is :admin (the full diff above) or :storefront — a price-only
# fallback used when the Admin API token was rejected, with `reason`
# saying why (e.g. :unauthorized). Always check `source` before treating
# `changes` as a complete diff.
#
# `total_shopify_products` (every product Source.fetch/2 returned) and
# `matched_local_products` (how many of those matched a local product by
# handle, via ProductDiff.matched_count/3) are what "how much of the
# Shopify catalog can this sync even see" needs — only comparable to
# each other when `source == :admin`; the storefront fallback only ever
# sees products published to the Online Store, a narrower population.

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

Keys are `shop_`-prefixed, except `api_confirm_price_change_pct`. (Earlier revisions of this table listed
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
| `api_confirm_price_change_pct` | integer | `30` | Admin API: a price move above this percent needs a confirmation. Not `shop_`-prefixed |

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

### SEO tags in the host's root layout

The catalog, category and product pages assign three values for the host's
root layout to put in `<head>`:

- `og` — `%{type, title, description, image, url, locale}` (keys present when known)
- `canonical_url` — the page's absolute canonical URL (the same value as `og.url`)
- `hreflang_links` — `[%{code: "en", url: "https://…"}, …]`, one per language
  the page exists in; empty when there is only one

PhoenixKit's own root layout reads `og` only: it emits the Open Graph tags and
a canonical link from `og.url`, and no `hreflang` alternates. A host that
wants language alternates — or that uses its own root layout — renders them
itself:

```heex
<link :if={assigns[:canonical_url]} rel="canonical" href={assigns[:canonical_url]} />
<link
  :for={link <- assigns[:hreflang_links] || []}
  rel="alternate"
  hreflang={link.code}
  href={link.url}
/>
```

Render the canonical link once: skip the first line under PhoenixKit's root
layout, which already emits it.

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
    ├── shopify/
    │   ├── provider.ex            # PhoenixKit.Integrations provider definition
    │   ├── admin_client.ex        # Shopify Admin API client
    │   ├── storefront_client.ex   # Public storefront JSON client (price-only fallback)
    │   ├── source.ex              # Admin-primary / storefront-fallback picker
    │   ├── product_diff.ex        # Local-vs-Shopify field diff, by handle
    │   ├── text_diff.ex           # Word-level diff for text fields
    │   └── sync.ex                # Orchestrates fetch, diff, and apply
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
        ├── shopify_sync.ex      # Admin: Shopify catalog sync
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
| `/checkout/claim/:token` | Hand-off page of the public cart API (GET shows, POST confirms; no locale prefix) |

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

**Customer account** (login required; declared by core's router integration,
not by this package's route module):

| Path | Description |
|------|-------------|
| `/dashboard/orders` | The customer's orders (`PhoenixKitEcommerce.Web.UserOrders`) |
| `/dashboard/orders/:uuid` | One order (`PhoenixKitEcommerce.Web.UserOrderDetails`) |

All public routes support localized variants via `public_live_locale_routes/0`.

### Deprecated: the `PhoenixKit.Modules.Shop` namespace

The names this package had before it was extracted from core still compile,
and every one is deprecated: calling one prints a compiler warning naming
its replacement. They are removed in the release after this one.

| Deprecated | Use instead |
|------------|-------------|
| `PhoenixKit.Modules.Shop.<function>` | `PhoenixKitEcommerce.<function>` (same name and arguments) |
| `PhoenixKit.Modules.Shop.Cart` | `PhoenixKitEcommerce.Cart` |
| `PhoenixKit.Modules.Shop.Web.Routes` | `PhoenixKitEcommerce.Web.Routes` |
| `PhoenixKit.Modules.Shop.Web.Plugs.ShopSession` | `PhoenixKitEcommerce.Web.Plugs.ShopSession` |
| `PhoenixKit.Modules.Shop.Web.UserOrders` | `PhoenixKitEcommerce.Web.UserOrders` |
| `PhoenixKit.Modules.Shop.Web.UserOrderDetails` | `PhoenixKitEcommerce.Web.UserOrderDetails` |

A host router that declares the customer order pages itself switches one
line each — `live "/dashboard/orders", PhoenixKitEcommerce.Web.UserOrders, :index`
— or drops both lines: core declares the two routes whenever this package
is installed.

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
- Ensure Oban is configured with the `shop_imports` queue (every shop worker — CSV import, image migration, Shopify media sync — runs on it)
- Check Oban dashboard for failed jobs
- Review import logs at `/admin/shop/imports` for error details

### Search finds nothing
- Ensure Oban is configured with the `shop_search` queue (`queues: [shop_imports: 5, shop_search: 2]`). Without it the reindex and rebuild jobs stay `available` and the search index stays empty
- An empty index is rebuilt by a job enqueued 30 seconds after boot, and every night; check the Oban dashboard for failed `SearchRebuildWorker` jobs
- Typos are found only when the `pg_trgm` extension is installed and its operators are on the connection's search path; search works without it and logs a warning at boot

### Guest cart not persisting
- Verify `ShopSession` plug is included in your router pipeline
- Check that session cookies are configured correctly

### Images not downloading during import
- Ensure the `shop_imports` Oban queue is running
- Check that `download_images` is enabled in the import config
- Review image migration worker logs for HTTP errors

## License

MIT -- see [LICENSE](LICENSE) for details.
