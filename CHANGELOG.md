# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] - 2026-03-29

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
