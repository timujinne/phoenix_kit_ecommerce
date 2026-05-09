defmodule PhoenixKit.Modules.Shop do
  # Compat alias for PhoenixKitEcommerce. Delegates all public functions so
  # core can reference the old namespace. Will be removed once core is fully
  # migrated to `PhoenixKitEcommerce.*`.
  #
  # `@moduledoc false` keeps this transitional shim out of HexDocs and avoids
  # ex_doc warnings about defdelegates pointing at @impl callbacks that have
  # no explicit @doc on the target.
  @moduledoc false

  # Module info and config
  defdelegate enabled?(), to: PhoenixKitEcommerce
  defdelegate enable_system(), to: PhoenixKitEcommerce
  defdelegate disable_system(), to: PhoenixKitEcommerce
  defdelegate module_key(), to: PhoenixKitEcommerce
  defdelegate module_name(), to: PhoenixKitEcommerce
  defdelegate required_modules(), to: PhoenixKitEcommerce
  defdelegate route_module(), to: PhoenixKitEcommerce
  defdelegate translations(), to: PhoenixKitEcommerce
  defdelegate permission_metadata(), to: PhoenixKitEcommerce
  defdelegate admin_tabs(), to: PhoenixKitEcommerce
  defdelegate settings_tabs(), to: PhoenixKitEcommerce
  defdelegate user_dashboard_tabs(), to: PhoenixKitEcommerce
  defdelegate get_config(), to: PhoenixKitEcommerce

  # Dashboard
  defdelegate get_dashboard_stats(), to: PhoenixKitEcommerce
  defdelegate get_default_currency(), to: PhoenixKitEcommerce
  defdelegate get_default_currency_code(), to: PhoenixKitEcommerce
  defdelegate get_default_language(), to: PhoenixKitEcommerce

  # URLs
  defdelegate catalog_url(locale), to: PhoenixKitEcommerce
  defdelegate category_url(locale, slug), to: PhoenixKitEcommerce
  defdelegate product_url(locale, slug), to: PhoenixKitEcommerce
  defdelegate cart_url(locale), to: PhoenixKitEcommerce
  defdelegate checkout_url(locale), to: PhoenixKitEcommerce

  # Products
  defdelegate list_products(opts \\ []), to: PhoenixKitEcommerce
  defdelegate list_products_with_count(opts), to: PhoenixKitEcommerce
  defdelegate list_products_by_ids(ids), to: PhoenixKitEcommerce
  defdelegate list_products_localized(opts), to: PhoenixKitEcommerce
  defdelegate get_product(id), to: PhoenixKitEcommerce
  defdelegate get_product!(id), to: PhoenixKitEcommerce
  defdelegate get_product_by_slug(slug), to: PhoenixKitEcommerce
  defdelegate get_product_by_any_slug(slug), to: PhoenixKitEcommerce
  defdelegate get_product_by_slug_localized(slug, locale, opts \\ []), to: PhoenixKitEcommerce
  defdelegate get_product_slug(product, locale), to: PhoenixKitEcommerce
  defdelegate product_slug_exists?(slug, language, opts \\ []), to: PhoenixKitEcommerce
  defdelegate change_product(product, attrs \\ %{}), to: PhoenixKitEcommerce
  defdelegate create_product(attrs), to: PhoenixKitEcommerce
  defdelegate update_product(product, attrs), to: PhoenixKitEcommerce
  defdelegate update_product_translation(product, locale, attrs), to: PhoenixKitEcommerce
  defdelegate upsert_product(attrs), to: PhoenixKitEcommerce
  defdelegate delete_product(product), to: PhoenixKitEcommerce
  defdelegate calculate_product_price(product, selected_specs \\ %{}), to: PhoenixKitEcommerce
  defdelegate format_product_price(product, currency, style \\ :from), to: PhoenixKitEcommerce
  defdelegate collect_product_file_uuids(product), to: PhoenixKitEcommerce
  defdelegate collect_products_file_uuids(products), to: PhoenixKitEcommerce
  defdelegate find_product_by_slug_map(slug_map), to: PhoenixKitEcommerce
  defdelegate merge_localized_attrs(existing, new_attrs), to: PhoenixKitEcommerce
  defdelegate bulk_update_product_status(ids, status), to: PhoenixKitEcommerce
  defdelegate bulk_update_product_category(ids, category_id), to: PhoenixKitEcommerce
  defdelegate bulk_delete_products(ids), to: PhoenixKitEcommerce

  # Product specs and filters
  defdelegate get_price_affecting_specs(product), to: PhoenixKitEcommerce
  defdelegate get_selectable_specs(product), to: PhoenixKitEcommerce
  defdelegate get_price_range(products_or_opts), to: PhoenixKitEcommerce
  defdelegate validate_selected_specs(product, selected), to: PhoenixKitEcommerce
  defdelegate default_storefront_filters(), to: PhoenixKitEcommerce
  defdelegate get_storefront_filters(), to: PhoenixKitEcommerce
  defdelegate get_enabled_storefront_filters(), to: PhoenixKitEcommerce
  defdelegate update_storefront_filters(filters), to: PhoenixKitEcommerce
  defdelegate aggregate_filter_values(products), to: PhoenixKitEcommerce
  defdelegate discover_filterable_options(), to: PhoenixKitEcommerce
  defdelegate ensure_featured_product(product), to: PhoenixKitEcommerce

  # Categories
  defdelegate list_categories(opts \\ []), to: PhoenixKitEcommerce
  defdelegate list_categories_with_count(opts), to: PhoenixKitEcommerce
  defdelegate list_categories_localized(opts), to: PhoenixKitEcommerce
  defdelegate list_active_categories(opts \\ []), to: PhoenixKitEcommerce
  defdelegate list_visible_categories(opts \\ []), to: PhoenixKitEcommerce
  defdelegate list_root_categories(opts \\ []), to: PhoenixKitEcommerce
  defdelegate list_menu_categories(opts \\ []), to: PhoenixKitEcommerce
  defdelegate list_empty_categories(), to: PhoenixKitEcommerce
  defdelegate list_category_product_options(category_id), to: PhoenixKitEcommerce
  defdelegate category_options(), to: PhoenixKitEcommerce
  defdelegate product_counts_by_category(), to: PhoenixKitEcommerce
  defdelegate get_category(id), to: PhoenixKitEcommerce
  defdelegate get_category!(id), to: PhoenixKitEcommerce
  defdelegate get_category_by_slug(slug), to: PhoenixKitEcommerce
  defdelegate get_category_by_any_slug(slug), to: PhoenixKitEcommerce
  defdelegate get_category_by_slug_localized(slug, locale), to: PhoenixKitEcommerce
  defdelegate get_category_slug(category, locale), to: PhoenixKitEcommerce
  defdelegate category_slug_exists?(slug, language, opts \\ []), to: PhoenixKitEcommerce
  defdelegate change_category(category, attrs \\ %{}), to: PhoenixKitEcommerce
  defdelegate create_category(attrs), to: PhoenixKitEcommerce
  defdelegate update_category(category, attrs), to: PhoenixKitEcommerce
  defdelegate update_category_translation(category, locale, attrs), to: PhoenixKitEcommerce
  defdelegate delete_category(category), to: PhoenixKitEcommerce
  defdelegate bulk_update_category_status(ids, status), to: PhoenixKitEcommerce
  defdelegate bulk_update_category_parent(ids, parent_id), to: PhoenixKitEcommerce
  defdelegate bulk_delete_categories(ids), to: PhoenixKitEcommerce

  # Cart
  defdelegate get_or_create_cart(opts), to: PhoenixKitEcommerce
  defdelegate get_cart(id), to: PhoenixKitEcommerce
  defdelegate get_cart!(id), to: PhoenixKitEcommerce
  defdelegate find_active_cart(opts), to: PhoenixKitEcommerce
  defdelegate create_cart(attrs), to: PhoenixKitEcommerce
  defdelegate add_to_cart(cart, product_uuid, quantity, opts \\ []), to: PhoenixKitEcommerce
  defdelegate remove_from_cart(item), to: PhoenixKitEcommerce
  defdelegate update_cart_item(item, quantity), to: PhoenixKitEcommerce
  defdelegate clear_cart(cart), to: PhoenixKitEcommerce
  defdelegate merge_guest_cart(session_id, user), to: PhoenixKitEcommerce
  defdelegate set_cart_shipping(cart, method_uuid, cost), to: PhoenixKitEcommerce
  defdelegate set_cart_shipping_country(cart, country_code), to: PhoenixKitEcommerce
  defdelegate set_cart_payment_option(cart, payment_option_uuid), to: PhoenixKitEcommerce
  defdelegate auto_select_shipping_method(cart, shipping_methods), to: PhoenixKitEcommerce
  defdelegate auto_select_payment_option(cart, payment_options), to: PhoenixKitEcommerce
  defdelegate convert_cart_to_order(cart, opts), to: PhoenixKitEcommerce
  defdelegate list_carts_with_count(opts), to: PhoenixKitEcommerce
  defdelegate count_active_carts(), to: PhoenixKitEcommerce
  defdelegate expire_old_carts(), to: PhoenixKitEcommerce
  defdelegate mark_abandoned_carts(), to: PhoenixKitEcommerce

  # Shipping Methods
  defdelegate list_shipping_methods(opts \\ []), to: PhoenixKitEcommerce
  defdelegate get_shipping_method(id), to: PhoenixKitEcommerce
  defdelegate get_shipping_method!(id), to: PhoenixKitEcommerce
  defdelegate get_shipping_method_by_slug(slug), to: PhoenixKitEcommerce
  defdelegate get_available_shipping_methods(cart), to: PhoenixKitEcommerce
  defdelegate change_shipping_method(method, attrs \\ %{}), to: PhoenixKitEcommerce
  defdelegate create_shipping_method(attrs), to: PhoenixKitEcommerce
  defdelegate update_shipping_method(method, attrs), to: PhoenixKitEcommerce
  defdelegate delete_shipping_method(method), to: PhoenixKitEcommerce

  # Imports
  defdelegate list_import_configs(opts \\ []), to: PhoenixKitEcommerce
  defdelegate get_import_config(id), to: PhoenixKitEcommerce
  defdelegate get_import_config!(id), to: PhoenixKitEcommerce
  defdelegate get_import_config_by_name(name), to: PhoenixKitEcommerce
  defdelegate get_default_import_config(), to: PhoenixKitEcommerce
  defdelegate ensure_default_import_config(), to: PhoenixKitEcommerce
  defdelegate ensure_prom_ua_import_config(), to: PhoenixKitEcommerce
  defdelegate change_import_config(config, attrs \\ %{}), to: PhoenixKitEcommerce
  defdelegate create_import_config(attrs), to: PhoenixKitEcommerce
  defdelegate update_import_config(config, attrs), to: PhoenixKitEcommerce
  defdelegate delete_import_config(config), to: PhoenixKitEcommerce
  defdelegate list_import_logs(opts \\ []), to: PhoenixKitEcommerce
  defdelegate get_import_log(id), to: PhoenixKitEcommerce
  defdelegate get_import_log!(id), to: PhoenixKitEcommerce
  defdelegate create_import_log(attrs), to: PhoenixKitEcommerce
  defdelegate update_import_log(log, attrs), to: PhoenixKitEcommerce
  defdelegate update_import_progress(log, attrs), to: PhoenixKitEcommerce
  defdelegate delete_import_log(log), to: PhoenixKitEcommerce
  defdelegate start_import(import_log, total_rows), to: PhoenixKitEcommerce
  defdelegate complete_import(log, attrs), to: PhoenixKitEcommerce
  defdelegate fail_import(log, reason), to: PhoenixKitEcommerce
end
