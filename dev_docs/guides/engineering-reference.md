# Engineering reference

Detailed architecture, integration contracts, settings and test-harness notes
for `phoenix_kit_ecommerce`, moved from the root agent instructions.
Read [AGENTS.md](../../AGENTS.md) first; consult the relevant sections here
before changing a subsystem. Paths in this guide are relative to the repository
root unless stated otherwise. Keep this guide and the root instructions in sync
when a contract changes.

## Overview

E-commerce for PhoenixKit: products, categories, guest and authenticated
carts, checkout, shipping methods, CSV and Shopify imports. It is a library
plugged into a host Phoenix app, not a standalone app. Content is
multi-language, product options carry fixed and percentage price modifiers,
and checkout hands off to `phoenix_kit_billing` for orders and payment. It
ships admin LiveViews for the whole workflow plus the public storefront
pages.

- **Depends on:** `phoenix_kit` `>= 2.65.0 and < 4.0.0` (Hex — the release
  with the module callbacks `file_references/0` and `expected_schema/0`, above
  2.43.0's `ImageProcessor.limit_args/0` and `pinned_input/2`, which
  `ImageFingerprint` runs ImageMagick through, above 2.38.0's
  `PhoenixKitWeb.Actor` and `Activity.log/3`; the compound form
  keeps the ceiling open across later 2.x minors and core 3.x), `phoenix_kit_billing`
  `~> 0.25` (hard; 0.25 supplies durable order events for stock write-off and
  paid-order emails, above 0.20's
  `BillingProfileFields` and `BillingProfile.fields_changeset/3`, which
  checkout renders and validates over),
  `phoenix_kit_ai` `~> 0.27` (optional — the
  AI-translate UI, both translation adapters, the sweep worker and the
  translations page use it, and all of them compile out when it is absent;
  0.20 is the first engine that binds `{{SourceFields}}` and forwards
  `opts[:source_fields]`, `test/ai_pin_conformance_test.exs` guards it),
  `phoenix_kit_warehouse` `~> 0.7` (optional — only `StockTracking` calls
  it, for the switch, the stock of an item and the goods issue of a paid
  order),
  `phoenix_kit_web_analytics` (optional — the V5 migration step reads
  `PhoenixKitWebAnalytics.Config.default_exclusions/0`, to add the claim path
  to the analytics exclusion list, and `Web.ClaimController` calls
  `PhoenixKitWebAnalytics.Plug.skip/1` when it is loaded; the dialyzer ignore
  file names both).
  Also `phoenix`, `phoenix_live_view ~> 1.1`, `ecto_sql ~> 3.12`,
  `oban ~> 2.20`, `uuidv7`, `nimble_csv`, `req`, `jason`, `mdex`,
  `gettext ~> 1.0`. `phoenix_kit_catalogue` `~> 0.50` and
  `phoenix_kit_entities` `~> 0.7` are optional: a host on the Legacy product
  source needs neither. The extension slot is discovered duck-typed. The code
  that calls `PhoenixKitCatalogue.*` directly (the `ProductSource.Catalogue`
  adapter, `Catalogue.Writer`, the Shopify variants/collections/media sync)
  only runs behind `Code.ensure_loaded?/1` or `ProductSource.current/0`, with
  `@compile {:no_warn_undefined, …}` for hosts without it. Its
  `:catalogue`-tagged tests run whenever the package is loaded, which this
  repo's own build always has.
- **Consumed by:** no sibling declares a dependency on this module. Core
  calls `PhoenixKitEcommerce.*` by its own name (the route module, the
  session plug, the two customer order pages), and `phoenix_kit_catalogue`
  discovers `catalogue_extensions/0` by duck typing. Nothing in core or a
  sibling references the deprecated `PhoenixKit.Modules.Shop.*` names in
  `lib/phoenix_kit_ecommerce/compat/`; only a host written against them does.
- **Admin surface:** tab `E-Commerce` at `/admin/shop`, subtabs Dashboard,
  Products, Categories, Shipping, Carts, CSV Import, Shopify Sync (hidden
  while `shop_shopify_enabled` is off) and Translations
  (`/admin/shop/translations`, hidden until `shop_translations_enabled`); a
  settings subtab at `/admin/shop/settings`; user-dashboard tabs Shop
  (`/shop`) and My Cart (`/cart`, also in the avatar dropdown via the
  `Tab` option `user_menu: true`). Public storefront routes: `/shop`,
  `/shop/category/:slug`, `/shop/product/:slug`, `/cart`, `/checkout`,
  `/checkout/complete/:uuid`, and the assistant checkout hand-off
  `/checkout/claim/:token` (GET and POST, no locale prefix; a controller route
  emitted by `Web.Routes.generate/1`, not a LiveView).
- **The claim token is in the request path** (`GET /checkout/claim/<token>`).
  Three log lines carry the path before any controller runs: the endpoint's
  request logger (`Plug.Telemetry`, `GET /checkout/claim/...` at info) and core's
  `PhoenixKitWeb.Plugs.RequestTimer` (a `START` line at debug and an `END` line
  at info), which sits in the `:phoenix_kit_auto_setup` pipeline the claim route
  goes through. This module cannot keep them out (`filter_parameters` covers the
  `Parameters:` line only): the host needs a primary `:logger` filter that drops
  messages containing `/checkout/claim/` (the exact filter is in the README, in
  the hand-off paragraph of the assistant cart section), and core could skip the
  path in `RequestTimer`. The module's own
  guards: a claim is single-use, short-lived (`api_checkout_claim_ttl_minutes`)
  and only its digest is stored; the page sends `referrer-policy: no-referrer`,
  `cache-control: no-store` and `x-robots-tag: noindex, nofollow`, logs no
  token, and keeps itself out of web analytics twice over: the controller marks
  the request with `PhoenixKitWebAnalytics.Plug.skip/1` (an analytics version
  without it is simply not marked), and the V5 migration step appends
  `/checkout/claim/*` to `web_analytics_exclude_paths` when the analytics
  tables already existed at that moment (analytics installed later: add the
  pattern by hand).
- **Module key** `"shop"`; settings prefix `shop_`.

## What this module does NOT do

- **No payment logic.** Checkout converts a cart to an order through
  `PhoenixKitBilling`; tax configuration (`billing_tax_enabled`,
  `billing_default_tax_rate`) is read from billing, never redefined here.
  The same goes for online payment: `OnlinePayment` only asks
  `PhoenixKitBilling.start_order_payment/2` (looked up with
  `function_exported?/3`, so a billing without it keeps the old behaviour, and
  `OnlinePayment.awaiting?/1` is then false everywhere) for a checkout URL.
  Invoice, session and the "paid" fact are billing's; the provider's webhook,
  never the return URL, confirms a payment. While an online order is unpaid
  the admins get "New order ... awaiting online payment" at once, the buyer's
  "Your order is confirmed" waits for `InvoicePaymentHandler` (billing's
  durable invoice-event handler, `billing_invoice_event_handlers/0`), and
  `CheckoutComplete` shows "Awaiting payment" with "Pay now", updating on
  billing's `:order_paid` PubSub event on the buyer's own order topic (never the
  shop-wide one, which carries every order). An abandoned online order stays
  `pending`: nothing times it out. Tests swap the billing module through the
  `:online_payment_module` app env (`FakeOnlinePayment`); the real chain
  (`online_payment_chain_test.exs`, tag `:billing_start_order_payment`) runs
  once the resolved billing has the function. Checkout snapshots
  `checkout_language` and `payment_option_type` in order metadata: a delayed
  confirmation uses the buyer's language, and an edited or deleted option
  cannot change whether an order was placed online. Older orders fall back
  to the current option. The invoice handler locks the order and commits its
  `_shop_payment_notified` marker with the notification; redelivery is a
  no-op. Only a supported, positive-total online payment defers the
  confirmation (`OnlinePayment.required?/1`); free orders and older billing
  keep their immediate confirmation and the handler sends nothing more. So
  does an order with a price-on-request line, which is placed without a
  payment: the line counts 0 in the total, and a paid order can no longer be
  edited to add the quoted amount. The shop collects the whole amount itself.
  That internal marker changes neither the business revision nor
  `updated_at`; a notification insertion error rolls both writes back so
  billing's worker can retry.
- **No module-owned top-level layout.** The storefront is the host's
  surface and renders inside the host's configured `layouts_module`.
- **No scope on the public context API.** `PhoenixKitEcommerce.create_product/1`
  and friends (including the `compat/` re-exports) stay scope-less: hosts
  call them from their own controllers, workers and scripts, and the library
  cannot know whose authority those run under. Sub-permissions are checked in
  the bundled admin UI instead.
- **No order, payment or address through the API.** The public cart tools
  only fill a cart and hand the buyer to the site's own checkout.
- **No JavaScript.** There is no `js_sources/0` and no hook of its own.
- **No tables owned by another module.** This module's chain adopts the ten
  baseline shop tables where core 2.x created them, and builds them itself
  on core 3.x. It also creates `phoenix_kit_shop_search_index` (V4) and
  `phoenix_kit_shop_cart_claims` (V5). Billing owns the order tables; the shop's
  migration entry point runs billing's chain before adding its billing foreign
  key, so either module's host migration may run first.

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
provider only while `shop_shopify_enabled` is on (off by default).

```
lib/phoenix_kit_ecommerce.ex          # PhoenixKit.Module behaviour + the main context
lib/phoenix_kit_ecommerce/
├── schemas/          # Product, Category, Cart, CartItem, CartClaim, ShippingMethod,
│                     # ShopConfig, ImportConfig, ImportLog
├── options/          # option schema management, type system, metadata validation
├── import/           # CSV: format behaviour, detector, parser/validator/analyzer,
│                     # Shopify + Prom.ua + generic formats, transformer, filter
├── shopify/          # Shopify integration: provider, admin/storefront clients,
│                     # source, sync, product + text diffs
├── product_source.ex # Legacy | Catalogue adapter switch (shop_product_source)
├── product_source/   # Legacy (shop tables) and Catalogue (query + view) adapters
├── catalogue/        # duck-typed phoenix_kit_catalogue extension slot:
│                     # Extension, ItemCommerce, CategoryCommerce, ShopSections,
│                     # ShopStatusColumn, Writer (Shopify -> catalogue),
│                     # ShopifyAttribution, ValueResolver, SetSlug,
│                     # RelatedPicker (LiveComponent: the hand-picked product
│                     # lists inside the Shop section of the item form)
├── api.ex            # the admin API tools offered to core (api_tools/0)
├── api/              # the tools' handlers, plans and adapters to core/catalogue
├── warehouse_source_kind.ex # the shop_order kind offered to Warehouse
├── compat/           # deprecated PhoenixKit.Modules.Shop.* delegate shims
├── services/         # image download + batch image migration
├── workers/          # Oban: CSVImportWorker, ImageMigrationWorker,
│                     # ShopifyMediaSyncWorker, TranslationSweepWorker,
│                     # SearchReindexWorker, SearchRebuildWorker (queue shop_search),
│                     # ApiCartSweepWorker, ApiCartPruneWorker, ApiClaimPruneWorker
├── search/           # public search index: Entry, Dictionary, Trigram, OptionKeys,
│                     # Document, Indexer, Query, Jobs, Subscriber
├── api/              # public shop API tools: Visibility, Facts, Record, Loader, Context,
│                     # Cards, PlainText, SearchParams, PublicTools, Public.Schemas,
│                     # Public.Search, Public.Catalog; the cart tools: CartTools,
│                     # CartHandlers, CartToken, CartStore, CartWriter, CartOptions,
│                     # CartView, CartMoney, CartSettings, Signals, Claims
├── mix_tasks/        # install, deduplicate_products,
│                     # backfill_translation_fingerprints (one-shot),
│                     # backfill_image_fingerprints (after upgrading),
│                     # list_unstamped_prices (read-only audit)
├── web/              # LiveViews, components, plugs, routes, helpers, authz,
│                     # ClaimController + ClaimHTML (the checkout claim page);
│                     # components/related_products.ex (product page block),
│                     # components/cross_sells.ex (cart "Add to your order")
├── activity.ex       # activity-log wrapper (module + actor metadata, never raises)
├── policy.ex         # secure-by-default admin policy settings
├── vocabulary.ex     # "products" / "services" / "mixed" storefront wording
├── price_display.ex  # units, "From", price on request
├── selected_specs.ex # a cart line's option selection: value keys + label snapshot
├── item_image.ex    # a cart line's picture: product photo, else the host's :item_image_fallback
├── notifications.ex  # notification fan-out
├── errors.ex         # atom -> gettext-backed message dispatch
├── events.ex         # PubSub broadcasts
├── translations.ex   # multi-language content utilities
├── localized_slug.ex # slug projections
├── slug_resolver.ex  # multi-language slug lookup across products and categories
├── html_text.ex      # description sanitizing
├── html_to_markdown.ex # Shopify body_html -> Markdown on sync
├── name_prefix.ex    # display-time storefront name-prefix stripping
├── ai_translatable.ex# duck-typed phoenix_kit_ai translation adapter (products)
├── category_ai_translatable.ex # the same for categories
├── translation_fingerprint.ex  # staleness: hash, four states, write-narrowing, candidate SQL
├── translation_sweep_settings.ex # settings reader for translations + the sweep
├── stock_tracking.ex # Stock tracking switch, stock reads, goods issue of a sale (optional phoenix_kit_warehouse)
├── order_stock_handler.ex # billing's order event: writes a paid order's goods off
├── order_emails.ex   # who gets which order email and when; sends them once
├── order_email_defaults.ex # their default copy, variables and preview entries
├── order_email_handler.ex # billing's order event: queues a paid order's emails
├── related_products.ex # a product's hand-picked "You may also like" and cart cross-sell lists + their settings
├── availability.ex   # can a product be offered now (stock, or the host's hook)
├── prompt_rollout.ex # content-sha rollout of the code-managed AI prompts
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
| `CartClaim` | `phoenix_kit_shop_cart_claims` | one-time checkout claim of a cart the public cart API created: hashed token, expiry, used and superseded stamps |
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

Broadcast and subscribed through `PhoenixKitEcommerce.Events`, which uses
`PhoenixKit.PubSub.Manager` — core's own PubSub server, not the one
`PhoenixKit.PubSubHelper` resolves from the host's config. A publisher on one
and a subscriber on the other never meet and nothing fails, so a new topic
gets its topic, subscribe and broadcast functions in `Events`.

| Topic | Carries |
|---|---|
| `shop:products` | product created/updated/deleted, bulk status changes |
| `shop:products:<product_uuid>` | one product's changes |
| `shop:categories` | category created/updated/deleted, bulk status/parent/delete |
| `shop:inventory` | inventory changes |
| `shop:imports`, `shop:import:<import_log_uuid>` | CSV import completion, and one import's progress |
| `shop:image_migration:batch`, `shop:image_migration:<product_uuid>` | image migration start/cancel/per-product completion, and one product's progress |
| per-user and per-session cart topics | cart sync for real-time storefront updates |

`Search.Subscriber` listens to the two topics above **and** to the catalogue's
own topic (`PhoenixKitCatalogue.Catalogue.PubSub`, on the host's PubSub, a
different server) and turns events into Oban jobs; it never indexes inline.

### Web layer

- **Public LiveViews:** ShopCatalog, CatalogCategory, CatalogProduct,
  CartPage, CheckoutPage, CheckoutComplete. `UserOrders` and
  `UserOrderDetails` also live here; their routes (`/dashboard/orders`,
  `/dashboard/orders/:uuid`, localized and not) are declared by core's
  `PhoenixKitWeb.Integration` inside its authenticated session, against
  these modules by name. `Web.Routes` must not declare the same paths — its
  public routes land in a session without the login requirement.
- **Admin LiveViews:** Dashboard, Products, ProductForm, ProductDetail,
  Categories, CategoryForm, ShippingMethods, ShippingMethodForm, Carts,
  Settings, OptionsSettings, Imports, ImportShow, ImportConfigs, ShopifySync,
  Translations, TestShop.
- **Components:** ShopLayouts, ShopCards, CatalogSidebar, FilterHelpers,
  TranslationTabs.
- **Plug:** `Plugs.ShopSession` mints and reads the signed `shop_session_id`
  cookie (30 days) plus the Phoenix session entry, so a guest keeps one cart
  across pages. A disabled shop does not MINT a new identity but still
  RECOGNISES an existing signed one — the order-confirmation page is
  deliberately reachable while the shop is disabled, because it is a receipt.

### Admin API tools

`PhoenixKitEcommerce.api_tools/0` (no `@impl`, like `notification_types/0`)
returns `PhoenixKitEcommerce.API.tools/0`: `ecommerce.get_prices`,
`ecommerce.set_prices`, `ecommerce.set_availability`, `ecommerce.attach_images`,
`ecommerce.detach_images`.
`api_tools/0` adds `PhoenixKitEcommerce.API.OrderTools.tools/0` (list_orders,
get_orders, get_order_customers, set_order_sync), which is `[]` unless the
loaded billing exports `PhoenixKitBilling.put_order_sync/2`.
Rules that must hold:

- **Admin write handlers require the key owner's live `"catalogue"` permission**
  as well as core's `shop.manage_catalog` scope check, matching the catalogue
  editor. `API.Gate.authorize_catalogue/1` checks the owner with
  `Scope.for_user(narrow: false)` before any write handler or dry run;
  missing actors, revoked access and permission-layer failures deny the call.
- **The write tools are offered only when core enforces the confirmation
  gate** (`Keys.active?/1` and `Flow.gate/1`, see
  `API.confirmation_available?/0`). A core that cannot hold a dangerous call
  for confirmation would run a large price cut on the first call.
- **The batch reads and writes go through three adapters:** `API.Gate` (the
  product source is the catalogue and the catalogue is new enough, judged by
  what it exports, not by its version), `API.Refs`
  (`PhoenixKitCatalogue.API.resolve_refs/2`) and `API.CatalogueWrites`
  (`Catalogue.update_items/2`). Two more call sites reach the catalogue
  directly: `AttachImages` (`Attachments.attach_files/3`), `DetachImages`
  (`Catalogue.update_item/3` and core's `ResourceFolders.detach/2`) and `SetPrices`
  (`AttributeSets.resolve_for_items/2`); `Gate.catalogue_api_ready?/0` does not
  probe them. Anything the gate refuses answers `unsupported_source` and
  writes nothing.
- **`CatalogueWrites.with_locked_items/2` queries the catalogue's own tables**
  (`PhoenixKitCatalogue.Schemas.Item` and `Category`, no public function of
  the catalogue does it) and **copies the catalogue's lock order**: the
  categories involved `FOR SHARE`, then the items `FOR UPDATE`, each sorted by
  uuid, as `lock_items_for_batch` in `Catalogue` does. A catalogue that
  changes that order makes a deadlock with its own batch or a category trash
  possible, so a change of the order there means a change here (the proper
  fix is a public `lock_items/2` in the catalogue). `Gate.catalogue_api_ready?/0`
  probes the two schemas and the columns the query uses, not the order. The
  transaction can fail to commit (a write inside it rolled the transaction
  back, as a nested rollback does to the one around it); the helper then
  answers `{:error, row_error}` (it does not raise a `MatchError`), and the callers answer a row
  failure (`database_error`) for the rows it was to write.
- **Writes are limited to the `data` sub-paths a row changes**
  (`data_owned_paths`; an option price is one path per leaf), so a concurrent
  writer of any other field, the Shopify sync included, is never overwritten.
  The Shopify writer does the same (`Catalogue.ShopifyAttribution`), and a
  write that changes no `data` path sends `data_owned_paths: []`, never no
  option. A default that `ItemCommerce.cast/2` fills in for a field the sync
  did not touch is therefore not stored by the sync.
- **A product's own status is read with the storefront's rule**
  (`View.merchant_status/1`, `View.product_status/2`, made public for this):
  a product with no `shop_status` counts as `active`. Never a second copy.
  `get_prices` calls the result `shop_status_visible`: it does not look at
  the product's category, which the storefront also checks.
- **Only `set_prices` and `detach_images` have a `danger` function** (the price rule; a row that would leave a product with no picture). The size of
  a batch is core's rule (`api_confirm_batch_over`, applied to every admin
  write tool by the executor). The danger check, the plan of the call and the
  write each read the prices, so the handler closes the gaps: a call without a
  confirmation code (`ctx.confirmation_uuid` is `nil`) whose own plan has
  become dangerous is refused, and `API.Batch.write_if_unchanged/4` locks the
  items, plans them again and writes only the rows whose current values are the
  ones they were planned from (the others fail alone, `changed_since_planned`).
- **`detach_images` removes only what the product's gallery names** (its
  `media_order` and featured pointer): a file id or a URL that is not in it
  is reported in `not_attached` and changes nothing, which is also what makes
  a retry `unchanged`. The file leaves the product by core's folder rule
  (`ResourceFolders.detach/2`, the catalogue editor's remove button): a link
  is dropped, a file homed in the product's folder moves to another product's
  folder that holds it, else it is trashed (never hard deleted). The files are
  released and the gallery written in one transaction (a gallery that cannot be
  written rolls the releases back). Removing the featured picture clears the
  pointer, as the editor does. Its `danger` check is "a row would leave a
  product with no picture"; removing the main picture alone is not held. The
  danger check, the plan and the write each read the gallery, so the row lock
  re-checks: a gallery (order and featured pointer) that is no longer the one
  planned fails the row `changed_since_planned` and releases nothing. A URL is
  matched against the files the product's own gallery names (any Storage
  status), never the shop-wide one-file-per-URL index, and every gallery file
  from that URL goes. At most 50 pictures per product and 500 per call; files
  are released in sorted order so two calls sharing files cannot lock them
  crosswise. **Known:** core announces `{:phoenix_kit_file_trashed, uuid}`
  inside `ResourceFolders.detach/2`, before this transaction commits; a
  subscriber that re-reads on the event can read the file as still active,
  committed or not, and core's `FeaturedImage` does not look a settled lookup
  up again on its own, so a host that refreshes it on this event can keep the
  stale picture until something else prods it. A row rolled back afterwards
  has announced a file that is still active. Only core can announce later.
- **A dry run of a tool with a `danger` rule says whether the real call would
  be held:** `API.Batch.with_confirmation/3` adds `requires_confirmation`
  (`Batch.dangerous?/1`, the same function the `danger` check answers, or more
  rows than core's `api_confirm_batch_over`) and `confirmation_rules` (the
  thresholds). Every write tool answers it: a tool with no `danger` function
  (`set_availability`, `attach_images`) passes no rule, so the flag is core's
  row threshold alone. A dry run creates no confirmation code.
  `API.Batch.ensure_not_newly_dangerous/3` is the shared re-check of a call
  without a confirmation whose plan has become dangerous.
- **Prices are decimal strings with at most 2 decimals** (`API.Money`). A
  third decimal is refused, never rounded.
- **`attach_images` always passes `private_networks: :forbid`** to the
  downloader; `shop_image_import_allow_private_networks` is for the shop's
  own CSV import and does not apply to an API caller. It also passes
  `require_raster: true` (the bytes must be a PNG, JPEG, GIF or WebP picture
  of the declared type; an SVG is refused whatever `shop_allow_svg_uploads`
  says) and `redact_query: true` (a signed URL's query string is a credential
  and reaches no log line and no stored `source_url`; the path of the URL
  reaches no log line either, it can carry a signed token), a 10 MB limit per
  picture, and, on a core with the field, a `cost` of one rate-limit unit per
  picture. The downloads can take a minute and a half, so each product is read
  again with its row locked when its pictures are attached; one trashed or
  moved out of the shop catalogue meanwhile answers `not_found` and gets
  nothing.
- **A pinned download makes no pool.** The importer, the admin API and the
  Shopify storefront connect to the one address the private-network guard
  checked (`ImageDownloader.pinned_request/2`) through `Services.PinnedAdapter`,
  a Mint connection per request, with the `Host` header's name as SNI and
  certificate name. Never `connect_options: [hostname: ...]`: `Req` starts a
  `Finch` pool with a new atom per distinct value and never stops it, so every
  hostname a caller names would stay in the node. Every name lookup of the
  guard has a deadline (`:image_dns_timeout`, 3 s) and fails closed. The
  adapter is an adapter module and delegates a `plug:` request to
  `Req.Plug.run/1`, so `mix.exs` requires Req 0.7 (`dependency_floor_test.exs`
  pins it). **Cost:** with no pool there is no keep-alive, so every picture
  pays two TCP+TLS handshakes (the HEAD preflight and the GET), and each
  redirect hop one more. That is nothing for the API (20 URLs a call); the
  Shopify media sync and the CSV import fetch hundreds of pictures through the
  same path, so measure a real run on the stand before relying on their old
  timings.
- **A write that changed a product clears `StorefrontCache`** (once per call,
  after the rows are committed, in `API.Batch.write/3`,
  `API.Batch.write_if_unchanged/4` and `API.AttachImages`), like the Shopify
  sync does. A dry run and an unchanged row leave it alone.
- **Shopify is optional.** Nothing in the tools needs a product to be linked
  to it; the descriptions of the four write tools and the row warning
  `shopify_sync_may_overwrite` mention the sync only while it is on. "Linked"
  is one rule, `ItemCommerce.shopify_linked?/1` (a Shopify handle or product
  id), shared with the settings of the product form. `set_availability`
  warns on a visibility change and `attach_images` and `detach_images` on a
  picture, because the sync writes the shop status and replaces the picture order.
- `api_confirm_price_change_pct` (default 30, `API.Settings`) is the one
  e-commerce setting of the API; it has no `shop_` prefix, it shares the
  `api_` prefix of core's other API settings (`api_confirm_batch_over`).
  Changing it takes `shop.manage_settings` **and** core's `api` permission
  (`Web.Authz.can_manage_api?/1`).
- **The order tools** (`API.OrderTools`) read `PhoenixKitBilling.Order` only.
  The revision, the mark (`metadata["sync"]`) and the `sync` filter belong to
  billing (`Order.revision/1`, `Order.sync/1`, `Order.where_sync/2`,
  `put_order_sync/2`); nothing here writes an order. The buyer's contacts are
  part of an answer only when `ctx.scopes` holds `ecommerce.orders:customer`
  (`OrderTools.contacts?/1`); the serializer (`API.OrderExport`) takes them
  only through its `:contacts` option, so a caller that sends the order to the
  external system passes `contacts: true` on purpose. A scope is granted
  through the tools that declare it (core's `Keys.allowed_scopes_for/1`), which
  is why `ecommerce.get_order_customers` exists. All four order tools declare
  `shop.manage_orders`, so `contacts?/1` (scope only) is reached only by an
  owner who holds it: on every call core drops from a key the scopes whose
  tools' permission the owner no longer holds. `set_order_sync` is an admin
  write like the others: a batch above `api_confirm_batch_over` is held for
  confirmation by core, and the handler answers a dry run with a preview and
  no write. The order feed leaves out `draft` orders unless `statuses` names them.
- `PhoenixKitEcommerce.warehouse_source_kinds/0` offers the `shop_order` kind
  to Warehouse (`WarehouseSourceKind`); only orders placed by the storefront
  checkout count, and no label shows the customer.
- A `validation_failed` answer with `context.reason` `database_error`,
  `storage_error` or `unexpected` is not the caller's fault and is worth
  retrying; any other `validation_failed` should be fixed first.

Tests: the API's tests are tagged by what they need (`:catalogue_api`,
`:old_catalogue`, `:no_catalogue`, `:core_api`, `:core_confirm`,
`:core_no_confirm`, `:warehouse`; see `test/test_helper.exs`). Run the suite
once per build and read the excluded count each time.

### Permissions

The `"shop"` key opens the admin area's dashboard and nothing else. Five
sub-permissions carry the pages and capabilities (core enforces
sub-implies-base); each page is refused at mount without its key:

| Key | Covers |
|-----|--------|
| `shop.manage_catalog` | products + categories (list, form and detail pages); viewing the translations page; the test shop page |
| `shop.manage_orders` | every order tool of the API, reads included: orders carry the buyers' data and the totals |
| `shop.manage_carts` | the carts admin — **read included**, the rows carry customer contact details |
| `shop.manage_settings` | the settings page (security policy and the rest), product options, shipping methods (list and form); every translations-page action (translate, stamp, reset, stop, run sweep, sweep settings) |
| `shop.run_imports` | CSV imports and their detail pages, import configurations, Shopify sync |

⚠️ Core auto-grants a newly discovered sub-permission to the Admin system
role only. A CUSTOM role holding base `"shop"` keeps the dashboard but loses
every other page until an operator grants the sub-keys — secure by default
and deliberate, but a breaking authorization change on upgrade. Reading
orders through the API needs `shop.manage_orders` the same way.

Tests that show a capability refused inside a page open it with the key and
then take it away (`LiveCase.live_narrowed/2`, `swap_scope/2`): mounting with
the narrow scope is now refused before any event can be sent.

### Notifications and the audit trail

`notification_types/0` declares five sub-types under `"shop"`: admin `orders`,
customer `order_confirmations`, `stock` (a paid order that could not be written
off), `imports`, and `cart_activity`. They are
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

### Order emails

`OrderEmails` sends real emails, apart from the notifications above and from
each user's preferences. Three templates, overridable and previewable like any
other (`email_templates/0`, layout group `shop`): `shop_order_confirmation` and
`shop_order_paid` to the buyer, `shop_order_received` to the shop.

- **When.** On placing, the buyer's confirmation and the shop's email, unless the
  order awaits online payment; on `:paid`, the buyer's paid email and the shop's
  email if it has not gone yet. An online order is not confirmed until the money
  lands, so an abandoned payment mails nobody.
- **How.** One `Workers.OrderEmailWorker` job per email, on `default`. The placing
  jobs are queued in the conversion transaction, the paid ones by
  `OrderEmailHandler` from billing's durable order event, so the checkout never
  waits for a mail server and a failure cannot reach it.
- **Once.** A job is unique per order and email, and a sent email is marked in
  `metadata["_shop_emails"]`, which outlives the job row (Oban prunes those).
  A delivery claims the email first: under the order's row lock it reads the
  stored mark and status, writes `%{"claimed_at" => unix_seconds}` in the mark's
  place, and commits. Then it sends, and writes `true` over the claim. A second
  delivery that finds a claim sends nothing and answers `{:snooze, seconds}`, so
  overlapping deliveries cannot both send. A send that fails or raises gives its
  claim back, and the retry sends at once. Cancelled and refunded orders send
  nothing, even if a job or a caller's copy of the order predates the change.
- **The send runs in no transaction of this module.** An email provider
  (`phoenix_kit_emails`) writes its log on the same connection and rescues its
  own errors. Inside a transaction a failed statement of its would abort the
  transaction: the mail goes, the mark cannot be written, and each retry mails
  again. Keep the send outside; `order_emails_test.exs` pins it with a provider
  whose log write fails.
- **A crash.** The mark changes neither the revision nor `updated_at`. A delivery
  that dies between the send and the mark leaves its claim, which is good for
  five minutes; the next delivery after that sends, so a crash can repeat an
  email and never loses one. A buyer email and its copy are claimed and marked
  separately, so a failed copy keeps the buyer's mark.
- **Copies.** Each buyer email that goes is sent again, unchanged (same template,
  language and order link, replies to the buyer, no `user_uuid`), to the copy
  addresses. It is a second message, not a `Bcc:`: core's
  `Mailer.send_from_template/4` takes no `:bcc`. It runs in the buyer email's job
  after the buyer's send, with its own mark (`"buyer_placed_copy"`,
  `"buyer_paid_copy"`), so a failed copy retries without mailing the buyer
  twice, and an email the buyer did not get (turned off, no address) has no copy.
- **Language.** The buyer's emails use `metadata["checkout_language"]`. The shop's
  uses `OrderEmails.shop_email_language/0`: the language chosen for it while the
  site still serves it, the primary language otherwise. Order lines keep the
  text the buyer saw.
- **The order link.** A confirmed account gets `/dashboard/orders/:uuid`. A guest
  gets `/checkout/complete/:uuid` only under the `:link` lookup policy: under
  `:strict` that page opens only in the placing session, so the link is left out.
- **Settings**, through `OrderEmails`: `shop_order_emails_to_buyer` (default on,
  a read error counts as off), `shop_order_email_recipients` (addresses; none
  means no shop email), `shop_order_email_copy_recipients` (addresses; none means
  no copies) and `shop_order_email_language` (an enabled language code, `""` for
  the primary language; the selector shows only with two or more languages
  enabled, and a code the site no longer serves falls back). An address list with
  one bad entry is refused whole.

### Settings keys

All stored via `PhoenixKit.Settings`. Keys are **`shop_`-prefixed**, except `api_confirm_price_change_pct`.

**Behaviour**

- `shop_enabled` — module master switch (default: `false`)
- `shop_inventory_tracking` — legacy; no longer exposed on the settings
  page and read only into the unused `config.inventory_tracking`
- `shop_product_source` — `"legacy"` (default) or `"catalogue"`; stored in
  `phoenix_kit_shop_config`, not `PhoenixKit.Settings`. Read through
  `PhoenixKitEcommerce.ProductSource.current/0`, which fails closed to
  Legacy when `phoenix_kit_catalogue` is not loaded or the read fails. The
  value is memoized per process for `:product_source_memo_ms` (application
  env, default 1000, `0` in tests): nothing in this package writes the row,
  so there is no write to invalidate a shared cache on.
- `shop_catalogue` — the name of the one catalogue the shop reads under the
  Catalogue source; stored in `phoenix_kit_shop_config`. It has no default and
  no writer here: a host on that source sets it. Unset, or naming no catalogue,
  `Query.catalogue_uuid/0` answers `nil`: the storefront is empty, each
  resolution logs a warning, and the admin API refuses with
  `no_shop_catalogue`. It never picks a catalogue by itself, because creating
  an unrelated catalogue must not change what the shop sells.
- `shop_allow_price_override` — allow per-product price overrides (default: `false`)
- `shop_enforce_product_currency` — refuse, rather than warn, when a product's
  currency does not match the shop's (default: `false`). Read through
  `enforce_product_currency?/0`.
- `shop_require_phone_at_checkout` — require a phone number at checkout
  (default: `false`). Read through `require_phone_at_checkout?/0`. The checkout
  form requires it, and `convert_cart_to_order` refuses details without one
  (`{:billing_incomplete, ["phone"]}`), a saved profile included: a profile was
  never required to carry a phone, and a crafted `confirm_order` skips the
  form. The setting adds the phone to a billing form and to saved profiles;
  it does not introduce a billing step where there was none (a checkout that
  skipped the step passes blank form data, which asks for nothing). Billing's
  own `require_phone` option is only an extra: the shop's check
  does not depend on it (it only marks the input required).

**Admin API**

- `api_confirm_price_change_pct` — percent; a price above zero that moves by
  more than this needs a confirmation, and so does an option price added,
  changed or removed by more than this percent of the product's current price (default: `30`; it has no `shop_` prefix). Read through `API.Settings.price_change_pct/0`, which
  reads any invalid value as the default.

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
- `shop_sidebar_enabled` — render the desktop sidebar on `/shop` and the
  category pages (default: `true`). Off drops the `<aside>`, gives the
  products the full width (a 2 / 3 / 4 column grid) and keeps the filters
  button and the category list at every width, because the sidebar was where
  they lived. Read through `Web.Helpers.sidebar_enabled?/0`.
- `shop_category_display` — `"cards"` (default) or `"buttons"`. `buttons` is
  one wrapping row (`CatalogSidebar.category_chips/1`: "All" first, the current
  category highlighted) that replaces the cards and the phone category list.
  On `/shop` it follows `shop_sidebar_show_categories` like the cards do; on a
  category page it always shows. A stored value neither reader understands
  counts as `"cards"`. Read through `Web.Helpers.category_display/0`.
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

**Related products — read through `PhoenixKitEcommerce.RelatedProducts`, never directly**

- A product's "You may also like" list is `related_product_uuids`, and its
  cart cross-sell list `cross_sell_product_uuids` (each at most 12 uuids, the
  merchant's order). Legacy: keys in `metadata`, edited in the product form's
  "Related products" and "Cross-sells" cards (core's `SearchPicker`; both keys
  are in `@form_owned_metadata_keys` and the lists live in socket assigns).
  Catalogue: the same keys in the item's `data["ecommerce"]` (`ItemCommerce`
  normalizes them; the catalogue view copies them into the view-struct's
  `metadata`), edited by `Catalogue.RelatedPicker`, a LiveComponent inside the
  Shop section of the catalogue item form (it submits hidden
  `item[ecommerce][...][]` inputs, plus an always-present empty one so an
  emptied list can be cleared). No column, no migration. Every reader goes through `RelatedProducts.normalize/2`: it
  keeps only well-formed uuid strings, once each, never the product itself;
  any other shape reads as empty. The block renders only products
  `Legacy.list_listed_by_ids/1` returns (status `active`, category not
  `hidden`) that `PhoenixKitEcommerce.Availability.available?/1` accepts
  (`Legacy.list_listed_by_ids/1`, `Catalogue.list_listed_by_ids/2`);
  `Availability` answers false for a product stock tracking counts with
  nothing on hand, unless the host answers instead (`config
  :phoenix_kit_ecommerce, :availability, {Module, :function}`; a hook that is
  missing, has another arity, raises, exits or throws counts as available and
  is logged as a warning, so a broken hook never crashes a product page). Dangling ids are skipped on read and dropped when the
  merchant next saves the form (a legacy product's form drops a deleted product
  from its chips; the catalogue picker does the same); nothing sweeps them. The cart's "Add to your order" block (`CartPage`,
  `Web.Components.CrossSells`) is `RelatedProducts.cross_sells/2`: the
  cross-sell lists of the products in the cart together, in cart order,
  minus what is already in the cart (a catalogue line is matched by
  `metadata["catalogue_item_uuid"]`). Its "Add" button only exists for a
  product with nothing to choose (no selectable option); any other gets a
  link to its page. The Add event reloads the originating cart and its offers,
  rechecking visibility, availability and selectable options before adding;
  an old button cannot add a removed offer or bypass a newly introduced choice.
  The destination is the shopper's active cart, so a page left open across
  checkout starts a new cart. Both `add_to_cart` paths lock and reload the cart
  after locking/reloading the product, before inserting or incrementing a line;
  checkout winning that lock refuses the add with `{:error, :cart_not_active}`.
- `shop_related_fallback` — `"off"` (default) or `"category"`: when nothing
  the merchant picked can be shown, listed products of the
  product's own category stand in (legacy: newest first; catalogue: the
  catalogue's own order, by position and name). Off keeps a page without a
  list exactly as it was.
- `shop_related_limit` — products each block shows, 1..12 (default 4); any
  other stored value reads as 4.

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
- `shop_shipping_parcel_defaults` — JSON `%{"length_mm", "width_mm",
  "height_mm", "weight_g"}`: the standard box and the weight assumed for a
  line without one. Read via `shipping_parcel_defaults/0`, written via
  `update_shipping_parcel_defaults/1` (validates; the settings LiveView
  logs `shop.shipping_parcel_defaults_changed`).
- Packing data has no columns: a product's size lives in
  `metadata["dimensions_mm"]` (virtual `length_mm`/`width_mm`/`height_mm`,
  `Product.dimensions_mm/1`; catalogue items keep it in
  `data["ecommerce"]`), a category's in `metadata["parcel_defaults"]`
  (`Category.parcel_defaults/1`; catalogue: `CategoryCommerce.parcel_*`,
  exposed by `View.category_view/2` through the same metadata key). Adding a
  line freezes `metadata["shipping_profile"]` on it (`Shipping.CartPacking`);
  `cart_parcels/1` packs from those snapshots, never from the live product.
- A shipping method's `metadata["shipping_provider"]` is set through the
  top-level `shipping_provider` param of `ShippingMethod.changeset/2`
  (validated by `Shipping.MethodParams`), never as `metadata` itself, which
  `cast/3` would replace whole. The `"fixed"` provider is the not-calculated
  path: it has no settings or service and never asks for a destination, and a
  stored fixed block is read as no block. Price rounding is off unless
  `pricing.round_to` is a positive step.
- The block's `"services"` are the services the shopper may choose from
  (`"service"` is the default, the first of them; a block with only
  `"service"` reads as a list of that one, so older methods need no data
  migration). The shopper's choice is `cart.metadata["shipping_service"]`
  (`set_cart_shipping_service/2`); the service in effect is the choice when
  the method still allows it, else the default (`cart_shipping_service_key/1`).
  It goes into `RateRequest.service`, so a quote for another service is stale,
  and into the order's `shipping_provider.service`. Never read
  `shipping_config(method).service` for a cart: use the service in effect.
  A choice the admin has since unticked is stale: until a destination is
  stored (which records the service now in effect) or another service is chosen,
  the destination counts only as its locality (`request_destination/2`,
  `destination_in_effect/2`), so the shopper is asked for a place again.
  Saving a nonempty destination records
  its service even when the shopper used the default without clicking its radio:
  changing the default must not reinterpret an existing pickup point. A legacy
  destination without a recorded service requires confirmation once, since its
  historical default is unknown.
- The limits of a chosen pickup point (weight, size, value) are re-checked
  against the cart whenever its shipping status is worked out
  (`check_destination`): a point that no longer takes the parcels makes the
  status `:needs_destination` with snapshot `reason: "point_limits"`, which
  blocks checkout like any other missing destination.
- Locality search and pickup point listing are rate limited per provider
  (`Shipping.RateLimit`, `:shipping_lookup_rate`, default 20/s; `{:error,
  :rate_limited}` is transient and never cached) and their cache entries are
  bounded apart (`:shipping_cache_max_lookup_entries`,
  `:shipping_cache_max_list_size`). Both need `Shipping.Cache` running (it
  owns the tables).

**Public cart API** (core's `api_` namespace, not `shop_`)

- `api_cart_idle_days` (7, 1..365), `api_checkout_claim_ttl_minutes` (30,
  1..1440), `api_signal_per_cart_per_hour` (3, 0..1000) and
  `api_signal_global_per_hour` (30, 0..100000). Read through
  `API.CartSettings` (defaults and ranges live there) and edited on the shop
  settings page. The two cart-row limits belong to core.

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

**Shopify — read through `PhoenixKitEcommerce.shopify_enabled?/0`**

- `shop_shopify_enabled` — default `false`, and a failing settings read also
  answers `false` (fail closed). Off hides the Shopify Sync tab, redirects the
  sync page, empties `integration_providers/0` and `required_integrations/0`
  (the provider cache is cleared on toggle). The stored connection and its
  token are never touched.
- The connection's `shop_domain` is accepted only as a bare
  `<store>.myshopify.com` host (`Shopify.ShopDomain`): it is interpolated
  into the URL every Admin API request goes to with the access token
  attached. For the same reason `Shopify.AdminClient` follows no redirect
  and no next-page link to another host, and bounds a paginated read by
  page count and wall clock. Installs that used Shopify under the old default of
  `true` get the row written by the chain's V3 step (below).
- **No price is written from Shopify while the shop has no base currency.**
  `Shopify.Sync.currency_verdict/1` answers `:missing_base_currency` before
  it looks at the store at all: creates are refused, price fields are
  dropped from an update (its other fields still apply), the variants sync
  writes no modifier, and the sync page disables those actions under a
  banner. An amount stored with no currency is read as whatever the base
  later becomes. `mix phoenix_kit_ecommerce.list_unstamped_prices` lists the
  catalogue items that already carry one; it stamps nothing.
- **A base-currency change is refused on a catalogue-backed shop**
  (`reprice_for_base_change/3` reprices the shop's own tables only). A
  screen offering the change asks `base_currency_change_supported/0` before
  its confirmation step and shows `Errors.message/1` of the reason.

**Stock tracking — read through `PhoenixKitEcommerce.StockTracking`**

- `shop_stock_tracking_enabled` — default `false`. The effective state is
  this setting AND `phoenix_kit_warehouse` installed AND enabled, so
  disabling or removing Warehouse switches tracking off without touching the
  key. `StockTracking.set_enabled(true)` is refused (`:warehouse_not_installed`
  / `:warehouse_disabled`) in the context, not only greyed out on the settings
  page; turning it off always works. `warehouse_status/0` is
  `:not_installed | :disabled | :no_default_location | :ready`. The Warehouse
  modules are reached by variable-module calls behind `Code.ensure_loaded?/1`
  (no compile-time reference, so a host without the package compiles
  unchanged) and a failing probe counts as `:disabled`; tests swap them via
  the `:stock_tracking_modules` app env (`test/support/fake_warehouse.ex`).
- **What is limited.** While `StockTracking.location/0` answers (tracking on and
  a default warehouse chosen), stock at that location limits a sale. A catalogue
  item that ships is counted, and one with no stock row has none, so turning the
  switch on before receiving goods makes them out of stock. A Legacy product has
  no warehouse item and a line with `requires_shipping: false` is not goods;
  neither is limited. Quantities are whole units: a fraction on hand is not a
  unit. A failed stock read is logged and limits nothing.
- **Where it is refused.** `add_to_cart/4` and `update_cart_item/2` answer
  `{:error, {:insufficient_stock, [line]}}` counting every line of the item, and
  lowering a quantity is always allowed. An add checks before its transaction
  opens. An update locks the cart and re-reads the line before checking, so an
  older, larger quantity cannot make an increase look like a decrease or hide
  an update from Ecto. A refusal returns without rolling back either caller's
  transaction: `API.CartWriter` and the claim's merge can continue other lines.
  `convert_cart_to_order/2` decides again on
  the locked cart. `shop.set_cart_items` makes it the line's `insufficient_stock`
  error with `allowed.max`; the claim's merge skips and names the line.
- **The write-off.** `OrderStockHandler.handle_order_event(:paid, order)` posts
  one goods issue through `StockTracking.post_sale/3`: reason `sale`, the order
  number as `external_ref`, a `shop_order` source reference, no performer. Only
  `metadata["source"] == "shop_checkout"` orders still `paid` at delivery count.
  `external_ref` makes a redelivery a no-op. A goods issue is all or nothing: a
  short line posts nothing and the job ends `:ok`, with one
  `shop.order_stock_short` notification to shop operators and warehouse keepers,
  held to one by `metadata["_shop_stock_short"]` on the locked order. The keeper
  posts the issue by hand. Order events reach the handler on billing's `billing`
  queue.
- **Not there yet (#82).** Nothing is reserved: a cart or an unpaid order holds
  no stock, so the last unit can be sold twice and the second order is flagged.
  A refund or a cancellation gives nothing back, there is no low-stock reminder,
  the product page shows no "N left", and native per-variant stock does not exist.

**AI translations — read through `PhoenixKitEcommerce.TranslationSweepSettings`**

- `shop_translations_enabled` — default `false`. The feature exists at all:
  page, tab, manual actions. Turning it off also turns the sweep off; turning
  it on is refused without a usable AI endpoint or under the catalogue
  product source.
- `shop_translation_sweep_enabled` — default `false`. Automatic ticks only;
  the page's "Run sweep" ignores it.
- `shop_translation_interval_minutes` (`60`), `shop_translation_batch` (`3`,
  resources per tick), `shop_translation_max_in_flight` (`6`, incomplete
  shop `TranslateWorker` JOBS). The page refuses a batch or ceiling below 1;
  a ceiling below the target-language count admits the languages that fit
  and leaves the rest for a later tick.
- `shop_translation_languages` — `%{"codes" => [...]}`, default every enabled
  language but the primary; intersected with enabled languages on every read.
- `shop_translation_statuses` — `%{"statuses" => [...]}`, default
  `["active"]`; products only, categories are never status-filtered.
- The last tick's outcome is not a `shop_` key: `phoenix_kit_ai`'s sweep
  engine keeps it (`TranslationSweepWorker.last_run/0` reads it).

**Consumed from billing** (owned by `phoenix_kit_billing`, read here)

- `billing_tax_enabled`, `billing_default_tax_rate`

## Database & migrations

Owns a versioned chain: `PhoenixKitEcommerce.Migrations` via
`migration_module/0`, marker `pke_schema:<N>` as a COMMENT ON
`phoenix_kit_shop_config`, currently V6. `mix phoenix_kit.update` applies it
in hosts (and `mix phoenix_kit.status` reports it); tests apply it by running
`up_statements/1` directly. A marker-less or foreign-comment table reads as
version 0 — the core-baseline shape from before the chain existed.

`up/1` and `down/1` both honour `:version`. `up(version: N)` applies V1
through VN and stamps N — the call a generated host migration makes — and
leaves a database already past N untouched; with no `:version` it goes to
`current_version/0`. A target outside `1..current_version/0` raises.
`up_statements/2` takes the same target.

Before its own statements `up/1` runs billing's chain (`PhoenixKitBilling.Migrations.up/1`,
to billing's current version): this chain's foreign key points at
`phoenix_kit_payment_options`, core 3.x no longer creates it, and a host's
migration files written under core 2.x can run this chain before billing's.
A run re-applies billing's chain and stamps its current version. That changes
nothing, because its statements are idempotent and it seeds a table only when
it creates it (`migrations_up_version_test.exs` pins this). A database already
past the target is left as it is, so a host's older billing file cannot lower
the marker.
`up_statements/2` stays this chain's SQL only.

V1 is **adoptive**: under core 2.x all ten shop tables are core baseline tables,
so V1 changes no shape — it stamps the marker and claims future ownership. Core
3.x no longer creates them, and the same `CREATE TABLE IF NOT EXISTS` statements
build them. V2 is the chain's first deliberate divergence: it drops the
`DEFAULT 'USD'` core declares on the `currency` column of
`phoenix_kit_shop_carts`, `…_cart_items`, `…_products` and
`…_shipping_methods`, so an insert that names no currency stores NULL.
Existing rows are untouched. V3 writes `shop_shopify_enabled = "true"` for an
install that already uses Shopify (a Shopify integration connection, or
catalogue items / legacy products carrying a Shopify product id) and has no
such row yet, so flipping the default to off does not switch its sync off on
upgrade. It never overwrites an existing row; `down/1` leaves the row alone.
V4 creates `phoenix_kit_shop_search_index` (one row per listed product per
enabled language: weighted `tsvector`, lower-cased `title_trgm`, filter and
sort keys; unique on `(item_uuid, language)`, GIN on `document`,
`category_path_uuids` and `option_pairs`) and tries
`CREATE EXTENSION IF NOT EXISTS pg_trgm`, building the trigram index only
when the extension exists. The table is derived data: `down/1` leaves it, and
`Search.Indexer.rebuild/0` refills it.
V5 creates `phoenix_kit_shop_cart_claims` (one-time checkout claims of the
public cart API: a unique `token_hash`, the cart it belongs to with
`ON DELETE CASCADE`, the hash of the cart token it was issued for, the
language, `expires_at`, `used_at`, `superseded_at`) and, when the analytics
module's events table exists, appends `<url_prefix>/checkout/claim/*` to
`web_analytics_exclude_paths` (the trailing `*` matters: analytics matches any
other pattern as an exact path). `down/1` keeps the table and the setting.
V6 adds the base-currency columns core's V186 added (`base_currency` and
`exchange_rate` on `phoenix_kit_shop_carts`, `base_unit_price` on
`phoenix_kit_shop_cart_items`) with `ADD COLUMN IF NOT EXISTS`, so the chain
builds the shop tables without core. No backfill; `down/1` keeps the columns.

Rules for the chain, all of which have been broken at least once:

1. **Never edit a shipped version** — V1 or any later one. A shape change
   is a new version: a new `version_statements/3` clause, a new digest in
   `migrations_test.exs` for the new target. The digests of the shipped
   targets never change.
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
and the test Endpoint. It forces core's URL prefix to `/`. Admin paths in
tests carry the default-locale prefix (`/en/admin/shop`) on a core that always
emits one; a core with the URL language policy drops the segment on a
single-language site (`/admin/shop`). The test router serves BOTH shapes inside
one `live_session`, because a `push_patch` may not cross sessions — so build an
expected admin href with `Routes.path/1`, never as a literal.

Support modules under `test/support/` are loaded with explicit
`Code.require_file/2` — Elixir 1.19's `mix test` no longer auto-loads them at
test-helper time, so a new support file must be added to that list:

- `PhoenixKitEcommerce.DataCase` — context/schema tests: sandbox connection
  plus Ecto query/changeset helpers.
- `PhoenixKitEcommerce.LiveCase` — LiveView tests: the test endpoint/router
  and conn helpers on top of `DataCase`.
- `ActivityLogAssertions`, `NotificationAssertions`, `CheckoutFixtures`,
  `TestLayouts` (a host-consumer layout fixture), `FakeWarehouse` (stand-in
  for the optional Warehouse package), `Hooks`, `TestRepo`, `TestRouter`,
  `TestEndpoint`.

Postgres connection settings come from `PGUSER` (default `postgres`),
`PGPASSWORD`, `PGHOST`, `PGDATABASE`, `PGPOOL` and `MIX_TEST_PARTITION`. On a
machine whose Postgres has no `postgres` role, export `PGUSER` or integration
tests fail as pool timeouts that look like flakiness.

These tag families are excluded when their prerequisite is missing, and start
running by themselves once the dep is upgraded: `:integration` (no database),
`:requires_phoenix_kit_i18n_api` (core without
`Dashboard.Tab.localized_label/1`), `:requires_core_transliteration` (core
without `Utils.Slug` transliteration), `:requires_core_user_menu` (core
without `Dashboard.Tab.user_menu?/2`, the avatar-dropdown flag),
`:requires_billing_user_menu` (billing without `user_menu_with_shop?/1`, the
gate on its own avatar-dropdown tabs) and `:requires_core_single_language`
(core without `Languages.set_primary_language/1`, i.e. before the URL
language policy: a switched-off multi-language site's primary language is
then `"en"`, not the stored default). The single-language link tests
(`single_language_links_test.exs`) are written to pass on both kinds of core;
run them against a core with the policy too (`PHOENIX_KIT_PATH=…`).

Four more are excluded the same way: `:requires_core_api` (core without
`PhoenixKit.API.Tool` or `PhoenixKit.ObanCrons`, i.e. without the public API; it
gates every test of the public read and cart tools, a few hundred of them),
`:mcp` (core without the MCP plug), `:analytics` (no `phoenix_kit_web_analytics`)
and `:requires_pg_trgm` (a database without the `pg_trgm` extension). To run the
API tests, point `PHOENIX_KIT_PATH` at a core checkout that carries the public API;
against a released core without it they show up in the `excluded` count.

Two tags split the language-domain API links by core: `:requires_core_canonical_urls`
(excluded when core lacks `Routes.canonical_absolute_or_nil/2`) and its inverse
`:core_without_canonical_urls` (excluded when core has it; it runs only on an older
core and pins the request's-host fallback, so it is not a skipped test). Run both
sides, a core with the helper and a released one, as `test/test_helper.exs` says.

The admin API's tests need a core with the tool registry, a catalogue with the
admin API and `phoenix_kit_warehouse` with source kinds. A build can lack any of
them, and the `:old_catalogue` and `:no_catalogue` families need the lack. Their
families (`:core_api`, `:core_confirm`,
`:core_no_confirm`, `:catalogue_api`, `:old_catalogue`, `:no_catalogue`,
`:warehouse`) are excluded or included by what the build has (see
`test/test_helper.exs`, which prints the excluded set): run the suite once per
build and read the excluded count. `test/support/api_case.ex` and
`api_fixtures.ex` are the shared case and fixtures.

Three conformance tests run without a database and guard cross-repo contracts:
`core_pin_conformance_test.exs` (the two-segment core floor),
`phoenix_kit_ecommerce/dependency_floor_test.exs` (the core migration
version the floor promises),
and `schema_prefix_conformance_test.exs` (every table-backed schema uses
`PhoenixKit.SchemaPrefix`). Dialyzer suppressions live in
`.dialyzer_ignore.exs`.

## Feature notes

| Feature | Constraint that must hold | Where |
|---|---|---|
| Price display and storefront i18n | "Price on request" is snapshotted onto the cart line and the order line, never read live; every public LiveView calls `put_content_locale/1` in `mount/3`; `push_event` names, paths, route segments and setting keys are never wrapped in `gettext` | `dev_docs/guides/storefront.md` |
| AI translation control | Fingerprints are hashed identically in Elixir and SQL (`sql_trim_chars/0`); the sweep never auto-queues `unknown`; a write whose field fingerprint still matches is narrowed away; nothing enqueues under the catalogue product source. The sweep's chain, gates and budget are `PhoenixKitAI.TranslationSweep`'s — the worker supplies only the shop's gates, settings, candidates and prompts, and answers `:ai_unavailable` when the installed `phoenix_kit_ai` has no engine | `TranslationFingerprint`, `Workers.TranslationSweepWorker`, `Web.Translations` moduledocs |
| Shipping destination picker | `Web.Components.ShippingDestinationPicker` (the storefront's one LiveComponent, justified in its moduledoc; the admin side has `Catalogue.RelatedPicker`) is embedded by `CartPage` and `CheckoutPage` under the selected calculated method. Shipping is worked out ONCE per cart change by the parent (`Shop.shipping_quote_snapshot/2`: status, entry, presented, `blocks?`, service) and passed down — never recompute it in `render/1` or per component (packing, hashing, the service list and the provider's destination check are not free). The picker keeps no cart of its own: it saves, the shipping broadcast reaches the parent, the parent passes the new cart down; `:shipping_recheck` asks the parent to recompute when only the answer changed. Anything that calls the carrier on behalf of an anonymous shopper is bounded (one lookup in flight, `:shipping_lookup_interval`, capped texts, `Web.ShippingRequote` for automatic quotes: once per cart state, at most 3 in a row). A transient service failure is a retry, never "not available for this order". The shared display lines (ETA, COD fee, estimate note, reasons) are `Web.Components.ShippingDisplay`; DOM ids inside the picker derive from its `id` | `Web.Components.ShippingDestinationPicker`, `Web.ShippingRequote`, `PhoenixKitEcommerce.shipping_quote_snapshot/2` |
| Public read API and search index | Visibility is decided only by `API.Visibility` and every public tool loads products through `API.Loader`; the index holds listed products and base-currency prices only; `Indexer` upserts first and deletes stale rows last, so a rebuild never empties the index, and does nothing when the shop catalogue cannot be resolved; a hidden product, a malformed id and an unknown id answer alike; products and cards are always read live while the `count`, the facets and the category counts come from the index and lag a change by the reindex delay, so every write path of a product source must enqueue its reindex (`Search.Jobs`; the Legacy bulk category change and bulk delete do it themselves, the rest reaches `Search.Subscriber` as events, and the events of other catalogues are dropped there); a UUID from a caller is accepted only through `API.Loader.canonical_uuid/1`; money is converted only by `API.Context.money/2`; no value in a public answer is a `Decimal`, a `DateTime` or a struct | `API.Visibility`, `Search.Indexer`, `Search.Query`, `API.Public.*` moduledocs |
| Public cart API | The cart token is a signed bearer value and is never stored, logged or put in a notification; the cart row is created only by the first write, under core's cart-row limits; option keys are the ones `Search.OptionKeys` announces and `CartOptions` only maps them back; a line is addable only when `API.Visibility` says `:listed`, and a UUID from a caller goes through `API.Loader.canonical_uuid/1`; only the refusals `add_to_cart` makes before it opens its own transaction and that a retry cannot change (`CartWriter` `@line_refusals`) are that line's error, any other answer rolls the whole batch back for a retryable `state_changed`, because a refusal inside the writer's transaction dooms it; `shop.clear_cart` asks for confirmation only when the cart has lines; a carrier-priced method has no price until the buyer picks a destination; while a cart is checking out only `shop.get_cart` answers it (`checking_out`, no lines): the other read, `shop.get_shipping_options`, refuses it with `cart_locked` like a write (deliberate, pinned by a test); the claim route has no locale prefix, the claim URL's host must be one of `ctx.hosts` or the host of the `site_url` setting (else the first of `ctx.hosts`, else the `site_url` origin; no host to use at all refuses the call before a claim exists, a dry run refusing in exactly the same cases; core fills `hosts` with the request's Host header unless the host app's `:api_request_context` hook names the domains, so with core's defaults any Host header is believed and a multi-domain install should name its domains) and a GET never consumes a claim; the claim page's form carries the revision of the cart it showed, and a POST made after the agent changed the cart, or without that revision, shows the page again (`Claims.redeem/3` requires `revision` and answers `:reshow` for a missing or different one) instead of claiming lines the buyer did not see | `API.CartTools`, `API.Claims`, `API.CartStore` moduledocs |
| Agentic Commerce / ACP | Assessed and deliberately not built: a bridge plugin, not code in this module, is the shape if it is ever built | `dev_docs/agentic_commerce_acp_research.md` |
