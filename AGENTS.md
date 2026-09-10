# AGENTS.md

Guidance for AI agents working on `phoenix_kit_ecommerce`.

## Overview

E-commerce for PhoenixKit: products, categories, guest and authenticated
carts, checkout, shipping methods, CSV and Shopify imports. It is a library
plugged into a host Phoenix app, not a standalone app. Content is
multi-language, product options carry fixed and percentage price modifiers,
and checkout hands off to `phoenix_kit_billing` for orders and payment. It
ships admin LiveViews for the whole workflow plus the public storefront
pages.

- **Depends on:** `phoenix_kit` `~> 2.15` (Hex), `phoenix_kit_billing`
  `~> 0.11` (hard), `phoenix_kit_ai` `~> 0.18` (optional — only the
  AI-translate UI and adapter use it and both compile out when it is
  absent). Also `phoenix`, `phoenix_live_view ~> 1.1`, `ecto_sql ~> 3.12`,
  `oban ~> 2.20`, `uuidv7`, `nimble_csv`, `req`, `jason`, `gettext ~> 1.0`.
  There is deliberately **no** dep on `phoenix_kit_catalogue`: the catalogue
  extension slot is reached duck-typed, so nothing here calls
  `PhoenixKitCatalogue` directly.
- **Consumed by:** no sibling declares a dependency on this module. Core
  reaches the old `PhoenixKit.Modules.Shop.*` namespace through the
  transitional shims in `lib/phoenix_kit_ecommerce/compat/`, and
  `phoenix_kit_catalogue` discovers `catalogue_extensions/0` by duck typing.
- **Admin surface:** tab `E-Commerce` at `/admin/shop`, subtabs Dashboard,
  Products, Categories, Shipping, Carts, CSV Import and Shopify Sync; a
  settings subtab at `/admin/shop/settings`; user-dashboard tabs Shop
  (`/shop`) and My Cart (`/cart`). Public storefront routes: `/shop`,
  `/shop/category/:slug`, `/shop/product/:slug`, `/cart`, `/checkout`,
  `/checkout/complete/:uuid`.
- **Module key** `"shop"`; settings prefix `shop_`.

## What this module does NOT do

- **No payment logic.** Checkout converts a cart to an order through
  `PhoenixKitBilling`; tax configuration (`billing_tax_enabled`,
  `billing_default_tax_rate`) is read from billing, never redefined here.
- **No module-owned top-level layout.** The storefront is the host's
  surface and renders inside the host's configured `layouts_module`.
- **No scope on the public context API.** `PhoenixKitEcommerce.create_product/1`
  and friends (including the `compat/` re-exports) stay scope-less: hosts
  call them from their own controllers, workers and scripts, and the library
  cannot know whose authority those run under. Sub-permissions are checked in
  the bundled admin UI instead.
- **No JavaScript.** There is no `js_sources/0` and no hook of its own.
- **No table creation of its own beyond adoption.** All ten shop tables are
  core baseline tables; this module's chain adopts and then owns their
  evolution.
- **No catalogue version floor.** No released `phoenix_kit_catalogue` ships
  the extension slot the integration targets, so a `~>` floor could only be
  inaccurate.

## Commands

```bash
mix deps.get
createdb phoenix_kit_ecommerce_test   # once; DB-backed tests are tagged :integration and auto-skip without it
mix test
mix precommit                # compile --warnings-as-errors + format + credo --strict + dialyzer; run before every commit
```

`phoenix_kit*` deps resolve from Hex. To run against a local checkout, export
`<APP>_PATH` (the dep's app name upper-cased plus `_PATH`); `pk_dep/3` in
`mix.exs` swaps the Hex pin for a `path:` dep at resolve time. Unset means the
Hex pin, so `mix hex.publish` is unaffected. Run `mix deps.get` with the var
exported before the first `mix test` (a stale lock aborts on the optional
`igniter` dep), and never commit a hand-edited `path:` tuple.

```bash
PHOENIX_KIT_PATH=../phoenix_kit mix deps.get && PHOENIX_KIT_PATH=../phoenix_kit mix test
PHOENIX_KIT_BILLING_PATH=../phoenix_kit_billing mix test
PHOENIX_KIT_AI_PATH=../phoenix_kit_ai mix test
```

Repo-local aliases:

- `mix quality` — `format` + `credo --strict` + `dialyzer` (applies formatting).
- `mix quality.ci` — `format --check-formatted` + `credo --strict` + `dialyzer`: it CHECKS formatting rather than applying it, so run `mix format` first.
- `mix test.reset` — drops the test database and recreates it.
- `mix test.setup` — `ecto.create` on the test repo, the alias equivalent of `createdb`.

## Conventions

- **Module key** is `"shop"` in every callback. Tab ids are prefixed
  `:admin_shop` (admin tabs) and `:admin_settings_shop` (settings tab); URL
  segments use hyphens, never underscores (`/admin/shop/shopify-sync`,
  `/admin/shop/settings/import-configs`).
- **Never hardcode a URL or path.** Build links with
  `PhoenixKit.Utils.Routes.path/1`, including cross-module links.
- **Routing.** `route_module/0` returns `PhoenixKitEcommerce.Web.Routes`,
  which emits quoted `live` declarations: `public_live_routes/0` and
  `public_live_locale_routes/0` for the storefront (spliced into core's
  unified `:phoenix_kit_public` live_session), `admin_routes/0` and
  `admin_locale_routes/0` for the admin pages. Admin tabs supply the
  navigation; never hand-register these routes in a host router.
- **LiveView macro** is this module's own: `use PhoenixKitEcommerce.Web,
  :live_view` (and `:live_component`), defined in `web/shop_web.ex`. It wraps
  `use Phoenix.LiveView`, injects `PhoenixKitEcommerce.Gettext` as the Gettext
  backend, and imports core's `PhoenixKitWeb.Components.Core.*` components —
  use those before hand-rolling markup. A component outside `web/` that uses
  plain `use Phoenix.Component` inherits none of it and must declare the
  Gettext backend itself.
- **Layouts.** Every public storefront page — catalog, category, product,
  cart, checkout, confirmation — renders through core's
  `LayoutWrapper.app_layout`, i.e. the HOST application's configured
  `layouts_module`, for guests and logged-in visitors alike.
  `ShopLayouts.shop_layout/1` is the single wrapper. The in-page
  category/filter sidebar renders in the page templates for everyone. Admin
  LiveViews do not wrap themselves in a layout; core's admin shell supplies
  it.
- **Gettext** is this module's own backend (`PhoenixKitEcommerce.Gettext`,
  catalogues under `priv/gettext/{en,et,ru,de,fr}`). A `gettext("…")` added
  anywhere under `web/` lands in THIS catalogue, so it needs
  `mix gettext.extract && mix gettext.merge priv/gettext --no-fuzzy` here,
  not in core. Merge with `--no-fuzzy`: fuzzy entries are live at runtime, so
  a plain merge after an extraction gap ships guessed translations.
- **Every public LiveView calls `Helpers.put_content_locale/1` (or
  `put_content_locale_from/1`) in its `mount/3`.** Core writes a dialect
  (`ru-RU`) into the process locale and this module's catalogues are plain
  codes; without the resolve step every lookup misses and the page renders
  English beside translated siblings.
- **Never wrap in `gettext`:** `push_event` names, URL paths, route segments,
  setting keys. Translating one breaks at runtime in every non-English locale.
- **JS hooks:** none. If one is ever needed, ship it as a prebuilt bundle
  declared by `js_sources/0` under a namespaced global — never registered from
  an inline `<script>`, which morphdom does not execute on LiveView
  navigation, so the hook vanishes on the first live nav.
- **CSS:** `css_sources/0` returns `[:phoenix_kit_ecommerce]` so core's CSS
  compiler adds the `@source` directive to the host's `app.css`. Without it
  Tailwind purges every class used only by this module's templates, and the
  compiler only warns when the TOTAL source list is empty, so any other
  installed module masks the absence.
- **`enabled?/0` rescues and returns `false`** — the database may not be
  available when it is asked.
- **Settings are read through their wrapper, never directly:**
  `PhoenixKitEcommerce.Policy` (security policy),
  `PhoenixKitEcommerce.Vocabulary` (catalog vocabulary),
  `PhoenixKitEcommerce.NamePrefix` (storefront name-prefix stripping),
  `PhoenixKitEcommerce` itself (`shipping_skip_mode/0`,
  `shipping_selection_position/0`, `notify_event?/1`,
  `enforce_product_currency?/0`). The wrapper is the
  single source of truth for the default, so the admin UI and the enforcement
  point cannot disagree; every policy reader fails *closed* on a
  settings-layer error and tolerates a malformed stored value by falling back
  to the safe default rather than raising.
- **"Price on request" is snapshotted onto the cart line and the order line,
  never read live from the product.** A line that lost the flag formats its
  stored `unit_price` (typically `0`) and renders "0.00" where the customer
  agreed to "price on request".
- **Money is `Decimal`.** Never floats for currency.
- **Async work is Oban.** CSV import and image migration run as workers
  (queues `shop_import`, `shop_images`); never spawn a bare `Task`.
- **Schemas:** UUIDv7 primary keys (`@primary_key {:uuid, UUIDv7,
  autogenerate: true}`, `uuid_generate_v7()` in DDL — never
  `gen_random_uuid()`), and every table-backed schema declares
  `use PhoenixKit.SchemaPrefix` so its queries target the schema core's
  migrations installed into. A conformance test enforces the second.
- **Authorization pattern.** Core's route gate admits the base `"shop"` key;
  every mutating admin event handler re-checks its specific capability
  through `Web.Authz` (fail-closed on a missing scope), and pages showing
  customer data check on mount. The public `handle_event/3` clause matches the
  event name and delegates through `Authz.authorize/3` to a private
  `gated_event/3` clause holding the original body — keeping the body in its
  own clause is what stops the wrapper adding a nesting level to 47 handlers.
  Workers are authorized at ENQUEUE by the LiveView that starts them.
- **Activity logging happens at the LiveView layer**, on the `{:ok, _}` branch
  of a successful mutation, through `PhoenixKitEcommerce.Activity` — never
  inside context functions, which stay pure and keep stable signatures. The
  wrapper centralizes the `Code.ensure_loaded?/1` guard, the rescue (logging
  failures never crash the caller) and the default metadata (`module: "shop"`,
  `actor_role`); the actor comes from `socket.assigns[:phoenix_kit_current_scope]`.
  Rows carry no PII.
- **The core pin floor is two-segment (`~> 2.15`) on purpose.** The
  three-segment form (`~> 2.6.4`) expands to `< 2.7.0` and breaks CONSUMERS —
  a host on a newer core minor gets an unsolvable dependency set — while
  nothing in this repo's own run notices, which is why a test guards it.
  Raising the floor is fine and expected; raise it in `mix.exs` and in
  `test/core_pin_conformance_test.exs` together whenever a newly-adopted core
  or billing API needs it.
- **Assigns available in admin LiveViews:** `@phoenix_kit_current_scope`,
  `@current_locale`, `@url_path`.

### Landmines

- **The test harness must apply billing's migration chain, not just core's.**
  This module reads and writes billing's schemas directly, and billing owns
  `phoenix_kit_currencies` from its own V2 on, so a test database built from
  core's baseline alone is missing columns billing's `Currency` schema selects.
  The symptom is an `undefined_column` on `rounding_rule` raised from a
  currency read, hundreds of tests deep and nowhere near anything about
  currencies. `test_helper.exs` runs core's chain, then billing's, then this
  module's, in that order.
- **Raising a dependency requirement means updating `mix.lock` in the same
  change.** A requirement bumped without it leaves the repo refusing to
  compile ("lock mismatch: the dependency is out of date") until someone runs
  `mix deps.get`, and the failure names the dependency rather than the commit
  that raised the floor.
- A new public page that omits `put_content_locale/1` in `mount/3` renders
  fully English while its siblings translate — the page looks correct in
  tests and inert in production. Call it, or inherit it via
  `put_content_locale_from/1`.
- Reading `price_on_request` live from the product instead of the stored line
  turns a committed "price on request" order into a "0.00" order; the product
  row is `ON DELETE SET NULL`, so deleting a product is enough to trigger it.
- `compat/shop.ex` redefines `PhoenixKit.Modules.Shop`, which is why
  `elixirc_options: [ignore_module_conflict: true]` is set. That suppression
  also hides a genuine redefinition warning, and a new public function without
  a delegate there fails only at core's call site — re-audit the delegate list
  whenever the public API changes.
- Under `shop_shipping_selection_position: "checkout"` the cart page renders
  **no** shipping section, so redirecting a shopper to `/cart` to "pick
  another method" is a closed loop with no way out. `CheckoutPage` re-enters
  its own `:shipping` step instead.
- Every statement in the migration chain must be idempotent: `test_helper.exs`
  executes `up_statements/1` directly (no `Ecto.Migration` runner), so a
  non-idempotent statement breaks every integration run against a re-used test
  database.

## Architecture

A library that registers itself with core through `use PhoenixKit.Module`;
core discovers it from `.beam` files at startup and generates routes at
compile time from `admin_tabs/0` / `route_module/0`. `settings_tabs/0` adds
the settings page, `user_dashboard_tabs/0` the user-facing entries,
`permission_metadata/0` the permission tree, `notification_types/0` the
notification tree, and `migration_module/0` the migration chain. Settings
persist through `PhoenixKit.Settings` (DB-backed in the host), never
application env. `required_modules/0` declares `"billing"`;
`required_integrations/0` and `integration_providers/0` declare the Shopify
provider.

```
lib/phoenix_kit_ecommerce.ex          # PhoenixKit.Module behaviour + the main context
lib/phoenix_kit_ecommerce/
├── schemas/          # Product, Category, Cart, CartItem, ShippingMethod,
│                     # ShopConfig, ImportConfig, ImportLog
├── options/          # option schema management, type system, metadata validation
├── import/           # CSV: format behaviour, detector, parser/validator/analyzer,
│                     # Shopify + Prom.ua + generic formats, transformer, filter
├── shopify/          # Shopify integration: provider, admin/storefront clients,
│                     # source, sync, product + text diffs
├── catalogue/        # duck-typed phoenix_kit_catalogue extension slot:
│                     # Extension, ItemCommerce, CategoryCommerce, ShopSections
├── compat/           # transitional PhoenixKit.Modules.Shop.* delegate shims
├── services/         # image download + batch image migration
├── workers/          # Oban: CSVImportWorker, ImageMigrationWorker
├── mix_tasks/        # install, deduplicate_products
├── web/              # LiveViews, components, plugs, routes, helpers, authz
├── activity.ex       # activity-log wrapper (module + actor metadata, never raises)
├── policy.ex         # secure-by-default admin policy settings
├── vocabulary.ex     # "products" / "services" / "mixed" storefront wording
├── price_display.ex  # units, "From", price on request
├── notifications.ex  # notification fan-out
├── errors.ex         # atom -> gettext-backed message dispatch
├── events.ex         # PubSub broadcasts
├── translations.ex   # multi-language content utilities
├── localized_slug.ex # slug projections
├── slug_resolver.ex  # multi-language slug lookup across products and categories
├── html_text.ex      # description sanitizing
├── ai_translatable.ex# duck-typed phoenix_kit_ai translation adapter
├── gettext.ex        # PhoenixKitEcommerce.Gettext backend
└── migrations.ex     # module-owned migration chain
```

### Schemas and tables

All use UUIDv7 primary keys.

| Schema | Table | Notes |
|---|---|---|
| `Product` | `phoenix_kit_shop_products` | physical/digital, multi-language title/slug/description, pricing, images, SEO, status `draft → active → archived` |
| `Category` | `phoenix_kit_shop_categories` | hierarchical via `parent_uuid`, multi-language, per-category `option_schema`, position ordering |
| `Cart` | `phoenix_kit_shop_carts` | guest (session-based, 30-day expiry) and user (persistent); status `active → converted \| merged \| abandoned \| expired` |
| `CartItem` | `phoenix_kit_shop_cart_items` | price snapshots, selected specs, weight |
| `ShippingMethod` | `phoenix_kit_shop_shipping_methods` | weight/price constraints, geographic restrictions, free-shipping thresholds, delivery estimates |
| `ShopConfig` | `phoenix_kit_shop_config` | JSONB key-value store; also carries the migration marker |
| `ImportConfig` | `phoenix_kit_shop_import_configs` | CSV import profiles: keyword filtering, category rules, option mappings |
| `ImportLog` | `phoenix_kit_shop_import_logs` | import run tracking: progress, row counts, errors |

Two further tables, `phoenix_kit_shop_product_slugs` and
`phoenix_kit_shop_category_slugs`, are slug projections maintained by
Postgres functions and triggers; they have no Ecto schema.

### Product options and pricing

Two levels: **global options** defined in `ShopConfig` and available to every
product, and **category options** defined per category via `option_schema`.
Option types are text, number, boolean, select and multiselect. Price
modifiers are fixed amounts or percentages.

### Imports

CSV formats are implementations of the `ImportFormat` behaviour — Shopify,
Prom.ua, and a generic configurable column mapping — with automatic format
detection, keyword filtering, category assignment rules and product upsert by
slug matching. The Shopify integration additionally syncs live through the
Admin and Storefront APIs.

### PubSub topics

Broadcast through `PhoenixKit.PubSub.Manager` (the HOST's PubSub), from
`PhoenixKitEcommerce.Events`.

| Topic | Carries |
|---|---|
| `shop:products` | product created/updated/deleted, bulk status changes |
| `shop:products:<product_uuid>` | one product's changes |
| `shop:categories` | category created/updated/deleted, bulk status/parent/delete |
| `shop:inventory` | inventory changes |
| per-user and per-session cart topics | cart sync for real-time storefront updates |

### Web layer

- **Public LiveViews:** ShopCatalog, CatalogCategory, CatalogProduct,
  CartPage, CheckoutPage, CheckoutComplete. `UserOrders` and
  `UserOrderDetails` also live here but this module registers no route for
  them; they are reached through the `compat/` namespace.
- **Admin LiveViews:** Dashboard, Products, ProductForm, ProductDetail,
  Categories, CategoryForm, ShippingMethods, ShippingMethodForm, Carts,
  Settings, OptionsSettings, Imports, ImportShow, ImportConfigs, ShopifySync,
  TestShop.
- **Components:** ShopLayouts, ShopCards, CatalogSidebar, FilterHelpers,
  TranslationTabs.
- **Plug:** `Plugs.ShopSession` mints and reads the signed `shop_session_id`
  cookie (30 days) plus the Phoenix session entry, so a guest keeps one cart
  across pages. A disabled shop does not MINT a new identity but still
  RECOGNISES an existing signed one — the order-confirmation page is
  deliberately reachable while the shop is disabled, because it is a receipt.

### Permissions

The `"shop"` key is admin-area READ access. Four sub-permissions carry the
capabilities (core enforces sub-implies-base):

| Key | Covers |
|-----|--------|
| `shop.manage_catalog` | products + categories (list, form and detail pages) |
| `shop.manage_carts` | the carts admin — **read included**, the rows carry customer contact details |
| `shop.manage_settings` | settings, security policy, product options, shipping methods |
| `shop.run_imports` | CSV imports, import configurations, Shopify sync |

⚠️ Core auto-grants a newly discovered sub-permission to the Admin system
role only. A CUSTOM role holding base `"shop"` keeps its reads but loses every
mutation until an operator re-grants — secure by default and deliberate, but a
breaking authorization change on upgrade.

### Notifications and the audit trail

`notification_types/0` declares four sub-types under `"shop"`: admin `orders`,
customer `order_confirmations`, `imports`, and `cart_activity`. They are
separate so an operator can mute the order firehose without silencing their
own receipts.

⚠️ **The audit action strings are deliberately DIFFERENT from the notify
action strings** (`shop.order_converted` vs `shop.order_placed`;
`shop.import_run_completed/failed` vs `shop.import_completed/failed`). Core's
`Activity.log/1` auto-derives notifications from registered actions, so
reusing a notify action in an audit row delivers a duplicate on top of the
explicit fan-out. A test pins this contract — keep it.

Recipients union permission holders with **Owner-role holders and `"*"`
superadmins**: neither has permission rows, so a key-only query misses the
primary operator of a default install.

### Settings keys

All stored via `PhoenixKit.Settings`. Keys are **`shop_`-prefixed**.

**Behaviour**

- `shop_enabled` — module master switch (default: `false`)
- `shop_inventory_tracking` — track product inventory (default: `true`)
- `shop_allow_price_override` — allow per-product price overrides (default: `false`)
- `shop_enforce_product_currency` — refuse, rather than warn, when a product's
  currency does not match the shop's (default: `false`). Read through
  `enforce_product_currency?/0`.

**Storefront display**

- `shop_name_prefixes` — comma-separated prefixes ("3D Printed"), empty by
  default (longest configured prefix wins on overlap). Read through
  `PhoenixKitEcommerce.NamePrefix`, never directly. Strips a matching
  prefix from a product/category name at DISPLAY time only — the stored
  name (and a cart/order line's snapshotted `product_title`/`"name"`) is
  never rewritten, so a re-sync from Shopify (which owns these names)
  can never be silently overwritten by, or diverge from, a cosmetic
  rename. Applied on every storefront page a shopper sees a name on,
  browse through order confirmation and their own order history alike
  (`Translations.get_display/3` for a live product/category read,
  `NamePrefix.strip/1` directly on a cart/order line's snapshot string).
  Admin edit pages and the Shopify diff/apply path always read the raw
  stored value.
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
  shopper there to "pick another method"; `CheckoutPage` re-enters its own
  `:shipping` step instead.

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
settings-layer error.

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
  cleanup to categories the import created; `"all_empty"` deletes *every*
  empty category, including deliberate placeholders.
- `shop_legacy_cookie_until` — ISO8601 cutoff after which pre-signing
  `shop_session_id` cookies stop being adopted. ⚠️ Unset means "still
  migrating"; this is the one key here where leaving the default forever is
  wrong, because nothing prunes carts so the window never self-closes.

**Consumed from billing** (owned by `phoenix_kit_billing`, read here)

- `billing_tax_enabled`, `billing_default_tax_rate`

## Database & migrations

Owns a versioned chain: `PhoenixKitEcommerce.Migrations` via
`migration_module/0`, marker `pke_schema:<N>` as a COMMENT ON
`phoenix_kit_shop_config`, currently V2. `mix phoenix_kit.update` applies it
in hosts (and `mix phoenix_kit.status` reports it); tests apply it by running
`up_statements/1` directly. A marker-less or foreign-comment table reads as
version 0 — the core-baseline shape from before the chain existed.

V1 is **adoptive**: all ten shop tables are core baseline tables that core
still creates, so V1 changes no shape — it stamps the marker and claims future
ownership. V2 is the chain's first deliberate divergence: it drops the
`DEFAULT 'USD'` core declares on the `currency` column of
`phoenix_kit_shop_carts`, `…_cart_items`, `…_products` and
`…_shipping_methods`, so an insert that names no currency stores NULL.
Existing rows are untouched.

Rules for the chain, all of which have been broken at least once:

1. **Never edit V1.** A shape change is a new version.
2. **`down/1` drops nothing.** It unstamps the marker and restores the V2
   column defaults; it never drops a table, function or trigger. The tables
   are core-created and rolling back this chain must not destroy data.
3. **Every statement is parameterized by the prefix.** A hardcoded `public.`
   aborts a prefixed install, or writes into a schema this module does not own.
4. **Object names mirror core's, including how core names them per schema.**
   Core embeds the schema name in exactly five shop index names under a
   non-public prefix — the `*_uuid_idx` on `phoenix_kit_shop_cart_items`,
   `…_carts`, `…_categories`, `…_products` and `…_shipping_methods` (core's
   `pn` helper; `__PK_NAME_EXEMPT__` in its expected-schema manifest). Every
   other index is named identically in every schema. A bare name for those
   five does not match core's index, so `CREATE … IF NOT EXISTS` silently
   builds a duplicate.

The chain is emitted as data (`up_statements/1`, `down_statements/2`) and
`test/phoenix_kit_ecommerce/migrations_test.exs` scans it without a database —
object counts, names, the prefix rules above, and that no statement can drop
or truncate. When adding a version, extend those scans; they are the only
check that runs, since the test repo deliberately applies core's DDL and this
chain, nothing else.

## Testing

Test database `phoenix_kit_ecommerce_test` (`createdb` it once). The suite is
two-tiered: unit tests (schemas, changesets, pure functions) always run, and
integration tests — tagged `:integration` by the case templates — are excluded
automatically when Postgres is unavailable, so `mix test` never hard-fails on
a fresh checkout.

`test/test_helper.exs` boots `PhoenixKitEcommerce.Test.Repo`, builds the
schema with `PhoenixKit.Migration.ensure_current/2` (the same call a host
makes in production), then executes this module's own chain on top via
`PhoenixKitEcommerce.Migrations.up_statements/1`, and puts the Ecto sandbox in
`:manual` mode. It also starts the services the context layer needs:
`PhoenixKit.PubSub.Manager`, `PhoenixKit.ModuleRegistry` (registered with this
module — without it every `Scope.can?/2` answers false and the authorization
tests would pass for the wrong reason), `PhoenixKit.Users.RateLimiter.Backend`,
and the test Endpoint. It forces core's URL prefix to `/`, so admin paths in
tests carry the default-locale prefix (`/en/admin/shop`).

Support modules under `test/support/` are loaded with explicit
`Code.require_file/2` — Elixir 1.19's `mix test` no longer auto-loads them at
test-helper time, so a new support file must be added to that list:

- `PhoenixKitEcommerce.DataCase` — context/schema tests: sandbox connection
  plus Ecto query/changeset helpers.
- `PhoenixKitEcommerce.LiveCase` — LiveView tests: the test endpoint/router
  and conn helpers on top of `DataCase`.
- `ActivityLogAssertions`, `NotificationAssertions`, `CheckoutFixtures`,
  `TestLayouts` (a host-consumer layout fixture), `Hooks`, `TestRepo`,
  `TestRouter`, `TestEndpoint`.

Postgres connection settings come from `PGUSER` (default `postgres`),
`PGPASSWORD`, `PGHOST`, `PGDATABASE`, `PGPOOL` and `MIX_TEST_PARTITION`. On a
machine whose Postgres has no `postgres` role, export `PGUSER` or integration
tests fail as pool timeouts that look like flakiness.

Three tag families are excluded when their prerequisite is missing, and start
running by themselves once the dep is upgraded: `:integration` (no database),
`:requires_phoenix_kit_i18n_api` (core without
`Dashboard.Tab.localized_label/1`), `:requires_core_transliteration` (core
without `Utils.Slug` transliteration).

Three conformance tests run without a database and guard cross-repo contracts:
`core_pin_conformance_test.exs` (the two-segment core floor),
`dependency_floor_test.exs` (the core migration version the floor promises),
and `schema_prefix_conformance_test.exs` (every table-backed schema uses
`PhoenixKit.SchemaPrefix`). Dialyzer suppressions live in
`.dialyzer_ignore.exs`.

## Feature notes

| Feature | Constraint that must hold | Where |
|---|---|---|
| Price display and storefront i18n | "Price on request" is snapshotted onto the cart line and the order line, never read live; every public LiveView calls `put_content_locale/1` in `mount/3`; `push_event` names, paths, route segments and setting keys are never wrapped in `gettext` | `dev_docs/guides/storefront.md` |
| Agentic Commerce / ACP | Assessed and deliberately not built: a bridge plugin, not code in this module, is the shape if it is ever built | `dev_docs/agentic_commerce_acp_research.md` |

## Versioning & releases

SemVer. The version is single-sourced in `mix.exs` (`@version`); `version/0`
reads it at compile time and the behaviour test asserts against
`Mix.Project.config()[:version]`, so nothing else needs bumping.

Release procedure (the steps the maintainer runs):

1. Bump `@version` in `mix.exs`; add a `CHANGELOG.md` entry headed `## x.y.z - YYYY-MM-DD`.
2. `mix precommit` clean.
3. Commit (`"Bump version to x.y.z"`) and push; verify the push landed.
4. `mix hex.publish`.
5. Tag, matching the form of the newest existing tag (`git tag --sort=-creatordate | head -1` shows it), and push the tag.
6. GitHub release via `gh release create` if the repo does those (`gh release list` shows whether it does).

Tags are immutable pointers: never tag before the commit is pushed and the
publish has succeeded.

## Pull requests & commits

- Commit messages start with an action verb (`Add`, `Update`, `Fix`, `Remove`, `Merge`). No AI attribution and no `Co-Authored-By` trailers.
- Version bumps and CHANGELOG entries land with the release commit on upstream, not in feature PRs.
- Review files live in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/{AGENT}_REVIEW.md`, one file per reviewing agent, never edited by another agent; `FOLLOW_UP.md` records how each finding was resolved. Severities: `BUG - CRITICAL/HIGH/MEDIUM`, `IMPROVEMENT - HIGH/MEDIUM`, `NITPICK`.

## TODOs

- **Remove the `compat/` namespace** (and `elixirc_options:
  [ignore_module_conflict: true]` in `mix.exs`) once core no longer references
  `PhoenixKit.Modules.Shop`.
- **Add a `phoenix_kit_catalogue` floor** once a released catalogue ships the
  `PhoenixKitCatalogue.Extension` slot the duck-typed integration targets.
- **Deprecate `phoenix_kit_shop_products` / `phoenix_kit_shop_categories` and
  the two slug projections** in favour of `phoenix_kit_catalogue` once the
  storefront switches — by a host-side `COMMENT ON TABLE … 'deprecated …'`,
  never a DROP, and not part of this chain.
