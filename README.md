# PhoenixKit Ecommerce

E-commerce module for PhoenixKit — products, categories, cart, and checkout.

## Features

- Products with options-based pricing
- Hierarchical categories
- Cart management (persistent, DB-backed)
- Checkout with shipping methods
- CSV product import (Shopify, Prom.ua formats)
- Image downloader and migration tools

## Installation

Add to your `mix.exs`:

```elixir
{:phoenix_kit_ecommerce, "~> 0.1"}
```

## Requirements

- [PhoenixKit](https://github.com/BeamLabEU/phoenix_kit) `~> 1.7`
- [PhoenixKit Billing](https://github.com/BeamLabEU/phoenix_kit_billing) `~> 0.1`

## License

MIT
