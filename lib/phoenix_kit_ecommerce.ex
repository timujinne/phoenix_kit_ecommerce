defmodule PhoenixKitEcommerce do
  @moduledoc """
  E-commerce Shop Module for PhoenixKit.

  Provides comprehensive e-commerce functionality including products, categories,
  options-based pricing, and cart management.

  ## Features

  - **Products**: Physical and digital products with JSONB flexibility
  - **Categories**: Hierarchical product categories
  - **Options**: Product options with dynamic pricing (fixed or percent modifiers)
  - **Inventory**: Stock tracking with reservation system
  - **Cart**: Persistent shopping cart (DB-backed for cross-device support)

  ## System Enable/Disable

      # Check if shop is enabled
      PhoenixKitEcommerce.enabled?()

      # Enable/disable shop system
      PhoenixKitEcommerce.enable_system()
      PhoenixKitEcommerce.disable_system()

  ## Integration with Billing

  Shop integrates with the Billing module for orders and payments.
  Order line_items include shop metadata for product tracking.
  """

  use PhoenixKit.Module

  import Ecto.Query, warn: false
  require Logger

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Migrations.Postgres, as: PostgresMigrations
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes
  alias PhoenixKit.Utils.UUID, as: UUIDUtils
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Currency
  alias PhoenixKitEcommerce.Cart
  alias PhoenixKitEcommerce.CartItem
  alias PhoenixKitEcommerce.Category
  alias PhoenixKitEcommerce.Events
  alias PhoenixKitEcommerce.ImportConfig
  alias PhoenixKitEcommerce.Options
  alias PhoenixKitEcommerce.Options.MetadataValidator
  alias PhoenixKitEcommerce.Policy
  alias PhoenixKitEcommerce.Product
  alias PhoenixKitEcommerce.ShippingMethod
  alias PhoenixKitEcommerce.ShopConfig
  alias PhoenixKitEcommerce.Shopify.Provider, as: ShopifyProvider
  alias PhoenixKitEcommerce.SlugResolver
  alias PhoenixKitEcommerce.Translations

  # ============================================
  # SYSTEM ENABLE/DISABLE
  # ============================================

  @impl PhoenixKit.Module
  @doc """
  Checks if the shop system is enabled.
  """
  def enabled? do
    Settings.get_boolean_setting("shop_enabled", false)
  rescue
    _ -> false
  end

  @impl PhoenixKit.Module
  def required_modules, do: ["billing"]

  @impl PhoenixKit.Module
  def required_integrations, do: ["shopify"]

  @impl PhoenixKit.Module
  def integration_providers, do: [ShopifyProvider.definition()]

  @impl PhoenixKit.Module
  @doc """
  Enables the shop system.
  """
  def enable_system do
    result = Settings.update_boolean_setting_with_module("shop_enabled", true, "shop")
    refresh_dashboard_tabs()
    result
  end

  @impl PhoenixKit.Module
  @doc """
  Disables the shop system.
  """
  def disable_system do
    result = Settings.update_boolean_setting_with_module("shop_enabled", false, "shop")
    refresh_dashboard_tabs()
    result
  end

  defp refresh_dashboard_tabs do
    if Code.ensure_loaded?(PhoenixKit.Dashboard.Registry) and
         PhoenixKit.Dashboard.Registry.initialized?() do
      PhoenixKit.Dashboard.Registry.load_defaults()
    end
  end

  @impl PhoenixKit.Module
  @doc """
  Returns the current shop configuration.
  """
  def get_config do
    %{
      enabled: enabled?(),
      currency: get_default_currency_code(),
      tax_enabled: billing_tax_enabled?(),
      tax_rate: billing_tax_rate_percent(),
      inventory_tracking:
        Settings.get_setting_cached("shop_inventory_tracking", "true") == "true",
      allow_price_override:
        Settings.get_setting_cached("shop_allow_price_override", "false") == "true",
      products_count: count_products(),
      categories_count: count_categories()
    }
  end

  @doc """
  Effective shipping-skip mode for checkout.

    * `:off`      — shipping method required (legacy behavior)
    * `:fallback` — required when available; orders proceed without one when
      no method covers the buyer's country
    * `:always`   — shipping step disabled entirely
  """
  def shipping_skip_mode do
    case Settings.get_setting_cached("shop_shipping_skip_mode", "off") do
      "fallback" -> :fallback
      "always" -> :always
      _ -> :off
    end
  end

  @doc """
  Where the buyer picks a shipping method: on the cart page (legacy) or as
  a checkout step after billing, when the destination country is known.
  """
  def shipping_selection_position do
    case Settings.get_setting_cached("shop_shipping_selection_position", "cart") do
      "checkout" -> :checkout
      _ -> :cart
    end
  end

  @notify_setting_keys %{
    cart_first_item: "shop_notify_cart_first_item",
    cart_item: "shop_notify_cart_item",
    checkout_started: "shop_notify_checkout_started"
  }

  @doc """
  Whether operators asked to be notified about the given storefront event.
  """
  def notify_event?(event) when is_map_key(@notify_setting_keys, event) do
    Settings.get_setting_cached(@notify_setting_keys[event], "false") == "true"
  end

  @doc """
  Returns dashboard statistics for the shop.
  """
  def get_dashboard_stats do
    %{
      total_products: count_products(),
      active_products: count_products_by_status("active"),
      draft_products: count_products_by_status("draft"),
      archived_products: count_products_by_status("archived"),
      total_categories: count_categories(),
      physical_products: count_products_by_type("physical"),
      digital_products: count_products_by_type("digital"),
      default_currency: get_default_currency_code()
    }
  end

  @doc """
  The base currency code from Billing, or `nil` when no default currency
  is configured. `create_cart/1` then fails loudly on its own changeset
  (`Cart.changeset/2` requires `:currency`) instead of a silent literal
  masking an empty currency table (§4.2, §7.3).
  """
  def get_default_currency_code do
    case Billing.get_default_currency() do
      %{code: code} -> code
      nil -> nil
    end
  end

  @doc """
  Gets the default currency struct from Billing module.
  """
  def get_default_currency do
    Billing.get_default_currency()
  end

  @doc """
  Resolves the currency a PERSISTED record was denominated in.

  Order and cart pages used to load today's default currency, so changing
  the shop currency silently relabeled every historical order's amounts.
  Given the code stored on the record, this returns its `Currency` struct;
  an unresolvable code returns nil — callers then show the bare code rather
  than borrowing today's default symbol for an amount it does not describe.
  """
  def currency_for_code(nil), do: get_default_currency()

  def currency_for_code(code) when is_binary(code) do
    Billing.get_currency_by_code(code) || code
  rescue
    _ -> code
  end

  # ============================================
  # MODULE BEHAVIOUR CALLBACKS
  # ============================================

  @impl PhoenixKit.Module
  def module_key, do: "shop"

  @impl PhoenixKit.Module
  def module_name, do: "E-Commerce"

  @doc """
  Tailwind source roots contributed to the host's CSS build.

  Both `README.md` and `AGENTS.md` claimed this was implemented; it was
  not, and the `use PhoenixKit.Module` default returns `[]`. The
  consequence was invisible rather than loud: core's
  `:phoenix_kit_css_sources` compiler collects this from every discovered
  module and writes `assets/css/_phoenix_kit_sources.css`, so with shop
  contributing nothing, Tailwind purged every class used only by this
  module's storefront and admin templates from the host build.

  It stayed hidden because the compiler only warns when the TOTAL source
  list is empty — any other installed module masked the absence.
  """
  @impl PhoenixKit.Module
  def css_sources, do: [:phoenix_kit_ecommerce]

  @impl PhoenixKit.Module
  def version do
    case Application.spec(:phoenix_kit_ecommerce, :vsn) do
      nil -> "0.0.0"
      vsn -> to_string(vsn)
    end
  end

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: "shop",
      label: "E-Commerce",
      icon: "hero-shopping-cart",
      description: "Product catalog, orders, and e-commerce management",
      # Base "shop" is admin-area READ access. Each sub-permission is a
      # capability this module checks itself (core enforces sub-implies-base).
      #
      # ⚠️ Upgrade note: core auto-grants newly discovered sub-permissions to
      # the Admin system role only, so a CUSTOM role that holds base "shop"
      # keeps its read access but loses every mutation until an operator
      # re-grants the subs. That is deliberate - secure by default, and the
      # operator decides who gets what rather than inheriting a blanket
      # grant - but it IS a breaking authorization change on upgrade and is
      # called out in the PR body and AGENTS.md.
      sub_permissions: [
        %{
          key: "manage_catalog",
          label: "Manage catalog",
          description: "Create, edit and delete products and categories"
        },
        %{
          key: "manage_carts",
          label: "Manage carts",
          description: "View and act on customer carts (includes their contact details)"
        },
        %{
          key: "manage_settings",
          label: "Manage shop settings",
          description: "Shop settings, security policy, product options and shipping methods"
        },
        %{
          key: "run_imports",
          label: "Run imports",
          description: "Start CSV imports and manage import configurations"
        }
      ]
    }
  end

  @doc """
  Notification types this module contributes (duck-typed, discovered by
  core's `Notifications.Types`).

  Two audiences, deliberately separate sub-types so a shop operator can
  mute the order firehose without silencing their own receipts — and so a
  customer's confirmation is never governed by an admin-facing preference.

  ⚠️ The actions registered here are the NOTIFY actions. The audit trail
  uses different action strings on purpose: `Activity.log/1` auto-derives
  notifications from registered actions, so an audit row written with a
  notify action would deliver a second, duplicate notification.
  """
  def notification_types do
    [
      %{
        key: "shop",
        label: "Shop",
        description: "Orders and catalog imports",
        actions: [],
        default: true,
        sub_types: [
          %{
            key: "orders",
            label: "New orders",
            description: "An order was placed in the shop",
            actions: ["shop.order_placed"],
            default: true
          },
          %{
            key: "order_confirmations",
            label: "Your order confirmations",
            description: "Confirmation that an order you placed went through",
            actions: ["shop.order_confirmed"],
            default: true
          },
          %{
            key: "imports",
            label: "Catalog imports",
            description: "A CSV import finished or failed",
            actions: ["shop.import_completed", "shop.import_failed"],
            default: true
          },
          %{
            key: "cart_activity",
            label: "Cart activity",
            description: "A visitor added to a cart or started checkout",
            actions: [
              "shop.cart_first_item_added",
              "shop.cart_item_added",
              "shop.checkout_started"
            ],
            default: true
          }
        ]
      }
    ]
  end

  @impl PhoenixKit.Module
  def admin_tabs do
    [
      Tab.new!(
        id: :admin_shop,
        label: "E-Commerce",
        icon: "hero-shopping-bag",
        path: "shop",
        priority: 530,
        level: :admin,
        permission: "shop",
        match: :exact,
        group: :admin_modules,
        subtab_display: :when_active,
        highlight_with_subtabs: false,
        gettext_backend: PhoenixKitEcommerce.Gettext
      ),
      Tab.new!(
        id: :admin_shop_dashboard,
        label: "Dashboard",
        icon: "hero-home",
        path: "shop",
        priority: 531,
        level: :admin,
        permission: "shop",
        parent: :admin_shop,
        match: :exact,
        gettext_backend: PhoenixKitEcommerce.Gettext
      ),
      Tab.new!(
        id: :admin_shop_products,
        label: "Products",
        icon: "hero-cube",
        path: "shop/products",
        priority: 532,
        level: :admin,
        permission: "shop.manage_catalog",
        parent: :admin_shop,
        gettext_backend: PhoenixKitEcommerce.Gettext
      ),
      Tab.new!(
        id: :admin_shop_categories,
        label: "Categories",
        icon: "hero-folder",
        path: "shop/categories",
        priority: 533,
        level: :admin,
        permission: "shop.manage_catalog",
        parent: :admin_shop,
        gettext_backend: PhoenixKitEcommerce.Gettext
      ),
      Tab.new!(
        id: :admin_shop_shipping,
        label: "Shipping",
        icon: "hero-truck",
        path: "shop/shipping",
        priority: 534,
        level: :admin,
        permission: "shop.manage_settings",
        parent: :admin_shop,
        gettext_backend: PhoenixKitEcommerce.Gettext
      ),
      Tab.new!(
        id: :admin_shop_carts,
        label: "Carts",
        icon: "hero-shopping-cart",
        path: "shop/carts",
        priority: 535,
        level: :admin,
        permission: "shop.manage_carts",
        parent: :admin_shop,
        gettext_backend: PhoenixKitEcommerce.Gettext
      ),
      Tab.new!(
        id: :admin_shop_imports,
        label: "CSV Import",
        icon: "hero-cloud-arrow-up",
        path: "shop/imports",
        priority: 536,
        level: :admin,
        permission: "shop.run_imports",
        parent: :admin_shop,
        gettext_backend: PhoenixKitEcommerce.Gettext
      ),
      Tab.new!(
        id: :admin_shop_shopify_sync,
        label: "Shopify Sync",
        icon: "hero-arrow-path",
        path: "shop/shopify-sync",
        priority: 537,
        level: :admin,
        permission: "shop.run_imports",
        parent: :admin_shop,
        gettext_backend: PhoenixKitEcommerce.Gettext
      )
    ]
  end

  @impl PhoenixKit.Module
  def settings_tabs do
    [
      Tab.new!(
        id: :admin_settings_shop,
        label: "E-Commerce",
        icon: "hero-shopping-bag",
        path: "/admin/shop/settings",
        priority: 927,
        level: :admin,
        parent: :admin_settings,
        permission: "shop.manage_settings",
        gettext_backend: PhoenixKitEcommerce.Gettext
      )
    ]
  end

  @impl PhoenixKit.Module
  def user_dashboard_tabs do
    [
      Tab.new!(
        id: :dashboard_shop,
        label: "Shop",
        icon: "hero-building-storefront",
        path: "/shop",
        priority: 300,
        match: :prefix,
        group: :shop,
        gettext_backend: PhoenixKitEcommerce.Gettext
      ),
      Tab.new!(
        id: :dashboard_cart,
        label: "My Cart",
        icon: "hero-shopping-cart",
        path: "/cart",
        priority: 310,
        match: :prefix,
        group: :shop,
        gettext_backend: PhoenixKitEcommerce.Gettext
      )
    ]
  end

  @impl PhoenixKit.Module
  def route_module, do: PhoenixKitEcommerce.Web.Routes

  # All ten shop tables are core-created (V135+); this chain's V1 only
  # ADOPTS them (stamps the `pke_schema:` marker, changes no shape) and
  # owns their future evolution — see the moduledoc in
  # PhoenixKitEcommerce.Migrations.
  @impl PhoenixKit.Module
  def migration_module, do: PhoenixKitEcommerce.Migrations

  @doc """
  PhoenixKitAI translation adapters (duck-typed discovery — see
  `PhoenixKitAI.Translatables`).
  """
  def ai_translatables do
    [{PhoenixKitEcommerce.AITranslatable.resource_type(), PhoenixKitEcommerce.AITranslatable}]
  end

  # ============================================
  # PRODUCTS
  # ============================================

  @doc """
  Lists all products with optional filters.

  ## Options
  - `:status` - Filter by status (draft, active, archived)
  - `:product_type` - Filter by type (physical, digital)
  - `:category_uuid` - Filter by category
  - `:search` - Search in title and description
  - `:page` - Page number
  - `:per_page` - Items per page
  - `:preload` - Associations to preload
  """
  def list_products(opts \\ []) do
    Product
    |> apply_product_filters(opts)
    |> order_by([p], desc: p.inserted_at)
    |> maybe_preload(Keyword.get(opts, :preload))
    |> repo().all()
  end

  @doc """
  Lists products with count for pagination.
  """
  def list_products_with_count(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 25)
    offset = (page - 1) * per_page

    base_query =
      Product
      |> apply_product_filters(opts)

    total = repo().aggregate(base_query, :count)

    products =
      base_query
      |> order_by([p], desc: p.inserted_at)
      |> limit(^per_page)
      |> offset(^offset)
      |> maybe_preload(Keyword.get(opts, :preload, [:category]))
      |> repo().all()

    {products, total}
  end

  @doc """
  Lists products by their IDs.

  Returns products in the order of the provided IDs.
  """
  def list_products_by_ids([]), do: []

  def list_products_by_ids(ids) when is_list(ids) do
    Product |> where([p], p.uuid in ^ids) |> repo().all()
  end

  # ============================================
  # STOREFRONT FILTERS
  # ============================================

  @storefront_filters_key "storefront_filters"

  @doc """
  Gets storefront filter configuration from shop_config.

  Returns a list of filter definition maps with keys:
  key, type, label, enabled, position.

  Default: price filter only.
  """
  def get_storefront_filters do
    case repo().get(ShopConfig, @storefront_filters_key) do
      %ShopConfig{value: %{"filters" => filters}} when is_list(filters) ->
        filters

      _ ->
        default_storefront_filters()
    end
  end

  @doc """
  Returns only enabled storefront filters, sorted by position.
  """
  def get_enabled_storefront_filters do
    get_storefront_filters()
    |> Enum.filter(& &1["enabled"])
    |> Enum.sort_by(& &1["position"])
  end

  @doc """
  Saves storefront filter configuration.
  """
  def update_storefront_filters(filters) when is_list(filters) do
    value = %{"filters" => filters}

    case repo().get(ShopConfig, @storefront_filters_key) do
      nil ->
        %ShopConfig{}
        |> ShopConfig.changeset(%{key: @storefront_filters_key, value: value})
        |> repo().insert()

      config ->
        config
        |> ShopConfig.changeset(%{value: value})
        |> repo().update()
    end
  end

  @doc """
  Aggregates filter values for sidebar display.

  Returns a map of filter_key => aggregated data.
  For price_range: %{min: Decimal, max: Decimal}
  For vendor: [%{value: "Vendor", count: 5}, ...]
  For metadata_option: [%{value: "8 inches", count: 3}, ...]

  Options:
  - `:category_uuid` - Scope aggregation to a specific category by UUID
  """
  def aggregate_filter_values(opts \\ []) do
    filters = get_enabled_storefront_filters()
    category_uuid = Keyword.get(opts, :category_uuid)

    Enum.reduce(filters, %{}, fn filter, acc ->
      Map.put(acc, filter["key"], aggregate_single_filter(filter, category_uuid))
    end)
  end

  defp aggregate_single_filter(%{"type" => "price_range"}, category_uuid) do
    query =
      Product
      |> where([p], p.status == "active")
      |> maybe_filter_category(category_uuid)

    min_price = repo().aggregate(query, :min, :price)
    max_price = repo().aggregate(query, :max, :price)
    %{min: min_price, max: max_price}
  rescue
    _ -> %{min: nil, max: nil}
  end

  defp aggregate_single_filter(%{"type" => "vendor"}, category_uuid) do
    query =
      Product
      |> where([p], p.status == "active" and not is_nil(p.vendor) and p.vendor != "")
      |> maybe_filter_category(category_uuid)
      |> group_by([p], p.vendor)
      |> select([p], %{value: p.vendor, count: count(p.uuid)})
      |> order_by([p], desc: count(p.uuid))

    repo().all(query)
  rescue
    _ -> []
  end

  defp aggregate_single_filter(%{"type" => "metadata_option", "option_key" => key}, category_uuid)
       when is_binary(key) do
    # Query distinct option values from metadata->'_option_values'->key JSONB array
    sql = """
    SELECT val AS value, COUNT(DISTINCT p.uuid) AS count
    FROM phoenix_kit_shop_products p,
         jsonb_array_elements_text(COALESCE(p.metadata->'_option_values'->$1, '[]'::jsonb)) AS val
    WHERE p.status = 'active'
    #{if category_uuid, do: "AND p.category_uuid = $2", else: ""}
    GROUP BY val
    ORDER BY count DESC
    """

    params =
      if category_uuid do
        {:ok, uuid_bin} = Ecto.UUID.dump(category_uuid)
        [key, uuid_bin]
      else
        [key]
      end

    case repo().query(sql, params) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [value, count] -> %{value: value, count: count} end)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp aggregate_single_filter(_filter, _category_uuid), do: []

  defp maybe_filter_category(query, nil), do: query
  defp maybe_filter_category(query, uuid), do: where(query, [p], p.category_uuid == ^uuid)

  @doc """
  Discovers filterable option keys from product metadata.

  Returns a list of {key, product_count} tuples sorted by count descending.
  Used by admin UI to auto-suggest available filters.
  """
  def discover_filterable_options do
    sql = """
    SELECT key, COUNT(DISTINCT p.uuid) AS product_count
    FROM phoenix_kit_shop_products p,
         jsonb_object_keys(COALESCE(p.metadata->'_option_values', '{}'::jsonb)) AS key
    WHERE p.status = 'active'
    GROUP BY key
    ORDER BY product_count DESC
    """

    case repo().query(sql, []) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [key, count] -> %{key: key, count: count} end)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  @doc """
  Returns the default storefront filter configuration.
  """
  def default_storefront_filters do
    [
      %{
        "key" => "search",
        "type" => "search",
        "label" => "Search",
        "enabled" => true,
        "position" => 0
      },
      %{
        "key" => "price",
        "type" => "price_range",
        "label" => "Price",
        "enabled" => true,
        "position" => 1
      },
      %{
        "key" => "vendor",
        "type" => "vendor",
        "label" => "Vendor",
        "enabled" => false,
        "position" => 2
      }
    ]
  end

  @doc """
  Merges built-in default filters missing from a saved filter config.

  Configs saved before a built-in filter existed (e.g. `search`) never
  gain it on their own; this merges the absent built-ins in as disabled
  so admins can discover and enable them from the settings page without
  changing storefront behavior until they do.

  Missing filters are positioned below every saved filter's `"position"`
  (preserving their relative order from `default_storefront_filters/0`)
  rather than reusing their default position outright — a saved config
  predating the new filter can already hold that same position number, and
  a tie would fall back to list order once enabled, silently overriding
  the intended placement (e.g. `search` no longer sorting first).
  """
  def merge_missing_builtin_filters(filters) do
    # NOTE: the below-minimum positioning preserves default relative order
    # only within a single merge pass. If a future release adds a built-in
    # defined AFTER an already-merged one in default_storefront_filters/0,
    # a later pass will stack it above the earlier merge (more-negative
    # position), inverting their intended order. If a second sidebar-leading
    # built-in is ever added, renormalize positions on save instead of
    # extending this scheme.
    existing_keys = MapSet.new(filters, & &1["key"])
    min_position = filters |> Enum.map(&(&1["position"] || 0)) |> Enum.min(fn -> 0 end)

    missing =
      default_storefront_filters()
      |> Enum.reject(&MapSet.member?(existing_keys, &1["key"]))
      |> Enum.map(&Map.put(&1, "enabled", false))

    missing_count = length(missing)

    missing =
      missing
      |> Enum.with_index()
      |> Enum.map(fn {filter, index} ->
        Map.put(filter, "position", min_position - missing_count + index)
      end)

    missing ++ filters
  end

  @doc """
  Gets a product by ID or UUID.
  """
  def get_product(id, opts \\ [])

  def get_product(id, opts) when is_binary(id) do
    if UUIDUtils.valid?(id) do
      Product
      |> where([p], p.uuid == ^id)
      |> maybe_preload(Keyword.get(opts, :preload))
      |> repo().one()
    else
      nil
    end
  end

  def get_product(_, _opts), do: nil

  @doc """
  Gets a product by ID or UUID, raises if not found.
  """
  def get_product!(id, opts \\ []) do
    case get_product(id, opts) do
      nil -> raise Ecto.NoResultsError, queryable: Product
      product -> product
    end
  end

  @doc """
  Gets a product by slug.

  Supports localized slugs stored as JSONB maps.

  ## Options

    - `:language` - Language code for slug lookup (default: system default)
    - `:preload` - Associations to preload

  ## Examples

      iex> get_product_by_slug("planter")
      %Product{}

      iex> get_product_by_slug("kashpo", language: "ru")
      %Product{}
  """
  def get_product_by_slug(slug, opts \\ []) do
    language = Keyword.get(opts, :language, Translations.default_language())
    preload = Keyword.get(opts, :preload, [])

    case SlugResolver.find_product_by_slug(slug, language, preload: preload) do
      {:ok, product} -> product
      {:error, :not_found} -> nil
    end
  end

  @doc """
  Creates a new product.

  Automatically normalizes metadata (price modifiers, option values)
  before saving to ensure consistent storage format.
  """
  def create_product(attrs) do
    attrs =
      attrs
      |> MetadataValidator.normalize_product_attrs()
      |> maybe_set_default_currency()

    result =
      %Product{}
      |> Product.changeset(attrs)
      |> repo().insert()

    case result do
      {:ok, product} ->
        Events.broadcast_product_created(product)
        {:ok, product}

      error ->
        error
    end
  end

  # §7.3/N3: `product.ex`/`shipping_method.ex`'s `:currency` lost its
  # `default: "USD"` literal (both columns allow NULL, so nothing forced
  # a real value at the DB level either). Every creation path funnels
  # through here — the admin forms, the CSV/Shopify importer
  # (`import/shopify_csv.ex`, direct and via `upsert_product/1`) — so
  # this is the one place a caller that omits `:currency` gets the
  # shop's base currency instead of a silent `nil` reaching the insert.
  # A caller that DOES pass `:currency` is never overridden.
  #
  # Matches the incoming map's key style (atom vs string) before adding
  # the fallback: `Ecto.Changeset.cast/3` raises on a mixed-key map, and
  # callers disagree — LiveView form params are string-keyed, the CSV
  # importer's `ProductTransformer.transform/5` output is atom-keyed.
  defp maybe_set_default_currency(attrs) do
    if Map.has_key?(attrs, :currency) || Map.has_key?(attrs, "currency") do
      attrs
    else
      Map.put(attrs, currency_key(attrs), get_default_currency_code())
    end
  end

  defp currency_key(attrs) do
    if Enum.any?(attrs, fn {k, _} -> is_binary(k) end), do: "currency", else: :currency
  end

  @doc """
  Updates a product.

  Automatically normalizes metadata (price modifiers, option values)
  before saving to ensure consistent storage format.
  """
  def update_product(%Product{} = product, attrs) do
    attrs = MetadataValidator.normalize_product_attrs(attrs)

    result =
      product
      |> Product.changeset(attrs)
      |> repo().update()

    case result do
      {:ok, updated_product} ->
        Events.broadcast_product_updated(updated_product)
        {:ok, updated_product}

      error ->
        error
    end
  end

  @doc """
  Deletes a product.
  """
  def delete_product(%Product{} = product) do
    product_uuid = product.uuid

    case repo().delete(product) do
      {:ok, _} = result ->
        Events.broadcast_product_deleted(product_uuid)
        result

      error ->
        error
    end
  end

  @doc """
  Returns a changeset for product form.
  """
  def change_product(%Product{} = product, attrs \\ %{}) do
    Product.changeset(product, attrs)
  end

  @doc """
  Bulk update product status.
  Returns count of updated products.
  """
  def bulk_update_product_status(ids, status) when is_list(ids) and is_binary(status) do
    query = Product |> where([p], p.uuid in ^ids)

    {count, _} =
      query
      |> repo().update_all(set: [status: status, updated_at: UtilsDate.utc_now()])

    if count > 0 do
      Events.broadcast_products_bulk_status_changed(ids, status)
    end

    count
  end

  @doc """
  Bulk update product category.
  Returns count of updated products.
  """
  def bulk_update_product_category(uuids, category_uuid) when is_list(uuids) do
    cat_uuid =
      if category_uuid do
        case repo().get_by(Category, uuid: category_uuid) do
          nil -> nil
          cat -> cat.uuid
        end
      else
        nil
      end

    # Don't unassign category if a specific category was requested but not found
    if category_uuid && is_nil(cat_uuid) do
      0
    else
      query = Product |> where([p], p.uuid in ^uuids)

      {count, _} =
        query
        |> repo().update_all(
          set: [
            category_uuid: cat_uuid,
            updated_at: UtilsDate.utc_now()
          ]
        )

      count
    end
  end

  @doc """
  Bulk delete products.
  Returns count of deleted products.
  """
  def bulk_delete_products(ids) when is_list(ids) do
    query = Product |> where([p], p.uuid in ^ids)

    {count, _} = repo().delete_all(query)

    count
  end

  @doc """
  Collects all storage file UUIDs associated with a single product.
  """
  def collect_product_file_uuids(%Product{} = product) do
    [product.featured_image_uuid, product.file_uuid | product.image_uuids || []]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc """
  Collects all storage file UUIDs for a list of product UUIDs.
  """
  def collect_products_file_uuids(product_uuids) when is_list(product_uuids) do
    from(p in Product,
      where: p.uuid in ^product_uuids,
      select: %{
        featured_image_uuid: p.featured_image_uuid,
        file_uuid: p.file_uuid,
        image_uuids: p.image_uuids
      }
    )
    |> repo().all()
    |> Enum.flat_map(fn p ->
      [p.featured_image_uuid, p.file_uuid | p.image_uuids || []]
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # ============================================
  # OPTIONS-BASED PRICING
  # ============================================

  @doc """
  Calculates the final price for a product based on selected specifications.

  Applies option price modifiers (fixed and percent) to the base price.
  Fixed modifiers are applied first, then percent modifiers.

  ## Example

      product = %Product{price: Decimal.new("20.00")}
      selected_specs = %{"material" => "PETG", "finish" => "Premium"}

      # If PETG has +$10 fixed and Premium has +20% percent:
      calculate_product_price(product, selected_specs)
      # => Decimal.new("36.00")  # ($20 + $10) * 1.20
  """
  def calculate_product_price(%Product{} = product, selected_specs) when is_map(selected_specs) do
    base_price = product.price || Decimal.new("0")
    metadata = product.metadata || %{}

    # Get price-affecting options for this product
    price_affecting_specs = Options.get_price_affecting_specs_for_product(product)

    # Calculate final price with fixed and percent modifiers
    # Pass metadata to apply custom per-product price overrides
    Options.calculate_final_price(price_affecting_specs, selected_specs, base_price, metadata)
  end

  def calculate_product_price(%Product{} = product, _) do
    product.price || Decimal.new("0")
  end

  @doc """
  Gets the price range for a product based on option modifiers.

  Returns `{min_price, max_price}` where:
  - min_price = minimum possible price (base + min modifiers)
  - max_price = maximum possible price (base + max modifiers)

  ## Example

      # Product with base $20, material options (0, +5, +10), finish options (0%, +20%)
      get_price_range(product)
      # => {Decimal.new("20.00"), Decimal.new("36.00")}
  """
  def get_price_range(%Product{} = product) do
    base_price = product.price || Decimal.new("0")
    metadata = product.metadata || %{}

    # Get price-affecting options
    price_affecting_specs = Options.get_price_affecting_specs_for_product(product)

    if Enum.empty?(price_affecting_specs) do
      {base_price, base_price}
    else
      # Pass metadata to apply custom per-product price overrides
      Options.get_price_range(price_affecting_specs, base_price, metadata)
    end
  end

  @doc """
  Formats the product price for catalog display.

  Returns:
  - "$19.99" for products without price-affecting options
  - "From $19.99" if options have different price modifiers
  - "$19.99 - $38.00" for range display
  """
  def format_product_price(%Product{} = product, currency, style \\ :from) do
    {min_price, max_price} = get_price_range(product)

    format_fn = fn price ->
      case currency do
        %{} = c -> Currency.format_amount(price, c)
        nil -> "$#{Decimal.round(price, 2)}"
      end
    end

    if Decimal.compare(min_price, max_price) == :eq do
      format_fn.(min_price)
    else
      case style do
        :from -> "From #{format_fn.(min_price)}"
        :range -> "#{format_fn.(min_price)} - #{format_fn.(max_price)}"
      end
    end
  end

  @doc """
  Gets price-affecting options for a product.

  Convenience wrapper around `Options.get_price_affecting_specs_for_product/1`.
  """
  def get_price_affecting_specs(%Product{} = product) do
    Options.get_price_affecting_specs_for_product(product)
  end

  @doc """
  Gets all selectable options for a product (for UI display).

  Returns all select/multiselect options regardless of whether they affect price.
  This includes options like Color that may not have price modifiers but should
  still be selectable in the UI.

  Convenience wrapper around `Options.get_selectable_specs_for_product/1`.
  """
  def get_selectable_specs(%Product{} = product) do
    Options.get_selectable_specs_for_product(product)
  end

  # ============================================
  # CATEGORIES
  # ============================================

  @doc """
  Lists all categories.

  ## Options
  - `:parent_uuid` - Filter by parent UUID (nil for root categories)
  - `:status` - Filter by status: "active", "hidden", "archived", or list of statuses
  - `:search` - Search in name
  - `:preload` - Associations to preload
  """
  def list_categories(opts \\ []) do
    Category
    |> apply_category_filters(opts)
    |> order_by([c], [c.position, c.name])
    |> maybe_preload(Keyword.get(opts, :preload))
    |> repo().all()
  end

  @doc """
  Returns a map of category_uuid => product_count for all categories.
  """
  def product_counts_by_category do
    Product
    |> where([p], not is_nil(p.category_uuid))
    |> group_by([p], p.category_uuid)
    |> select([p], {p.category_uuid, count(p.uuid)})
    |> repo().all()
    |> Map.new()
  rescue
    e ->
      Logger.warning("Failed to load product counts by category: #{inspect(e)}")
      %{}
  end

  @doc """
  Lists root categories (no parent).
  """
  def list_root_categories(opts \\ []) do
    list_categories(Keyword.put(opts, :parent_uuid, nil))
  end

  @doc """
  Lists active categories only (for storefront display).
  """
  def list_active_categories(opts \\ []) do
    list_categories(Keyword.put(opts, :status, "active"))
  end

  @doc """
  Lists categories visible in storefront navigation/menu.
  Only active categories appear in menus.
  Semantic alias for list_active_categories/1.
  """
  def list_menu_categories(opts \\ []) do
    list_active_categories(opts)
  end

  @doc """
  Lists categories whose products are visible in storefront.
  Includes both active and unlisted categories.
  Use for product filtering, not for navigation menus.
  """
  def list_visible_categories(opts \\ []) do
    list_categories(Keyword.put(opts, :status, ["active", "unlisted"]))
  end

  @doc """
  Lists categories with count for pagination.
  """
  def list_categories_with_count(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 25)
    offset = (page - 1) * per_page

    base_query =
      Category
      |> apply_category_filters(opts)

    total = repo().aggregate(base_query, :count)

    categories =
      base_query
      |> order_by([c], [c.position, c.name])
      |> limit(^per_page)
      |> offset(^offset)
      |> maybe_preload(Keyword.get(opts, :preload))
      |> repo().all()

    {categories, total}
  end

  @doc """
  Gets a category by ID or UUID.
  """
  def get_category(id, opts \\ [])

  def get_category(id, opts) when is_binary(id) do
    if UUIDUtils.valid?(id) do
      Category
      |> where([c], c.uuid == ^id)
      |> maybe_preload(Keyword.get(opts, :preload))
      |> repo().one()
    else
      nil
    end
  end

  def get_category(_, _opts), do: nil

  @doc """
  Gets a category by ID or UUID, raises if not found.
  """
  def get_category!(id, opts \\ []) do
    case get_category(id, opts) do
      nil -> raise Ecto.NoResultsError, queryable: Category
      category -> category
    end
  end

  @doc """
  Gets a category by slug.

  Supports localized slugs stored as JSONB maps.

  ## Options

    - `:language` - Language code for slug lookup (default: system default)
    - `:preload` - Associations to preload

  ## Examples

      iex> get_category_by_slug("planters")
      %Category{}

      iex> get_category_by_slug("kashpo", language: "ru")
      %Category{}
  """
  def get_category_by_slug(slug, opts \\ []) do
    language = Keyword.get(opts, :language, Translations.default_language())
    preload = Keyword.get(opts, :preload, [])

    case SlugResolver.find_category_by_slug(slug, language, preload: preload) do
      {:ok, category} -> category
      {:error, :not_found} -> nil
    end
  end

  @doc """
  Creates a new category.
  """
  def create_category(attrs) do
    result =
      %Category{}
      |> Category.changeset(attrs)
      |> repo().insert()

    case result do
      {:ok, category} ->
        Events.broadcast_category_created(category)
        {:ok, category}

      error ->
        error
    end
  end

  @doc """
  Updates a category.
  """
  def update_category(%Category{} = category, attrs) do
    result =
      category
      |> Category.changeset(attrs)
      |> repo().update()

    case result do
      {:ok, updated_category} ->
        Events.broadcast_category_updated(updated_category)
        {:ok, updated_category}

      error ->
        error
    end
  end

  @doc """
  Lists categories that have no products assigned.
  """
  def list_empty_categories do
    subquery = from(p in Product, select: p.category_uuid, where: not is_nil(p.category_uuid))

    from(c in Category, where: c.uuid not in subquery(subquery))
    |> repo().all()
  end

  @doc """
  Deletes a category.
  """
  def delete_category(%Category{} = category) do
    category_uuid = category.uuid

    case repo().delete(category) do
      {:ok, _} = result ->
        Events.broadcast_category_deleted(category_uuid)
        result

      error ->
        error
    end
  end

  @doc """
  Returns a changeset for category form.
  """
  def change_category(%Category{} = category, attrs \\ %{}) do
    Category.changeset(category, attrs)
  end

  @doc """
  Bulk update category status.
  Returns count of updated categories.
  """
  def bulk_update_category_status(ids, status) when is_list(ids) and is_binary(status) do
    query = Category |> where([c], c.uuid in ^ids)

    {count, _} =
      query
      |> repo().update_all(set: [status: status, updated_at: UtilsDate.utc_now()])

    if count > 0 do
      Events.broadcast_categories_bulk_status_changed(ids, status)
    end

    count
  end

  @doc """
  Bulk update category parent.
  Returns count of updated categories. Excludes the target parent from the update set
  to prevent self-reference. Uses a single UPDATE with subquery to resolve parent_uuid.
  """
  def bulk_update_category_parent(ids, parent_uuid) when is_list(ids) do
    # Exclude the target parent and its ancestors from update set to prevent cycles
    ids_to_update =
      if parent_uuid do
        ancestors = collect_ancestor_uuids(parent_uuid, %{})

        Enum.reject(ids, &(&1 == parent_uuid or Map.has_key?(ancestors, &1)))
      else
        ids
      end

    if ids_to_update == [] do
      0
    else
      now = UtilsDate.utc_now()

      {count, _} =
        if is_nil(parent_uuid) do
          # Make root — set parent to nil
          Category
          |> where([c], c.uuid in ^ids_to_update)
          |> repo().update_all(set: [parent_uuid: nil, updated_at: now])
        else
          # Set parent_uuid directly
          Category
          |> where([c], c.uuid in ^ids_to_update)
          |> repo().update_all(set: [parent_uuid: parent_uuid, updated_at: now])
        end

      if count > 0 do
        Events.broadcast_categories_bulk_parent_changed(ids_to_update, parent_uuid)
      end

      count
    end
  end

  defp collect_ancestor_uuids(nil, acc), do: acc

  defp collect_ancestor_uuids(uuid, acc) do
    if Map.has_key?(acc, uuid) do
      acc
    else
      case repo().get_by(Category, uuid: uuid) do
        nil -> acc
        %{parent_uuid: parent} -> collect_ancestor_uuids(parent, Map.put(acc, uuid, true))
      end
    end
  end

  @doc """
  Bulk delete categories.
  Returns count of deleted categories. Nullifies category references on orphaned products.
  """
  def bulk_delete_categories(ids) when is_list(ids) do
    # Nullify category references on products to prevent orphans
    orphan_query = Product |> where([p], p.category_uuid in ^ids)

    repo().update_all(orphan_query,
      set: [category_uuid: nil, updated_at: UtilsDate.utc_now()]
    )

    # Delete categories
    category_query = Category |> where([c], c.uuid in ^ids)

    {count, _} = repo().delete_all(category_query)

    if count > 0 do
      Events.broadcast_categories_bulk_deleted(ids)
    end

    count
  end

  @doc """
  Returns categories as options for select input.
  Returns list of {localized_name, id} tuples.
  """
  def category_options do
    default_lang = Translations.default_language()

    Category
    |> order_by([c], [c.position, c.name])
    |> repo().all()
    |> Enum.map(fn cat ->
      {Translations.get(cat, :name, default_lang), cat.uuid}
    end)
  end

  @doc """
  Ensures a category has a featured_product_uuid set.

  If the category has no image_uuid and no featured_product_uuid, auto-detects the
  first active product with an image and saves it. Returns the (possibly updated)
  category with :featured_product preloaded.
  """
  def ensure_featured_product(
        %Category{featured_product_uuid: nil, image_uuid: nil, uuid: cat_uuid} = cat
      ) do
    case find_default_featured_product(cat_uuid) do
      nil ->
        cat

      product_uuid ->
        {:ok, updated} =
          update_category(cat, %{
            featured_product_uuid: product_uuid
          })

        repo().preload(updated, :featured_product)
    end
  end

  def ensure_featured_product(cat), do: cat

  defp find_default_featured_product(category_uuid) do
    from(p in Product,
      where: p.category_uuid == ^category_uuid,
      where: p.status == "active",
      where:
        not is_nil(p.featured_image_uuid) or
          (not is_nil(p.featured_image) and p.featured_image != ""),
      order_by: [asc: p.inserted_at],
      limit: 1,
      select: p.uuid
    )
    |> repo().one()
  end

  @doc """
  Returns a list of {name, id} tuples for products in a category that have images.
  Used for the featured product dropdown in the admin category form.
  """
  def list_category_product_options(category_uuid) do
    default_lang = Translations.default_language()

    query = category_product_options_query(category_uuid)

    if query do
      query
      |> repo().all()
      |> Enum.map(fn {title_map, uuid} ->
        {extract_product_name(title_map, uuid, default_lang), uuid}
      end)
    else
      []
    end
  end

  defp extract_product_name(%{} = map, _uuid, default_lang) do
    map[default_lang] || map |> Map.values() |> List.first()
  end

  defp extract_product_name(_, uuid, _default_lang), do: "Product #{uuid}"

  defp category_product_options_query(category_uuid) when is_binary(category_uuid) do
    if match?({:ok, _}, Ecto.UUID.cast(category_uuid)) do
      from(p in Product,
        where: p.category_uuid == ^category_uuid,
        where: p.status == "active",
        where:
          not is_nil(p.featured_image_uuid) or
            (not is_nil(p.featured_image) and p.featured_image != ""),
        order_by: [asc: p.uuid],
        select: {p.title, p.uuid}
      )
    end
  end

  defp category_product_options_query(_), do: nil

  # ============================================
  # SHIPPING METHODS
  # ============================================

  @doc """
  Lists all shipping methods.

  ## Options
  - `:active` - Filter by active status
  - `:country` - Filter by country availability
  """
  def list_shipping_methods(opts \\ []) do
    ShippingMethod
    |> filter_shipping_by_active(Keyword.get(opts, :active))
    |> order_by([s], [s.position, s.name])
    |> repo().all()
  end

  @doc """
  Whether any line in the cart needs physical shipping.

  Reads the `"requires_shipping"` flag snapshotted onto each cart item at
  add time. Rows created before the snapshot existed fall back to the live
  product's flag (batched, one query); a line whose product is GONE counts
  as requiring shipping — the conservative default, since charging shipping
  on a digital line is a smaller failure than shipping-free physical goods.

  Digital-only carts skip the shipping-method requirement, the shipping
  charge, and the shipping line on the resulting order.
  """
  def cart_requires_shipping?(%Cart{} = cart) do
    cart |> cart_items_loaded() |> items_require_shipping?()
  end

  defp cart_items_loaded(%Cart{items: items}) when is_list(items), do: items

  defp cart_items_loaded(%Cart{uuid: uuid}) do
    CartItem |> where([i], i.cart_uuid == ^uuid) |> repo().all()
  end

  defp items_require_shipping?(items) do
    {known, unknown} =
      Enum.split_with(items, fn item ->
        is_boolean((item.metadata || %{})["requires_shipping"])
      end)

    Enum.any?(known, & &1.metadata["requires_shipping"]) or
      legacy_items_require_shipping?(unknown)
  end

  defp legacy_items_require_shipping?([]), do: false

  defp legacy_items_require_shipping?(items) do
    product_uuids = items |> Enum.map(& &1.product_uuid) |> Enum.reject(&is_nil/1)

    flags =
      Product
      |> where([p], p.uuid in ^product_uuids)
      |> select([p], {p.uuid, p.requires_shipping})
      |> repo().all()
      |> Map.new()

    Enum.any?(items, fn item ->
      # A line without a snapshot AND without a live product requires
      # shipping by default.
      Map.get(flags, item.product_uuid, true)
    end)
  end

  # Weight that participates in shipping eligibility and pricing - lines
  # that don't ship contribute none, so a heavy digital bundle can't push
  # a mixed cart over a method's weight cap.
  defp shippable_weight_grams(items) do
    {known, unknown} =
      Enum.split_with(items, fn item ->
        is_boolean((item.metadata || %{})["requires_shipping"])
      end)

    known_weight =
      known
      |> Enum.filter(& &1.metadata["requires_shipping"])
      |> Enum.reduce(0, fn i, acc -> acc + (i.weight_grams || 0) * i.quantity end)

    # Legacy rows (no snapshot) keep their weight in the shippable total -
    # matching the conservative "requires shipping" default above.
    known_weight +
      Enum.reduce(unknown, 0, fn i, acc -> acc + (i.weight_grams || 0) * i.quantity end)
  end

  @doc """
  Gets available shipping methods for a cart.
  Filters by weight, subtotal, and country.
  """
  def get_available_shipping_methods(%Cart{} = cart) do
    shippable_weight = cart |> cart_items_loaded() |> shippable_weight_grams()

    ShippingMethod
    |> where([s], s.active == true)
    |> order_by([s], [s.position, s.name])
    |> repo().all()
    |> Enum.filter(fn method ->
      ShippingMethod.available_for?(method, %{
        weight_grams: shippable_weight,
        subtotal: cart.subtotal || Decimal.new("0"),
        country: cart.shipping_country
      })
    end)
  end

  @doc """
  Whether this cart may convert without a shipping method, and why.

  The country checked is the effective checkout country - `cart.shipping_country`
  as of `apply_checkout_shipping_country/2`, which must have already run.
  Returns `false` (never skippable) when the mode is `:off`, or when the
  mode is `:fallback` but a method still covers the cart's country - that
  case stays a hard requirement, not a fallback.
  """
  @spec shipping_skippable?(Cart.t()) ::
          false | {:skip, :always} | {:skip, :no_method_for_country}
  def shipping_skippable?(%Cart{} = cart) do
    case shipping_skip_mode() do
      :always ->
        {:skip, :always}

      :fallback ->
        if get_available_shipping_methods(cart) == [] do
          {:skip, :no_method_for_country}
        else
          false
        end

      :off ->
        false
    end
  end

  @doc """
  Gets a shipping method by ID or UUID.
  """
  def get_shipping_method(id) when is_binary(id) do
    if UUIDUtils.valid?(id) do
      repo().get_by(ShippingMethod, uuid: id)
    else
      nil
    end
  end

  def get_shipping_method(_), do: nil

  @doc """
  Gets a shipping method by ID or UUID, raises if not found.
  """
  def get_shipping_method!(id) do
    case get_shipping_method(id) do
      nil -> raise Ecto.NoResultsError, queryable: ShippingMethod
      method -> method
    end
  end

  @doc """
  Gets a shipping method by slug.
  """
  def get_shipping_method_by_slug(slug) do
    ShippingMethod
    |> where([s], s.slug == ^slug)
    |> repo().one()
  end

  @doc """
  Creates a new shipping method.
  """
  def create_shipping_method(attrs) do
    attrs = maybe_set_default_currency(attrs)

    %ShippingMethod{}
    |> ShippingMethod.changeset(attrs)
    |> repo().insert()
  end

  @doc """
  Updates a shipping method.
  """
  def update_shipping_method(%ShippingMethod{} = method, attrs) do
    method
    |> ShippingMethod.changeset(attrs)
    |> repo().update()
  end

  @doc """
  Deletes a shipping method.
  """
  def delete_shipping_method(%ShippingMethod{} = method) do
    repo().delete(method)
  end

  @doc """
  Returns a changeset for shipping method form.
  """
  def change_shipping_method(%ShippingMethod{} = method, attrs \\ %{}) do
    ShippingMethod.changeset(method, attrs)
  end

  # ============================================
  # CARTS
  # ============================================

  @doc """
  Gets or creates a cart for the current user/session.

  ## Options
  - `:user_uuid` - User UUID (for authenticated users)
  - `:session_id` - Session ID (for guests)
  """
  def get_or_create_cart(opts) do
    user_uuid = Keyword.get(opts, :user_uuid)
    session_id = Keyword.get(opts, :session_id)

    case find_active_cart(user_uuid: user_uuid, session_id: session_id) do
      nil -> create_cart(user_uuid: user_uuid, session_id: session_id)
      cart -> {:ok, cart}
    end
  end

  @doc """
  Finds active cart by user_uuid or session_id.

  Search priority:
  1. If user_uuid is provided, search by user_uuid first
  2. If not found and session_id is provided, search by session_id (handles guest->login transition)
  3. If only session_id is provided, search by session_id with no user_uuid
  """
  def find_active_cart(opts) do
    user_uuid = Keyword.get(opts, :user_uuid)
    session_id = Keyword.get(opts, :session_id)

    base_query =
      Cart
      |> where([c], c.status == "active")
      |> preload([:items, :shipping_method])

    cond do
      not is_nil(user_uuid) ->
        # First try to find by user_uuid
        case base_query |> where([c], c.user_uuid == ^user_uuid) |> repo().one() do
          nil when not is_nil(session_id) ->
            # Fallback: a cart this session started before logging in.
            #
            # `is_nil(c.user_uuid)` is load-bearing and was missing. A
            # logged-in user's cart carries BOTH user_uuid and session_id,
            # and the shop_session_id cookie outlives logout by 30 days —
            # so on a shared browser, the next user to log in without a cart
            # of their own matched the PREVIOUS user's cart here and could
            # edit it and check out against it. Only claim carts that are
            # still unowned.
            base_query
            |> where([c], c.session_id == ^session_id and is_nil(c.user_uuid))
            |> repo().one()

          result ->
            result
        end

      not is_nil(session_id) ->
        # Guest user - search by session_id only
        base_query
        |> where([c], c.session_id == ^session_id and is_nil(c.user_uuid))
        |> repo().one()

      true ->
        # No identity provided
        nil
    end
  end

  @doc """
  Creates a new cart.
  """
  def create_cart(opts) do
    attrs = %{
      user_uuid: Keyword.get(opts, :user_uuid),
      session_id: Keyword.get(opts, :session_id),
      currency: get_default_currency_code()
    }

    case %Cart{} |> Cart.changeset(attrs) |> repo().insert() do
      {:ok, cart} -> {:ok, repo().preload(cart, [:items, :shipping_method])}
      error -> error
    end
  end

  @doc """
  Atomically claims a one-shot boolean flag on the cart's metadata.

  Returns `true` exactly once per (cart, flag) — the caller that wins the
  claim; `false` for everyone after (or on any error). Used to deduplicate
  per-cart notifications under concurrent tabs.
  """
  def claim_cart_flag(%Cart{uuid: uuid}, flag) when is_binary(flag) do
    {count, _} =
      from(c in Cart,
        where: c.uuid == ^uuid,
        where: fragment("NOT (COALESCE(metadata, '{}'::jsonb) \\? ?)", ^flag),
        update: [
          set: [
            metadata:
              fragment(
                "COALESCE(metadata, '{}'::jsonb) || jsonb_build_object(?::text, true)",
                ^flag
              )
          ]
        ]
      )
      |> repo().update_all([])

    count == 1
  rescue
    error ->
      Logger.warning("[Shop] claim_cart_flag failed: #{inspect(error)}")
      false
  end

  @doc """
  Gets a cart by ID or UUID with items preloaded.
  """
  def get_cart(uuid) when is_binary(uuid) do
    if UUIDUtils.valid?(uuid) do
      Cart
      |> where([c], c.uuid == ^uuid)
      |> preload([:items, :shipping_method])
      |> repo().one()
    else
      nil
    end
  end

  def get_cart(_), do: nil

  @doc """
  Whether any cart exists for this shop session id.

  Used by `PhoenixKitEcommerce.Web.Plugs.ShopSession` to decide whether an
  unsigned, pre-migration cookie names a real session worth adopting.
  Existence only — no cart is loaded and nothing is authorized by this.
  """
  @spec session_has_cart?(String.t() | any()) :: boolean()
  def session_has_cart?(session_id) when is_binary(session_id) and session_id != "" do
    # Deliberately narrow. The adopted id is a CART identity, so it may only
    # be adopted for a cart that is still a live GUEST cart:
    #
    #   * `status == "active"` — a converted or abandoned cart is finished
    #     business, and matching one would keep the migration window open
    #     forever (nothing deletes carts; `mark_abandoned_carts/1` only
    #     flips a status and is wired to no cron).
    #   * `is_nil(user_uuid)` — a cart already claimed by an account must
    #     never be reachable by presenting an unsigned cookie.
    Cart
    |> where([c], c.session_id == ^session_id)
    |> where([c], c.status == "active" and is_nil(c.user_uuid))
    |> limit(1)
    |> select([c], 1)
    |> repo().one()
    |> is_nil()
    |> Kernel.not()
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  def session_has_cart?(_), do: false

  @doc """
  Moves a live guest cart from one shop-session id to another.

  Used by the pre-signing cookie migration. The plug mints a FRESH id and
  re-keys the cart onto it, rather than re-signing whatever the client
  presented — re-signing a replayed value would have turned it into a
  fully trusted session on the very next request, which is the capability
  the signing exists to prevent.

  Scoped to active, unclaimed carts for the same reason `session_has_cart?/1`
  is: a converted or account-owned cart must never be re-keyed by an
  unsigned cookie. Returns `:ok` when exactly one cart moved.
  """
  @spec rekey_cart_session(String.t(), String.t()) :: :ok | :error
  def rekey_cart_session(from_id, to_id)
      when is_binary(from_id) and is_binary(to_id) and from_id != "" and to_id != "" do
    {count, _} =
      Cart
      |> where([c], c.session_id == ^from_id)
      |> where([c], c.status == "active" and is_nil(c.user_uuid))
      |> repo().update_all(set: [session_id: to_id])

    if count > 0, do: :ok, else: :error
  rescue
    _ -> :error
  catch
    :exit, _ -> :error
  end

  def rekey_cart_session(_from, _to), do: :error

  @doc """
  Returns just the `session_id` of a cart, without loading items.

  Used to authorize order confirmation pages for orders placed BEFORE
  `metadata["session_id"]` was recorded on the order itself. Those orders
  still carry `metadata["cart_uuid"]`, and the cart row survives
  conversion (`mark_cart_converted/2` flips its status, it is never
  deleted) with its `session_id` intact — so the placing session is still
  recoverable for them.

  Deliberately a narrow `select` rather than `get_cart/1`: this runs on a
  page load purely to compare one string, and `get_cart/1` preloads items
  and the shipping method.
  """
  @spec cart_session_id(String.t() | any()) :: String.t() | nil
  def cart_session_id(uuid) when is_binary(uuid) do
    if UUIDUtils.valid?(uuid) do
      Cart
      |> where([c], c.uuid == ^uuid)
      |> select([c], c.session_id)
      |> repo().one()
    end
  end

  def cart_session_id(_), do: nil

  @doc """
  Gets a cart by ID or UUID, raises if not found.
  """
  def get_cart!(id) do
    case get_cart(id) do
      nil -> raise Ecto.NoResultsError, queryable: Cart
      cart -> cart
    end
  end

  @doc """
  Adds item to cart.

  ## Options
  - `:selected_specs` - Map of selected specifications (for dynamic pricing)

  ## Examples

      # Add simple product
      add_to_cart(cart, product, 2)

      # Add product with specification-based pricing
      add_to_cart(cart, product, 1, selected_specs: %{"material" => "PETG", "color" => "Gold"})
  """
  def add_to_cart(cart, product, quantity \\ 1, opts \\ [])

  def add_to_cart(%Cart{} = cart, %Product{} = product, quantity, opts) when is_list(opts) do
    selected_specs = Keyword.get(opts, :selected_specs, %{})
    skip_validation = Keyword.get(opts, :skip_spec_validation, false)
    language = Keyword.get(opts, :language)

    # The disabled check lives in the CONTEXT, not only the LiveView mounts:
    # a LiveView connected before an admin flipped the switch can still send
    # events, and the mount gate cannot reach it.
    with :ok <- validate_shop_enabled(),
         :ok <- validate_cart_currency(cart, product),
         :ok <- maybe_validate_specs(product, selected_specs, skip_validation) do
      if map_size(selected_specs) > 0 do
        add_product_with_specs_to_cart(cart, product, quantity, selected_specs, language)
      else
        add_simple_product_to_cart(cart, product, quantity, language)
      end
    end
  end

  def add_to_cart(%Cart{} = cart, %Product{} = product, quantity, _opts)
      when is_integer(quantity) do
    with :ok <- validate_shop_enabled(),
         :ok <- validate_cart_currency(cart, product) do
      add_simple_product_to_cart(cart, product, quantity, nil)
    end
  end

  defp validate_shop_enabled do
    if enabled?(), do: :ok, else: {:error, :shop_disabled}
  end

  # Cart totals sum line decimals in the CART's currency frame, so every
  # line must be snapshotted in that frame. A product whose own currency
  # differs (usually the schema's "USD" default on a non-USD shop — the
  # importers never set the field) is logged, not rejected: prices are
  # entered thinking in the shop currency, and rejecting would brick every
  # existing catalog that carries the stale default.
  defp validate_cart_currency(%Cart{currency: cart_currency}, %Product{} = product) do
    if is_binary(product.currency) and is_binary(cart_currency) and
         product.currency != cart_currency do
      require Logger

      Logger.warning(
        "[Shop] product #{product.uuid} carries currency #{product.currency} " <>
          "but the cart is #{cart_currency}; the amount is charged in #{cart_currency}"
      )
    end

    :ok
  end

  # A product must still be purchasable AT THE LOCKED READ - the page the
  # shopper is holding may predate an archive/bulk-archive (those broadcast
  # on a topic the product page does not subscribe to), and mount-time
  # checks cannot see that.
  defp validate_locked_product_purchasable!(repo, %Product{status: status} = product) do
    if status != "active" do
      repo.rollback({:product_not_available, product.uuid})
    end

    :ok
  end

  defp add_simple_product_to_cart(cart, product, quantity, language) do
    result =
      repo().transaction(fn ->
        # Lock product row to prevent price changes during cart update
        # This ensures price snapshot is consistent with current product state
        locked_product =
          Product
          |> where([p], p.uuid == ^product.uuid)
          |> lock("FOR UPDATE")
          |> repo().one!()

        validate_locked_product_purchasable!(repo(), locked_product)

        # Use unified price calculation path (same as add_product_with_specs_to_cart)
        # With empty specs this returns base_price, but allows future extensibility
        calculated_price = calculate_product_price(locked_product, %{})

        # Check if product already in cart (without specs)
        existing = find_cart_item_by_specs(cart.uuid, product.uuid, %{})

        item =
          case existing do
            nil ->
              # Create new item with calculated price
              attrs =
                CartItem.from_product(locked_product, quantity,
                  language: language,
                  currency: cart.currency
                )
                |> Map.put(:cart_uuid, cart.uuid)
                |> Map.put(:unit_price, calculated_price)

              %CartItem{} |> CartItem.changeset(attrs) |> repo().insert!()

            item ->
              # Update quantity
              new_qty = item.quantity + quantity
              item |> CartItem.changeset(%{quantity: new_qty}) |> repo().update!()
          end

        # Recalculate totals
        updated_cart = recalculate_cart_totals!(cart)
        {updated_cart, item}
      end)

    case result do
      {:ok, {updated_cart, item}} ->
        Events.broadcast_item_added(updated_cart, item)
        PhoenixKitEcommerce.Notifications.cart_item_added(updated_cart, item, product)
        {:ok, updated_cart}

      error ->
        error
    end
  end

  defp add_product_with_specs_to_cart(cart, product, quantity, selected_specs, language) do
    result =
      repo().transaction(fn ->
        # Lock product row to prevent price/metadata changes during cart update
        locked_product =
          Product
          |> where([p], p.uuid == ^product.uuid)
          |> lock("FOR UPDATE")
          |> repo().one!()

        validate_locked_product_purchasable!(repo(), locked_product)

        # Calculate price with spec modifiers using locked product state
        calculated_price = calculate_product_price(locked_product, selected_specs)

        # Check if same product with same specs already in cart
        existing = find_cart_item_by_specs(cart.uuid, product.uuid, selected_specs)

        item =
          case existing do
            nil ->
              # Create new item with specs and calculated price
              attrs =
                CartItem.from_product(locked_product, quantity,
                  language: language,
                  currency: cart.currency
                )
                |> Map.put(:cart_uuid, cart.uuid)
                |> Map.put(:unit_price, calculated_price)
                |> Map.put(:selected_specs, selected_specs)

              %CartItem{} |> CartItem.changeset(attrs) |> repo().insert!()

            item ->
              # Update quantity (price already frozen from first add)
              new_qty = item.quantity + quantity
              item |> CartItem.changeset(%{quantity: new_qty}) |> repo().update!()
          end

        # Recalculate totals
        updated_cart = recalculate_cart_totals!(cart)
        {updated_cart, item}
      end)

    case result do
      {:ok, {updated_cart, item}} ->
        Events.broadcast_item_added(updated_cart, item)
        PhoenixKitEcommerce.Notifications.cart_item_added(updated_cart, item, product)
        {:ok, updated_cart}

      error ->
        error
    end
  end

  # ============================================
  # SELECTED SPECS VALIDATION
  # ============================================

  defp maybe_validate_specs(_product, _specs, true), do: :ok
  defp maybe_validate_specs(_product, specs, _skip) when specs == %{}, do: :ok

  defp maybe_validate_specs(product, selected_specs, _skip) do
    validate_selected_specs(product, selected_specs)
  end

  @doc """
  Validates selected_specs against product's option schema.

  Checks:
  - All spec keys exist in the option schema
  - All spec values are in allowed values list (if defined)
  - All required options have values

  ## Returns

  - `:ok` - All specs are valid
  - `{:error, :unknown_option_key, key}` - Key not in schema
  - `{:error, :invalid_option_value, %{key: key, value: value, allowed: list}}` - Value not allowed
  - `{:error, :missing_required_option, key}` - Required option not provided

  ## Examples

      iex> validate_selected_specs(product, %{"material" => "PETG"})
      :ok

      iex> validate_selected_specs(product, %{"material" => "Unobtainium"})
      {:error, :invalid_option_value, %{key: "material", value: "Unobtainium", allowed: ["PLA", "PETG"]}}
  """
  def validate_selected_specs(%Product{} = product, selected_specs) when is_map(selected_specs) do
    # Use full selectable specs (includes discovered options from metadata)
    # to match what the UI actually shows to users
    schema = Options.get_selectable_specs_for_product(product)

    # Build lookup map: key => option definition
    schema_map = Map.new(schema, fn opt -> {opt["key"], opt} end)

    # Check all provided keys exist and values are valid
    with :ok <- validate_spec_keys(selected_specs, schema_map),
         :ok <- validate_spec_values(selected_specs, schema_map) do
      validate_required_options(selected_specs, schema)
    end
  end

  def validate_selected_specs(_product, _specs), do: :ok

  # Validate that all provided keys exist in schema
  defp validate_spec_keys(selected_specs, schema_map) do
    invalid_key =
      Enum.find(Map.keys(selected_specs), fn key ->
        not Map.has_key?(schema_map, key)
      end)

    if invalid_key do
      {:error, :unknown_option_key, invalid_key}
    else
      :ok
    end
  end

  # Validate that all values are in allowed list (if options defined)
  defp validate_spec_values(selected_specs, schema_map) do
    invalid =
      Enum.find(selected_specs, fn {key, value} ->
        opt = Map.get(schema_map, key)
        allowed_values = opt["options"]

        # Only validate if options list is defined and non-empty
        if is_list(allowed_values) and allowed_values != [] do
          value not in allowed_values
        else
          false
        end
      end)

    case invalid do
      nil ->
        :ok

      {key, value} ->
        opt = Map.get(schema_map, key)
        {:error, :invalid_option_value, %{key: key, value: value, allowed: opt["options"]}}
    end
  end

  # Validate that all required options have values
  defp validate_required_options(selected_specs, schema) do
    missing =
      Enum.find(schema, fn opt ->
        required = opt["required"] == true
        key = opt["key"]

        required and not Map.has_key?(selected_specs, key)
      end)

    if missing do
      {:error, :missing_required_option, missing["key"]}
    else
      :ok
    end
  end

  @doc """
  Updates item quantity in cart.
  """
  def update_cart_item(%CartItem{} = item, quantity) when quantity > 0 do
    result =
      repo().transaction(fn ->
        cart = lock_active_cart!(item.cart_uuid)

        updated_item =
          item
          |> CartItem.changeset(%{quantity: quantity})
          |> repo().update!()

        updated_cart = recalculate_cart_totals!(cart)
        {updated_cart, updated_item}
      end)

    case result do
      {:ok, {updated_cart, updated_item}} ->
        Events.broadcast_quantity_updated(updated_cart, updated_item)
        {:ok, updated_cart}

      error ->
        error
    end
  end

  def update_cart_item(%CartItem{} = item, 0), do: remove_from_cart(item)

  @doc """
  Removes item from cart.
  """
  def remove_from_cart(%CartItem{} = item) do
    item_uuid = item.uuid

    result =
      repo().transaction(fn ->
        cart = lock_active_cart!(item.cart_uuid)
        repo().delete!(item)

        recalculate_cart_totals!(cart)
      end)

    case result do
      {:ok, updated_cart} ->
        Events.broadcast_item_removed(updated_cart, item_uuid)
        {:ok, updated_cart}

      error ->
        error
    end
  end

  @doc """
  Clears all items from cart.
  """
  def clear_cart(%Cart{} = cart) do
    result =
      repo().transaction(fn ->
        cart = lock_active_cart!(cart.uuid)

        CartItem
        |> where([i], i.cart_uuid == ^cart.uuid)
        |> repo().delete_all()

        recalculate_cart_totals!(cart)
      end)

    case result do
      {:ok, updated_cart} ->
        Events.broadcast_cart_cleared(updated_cart)
        {:ok, updated_cart}

      error ->
        error
    end
  end

  @doc """
  Sets the shipping country for the cart.
  """
  def set_cart_shipping_country(%Cart{} = cart, country) do
    cart
    |> Cart.shipping_changeset(%{shipping_country: country})
    |> repo().update()
  end

  @doc """
  Clears the cart's shipping selection and recalculates totals.

  Used when the selected method stops being eligible for the cart as it is
  NOW (weight change, last physical line removed) — leaving it selected
  showed a zero-cost method the cart had outgrown and let checkout proceed
  to an inevitable conversion failure.
  """
  def clear_cart_shipping(%Cart{} = cart) do
    result =
      repo().transaction(fn ->
        updated_cart =
          cart
          |> Cart.shipping_changeset(%{shipping_method_uuid: nil, shipping_amount: nil})
          |> repo().update!()

        recalculate_cart_totals!(updated_cart)
      end)

    case result do
      {:ok, updated_cart} ->
        Events.broadcast_shipping_selected(updated_cart)
        {:ok, updated_cart}

      error ->
        error
    end
  end

  @doc """
  Sets shipping method for cart.
  """
  def set_cart_shipping(%Cart{} = cart, %ShippingMethod{} = method, country) do
    shipping_cost = ShippingMethod.calculate_cost(method, cart.subtotal || Decimal.new("0"))

    result =
      repo().transaction(fn ->
        updated_cart =
          cart
          |> Cart.shipping_changeset(%{
            shipping_method_uuid: method.uuid,
            shipping_country: country,
            shipping_amount: shipping_cost
          })
          |> repo().update!()

        recalculate_cart_totals!(updated_cart)
      end)

    case result do
      {:ok, updated_cart} ->
        Events.broadcast_shipping_selected(updated_cart)
        {:ok, updated_cart}

      error ->
        error
    end
  end

  @doc """
  Sets payment option for cart.
  """
  def set_cart_payment_option(%Cart{} = cart, option) when is_map(option) do
    result =
      cart
      |> Cart.payment_changeset(%{
        payment_option_uuid: option.uuid
      })
      |> repo().update()

    case result do
      {:ok, updated_cart} ->
        Events.broadcast_payment_selected(updated_cart)
        {:ok, updated_cart}

      error ->
        error
    end
  end

  def set_cart_payment_option(%Cart{} = cart, payment_option_uuid)
      when is_binary(payment_option_uuid) do
    case Billing.get_payment_option(payment_option_uuid) do
      nil ->
        {:error, :payment_option_not_found}

      option ->
        set_cart_payment_option(cart, option)
    end
  end

  def set_cart_payment_option(%Cart{} = cart, nil) do
    result =
      cart
      |> Cart.payment_changeset(%{payment_option_uuid: nil})
      |> repo().update()

    case result do
      {:ok, updated_cart} ->
        Events.broadcast_payment_selected(updated_cart)
        {:ok, updated_cart}

      error ->
        error
    end
  end

  @doc """
  Auto-selects payment option if only one is available.

  If cart already has a payment option selected, does nothing.
  If only one option is available, selects it.
  """
  def auto_select_payment_option(%Cart{} = cart, payment_options) do
    cond do
      # Already has payment option selected
      not is_nil(cart.payment_option_uuid) ->
        {:ok, cart}

      # No options available
      payment_options == [] ->
        {:ok, cart}

      # Only one option available - auto-select it
      length(payment_options) == 1 ->
        option = hd(payment_options)
        set_cart_payment_option(cart, option)

      # Multiple options - user must choose
      true ->
        {:ok, cart}
    end
  end

  @doc """
  Auto-selects the cheapest available shipping method for a cart.

  If cart already has a shipping method selected, does nothing.
  If only one method is available, selects it.
  If multiple methods are available, selects the cheapest one.
  """
  def auto_select_shipping_method(%Cart{} = cart, shipping_methods) do
    cond do
      # Already has shipping method selected
      not is_nil(cart.shipping_method_uuid) ->
        {:ok, cart}

      # No items in cart
      cart.items == [] or is_nil(cart.items) ->
        {:ok, cart}

      # Digital-only carts don't get a method auto-selected
      not cart_requires_shipping?(cart) ->
        {:ok, cart}

      # No shipping methods available
      shipping_methods == [] ->
        {:ok, cart}

      # One or more methods available - select cheapest
      true ->
        cheapest = find_cheapest_shipping_method(shipping_methods, cart.subtotal)
        set_cart_shipping(cart, cheapest, nil)
    end
  end

  defp find_cheapest_shipping_method(methods, subtotal) do
    subtotal = subtotal || Decimal.new("0")

    # Enum.min_by on %Decimal{} structs compares by ERLANG TERM ORDER, not
    # value: `9.99` (coef 999, exp -2) sorts above `10` (coef 10, exp 0),
    # so the auto-selection could pick the more expensive method and charge
    # the customer for it. Same class as the price-range bug fixed in
    # Options - compare with Decimal.compare/2.
    methods
    |> Enum.min_by(
      fn method ->
        if ShippingMethod.free_for?(method, subtotal) do
          Decimal.new("0")
        else
          method.price || Decimal.new("999999")
        end
      end,
      &(Decimal.compare(&1, &2) != :gt)
    )
  end

  @doc """
  Merges guest cart into user cart after login.
  Accepts a user struct or user_uuid (string).
  """
  def merge_guest_cart(session_id, %{uuid: user_uuid}) do
    do_merge_guest_cart(session_id, user_uuid)
  end

  def merge_guest_cart(session_id, user_uuid) when is_binary(user_uuid) do
    do_merge_guest_cart(session_id, user_uuid)
  end

  defp do_merge_guest_cart(session_id, user_uuid) do
    guest_cart = find_active_cart(session_id: session_id)
    user_cart = find_active_cart(user_uuid: user_uuid)

    case {guest_cart, user_cart} do
      {nil, _} ->
        {:ok, user_cart}

      {guest, nil} ->
        # Convert guest cart to user cart
        guest
        |> Cart.changeset(%{
          user_uuid: user_uuid,
          session_id: nil,
          expires_at: nil
        })
        |> repo().update()

      {guest, user} ->
        # Merge items into user cart
        do_merge_guest_cart_items(guest, user)
    end
  end

  defp do_merge_guest_cart_items(guest, user) do
    repo().transaction(fn ->
      # Move items from guest to user cart
      Enum.each(guest.items, fn item ->
        merge_cart_item(user, item)
      end)

      # Mark guest cart as merged
      guest
      |> Cart.status_changeset("merged", %{
        merged_into_cart_uuid: user.uuid
      })
      |> repo().update!()

      # Recalculate user cart
      recalculate_cart_totals!(user)

      repo().get_by!(Cart, uuid: user.uuid)
      |> repo().preload([:items, :shipping_method, :payment_option])
    end)
  end

  defp merge_cart_item(user_cart, item) do
    existing =
      find_cart_item_by_specs(user_cart.uuid, item.product_uuid, item.selected_specs || %{})

    case existing do
      nil ->
        attrs =
          Map.from_struct(item)
          |> Map.drop([:__meta__, :id, :uuid, :cart, :product, :inserted_at, :updated_at])
          |> Map.put(:cart_uuid, user_cart.uuid)

        %CartItem{}
        |> CartItem.changeset(attrs)
        |> repo().insert!()

      existing_item ->
        new_qty = existing_item.quantity + item.quantity
        existing_item |> CartItem.changeset(%{quantity: new_qty}) |> repo().update!()
    end
  end

  @doc """
  Lists carts with filters for admin.
  """
  def list_carts_with_count(opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    per_page = Keyword.get(opts, :per_page, 25)
    offset = (page - 1) * per_page
    status = Keyword.get(opts, :status)
    search = Keyword.get(opts, :search)

    base_query = Cart

    base_query =
      if status && status != "" do
        where(base_query, [c], c.status == ^status)
      else
        base_query
      end

    base_query =
      if search && search != "" do
        search_term = search_like_pattern(search)

        base_query
        |> join(:left, [c], u in assoc(c, :user))
        |> where([c, u], ilike(u.email, ^search_term) or c.session_id == ^search)
      else
        base_query
      end

    total = repo().aggregate(base_query, :count)

    carts =
      base_query
      |> order_by([c], desc: c.updated_at)
      |> limit(^per_page)
      |> offset(^offset)
      |> preload([:user, :items])
      |> repo().all()

    {carts, total}
  end

  @doc """
  Marks abandoned carts (no activity for X days).
  """
  def mark_abandoned_carts(days \\ 7) do
    threshold = UtilsDate.utc_now() |> DateTime.add(-days, :day)

    {count, _} =
      Cart
      |> where([c], c.status == "active")
      |> where([c], c.updated_at < ^threshold)
      |> repo().update_all(set: [status: "abandoned"])

    {:ok, count}
  end

  @doc """
  Expires old guest carts.
  """
  def expire_old_carts do
    now = UtilsDate.utc_now()

    {count, _} =
      Cart
      |> where([c], c.status == "active")
      |> where([c], not is_nil(c.expires_at))
      |> where([c], c.expires_at < ^now)
      |> repo().update_all(set: [status: "expired"])

    {:ok, count}
  end

  @doc """
  Counts active carts.
  """
  def count_active_carts do
    Cart
    |> where([c], c.status == "active")
    |> repo().aggregate(:count)
  rescue
    _ -> 0
  end

  # ============================================
  # CHECKOUT / ORDER CONVERSION
  # ============================================

  @doc """
  Converts a cart to a Billing.Order.

  Takes an active cart with items and creates an Order with:
  - All cart items as line_items
  - Shipping as additional line item (if selected)
  - Billing profile snapshot (from profile_uuid or direct billing_data)
  - Cart marked as "converted"

  For guest checkout (no user_uuid on cart):
  - Creates a guest user via `Auth.create_guest_user/1`
  - Guest user has `confirmed_at = nil` until email verification
  - Sends confirmation email automatically
  - Order remains in "pending" status

  ## Options

  - `billing_profile_uuid: uuid` - Use existing billing profile (for logged-in users)
  - `billing_data: map` - Use direct billing data (for guest checkout)

  ## Returns

  - `{:ok, order}` - Order created successfully
  - `{:error, :cart_not_active}` - Cart is not active
  - `{:error, :cart_empty}` - Cart has no items
  - `{:error, :no_shipping_method}` - No shipping method selected
  - `{:error, :email_already_registered}` - Guest email belongs to confirmed user
  - `{:error, changeset}` - Validation errors
  """
  def convert_cart_to_order(%Cart{} = cart, opts) when is_list(opts) do
    cart = get_cart!(cart.uuid)

    # Wrap entire conversion in a transaction to ensure atomicity
    # If any step fails after order creation, the order is rolled back
    repo().transaction(fn ->
      # Use atomic status transition to prevent double-conversion on double-click
      # This atomically changes status from "active" to "converting" and fails
      # if another request already started conversion
      with :ok <- validate_shop_enabled(),
           :ok <- validate_cart_convertible(cart),
           {:ok, cart} <- try_lock_cart_for_conversion(cart),
           # AGAIN on the locked, reloaded cart - contents only. Another tab
           # can add a physical line (or empty the cart) between the pre-lock
           # read and the lock; without this a cart that gained a shippable
           # line converts with shipping_method_uuid still nil, i.e. physical
           # goods shipped for free. The STATUS check is deliberately not
           # repeated: the lock has already flipped it to "converting", and
           # winning that flip is what proves it was active.
           :ok <- validate_cart_contents(cart),
           # AFTER the cart lock, on locked product rows: an archive racing
           # the pre-transaction validation window cannot slip a
           # no-longer-active product into the order.
           :ok <- validate_line_products_active(cart),
           :ok <- validate_payment_option(cart),
           :ok <- validate_billing_completeness(cart, opts),
           # Snapshot the placing session from the LOCKED cart, before
           # anything can clear it.
           #
           # `resolve_checkout_user/2` runs next and, for both guest checkout
           # and a logged-in user adopting a guest cart, ends in
           # `assign_cart_to_user/2` — which writes `session_id: nil` onto the
           # cart. Reading `cart.session_id` after that point yields nil, so
           # the order was stamped with no placing session and the cart row
           # lost it too: the guest could not open the confirmation page they
           # were redirected to one line later, and the
           # `cart_uuid -> cart.session_id` fallback could not recover it.
           #
           # Deliberately a local binding rather than an option. This value
           # authorizes the order confirmation page, and
           # `convert_cart_to_order/2` is public (re-exported through
           # `compat/shop.ex`) — threading it through `opts` let a caller
           # supply their own and have it stamped into
           # `metadata["session_id"]`, handing out access to an order they
           # did not place. Derived internally, it cannot be influenced.
           placing_session_id = cart.session_id,
           {:ok, user_uuid, cart} <- resolve_checkout_user(cart, opts),
           :ok <- validate_billing_profile_owner(opts, user_uuid),
           {:ok, cart} <- apply_checkout_shipping_country(cart, opts),
           {:ok, cart} <- validate_shipping_method_available(cart),
           line_items <- build_order_line_items(cart),
           order_attrs <- build_order_attrs(cart, line_items, opts, placing_session_id),
           {:ok, order} <- do_create_order(user_uuid, order_attrs),
           {:ok, _cart} <- mark_cart_converted(cart, order.uuid) do
        {:ok, order}
      else
        {:error, reason} ->
          # Rollback transaction on any error, unwrapping the {:error, _} tuple
          # so the transaction returns {:error, reason} (not {:error, {:error, reason}})
          repo().rollback(reason)

        other ->
          repo().rollback(other)
      end
    end)
    # unwrap the transaction result
    |> case do
      {:ok, {:ok, order}} ->
        # Deliberately AFTER the transaction commits, not inside it.
        #
        # This used to be the last step of the `with` above, which meant an
        # SMTP failure rolled back an order the customer had already paid
        # for, and a slow mail server held the cart row lock open for the
        # length of the network round-trip. A confirmation email is a
        # notification about a committed fact — it must not be able to undo
        # that fact. Failure is logged inside `maybe_send_guest_confirmation/1`.
        _ = maybe_send_guest_confirmation(order.user_uuid)
        _ = log_order_converted(order)
        _ = PhoenixKitEcommerce.Notifications.order_placed(order)
        {:ok, order}

      {:error, reason} ->
        # A failed checkout is exactly what an operator wants to see later
        # ("customers keep bouncing off shipping"), so the attempt is
        # recorded too - PII-safe, no billing details.
        _ =
          PhoenixKitEcommerce.Activity.log_failed("shop.order_converted", reason,
            actor_uuid: cart.user_uuid,
            resource_type: "cart",
            resource_uuid: cart.uuid,
            mode: "checkout"
          )

        {:error, reason}
    end
  end

  @doc """
  Applies the checkout billing country to the cart and recalculates totals,
  WITHOUT converting anything.

  The review step must show the amount the customer is about to be charged.
  The cart page deliberately leaves `shipping_country` nil ("set at
  checkout"), and tax is zero for a nil-country cart — so before this
  existed, a customer reviewed a pre-tax total and `convert_cart_to_order/2`
  then applied the country, recalculated, and charged more. Cart 100.00 +
  shipping 10.00 at 20%: review said 110.00, the order said 130.00.

  That gap opened the moment tax started working at all, so it ships with
  the same change. Runs the identical country resolution and recalculation
  the conversion uses, so the two cannot disagree.

  Takes the same `:billing_profile_uuid` / `:billing_data` options as
  `convert_cart_to_order/2`. Returns the reloaded cart.
  """
  @spec preview_checkout_totals(Cart.t(), keyword()) :: {:ok, Cart.t()} | {:error, term()}
  def preview_checkout_totals(%Cart{} = cart, opts) when is_list(opts) do
    repo().transaction(fn ->
      case apply_checkout_shipping_country(get_cart!(cart.uuid), opts) do
        {:ok, updated} -> updated
        {:error, reason} -> repo().rollback(reason)
      end
    end)
  end

  # Persist the checkout address's country onto the cart, then recompute
  # totals, BEFORE the order is built from those totals.
  #
  # `set_cart_shipping_country/2` existed but had no caller: the cart page
  # deliberately leaves `shipping_country` nil ("set at checkout based on
  # billing info") and checkout never set it. Since `get_tax_rate/1`
  # returns 0 for a nil-country cart, every order was created tax-free
  # however billing tax was configured.
  #
  # Resolution order is: the address actually being used for this checkout,
  # then whatever the cart already had, then the admin's configured
  # fallback (`Policy.default_tax_country/0`, unset by default). When none
  # of those yields a country the behaviour is unchanged — no country, no
  # tax — because charging tax against a guessed jurisdiction would be
  # worse than charging none.
  defp apply_checkout_shipping_country(%Cart{} = cart, opts) do
    billing_profile_uuid = Keyword.get(opts, :billing_profile_uuid)
    billing_data = Keyword.get(opts, :billing_data)

    country =
      get_shipping_country(billing_profile_uuid, billing_data, cart) ||
        Policy.default_tax_country()

    with {:ok, cart} <- maybe_write_shipping_country(cart, country) do
      # ALWAYS recalculate before the order copies these totals, not only
      # when the country changed.
      #
      # Two reasons. `set_cart_shipping_country/2` writes the column but
      # not the totals, so a newly-applied country leaves tax_amount stale.
      # And a cart that ALREADY had the right country skipped recalculation
      # entirely — so any totals left stale by a concurrent cart edit (see
      # the lock in `recalculate_cart_totals!/1`) were copied onto the order
      # verbatim. Recomputing unconditionally, inside the conversion
      # transaction and under that lock, makes the order's totals a fresh
      # read rather than a trusted cache.
      _ = recalculate_cart_totals!(cart)
      {:ok, get_cart!(cart.uuid)}
    end
  end

  defp maybe_write_shipping_country(%Cart{} = cart, country) do
    if is_nil(country) or country == "" or country == cart.shipping_country do
      {:ok, cart}
    else
      set_cart_shipping_country(cart, country)
    end
  end

  # A billing profile may only be attached to an order by the user who owns
  # it — enforced HERE, in the context, not only in the LiveView.
  #
  # `convert_cart_to_order/2` is public and re-exported through
  # `compat/shop.ex`, and it took `billing_profile_uuid` straight from
  # `opts` and wrote it onto the order. Billing then snapshots that
  # profile's name, address, phone and email onto the order, which the
  # confirmation page renders — so an unchecked uuid was a PII read. The
  # checkout LiveView does check ownership, but a context function must not
  # depend on one caller remembering to.
  #
  # This is the same defect shape as the placing-session override, and it
  # gets the same treatment: the invariant lives with the write.
  defp validate_billing_profile_owner(opts, user_uuid) do
    case Keyword.get(opts, :billing_profile_uuid) do
      nil ->
        :ok

      profile_uuid ->
        case Billing.get_billing_profile(profile_uuid) do
          %{user_uuid: owner_uuid} when not is_nil(owner_uuid) and owner_uuid == user_uuid -> :ok
          _ -> {:error, :billing_profile_not_owned}
        end
    end
  end

  defp validate_cart_convertible(%Cart{} = cart) do
    if cart.status != "active" do
      {:error, :cart_not_active}
    else
      validate_cart_contents(cart)
    end
  end

  defp validate_cart_contents(%Cart{} = cart) do
    cond do
      Enum.empty?(cart.items) ->
        {:error, :cart_empty}

      # Only carts with a shippable line need a shipping method; a
      # digital-only cart converts without one (and without a charge).
      #
      # A missing method is rejected HERE only when the shop requires one
      # outright (`:off`). `:fallback` and `:always` defer the decision to
      # `validate_shipping_method_available/1`, which runs after
      # `apply_checkout_shipping_country/2` - the skip decision needs the
      # checkout country this cart does not have yet.
      is_nil(cart.shipping_method_uuid) and items_require_shipping?(cart.items) and
          shipping_skip_mode() == :off ->
        {:error, :no_shipping_method}

      true ->
        :ok
    end
  end

  # Every line's product must still be ACTIVE at conversion, checked on
  # LOCKED rows inside the conversion transaction — a pre-transaction check
  # races a concurrent archive between validation and order creation. A line
  # whose product row is gone (or was detached by ON DELETE SET NULL) is not
  # sellable either.
  defp validate_line_products_active(%Cart{items: items}) do
    uuids = items |> Enum.map(& &1.product_uuid) |> Enum.reject(&is_nil/1)

    if length(uuids) < length(items) do
      {:error, :product_not_available}
    else
      active =
        Product
        |> where([p], p.uuid in ^uuids and p.status == "active")
        |> lock("FOR UPDATE")
        |> select([p], p.uuid)
        |> repo().all()

      if length(active) == length(Enum.uniq(uuids)) do
        :ok
      else
        {:error, :product_not_available}
      end
    end
  end

  # The selected payment option must still exist, be active, and have its
  # billing-profile requirement satisfied. Until now the selection was
  # simply DISCARDED at conversion — never revalidated, never recorded on
  # the order (`build_order_attrs/4` re-reads it into order metadata).
  # A cart without a selection converts as before.
  defp validate_payment_option(%Cart{payment_option_uuid: nil}), do: :ok

  defp validate_payment_option(%Cart{payment_option_uuid: uuid}) do
    case PhoenixKitBilling.get_payment_option(uuid) do
      %{active: true} -> :ok
      _ -> {:error, :payment_option_unavailable}
    end
  rescue
    _ -> {:error, :payment_option_unavailable}
  end

  # A cart with a shippable line needs a deliverable address — enforced in
  # the CONTEXT, because the LiveView's completeness check lives on the
  # review step and a crafted confirm_order event skips it, and because
  # saved billing profiles were never required to carry an address at all.
  defp validate_billing_completeness(%Cart{} = cart, opts) do
    if items_require_shipping?(cart.items) do
      cond do
        uuid = Keyword.get(opts, :billing_profile_uuid) ->
          validate_profile_completeness(uuid)

        is_map(Keyword.get(opts, :billing_data)) ->
          validate_billing_data_completeness(Keyword.get(opts, :billing_data))

        true ->
          {:error, {:billing_incomplete, ["billing details"]}}
      end
    else
      :ok
    end
  end

  defp validate_profile_completeness(uuid) do
    case PhoenixKitBilling.get_billing_profile(uuid) do
      nil ->
        {:error, :billing_profile_not_found}

      profile ->
        name_missing =
          case profile.type do
            "company" -> blank_field?(profile.company_name)
            _ -> blank_field?(profile.first_name) and blank_field?(profile.name)
          end

        missing =
          [
            {name_missing, "name"},
            {blank_field?(profile.address_line1), "address_line1"},
            {blank_field?(profile.city), "city"},
            {blank_field?(profile.postal_code), "postal_code"},
            {blank_field?(profile.country), "country"}
          ]
          |> Enum.filter(&elem(&1, 0))
          |> Enum.map(&elem(&1, 1))

        if missing == [], do: :ok, else: {:error, {:billing_incomplete, missing}}
    end
  end

  defp validate_billing_data_completeness(data) do
    name_missing = blank_field?(data["first_name"]) and blank_field?(data["company_name"])

    missing =
      [
        {name_missing, "name"},
        {blank_field?(data["address_line1"]), "address_line1"},
        {blank_field?(data["city"]), "city"},
        {blank_field?(data["postal_code"]), "postal_code"},
        {blank_field?(data["country"]), "country"}
      ]
      |> Enum.filter(&elem(&1, 0))
      |> Enum.map(&elem(&1, 1))

    if missing == [], do: :ok, else: {:error, {:billing_incomplete, missing}}
  end

  defp blank_field?(nil), do: true
  defp blank_field?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_field?(_), do: false

  # No method selected: `validate_cart_contents/1` already let this cart
  # through, which only happens when the skip mode is not `:off`. Now that
  # the checkout country is on the cart, decide for real - `:always` skips
  # unconditionally, `:fallback` only when no method covers this country
  # (a covered country stays a hard requirement), and the decision is
  # stamped onto the in-memory cart for `build_order_attrs/4` to read.
  defp validate_shipping_method_available(%Cart{shipping_method_uuid: nil} = cart) do
    if items_require_shipping?(cart.items) do
      case shipping_skippable?(cart) do
        {:skip, reason} ->
          {:ok,
           %{
             cart
             | metadata: Map.put(cart.metadata || %{}, "shipping_skip_reason", to_string(reason))
           }}

        false ->
          {:error, :no_shipping_method}
      end
    else
      {:ok, cart}
    end
  end

  # Re-validate the shipping method AFTER the checkout country has been
  # applied, not before: a method may be eligible for a country-less cart
  # and ineligible once the billing address supplies a country it does not
  # serve, and running this too early would also wrongly reject that case
  # in reverse.
  defp validate_shipping_method_available(%Cart{} = cart) do
    if selected_shipping_method_available?(cart) do
      {:ok, cart}
    else
      {:error, :shipping_method_unavailable}
    end
  end

  # A selected shipping method must still be eligible for the cart AS IT IS
  # NOW, not as it was when the customer picked it.
  #
  # Checking only that `shipping_method_uuid` is set was exploitable:
  # `calculate_method_shipping/4` zeroes the cost of a method the cart has
  # outgrown while LEAVING it selected, so a customer could choose a cheap
  # light-parcel method, then load the cart past that method's weight or
  # subtotal cap, and check out with the shipping charge silently at zero.
  # Nothing downstream re-checked. Repeatable, and straight off the margin.
  defp selected_shipping_method_available?(%Cart{shipping_method_uuid: nil}), do: true

  defp selected_shipping_method_available?(%Cart{} = cart) do
    items = cart_items_loaded(cart)

    # Nothing ships: a method left selected from when the cart still had a
    # physical line is irrelevant - it is not being charged for, and it must
    # not be able to block the order.
    if items_require_shipping?(items) do
      case repo().get_by(ShippingMethod, uuid: cart.shipping_method_uuid) do
        nil ->
          false

        method ->
          # SHIPPABLE weight, matching what listing and pricing use. On
          # total weight a mixed cart could be quoted a method (priced on
          # its 100g of physical goods) and then refused at conversion
          # because a 50kg digital line pushed it over the cap.
          ShippingMethod.available_for?(method, %{
            weight_grams: shippable_weight_grams(items),
            subtotal: cart.subtotal || Decimal.new("0"),
            country: cart.shipping_country
          })
      end
    else
      true
    end
  end

  defp build_order_line_items(%Cart{} = cart) do
    product_items =
      Enum.map(cart.items, fn item ->
        %{
          "name" => item.product_title,
          "description" => format_item_description(item),
          "selected_specs" => item.selected_specs || %{},
          "quantity" => item.quantity,
          "unit_price" => Decimal.to_string(item.unit_price),
          "total" => Decimal.to_string(item.line_total),
          "sku" => item.product_sku,
          "type" => "product",
          # Carried so invoices and the confirmation page can render the
          # unit the customer saw. Rides billing's existing line-item JSONB;
          # first-class linkage is a billing-side change.
          "price_unit" => (item.metadata || %{})["price_unit"],
          # Carried for the same reason and with more at stake: without it the
          # order confirmation and order-details pages fall back to formatting
          # `total`, which for an on-request service is 0 — so a line the
          # customer agreed as "Price on request" reads "0.00" on a COMMITTED
          # order. The cart line snapshots this; the conversion has to forward it
          # or the snapshot dies at the cart/order boundary.
          "price_on_request" => (item.metadata || %{})["price_on_request"] == true
        }
      end)

    # A digital-only cart gets NO shipping line even when a method is still
    # selected (a mixed cart that lost its last physical line keeps the
    # association loaded); its charge is already zeroed by the totals.
    shipping_item =
      if cart.shipping_method && items_require_shipping?(cart.items) do
        [
          %{
            "name" => "Shipping: #{cart.shipping_method.name}",
            "description" => cart.shipping_method.description || "",
            "quantity" => 1,
            "unit_price" => Decimal.to_string(cart.shipping_amount || Decimal.new(0)),
            "total" => Decimal.to_string(cart.shipping_amount || Decimal.new(0)),
            "type" => "shipping"
          }
        ]
      else
        []
      end

    product_items ++ shipping_item
  end

  defp build_order_attrs(%Cart{} = cart, line_items, opts, placing_session_id) do
    billing_profile_uuid = Keyword.get(opts, :billing_profile_uuid)
    billing_data = Keyword.get(opts, :billing_data)

    # Get shipping country from billing data or cart
    shipping_country = get_shipping_country(billing_profile_uuid, billing_data, cart)

    # Use string keys to match Billing.maybe_set_order_number behavior
    base_attrs =
      %{
        "currency" => cart.currency,
        "line_items" => line_items,
        "subtotal" => cart.subtotal,
        "tax_amount" => cart.tax_amount || Decimal.new(0),
        "tax_rate" => get_tax_rate(cart),
        "discount_amount" => cart.discount_amount || Decimal.new(0),
        "discount_code" => cart.discount_code,
        "total" => cart.total,
        "status" => "pending",
        "metadata" =>
          %{
            "source" => "shop_checkout",
            "cart_uuid" => cart.uuid,
            # The shop session that placed this order. This is what lets the
            # confirmation page recognise a guest as the person who just checked
            # out, instead of treating knowledge of the order uuid as proof.
            # See `PhoenixKitEcommerce.Policy.order_lookup_policy/0`.
            #
            # Taken from the snapshot captured in `convert_cart_to_order/2`, NOT
            # from `cart.session_id` — by this point `assign_cart_to_user/2` has
            # already nulled the column for every guest checkout. Passed as an
            # argument rather than through `opts` so a caller of the public
            # `convert_cart_to_order/2` cannot choose it.
            "session_id" => placing_session_id,
            "shipping_country" => shipping_country,
            # nil for a digital-only order even when a stale selection remains
            # on the cart - the order must not reference a method it never
            # charged for.
            "shipping_method_uuid" =>
              if(items_require_shipping?(cart.items), do: cart.shipping_method_uuid),
            # Set by `validate_shipping_method_available/1` when the cart
            # converted without a method under `:always`/`:fallback` - the
            # durable record of WHY, since the cart row's in-memory stamp
            # (see that function) is never persisted.
            "shipping_skipped" =>
              items_require_shipping?(cart.items) and is_nil(cart.shipping_method_uuid),
            "shipping_skip_reason" => (cart.metadata || %{})["shipping_skip_reason"]
          }
          |> Map.merge(payment_option_metadata(cart))
      }
      |> maybe_put_payment_option(cart)

    cond do
      # Logged-in user with billing profile
      not is_nil(billing_profile_uuid) ->
        Map.put(base_attrs, "billing_profile_uuid", billing_profile_uuid)

      # Guest checkout with billing data - clean up _unused_ keys from LiveView
      is_map(billing_data) ->
        cleaned_billing_data = clean_billing_data(billing_data)
        Map.put(base_attrs, "billing_snapshot", cleaned_billing_data)

      true ->
        base_attrs
    end
  end

  # Get shipping country from billing profile, billing data, or cart
  defp get_shipping_country(billing_profile_uuid, _billing_data, cart)
       when not is_nil(billing_profile_uuid) do
    case Billing.get_billing_profile(billing_profile_uuid) do
      %{country: country} when is_binary(country) -> country
      _ -> cart.shipping_country
    end
  end

  defp get_shipping_country(_billing_profile_uuid, billing_data, cart)
       when is_map(billing_data) do
    billing_data["country"] || cart.shipping_country
  end

  defp get_shipping_country(_billing_profile_uuid, _billing_data, cart) do
    cart.shipping_country
  end

  # Remove _unused_ prefixed keys that Phoenix LiveView adds
  # The money path's audit row. Written after commit, PII-safe (uuids,
  # counts, total - never the customer's name, address or email).
  #
  # ⚠️ The action is DELIBERATELY not the notify action ("shop.order_placed"):
  # `Activity.log/1` auto-derives notifications from registered actions, so
  # reusing it here would deliver a duplicate on top of the explicit
  # fan-out. `target_uuid` stays nil for the same reason - a targeted audit
  # row with a registered action becomes a notification.
  defp log_order_converted(order) do
    PhoenixKitEcommerce.Activity.log("shop.order_converted",
      actor_uuid: order.user_uuid,
      resource_type: "order",
      resource_uuid: order.uuid,
      mode: "checkout",
      metadata: %{
        "order_number" => order.order_number,
        "currency" => order.currency,
        "total" => to_string(order.total),
        "item_count" => length(order.line_items || [])
      }
    )
  end

  # First-class linkage (billing Order.payment_option_uuid, core V162) so an
  # operator can see WHICH configured option a customer chose - several
  # options share one payment_method.
  #
  # ⚠️ The guard checks the host's MIGRATED VERSION, not the schema. The
  # schema always carries the field once billing is updated; what varies is
  # whether the host has actually run `mix phoenix_kit.update`. Checking
  # `__schema__(:fields)` therefore guarded nothing and every order insert
  # died with `column "payment_option_uuid" does not exist` - caught by
  # driving a real checkout in the browser, not by any test or review.
  defp maybe_put_payment_option(attrs, %Cart{payment_option_uuid: nil}), do: attrs

  defp maybe_put_payment_option(attrs, %Cart{payment_option_uuid: uuid}) do
    if payment_option_column_available?() do
      Map.put(attrs, "payment_option_uuid", uuid)
    else
      attrs
    end
  end

  # V162 added the column. Cached in :persistent_term because this runs on
  # every checkout and the answer only changes when an operator migrates -
  # at which point a restart (or a cache clear) picks it up.
  #
  # This constant is the ONLY thing standing between a host below that
  # version and a crash on a missing column, so it has to track the core
  # migration's real number: it was 161 until core merged a different V161
  # (citext username) ahead of this one.
  @payment_option_version 162
  @payment_option_cache_key {__MODULE__, :payment_option_column?}

  defp payment_option_column_available? do
    case :persistent_term.get(@payment_option_cache_key, :unknown) do
      :unknown ->
        # `Migration.migrated_version/0` only works INSIDE a migration
        # runner - at runtime it raises "could not find migration runner
        # process", which the rescue below turned into a permanent false.
        # `migrated_version_runtime/1` is core's runtime accessor (the same
        # one `phoenix_kit.status` and the module coordinator use).
        available? =
          PostgresMigrations.migrated_version_runtime([]) >=
            @payment_option_version

        :persistent_term.put(@payment_option_cache_key, available?)
        available?

      cached ->
        cached
    end
  rescue
    # Cannot tell -> do not write the column. An order that records the
    # payment option only in metadata is a smaller failure than an order
    # that cannot be placed at all.
    _ -> false
  end

  # The customer's validated payment choice, also recorded in metadata: the
  # column carries the LINK (nulled if the option is later deleted), the
  # metadata carries the code, so a deleted option still degrades to "it
  # was a bank transfer" rather than to nothing.
  defp payment_option_metadata(%Cart{payment_option_uuid: nil}), do: %{}

  defp payment_option_metadata(%Cart{payment_option_uuid: uuid}) do
    case PhoenixKitBilling.get_payment_option(uuid) do
      %{code: code} -> %{"payment_option_uuid" => uuid, "payment_option_code" => code}
      _ -> %{"payment_option_uuid" => uuid}
    end
  rescue
    _ -> %{"payment_option_uuid" => uuid}
  end

  defp clean_billing_data(data) when is_map(data) do
    data
    |> Enum.reject(fn {key, _value} ->
      key_str = if is_atom(key), do: Atom.to_string(key), else: key
      String.starts_with?(key_str, "_unused_")
    end)
    |> Map.new()
  end

  # Resolve user for checkout: logged-in user or create guest user
  defp resolve_checkout_user(%Cart{user_uuid: user_uuid} = cart, _opts)
       when not is_nil(user_uuid) do
    # Cart already has a user (logged-in checkout)
    {:ok, user_uuid, cart}
  end

  defp resolve_checkout_user(%Cart{user_uuid: nil} = cart, opts) do
    # Check if logged-in user_uuid was passed in opts (user is logged in but has guest cart)
    case Keyword.get(opts, :user_uuid) do
      user_uuid when not is_nil(user_uuid) ->
        resolve_logged_in_user_with_guest_cart(cart, user_uuid)

      nil ->
        resolve_guest_checkout(cart, opts)
    end
  end

  defp resolve_logged_in_user_with_guest_cart(cart, user_uuid) do
    user = Auth.get_user(user_uuid)

    case user && assign_cart_to_user(cart, user) do
      {:ok, updated_cart} -> {:ok, user_uuid, updated_cart}
      _ -> {:ok, user_uuid, cart}
    end
  end

  defp resolve_guest_checkout(cart, opts) do
    billing_data = Keyword.get(opts, :billing_data)

    if valid_billing_data?(billing_data) do
      create_guest_user_and_assign_cart(cart, billing_data)
    else
      {:ok, nil, cart}
    end
  end

  defp valid_billing_data?(data), do: is_map(data) and Map.has_key?(data, "email")

  defp create_guest_user_and_assign_cart(cart, billing_data) do
    case Auth.create_guest_user(%{
           email: billing_data["email"],
           first_name: billing_data["first_name"],
           last_name: billing_data["last_name"]
         }) do
      {:ok, user} ->
        assign_cart_and_return(cart, user)

      {:error, :email_exists_unconfirmed, user} ->
        assign_cart_and_return(cart, user)

      {:error, :email_exists_confirmed} ->
        {:error, :email_already_registered}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp assign_cart_and_return(cart, %{uuid: user_uuid} = user) do
    case assign_cart_to_user(cart, user) do
      {:ok, updated_cart} -> {:ok, user_uuid, updated_cart}
      {:error, _} -> {:ok, user_uuid, cart}
    end
  end

  # Assign cart to user (for guest -> user conversion)
  defp assign_cart_to_user(%Cart{} = cart, %{uuid: user_uuid}) do
    cart
    |> Cart.changeset(%{user_uuid: user_uuid, session_id: nil})
    |> repo().update()
  end

  # Create order with or without user
  defp do_create_order(nil, order_attrs) do
    Billing.create_order(order_attrs)
  end

  defp do_create_order(user_uuid, order_attrs) do
    Billing.create_order(user_uuid, order_attrs)
  end

  # Send confirmation email to guest users
  defp maybe_send_guest_confirmation(nil), do: :ok

  defp maybe_send_guest_confirmation(user_uuid) do
    case Auth.get_user(user_uuid) do
      %{confirmed_at: nil} = user ->
        # Guest user - send confirmation email
        Auth.deliver_user_confirmation_instructions(
          user,
          &Routes.url("/users/confirm/#{&1}")
        )

        :ok

      _ ->
        # Already confirmed user - no action needed
        :ok
    end
  end

  # Atomically transition cart from "active" to "converting" status.
  # This prevents double-conversion when user double-clicks checkout button.
  # If another request already started conversion, this returns error.
  defp try_lock_cart_for_conversion(%Cart{uuid: cart_uuid}) do
    # Use atomic UPDATE with WHERE clause to ensure only one request wins
    {count, _} =
      Cart
      |> where([c], c.uuid == ^cart_uuid and c.status == "active")
      |> repo().update_all(set: [status: "converting", updated_at: UtilsDate.utc_now()])

    if count == 1 do
      # Successfully locked - reload cart with new status
      {:ok, get_cart!(cart_uuid)}
    else
      # Another request already started conversion
      {:error, :cart_already_converting}
    end
  end

  defp mark_cart_converted(%Cart{} = cart, order_uuid) do
    cart
    |> Cart.status_changeset("converted", %{
      converted_at: UtilsDate.utc_now(),
      metadata: Map.put(cart.metadata || %{}, "order_uuid", order_uuid)
    })
    |> repo().update()
  end

  # ============================================
  # PRIVATE HELPERS
  # ============================================

  # Format cart item description including selected_specs
  defp format_item_description(%CartItem{product_slug: slug, selected_specs: specs})
       when specs == %{} or is_nil(specs) do
    slug
  end

  defp format_item_description(%CartItem{product_slug: slug, selected_specs: specs}) do
    specs_text =
      Enum.map_join(specs, ", ", fn {key, value} -> "#{humanize_key(key)}: #{value}" end)

    "#{slug} (#{specs_text})"
  end

  # Convert key to human-readable format: "material_type" -> "Material Type"
  defp humanize_key(key) when is_binary(key) do
    key
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp humanize_key(key), do: to_string(key)

  defp count_products do
    Product |> repo().aggregate(:count)
  rescue
    _ -> 0
  end

  defp count_products_by_status(status) do
    Product
    |> where([p], p.status == ^status)
    |> repo().aggregate(:count)
  rescue
    _ -> 0
  end

  defp count_products_by_type(product_type) do
    Product
    |> where([p], p.product_type == ^product_type)
    |> repo().aggregate(:count)
  rescue
    _ -> 0
  end

  defp count_categories do
    Category |> repo().aggregate(:count)
  rescue
    _ -> 0
  end

  defp apply_product_filters(query, opts) do
    query
    |> filter_by_status(Keyword.get(opts, :status))
    |> filter_by_product_type(Keyword.get(opts, :product_type))
    |> filter_by_category(Keyword.get(opts, :category_uuid))
    |> filter_by_product_search(Keyword.get(opts, :search))
    |> filter_by_visible_categories(Keyword.get(opts, :exclude_hidden_categories, false))
    |> filter_by_price_range(Keyword.get(opts, :price_min), Keyword.get(opts, :price_max))
    |> filter_by_vendors(Keyword.get(opts, :vendors))
    |> filter_by_metadata_options(Keyword.get(opts, :metadata_filters))
  end

  defp filter_by_status(query, nil), do: query
  defp filter_by_status(query, status), do: where(query, [p], p.status == ^status)

  defp filter_by_product_type(query, nil), do: query
  defp filter_by_product_type(query, type), do: where(query, [p], p.product_type == ^type)

  defp filter_by_category(query, nil), do: query

  defp filter_by_category(query, uuid) when is_binary(uuid) do
    if UUIDUtils.valid?(uuid) do
      where(query, [p], p.category_uuid == ^uuid)
    else
      query
    end
  end

  defp filter_by_visible_categories(query, false), do: query

  defp filter_by_visible_categories(query, true) do
    # Exclude products from categories with status "hidden"
    # Products from "active" and "unlisted" categories are visible
    # Use distinct to avoid duplicates from the left_join
    from(p in query,
      left_join: c in Category,
      on: c.uuid == p.category_uuid,
      where: is_nil(c.uuid) or c.status != "hidden",
      distinct: p.uuid
    )
  end

  defp filter_by_price_range(query, nil, nil), do: query
  defp filter_by_price_range(query, min, nil), do: where(query, [p], p.price >= ^min)
  defp filter_by_price_range(query, nil, max), do: where(query, [p], p.price <= ^max)

  defp filter_by_price_range(query, min, max),
    do: where(query, [p], p.price >= ^min and p.price <= ^max)

  defp filter_by_vendors(query, nil), do: query
  defp filter_by_vendors(query, []), do: query

  defp filter_by_vendors(query, vendors) when is_list(vendors),
    do: where(query, [p], p.vendor in ^vendors)

  defp filter_by_metadata_options(query, nil), do: query
  defp filter_by_metadata_options(query, []), do: query

  defp filter_by_metadata_options(query, filters) when is_list(filters) do
    Enum.reduce(filters, query, fn %{key: key, values: values}, q ->
      where(
        q,
        [p],
        fragment(
          "EXISTS (SELECT 1 FROM jsonb_array_elements_text(COALESCE(?->'_option_values'->?, '[]'::jsonb)) elem WHERE elem = ANY(?))",
          p.metadata,
          ^key,
          ^values
        )
      )
    end)
  end

  # Max length for a user-supplied search term. Anything longer is
  # truncated: ILIKE against unindexed JSONB expansions is linear in both
  # pattern and row count, so an unbounded public `?search=` param would be
  # a cheap seq-scan amplifier.
  @max_search_term_length 100

  # Builds a safe `%term%` ILIKE pattern from raw user input: caps the
  # length, strips NUL bytes (Postgres rejects them in text params), and
  # escapes LIKE metacharacters so `%`, `_`, and `\` match literally —
  # a search for "100%" must not match every "100", and SKUs routinely
  # contain underscores.
  defp search_like_pattern(search) do
    escaped =
      search
      |> String.replace(<<0>>, "")
      |> String.slice(0, @max_search_term_length)
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

    "%#{escaped}%"
  end

  defp filter_by_product_search(query, nil), do: query
  defp filter_by_product_search(query, ""), do: query

  defp filter_by_product_search(query, search) do
    search_term = search_like_pattern(search)
    default_lang = Translations.default_language()

    # Search in JSONB localized fields using PostgreSQL operators
    # Searches in default language and falls back to any language match,
    # plus SKU (metadata->>'sku') and tags. Columns are bound through the
    # product binding so the query stays valid when other filters join
    # additional tables (e.g. :exclude_hidden_categories).
    where(
      query,
      [p],
      fragment(
        "(COALESCE(?->>?, '') ILIKE ? OR COALESCE(?->>?, '') ILIKE ? OR EXISTS (SELECT 1 FROM jsonb_each_text(?) WHERE value ILIKE ?) OR EXISTS (SELECT 1 FROM jsonb_each_text(?) WHERE value ILIKE ?) OR COALESCE(?->>'sku', '') ILIKE ? OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(COALESCE(?, '[]'::jsonb)) AS tag WHERE tag ILIKE ?))",
        p.title,
        ^default_lang,
        ^search_term,
        p.description,
        ^default_lang,
        ^search_term,
        p.title,
        ^search_term,
        p.description,
        ^search_term,
        p.metadata,
        ^search_term,
        p.tags,
        ^search_term
      )
    )
  end

  defp apply_category_filters(query, opts) do
    query
    |> filter_by_parent_uuid(Keyword.get(opts, :parent_uuid, :skip))
    |> filter_by_category_status(Keyword.get(opts, :status, :skip))
    |> filter_by_category_search(Keyword.get(opts, :search))
  end

  defp filter_by_parent_uuid(query, :skip), do: query
  defp filter_by_parent_uuid(query, nil), do: where(query, [c], is_nil(c.parent_uuid))
  defp filter_by_parent_uuid(query, uuid), do: where(query, [c], c.parent_uuid == ^uuid)

  defp filter_by_category_status(query, :skip), do: query
  defp filter_by_category_status(query, nil), do: query

  defp filter_by_category_status(query, status) when is_binary(status) do
    where(query, [c], c.status == ^status)
  end

  defp filter_by_category_status(query, statuses) when is_list(statuses) do
    where(query, [c], c.status in ^statuses)
  end

  defp filter_by_category_search(query, nil), do: query
  defp filter_by_category_search(query, ""), do: query

  defp filter_by_category_search(query, search) do
    search_term = search_like_pattern(search)
    default_lang = Translations.default_language()

    # Search in JSONB localized name field using PostgreSQL operators
    where(
      query,
      [c],
      fragment(
        "(COALESCE(name->>?, '') ILIKE ? OR EXISTS (SELECT 1 FROM jsonb_each_text(name) WHERE value ILIKE ?))",
        ^default_lang,
        ^search_term,
        ^search_term
      )
    )
  end

  defp maybe_preload(query, nil), do: query
  defp maybe_preload(query, preloads), do: preload(query, ^preloads)

  # Shipping filters
  defp filter_shipping_by_active(query, nil), do: query
  defp filter_shipping_by_active(query, active), do: where(query, [s], s.active == ^active)

  # Cart helpers

  # Find cart item by product and selected_specs
  defp find_cart_item_by_specs(cart_uuid, product_uuid, specs) when map_size(specs) == 0 do
    # No specs - find item without specs
    CartItem
    |> where([i], i.cart_uuid == ^cart_uuid and i.product_uuid == ^product_uuid)
    |> where([i], i.selected_specs == ^%{})
    |> repo().one()
  end

  defp find_cart_item_by_specs(cart_uuid, product_uuid, specs) when is_map(specs) do
    # With specs - find item with matching specs
    CartItem
    |> where([i], i.cart_uuid == ^cart_uuid and i.product_uuid == ^product_uuid)
    |> where([i], i.selected_specs == ^specs)
    |> repo().one()
  end

  # Lock a cart row and refuse to mutate it unless it is still active.
  #
  # Two jobs, and the ORDER of the lock is what makes both work. Item
  # mutations previously changed a child row and only then recalculated,
  # so the cart lock inside `recalculate_cart_totals!/1` came too late to
  # serialize the mutation against a concurrent conversion: a quantity
  # edit could commit AFTER the order was created, leaving the order
  # saying one thing and `cart_items` another. Taking the lock first
  # closes that window.
  #
  # It also enforces the status invariant nothing was checking — a
  # converted or abandoned cart is finished business and must not accept
  # edits at all. Raises inside the caller's transaction so the whole
  # mutation rolls back.
  #
  # Lock ordering note: callers that also lock a PRODUCT row take
  # product-then-cart, and conversion locks only the cart, so there is no
  # cart→product path and no ABBA cycle.
  defp lock_active_cart!(cart_uuid) do
    cart =
      Cart
      |> where([c], c.uuid == ^cart_uuid)
      |> lock("FOR UPDATE")
      |> repo().one()

    case cart do
      %Cart{status: "active"} = cart -> cart
      %Cart{} -> repo().rollback(:cart_not_active)
      nil -> repo().rollback(:cart_not_found)
    end
  end

  defp recalculate_cart_totals!(%Cart{} = cart) do
    # Serialize concurrent recalculations of the SAME cart.
    #
    # Callers lock only the PRODUCT row, which does not serialize two adds
    # of DIFFERENT products: at READ COMMITTED both transactions insert
    # their item, each then recalculated over a snapshot containing only
    # its own, and the second cart UPDATE — which blocked on the first's
    # row lock — overwrote the totals with a value computed from stale
    # data. Both items persisted; the totals reflected one. Real money,
    # not just a UI glitch, since conversion copies these totals onto the
    # order.
    #
    # Taking the cart row lock HERE rather than in each of the eight
    # callers is what makes it correct: the lock must be held before the
    # item read, so the loser of the race re-reads after the winner
    # commits and sees both items. Contention is per-cart, so the cost is
    # negligible; the checkout conversion path is unaffected, it already
    # serializes on an atomic status transition.
    _locked =
      Cart
      |> where([c], c.uuid == ^cart.uuid)
      |> lock("FOR UPDATE")
      |> select([c], c.uuid)
      |> repo().one()

    items = CartItem |> where([i], i.cart_uuid == ^cart.uuid) |> repo().all()

    subtotal =
      Enum.reduce(items, Decimal.new("0"), fn i, acc ->
        Decimal.add(acc, i.line_total || Decimal.new("0"))
      end)

    total_weight =
      Enum.reduce(items, 0, fn i, acc ->
        acc + (i.weight_grams || 0) * i.quantity
      end)

    items_count =
      Enum.reduce(items, 0, fn i, acc ->
        acc + i.quantity
      end)

    # No shippable line, no shipping charge - the selected method (if any)
    # prices at zero and the order will omit the shipping line entirely.
    # Method pricing sees only the SHIPPABLE weight, so digital lines can't
    # move a mixed cart across a method's weight brackets.
    shipping_amount =
      if items_require_shipping?(items) do
        calculate_shipping(cart, subtotal, shippable_weight_grams(items))
      else
        Decimal.new("0")
      end

    # Calculate tax over the TAXABLE portion of the cart only.
    #
    # `CartItem` snapshots the product's `taxable` flag at add-to-cart
    # time, and every product form exposes it — but tax was charged on the
    # whole subtotal regardless, so a mixed cart over-collected on its
    # zero-rated lines. This was invisible until now only because tax was
    # always zero (the cart's shipping_country was never set), so fixing
    # that fix makes this one load-bearing.
    #
    # The discount is apportioned to the taxable share rather than
    # subtracted whole: taking it all off the taxable base would let a
    # discount on a zero-rated item wipe out tax owed on a standard-rated
    # one.
    tax_rate = get_tax_rate(cart)

    tax_amount =
      items
      |> taxable_base(subtotal, cart.discount_amount || Decimal.new("0"))
      |> Decimal.mult(tax_rate)
      |> Decimal.round(2)

    # Calculate total
    total =
      subtotal
      |> Decimal.add(shipping_amount)
      |> Decimal.add(tax_amount)
      |> Decimal.sub(cart.discount_amount || Decimal.new("0"))

    cart
    |> Cart.totals_changeset(%{
      subtotal: subtotal,
      shipping_amount: shipping_amount,
      tax_amount: tax_amount,
      total: total,
      total_weight_grams: total_weight,
      items_count: items_count
    })
    |> repo().update!()
    |> repo().preload([:items, :shipping_method], force: true)
  end

  # The portion of the cart tax actually applies to.
  #
  # `CartItem` snapshots the product's `taxable` flag, but tax used to be
  # charged on the whole subtotal, so a mixed cart over-collected on its
  # zero-rated lines.
  #
  # The discount is apportioned to the taxable share rather than subtracted
  # whole: taking it all off the taxable base would let a discount on a
  # zero-rated item wipe out tax owed on a standard-rated one.
  defp taxable_base(items, subtotal, discount) do
    taxable_subtotal =
      Enum.reduce(items, Decimal.new("0"), fn i, acc ->
        if i.taxable == false, do: acc, else: Decimal.add(acc, i.line_total || Decimal.new("0"))
      end)

    zero = Decimal.new("0")

    if Decimal.equal?(taxable_subtotal, zero) or Decimal.equal?(subtotal, zero) do
      zero
    else
      # Multiply BEFORE dividing. Computing `share = taxable / subtotal`
      # first rounds to Decimal's default 28 significant digits and the
      # error survives the multiplication: with taxable 1.05, subtotal
      # 10.02, discount 8.35 at 20%, the divide-first form yields a base of
      # 0.1749999999999999999999999999999999 and tax 0.03, where the exact
      # answer is 0.175 and 0.04. A cent, but a cent on every mixed cart.
      allocated_discount =
        discount
        |> Decimal.mult(taxable_subtotal)
        |> Decimal.div(subtotal)

      taxable_subtotal
      |> Decimal.sub(allocated_discount)
      |> Decimal.max(zero)
    end
  end

  defp calculate_shipping(cart, subtotal, total_weight) do
    if cart.shipping_method_uuid do
      cart.shipping_method_uuid
      |> then(&repo().get_by(ShippingMethod, uuid: &1))
      |> calculate_method_shipping(subtotal, total_weight, cart.shipping_country)
    else
      # No method selected, no charge - never echo back a stale
      # `cart.shipping_amount` from a previously-selected method that was
      # since cleared. This function's result is written straight back onto
      # the cart's `shipping_amount` by the caller, so echoing a stale value
      # here would persist it indefinitely.
      Decimal.new("0")
    end
  end

  defp calculate_method_shipping(nil, _subtotal, _weight, _country), do: Decimal.new("0")

  defp calculate_method_shipping(method, subtotal, total_weight, country) do
    if ShippingMethod.available_for?(method, %{
         weight_grams: total_weight,
         subtotal: subtotal,
         country: country
       }) do
      ShippingMethod.calculate_cost(method, subtotal)
    else
      Decimal.new("0")
    end
  end

  defp get_tax_rate(%Cart{shipping_country: nil}), do: Decimal.new("0")

  defp get_tax_rate(%Cart{shipping_country: _country}) do
    # Use billing module's tax rate as single source of truth
    billing_tax_rate()
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ============================================
  # TAX RATE (from Billing module — single source of truth)
  # ============================================

  defp billing_tax_enabled? do
    if Code.ensure_loaded?(PhoenixKitBilling) do
      PhoenixKitBilling.tax_enabled?()
    else
      Settings.get_setting_cached("billing_tax_enabled", "false") == "true"
    end
  end

  defp billing_tax_rate do
    if Code.ensure_loaded?(PhoenixKitBilling) do
      PhoenixKitBilling.get_tax_rate()
    else
      # Mirror PhoenixKitBilling.get_tax_rate/0, which yields 0 when tax is
      # disabled: without this gate the fallback would apply the default rate
      # even with billing_tax_enabled = "false".
      if billing_tax_enabled?(), do: fallback_tax_rate(), else: Decimal.new("0")
    end
  end

  defp fallback_tax_rate do
    rate = Settings.get_setting_cached("billing_default_tax_rate", "0")

    case Decimal.parse(rate) do
      {decimal, _rest} ->
        Decimal.div(decimal, Decimal.new("100"))

      :error ->
        Logger.warning(
          "Failed to parse billing_default_tax_rate setting #{inspect(rate)} as a decimal; " <>
            "falling back to a 0 tax rate."
        )

        Decimal.new("0")
    end
  end

  defp billing_tax_rate_percent do
    if Code.ensure_loaded?(PhoenixKitBilling) do
      PhoenixKitBilling.get_tax_rate_percent()
    else
      # Same enabled-gate as billing_tax_rate/0 so a configured default rate
      # is not reported while tax is disabled.
      if billing_tax_enabled?(), do: fallback_tax_rate_percent(), else: 0
    end
  end

  defp fallback_tax_rate_percent do
    rate = Settings.get_setting_cached("billing_default_tax_rate", "0")

    case Integer.parse(rate) do
      {value, _} ->
        value

      :error ->
        Logger.warning(
          "Failed to parse billing_default_tax_rate setting #{inspect(rate)} as an integer; " <>
            "falling back to a 0 tax-rate percent."
        )

        0
    end
  end

  # ============================================
  # IMPORT LOGS
  # ============================================

  alias PhoenixKitEcommerce.ImportLog

  @doc """
  Creates a new import log entry.
  """
  def create_import_log(attrs) do
    %ImportLog{}
    |> ImportLog.create_changeset(attrs)
    |> repo().insert()
  end

  @doc """
  Gets an import log by ID.
  """
  def get_import_log(id, opts \\ [])

  def get_import_log(uuid, opts) when is_binary(uuid) do
    ImportLog
    |> maybe_preload(Keyword.get(opts, :preload))
    |> repo().get_by(uuid: uuid)
  end

  @doc """
  Gets an import log by ID, raises if not found.
  """
  def get_import_log!(id) when is_binary(id) do
    case get_import_log(id) do
      nil -> raise Ecto.NoResultsError, queryable: ImportLog
      log -> log
    end
  end

  @doc """
  Lists recent import logs.
  """
  def list_import_logs(opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    ImportLog
    |> order_by([l], desc: l.inserted_at)
    |> limit(^limit)
    |> repo().all()
    |> repo().preload(:user)
  end

  @doc """
  Updates an import log.
  """
  def update_import_log(%ImportLog{} = import_log, attrs) do
    import_log
    |> ImportLog.update_changeset(attrs)
    |> repo().update()
  end

  @doc """
  Marks import as started.
  """
  def start_import(%ImportLog{} = import_log, total_rows) do
    import_log
    |> ImportLog.start_changeset(total_rows)
    |> repo().update()
  end

  @doc """
  Updates import progress.
  """
  def update_import_progress(%ImportLog{} = import_log, attrs) do
    import_log
    |> ImportLog.progress_changeset(attrs)
    |> repo().update()
  end

  @doc """
  Marks import as completed.
  """
  def complete_import(%ImportLog{} = import_log, stats) do
    import_log
    |> ImportLog.complete_changeset(stats)
    |> repo().update()
  end

  @doc """
  Marks import as failed.
  """
  def fail_import(%ImportLog{} = import_log, error) do
    import_log
    |> ImportLog.fail_changeset(error)
    |> repo().update()
  end

  @doc """
  Deletes an import log.
  """
  def delete_import_log(%ImportLog{} = import_log) do
    # Also delete the temp file if it exists
    if import_log.file_path && File.exists?(import_log.file_path) do
      File.rm(import_log.file_path)
    end

    repo().delete(import_log)
  end

  # ============================================
  # IMPORT CONFIG CRUD
  # ============================================

  @doc """
  Lists all active import configs.
  """
  def list_import_configs(opts \\ []) do
    query =
      ImportConfig
      |> order_by([c], desc: c.is_default, asc: c.name)

    query =
      if Keyword.get(opts, :active_only, true) do
        where(query, [c], c.active == true)
      else
        query
      end

    repo().all(query)
  end

  @doc """
  Gets an import config by ID.
  """
  def get_import_config(uuid) when is_binary(uuid) do
    repo().get_by(ImportConfig, uuid: uuid)
  end

  @doc """
  Gets an import config by ID, raises if not found.
  """
  def get_import_config!(id) when is_binary(id) do
    case get_import_config(id) do
      nil -> raise Ecto.NoResultsError, queryable: ImportConfig
      config -> config
    end
  end

  @doc """
  Gets the default import config, if one exists.
  """
  def get_default_import_config do
    ImportConfig
    |> where([c], c.is_default == true and c.active == true)
    |> limit(1)
    |> repo().one()
  end

  @doc """
  Gets an import config by name.
  """
  def get_import_config_by_name(name) when is_binary(name) do
    repo().get_by(ImportConfig, name: name)
  end

  @doc """
  Creates an import config.
  """
  def create_import_config(attrs \\ %{}) do
    result =
      %ImportConfig{}
      |> ImportConfig.changeset(attrs)
      |> repo().insert()

    # If this is the new default, clear other defaults
    case result do
      {:ok, %ImportConfig{is_default: true} = config} ->
        clear_other_defaults(config.uuid)
        {:ok, config}

      other ->
        other
    end
  end

  @doc """
  Updates an import config.
  """
  def update_import_config(%ImportConfig{} = config, attrs) do
    result =
      config
      |> ImportConfig.changeset(attrs)
      |> repo().update()

    # If this is the new default, clear other defaults
    case result do
      {:ok, %ImportConfig{is_default: true} = updated_config} ->
        clear_other_defaults(updated_config.uuid)
        {:ok, updated_config}

      other ->
        other
    end
  end

  @doc """
  Deletes an import config.
  """
  def delete_import_config(%ImportConfig{} = config) do
    repo().delete(config)
  end

  defp clear_other_defaults(except_uuid) do
    ImportConfig
    |> where([c], c.is_default == true and c.uuid != ^except_uuid)
    |> repo().update_all(set: [is_default: false])
  end

  @doc """
  Returns a changeset for tracking import config changes.
  """
  def change_import_config(%ImportConfig{} = config, attrs \\ %{}) do
    ImportConfig.changeset(config, attrs)
  end

  @doc """
  Creates the legacy default import config if no configs exist.

  Returns `{:created, config}` if a new config was created,
  or `:exists` if configs already exist.
  """
  def ensure_default_import_config do
    if repo().aggregate(ImportConfig, :count) == 0 do
      attrs = Map.from_struct(ImportConfig.from_legacy_defaults())
      {:ok, config} = create_import_config(attrs)
      {:created, config}
    else
      :exists
    end
  end

  @doc """
  Ensures a default Prom.ua import config exists.
  Creates one if no config with name "prom_ua_default" is found.
  """
  def ensure_prom_ua_import_config do
    case repo().get_by(ImportConfig, name: "prom_ua_default") do
      nil ->
        attrs =
          ImportConfig.from_prom_ua_defaults()
          |> Map.from_struct()
          |> Map.drop([:__meta__, :id, :uuid, :inserted_at, :updated_at])

        {:ok, config} = create_import_config(attrs)
        {:created, config}

      config ->
        {:exists, config}
    end
  end

  # ============================================
  # PRODUCT UPSERT
  # ============================================

  @doc """
  Creates or updates a product by slug.

  Uses explicit find-or-create pattern with proper localized field merging.
  After V47 migration, slug is a JSONB map (e.g., %{"en-US" => "my-slug"}),
  so ON CONFLICT doesn't work correctly - this function handles the lookup manually.

  Returns {:ok, product, action} where action is :inserted or :updated.

  ## Parameters

    - `attrs` - Product attributes including localized fields as maps

  ## Examples

      # Create new product
      iex> upsert_product(%{title: %{"en-US" => "Planter"}, slug: %{"en-US" => "planter"}, price: 10})
      {:ok, %Product{}, :inserted}

      # Update existing product (found by slug)
      iex> upsert_product(%{title: %{"en-US" => "Planter V2"}, slug: %{"en-US" => "planter"}, price: 15})
      {:ok, %Product{}, :updated}

      # Add translation to existing product
      iex> upsert_product(%{title: %{"es-ES" => "Maceta"}, slug: %{"es-ES" => "maceta", "en-US" => "planter"}, price: 10})
      {:ok, %Product{title: %{"en-US" => "Planter", "es-ES" => "Maceta"}}, :updated}

  """
  def upsert_product(attrs) do
    slug_map = get_attr(attrs, :slug) || %{}

    case find_product_by_slug_map(slug_map) do
      nil ->
        # New product - create it
        case create_product(attrs) do
          {:ok, product} -> {:ok, product, :inserted}
          error -> error
        end

      existing ->
        # Existing product - merge localized fields and update
        merged_attrs = merge_localized_attrs(existing, attrs)

        case update_product(existing, merged_attrs) do
          {:ok, product} -> {:ok, product, :updated}
          error -> error
        end
    end
  end

  @doc """
  Finds an existing product by any slug in the provided slug map.

  Searches through each slug value in the map to find a matching product.
  Returns the first product found, or nil if no match.

  ## Examples

      iex> find_product_by_slug_map(%{"en-US" => "planter"})
      %Product{} | nil

      iex> find_product_by_slug_map(%{"en-US" => "planter", "es-ES" => "maceta"})
      %Product{} | nil  # Finds by first matching slug
  """
  def find_product_by_slug_map(slug_map) when map_size(slug_map) == 0, do: nil

  def find_product_by_slug_map(slug_map) when is_map(slug_map) do
    # Try to find by any slug in the map
    Enum.find_value(slug_map, fn {lang, slug} ->
      case get_product_by_slug_localized(slug, lang) do
        {:ok, product} -> product
        _ -> nil
      end
    end)
  end

  @doc """
  Merges import attributes into an existing product.

  A feed states what it knows; it cannot state what it does not know. The
  importers always emit the full attribute set, so a column the file omits
  arrives as a blank — and treating that blank as an instruction meant a
  routine second import DELETED data the file never mentioned:

    * a blank Body (HTML) cell erased that product's description in *every*
      language, not merely the imported one;
    * a feed with no image columns cleared the product's images and vendor;
    * `metadata` was rebuilt from the feed, dropping the admin's option
      price modifiers, image mappings, price-display unit and custom keys.

  So a blank incoming value leaves the stored one alone, localized maps
  merge per language, and `metadata` merges per key. Anything the feed does
  carry still wins — including a value that clears a single translation.

  ## Examples

      iex> merge_localized_attrs(%Product{title: %{"en-US" => "Old"}}, %{title: %{"es-ES" => "Nuevo"}})
      %{title: %{"en-US" => "Old", "es-ES" => "Nuevo"}}
  """
  @localized_import_fields [:title, :slug, :description, :body_html, :seo_title, :seo_description]

  def merge_localized_attrs(existing, new_attrs) do
    language = import_language(new_attrs)

    @localized_import_fields
    |> Enum.reduce(new_attrs, fn field, acc ->
      merge_localized_field(acc, existing, field, language)
    end)
    |> merge_import_metadata(existing)
  end

  defp merge_localized_field(attrs, existing, field, language) do
    existing_map = Map.get(existing, field) || %{}
    new_map = get_attr(attrs, field) || %{}

    cond do
      map_size(new_map) > 0 ->
        put_attr(attrs, field, Map.merge(existing_map, new_map))

      # The column IS in the file and its cell is empty: clear that one
      # language. Writing `%{}` here erased every OTHER language too, which
      # no feed ever asked for.
      has_attr?(attrs, field) and is_binary(language) ->
        put_attr(attrs, field, Map.delete(existing_map, language))

      true ->
        drop_attr(attrs, field)
    end
  end

  # The language a set of import attrs is written in — read off whichever
  # localized map carries one. `title` is required, so this is nil only for a
  # row that will fail validation anyway.
  defp import_language(attrs) do
    Enum.find_value(@localized_import_fields, fn field ->
      case get_attr(attrs, field) do
        map when is_map(map) and map_size(map) > 0 -> map |> Map.keys() |> List.first()
        _ -> nil
      end
    end)
  end

  # `metadata` is DERIVED (option values, price modifiers, image mappings),
  # not a column, so an import that describes no options is not asking to
  # delete the admin's — or another importer's — namespaces.
  #
  # The merge is DEEP because these namespaces are keyed by option: a feed
  # that ships `_price_modifiers => %{"size" => …}` says nothing about the
  # admin-created `engraving` option living beside it, and a top-level merge
  # deleted it. A leaf the feed does carry still wins.
  defp merge_import_metadata(attrs, existing) do
    case get_attr(attrs, :metadata) do
      nil ->
        attrs

      incoming ->
        put_attr(attrs, :metadata, deep_merge(Map.get(existing, :metadata) || %{}, incoming))
    end
  end

  defp deep_merge(stored, incoming) when is_map(stored) and is_map(incoming) do
    Map.merge(stored, incoming, fn _key, old, new -> deep_merge(old, new) end)
  end

  defp deep_merge(_stored, incoming), do: incoming

  # Helper to get attribute from either atom or string keyed map
  defp get_attr(attrs, key) when is_atom(key) do
    Map.get(attrs, key) || Map.get(attrs, to_string(key))
  end

  defp has_attr?(attrs, key) when is_atom(key) do
    Map.has_key?(attrs, key) or Map.has_key?(attrs, to_string(key))
  end

  # Remove an attribute under either key spelling, so the changeset never
  # sees it and the stored value survives.
  defp drop_attr(attrs, key) when is_atom(key) do
    attrs |> Map.delete(key) |> Map.delete(to_string(key))
  end

  # Helper to put attribute preserving the map's key type.
  #
  # When the key is absent entirely, follow the spelling the REST of the map
  # uses: Ecto refuses a params map with mixed atom and string keys, so
  # adding `:metadata` to an otherwise string-keyed import row raised a
  # CastError instead of saving.
  defp put_attr(attrs, key, value) when is_atom(key) do
    cond do
      Map.has_key?(attrs, key) -> Map.put(attrs, key, value)
      Map.has_key?(attrs, to_string(key)) -> Map.put(attrs, to_string(key), value)
      Enum.any?(Map.keys(attrs), &is_binary/1) -> Map.put(attrs, to_string(key), value)
      true -> Map.put(attrs, key, value)
    end
  end

  # ============================================
  # LOCALIZED API (Multi-Language Support)
  # ============================================

  alias PhoenixKitEcommerce.SlugResolver
  alias PhoenixKitEcommerce.Translations

  @doc """
  Gets a product by slug with language awareness.

  Searches both translated slugs and canonical slug for the specified language.

  ## Parameters

    - `slug` - The URL slug to search for
    - `language` - Language code (e.g., "es-ES" or base code "en")
    - `opts` - Options: `:preload`, `:status`

  ## Examples

      iex> Shop.get_product_by_slug_localized("maceta-geometrica", "es-ES")
      {:ok, %Product{}}

      iex> Shop.get_product_by_slug_localized("geometric-planter", "en")
      {:ok, %Product{}}
  """
  def get_product_by_slug_localized(slug, language, opts \\ []) do
    SlugResolver.find_product_by_slug(slug, language, opts)
  end

  @doc """
  Gets a category by slug with language awareness.

  Searches both translated slugs and canonical slug for the specified language.

  ## Parameters

    - `slug` - The URL slug to search for
    - `language` - Language code (e.g., "es-ES" or base code "en")
    - `opts` - Options: `:preload`, `:status`

  ## Examples

      iex> Shop.get_category_by_slug_localized("jarrones-macetas", "es-ES")
      {:ok, %Category{}}
  """
  def get_category_by_slug_localized(slug, language, opts \\ []) do
    SlugResolver.find_category_by_slug(slug, language, opts)
  end

  @doc """
  Updates translation for a specific language on a product.

  ## Parameters

    - `product` - The product struct
    - `language` - Language code (e.g., "es-ES")
    - `attrs` - Translation attributes: title, slug, description, body_html, seo_title, seo_description

  ## Examples

      iex> Shop.update_product_translation(product, "es-ES", %{
      ...>   "title" => "Maceta Geométrica",
      ...>   "slug" => "maceta-geometrica"
      ...> })
      {:ok, %Product{}}
  """
  def update_product_translation(%Product{} = product, language, attrs)
      when is_binary(language) do
    # Convert attrs to atom-keyed map for changeset_attrs_multi
    field_values =
      attrs
      |> Enum.map(fn {k, v} -> {to_atom(k), v} end)
      |> Map.new()

    translation_attrs = Translations.changeset_attrs_multi(product, language, field_values)
    update_product(product, translation_attrs)
  end

  defp to_atom(key) when is_atom(key), do: key
  defp to_atom(key) when is_binary(key), do: String.to_existing_atom(key)

  @doc """
  Updates translation for a specific language on a category.

  ## Parameters

    - `category` - The category struct
    - `language` - Language code (e.g., "es-ES")
    - `attrs` - Translation attributes: name, slug, description

  ## Examples

      iex> Shop.update_category_translation(category, "es-ES", %{
      ...>   "name" => "Jarrones y Macetas",
      ...>   "slug" => "jarrones-macetas"
      ...> })
      {:ok, %Category{}}
  """
  def update_category_translation(%Category{} = category, language, attrs)
      when is_binary(language) do
    # Convert attrs to atom-keyed map for changeset_attrs_multi
    field_values =
      attrs
      |> Enum.map(fn {k, v} -> {to_atom(k), v} end)
      |> Map.new()

    translation_attrs = Translations.changeset_attrs_multi(category, language, field_values)
    update_category(category, translation_attrs)
  end

  @doc """
  Lists products with translated fields for a specific language.

  Returns products with an additional `:localized` virtual map containing
  translated fields with fallback to defaults.

  ## Parameters

    - `language` - Language code for translations
    - `opts` - Standard list options: `:page`, `:per_page`, `:status`, `:category_uuid`, etc.

  ## Examples

      iex> Shop.list_products_localized("es-ES", status: "active")
      [%Product{localized: %{title: "Maceta...", ...}}, ...]
  """
  def list_products_localized(language, opts \\ []) do
    products = list_products(opts)

    Enum.map(products, fn product ->
      Map.put(product, :localized, build_localized_product(product, language))
    end)
  end

  @doc """
  Lists categories with translated fields for a specific language.

  ## Parameters

    - `language` - Language code for translations
    - `opts` - Standard list options

  ## Examples

      iex> Shop.list_categories_localized("es-ES", status: "active")
      [%Category{localized: %{name: "Jarrones...", ...}}, ...]
  """
  def list_categories_localized(language, opts \\ []) do
    categories = list_categories(opts)

    Enum.map(categories, fn category ->
      Map.put(category, :localized, build_localized_category(category, language))
    end)
  end

  @doc """
  Gets the localized slug for a product.

  Returns translated slug if available, otherwise canonical slug.

  ## Examples

      iex> Shop.get_product_slug(product, "es-ES")
      "maceta-geometrica"
  """
  def get_product_slug(%Product{} = product, language) do
    SlugResolver.product_slug(product, language)
  end

  @doc """
  Gets the localized slug for a category.

  ## Examples

      iex> Shop.get_category_slug(category, "es-ES")
      "jarrones-macetas"
  """
  def get_category_slug(%Category{} = category, language) do
    SlugResolver.category_slug(category, language)
  end

  @doc """
  Finds a product by slug in any language.

  Searches across all translated slugs to find the product.
  Useful for cross-language redirect when user visits with a slug
  from a different language.

  ## Examples

      iex> Shop.get_product_by_any_slug("maceta-geometrica")
      {:ok, %Product{}, "es"}

      iex> Shop.get_product_by_any_slug("nonexistent")
      {:error, :not_found}
  """
  def get_product_by_any_slug(slug, opts \\ []) do
    SlugResolver.find_product_by_any_slug(slug, opts)
  end

  @doc """
  Finds a category by slug in any language.

  ## Examples

      iex> Shop.get_category_by_any_slug("jarrones-macetas")
      {:ok, %Category{}, "es"}
  """
  def get_category_by_any_slug(slug, opts \\ []) do
    SlugResolver.find_category_by_any_slug(slug, opts)
  end

  # ============================================
  # URL GENERATION
  # ============================================

  @doc """
  Generates a localized URL for a product.

  Returns the correct locale-prefixed URL with translated slug.
  The URL respects the PhoenixKit URL prefix configuration.

  ## Parameters

    - `product` - The Product struct
    - `language` - Language code (e.g., "en-US", "ru", "es-ES")

  ## Examples

      iex> Shop.product_url(product, "es-ES")
      "/es/shop/product/maceta-geometrica"

      iex> Shop.product_url(product, "ru")
      "/ru/shop/product/geometricheskoe-kashpo"

      iex> Shop.product_url(product, "en")
      "/shop/product/geometric-planter"  # Default language - no prefix
  """
  @spec product_url(Product.t(), String.t()) :: String.t()
  def product_url(%Product{} = product, language) do
    slug = SlugResolver.product_slug(product, language)
    base = DialectMapper.extract_base(language)
    # Let Routes.path handle locale prefix - it adds prefix for non-default locales
    Routes.path("/shop/product/#{slug}", locale: base)
  end

  @doc """
  Generates a localized URL for a category.

  Returns the correct locale-prefixed URL with translated slug.

  ## Parameters

    - `category` - The Category struct
    - `language` - Language code (e.g., "en-US", "ru", "es-ES")

  ## Examples

      iex> Shop.category_url(category, "es-ES")
      "/es/shop/category/jarrones-macetas"

      iex> Shop.category_url(category, "en")
      "/shop/category/vases-planters"  # Default language - no prefix
  """
  @spec category_url(Category.t(), String.t()) :: String.t()
  def category_url(%Category{} = category, language) do
    slug = SlugResolver.category_slug(category, language)
    base = DialectMapper.extract_base(language)
    # Let Routes.path handle locale prefix - it adds prefix for non-default locales
    Routes.path("/shop/category/#{slug}", locale: base)
  end

  @doc """
  Generates a localized URL for the shop catalog.

  ## Examples

      iex> Shop.catalog_url("es-ES")
      "/es/shop"

      iex> Shop.catalog_url("en")
      "/shop"
  """
  @spec catalog_url(String.t()) :: String.t()
  def catalog_url(language) do
    base = DialectMapper.extract_base(language)
    # Let Routes.path handle locale prefix - it adds prefix for non-default locales
    Routes.path("/shop", locale: base)
  end

  @doc """
  Generates a localized URL for the cart page.

  ## Examples

      iex> Shop.cart_url("ru")
      "/ru/cart"

      iex> Shop.cart_url("en")
      "/cart"
  """
  @spec cart_url(String.t()) :: String.t()
  def cart_url(language) do
    base = DialectMapper.extract_base(language)
    # Let Routes.path handle locale prefix - it adds prefix for non-default locales
    Routes.path("/cart", locale: base)
  end

  @doc """
  Generates a localized URL for the checkout page.

  ## Examples

      iex> Shop.checkout_url("ru")
      "/ru/checkout"

      iex> Shop.checkout_url("en")
      "/checkout"
  """
  @spec checkout_url(String.t()) :: String.t()
  def checkout_url(language) do
    base = DialectMapper.extract_base(language)
    # Let Routes.path handle locale prefix - it adds prefix for non-default locales
    Routes.path("/checkout", locale: base)
  end

  @doc """
  Gets the default language code (base code, e.g., "en").

  Reads from Languages module configuration or falls back to "en".
  """
  @spec get_default_language() :: String.t()
  def get_default_language do
    case Languages.get_default_language() do
      nil -> "en"
      lang -> DialectMapper.extract_base(lang.code)
    end
  end

  @doc """
  Checks if a product slug exists for a language.

  Useful for validation during translation editing.

  ## Examples

      iex> Shop.product_slug_exists?("maceta-geometrica", "es-ES")
      true

      iex> Shop.product_slug_exists?("maceta-geometrica", "es-ES", exclude_uuid: "some-uuid")
      false
  """
  def product_slug_exists?(slug, language, opts \\ []) do
    SlugResolver.product_slug_exists?(slug, language, opts)
  end

  @doc """
  Checks if a category slug exists for a language.

  ## Examples

      iex> Shop.category_slug_exists?("jarrones-macetas", "es-ES")
      true
  """
  def category_slug_exists?(slug, language, opts \\ []) do
    SlugResolver.category_slug_exists?(slug, language, opts)
  end

  @doc """
  Returns translation helpers module for direct access.

  ## Examples

      iex> Shop.translations()
      PhoenixKitEcommerce.Translations
  """
  def translations, do: Translations

  # Build localized map for a product
  defp build_localized_product(product, language) do
    %{
      title: Translations.get_field(product, :title, language),
      slug: Translations.get_field(product, :slug, language) || product.slug,
      description: Translations.get_field(product, :description, language),
      body_html: Translations.get_field(product, :body_html, language),
      seo_title: Translations.get_field(product, :seo_title, language),
      seo_description: Translations.get_field(product, :seo_description, language)
    }
  end

  # Build localized map for a category
  defp build_localized_category(category, language) do
    %{
      name: Translations.get_field(category, :name, language),
      slug: Translations.get_field(category, :slug, language) || category.slug,
      description: Translations.get_field(category, :description, language)
    }
  end
end
