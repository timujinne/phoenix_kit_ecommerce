defmodule PhoenixKit.Modules.Shop do
  # DEPRECATED DELEGATE SHIM — not a real module home.
  #
  # The pre-extraction name of `PhoenixKitEcommerce`, kept so a host written
  # against it keeps compiling while it switches. Every delegate is
  # `@deprecated` and names its replacement, which is the same function on
  # `PhoenixKitEcommerce`. Nothing is added here: a function that exists only
  # under the new name has no delegate, and a removed one loses its own.
  #
  # `@moduledoc false` keeps this transitional shim out of HexDocs and avoids
  # ex_doc warnings about defdelegates pointing at @impl callbacks that have
  # no explicit @doc on the target.
  @moduledoc false

  # Module info and config
  @deprecated "Use PhoenixKitEcommerce.enabled?/0 instead"
  defdelegate enabled?(), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.enable_system/0 instead"
  defdelegate enable_system(), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.disable_system/0 instead"
  defdelegate disable_system(), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.module_key/0 instead"
  defdelegate module_key(), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.module_name/0 instead"
  defdelegate module_name(), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.required_modules/0 instead"
  defdelegate required_modules(), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.route_module/0 instead"
  defdelegate route_module(), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.translations/0 instead"
  defdelegate translations(), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.permission_metadata/0 instead"
  defdelegate permission_metadata(), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.admin_tabs/0 instead"
  defdelegate admin_tabs(), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.settings_tabs/0 instead"
  defdelegate settings_tabs(), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.user_dashboard_tabs/0 instead"
  defdelegate user_dashboard_tabs(), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.get_config/0 instead"
  defdelegate get_config(), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.children/0 instead"
  defdelegate children(), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.default_checkout_country/0 instead"
  defdelegate default_checkout_country(), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.stock_tracking_enabled?/0 instead"
  defdelegate stock_tracking_enabled?(), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.warehouse_status/0 instead"
  defdelegate warehouse_status(), to: PhoenixKitEcommerce

  # Dashboard
  @deprecated "Use PhoenixKitEcommerce.get_dashboard_stats/0 instead"
  defdelegate get_dashboard_stats(), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.get_default_currency/0 instead"
  defdelegate get_default_currency(), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.get_default_currency_code/0 instead"
  defdelegate get_default_currency_code(), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.get_display_currency_code/0 instead"
  defdelegate get_display_currency_code(), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.get_base_currency/0 instead"
  defdelegate get_base_currency(), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.enforce_product_currency?/0 instead"
  defdelegate enforce_product_currency?(), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.currency_for_code/1 instead"
  defdelegate currency_for_code(code), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.fx_rate_drift_alert_pct/0 instead"
  defdelegate fx_rate_drift_alert_pct(), to: PhoenixKitEcommerce

  @deprecated "Use PhoenixKitEcommerce.reprice_for_base_change/3 instead"
  defdelegate reprice_for_base_change(old_base_code, new_base_code, multiplier),
    to: PhoenixKitEcommerce

  @deprecated "Use PhoenixKitEcommerce.get_default_language/0 instead"
  defdelegate get_default_language(), to: PhoenixKitEcommerce

  # URLs
  @deprecated "Use PhoenixKitEcommerce.catalog_url/1 instead"
  defdelegate catalog_url(locale), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.category_url/2 instead"
  defdelegate category_url(locale, slug), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.product_url/2 instead"
  defdelegate product_url(locale, slug), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.cart_url/1 instead"
  defdelegate cart_url(locale), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.checkout_url/1 instead"
  defdelegate checkout_url(locale), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.url_locale/1 instead"
  defdelegate url_locale(language), to: PhoenixKitEcommerce

  # Products
  @deprecated "Use PhoenixKitEcommerce.list_products/1 instead"
  defdelegate list_products(opts \\ []), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.list_products_with_count/1 instead"
  defdelegate list_products_with_count(opts), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.list_products_by_ids/1 instead"
  defdelegate list_products_by_ids(ids), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.list_products_localized/1 instead"
  defdelegate list_products_localized(opts), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.get_product/1 instead"
  defdelegate get_product(id), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.get_product!/1 instead"
  defdelegate get_product!(id), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.get_product_by_slug/1 instead"
  defdelegate get_product_by_slug(slug), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.get_product_by_any_slug/1 instead"
  defdelegate get_product_by_any_slug(slug), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.get_product_by_slug_localized/3 instead"
  defdelegate get_product_by_slug_localized(slug, locale, opts \\ []), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.get_product_slug/2 instead"
  defdelegate get_product_slug(product, locale), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.product_slug_exists?/3 instead"
  defdelegate product_slug_exists?(slug, language, opts \\ []), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.change_product/2 instead"
  defdelegate change_product(product, attrs \\ %{}), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.create_product/1 instead"
  defdelegate create_product(attrs), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.update_product/2 instead"
  defdelegate update_product(product, attrs), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.update_product_translation/3 instead"
  defdelegate update_product_translation(product, locale, attrs), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.upsert_product/1 instead"
  defdelegate upsert_product(attrs), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.delete_product/1 instead"
  defdelegate delete_product(product), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.calculate_product_price/2 instead"
  defdelegate calculate_product_price(product, selected_specs \\ %{}), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.format_product_price/3 instead"
  defdelegate format_product_price(product, currency, style \\ :from), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.collect_product_file_uuids/1 instead"
  defdelegate collect_product_file_uuids(product), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.collect_products_file_uuids/1 instead"
  defdelegate collect_products_file_uuids(products), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.find_product_by_slug_map/1 instead"
  defdelegate find_product_by_slug_map(slug_map), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.merge_localized_attrs/2 instead"
  defdelegate merge_localized_attrs(existing, new_attrs), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.bulk_update_product_status/2 instead"
  defdelegate bulk_update_product_status(ids, status), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.bulk_update_product_category/2 instead"
  defdelegate bulk_update_product_category(ids, category_id), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.bulk_delete_products/1 instead"
  defdelegate bulk_delete_products(ids), to: PhoenixKitEcommerce

  # Product specs and filters
  @deprecated "Use PhoenixKitEcommerce.get_price_affecting_specs/1 instead"
  defdelegate get_price_affecting_specs(product), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.get_selectable_specs/1 instead"
  defdelegate get_selectable_specs(product), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.get_price_range/1 instead"
  defdelegate get_price_range(products_or_opts), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.validate_selected_specs/2 instead"
  defdelegate validate_selected_specs(product, selected), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.default_storefront_filters/0 instead"
  defdelegate default_storefront_filters(), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.get_storefront_filters/0 instead"
  defdelegate get_storefront_filters(), to: PhoenixKitEcommerce

  @deprecated "Use PhoenixKitEcommerce.get_enabled_storefront_filters/2 instead"
  defdelegate get_enabled_storefront_filters(category \\ nil, language \\ nil),
    to: PhoenixKitEcommerce

  @deprecated "Use PhoenixKitEcommerce.merge_storefront_filters/2 instead"
  defdelegate merge_storefront_filters(global_filters, category_filters), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.update_storefront_filters/1 instead"
  defdelegate update_storefront_filters(filters), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.aggregate_filter_values/1 instead"
  defdelegate aggregate_filter_values(products), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.discover_filterable_options/0 instead"
  defdelegate discover_filterable_options(), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.ensure_featured_product/1 instead"
  defdelegate ensure_featured_product(product), to: PhoenixKitEcommerce

  # Categories
  @deprecated "Use PhoenixKitEcommerce.list_categories/1 instead"
  defdelegate list_categories(opts \\ []), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.list_categories_with_count/1 instead"
  defdelegate list_categories_with_count(opts), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.list_categories_localized/1 instead"
  defdelegate list_categories_localized(opts), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.list_active_categories/1 instead"
  defdelegate list_active_categories(opts \\ []), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.list_visible_categories/1 instead"
  defdelegate list_visible_categories(opts \\ []), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.list_root_categories/1 instead"
  defdelegate list_root_categories(opts \\ []), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.list_menu_categories/1 instead"
  defdelegate list_menu_categories(opts \\ []), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.list_empty_categories/0 instead"
  defdelegate list_empty_categories(), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.list_category_product_options/1 instead"
  defdelegate list_category_product_options(category_id), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.category_options/0 instead"
  defdelegate category_options(), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.product_counts_by_category/0 instead"
  defdelegate product_counts_by_category(), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.get_category/1 instead"
  defdelegate get_category(id), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.get_category!/1 instead"
  defdelegate get_category!(id), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.get_category_by_slug/1 instead"
  defdelegate get_category_by_slug(slug), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.get_category_by_any_slug/1 instead"
  defdelegate get_category_by_any_slug(slug), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.get_category_by_slug_localized/2 instead"
  defdelegate get_category_by_slug_localized(slug, locale), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.get_category_slug/2 instead"
  defdelegate get_category_slug(category, locale), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.category_slug_exists?/3 instead"
  defdelegate category_slug_exists?(slug, language, opts \\ []), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.change_category/2 instead"
  defdelegate change_category(category, attrs \\ %{}), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.create_category/1 instead"
  defdelegate create_category(attrs), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.update_category/2 instead"
  defdelegate update_category(category, attrs), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.update_category_translation/3 instead"
  defdelegate update_category_translation(category, locale, attrs), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.delete_category/1 instead"
  defdelegate delete_category(category), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.bulk_update_category_status/2 instead"
  defdelegate bulk_update_category_status(ids, status), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.bulk_update_category_parent/2 instead"
  defdelegate bulk_update_category_parent(ids, parent_id), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.bulk_delete_categories/1 instead"
  defdelegate bulk_delete_categories(ids), to: PhoenixKitEcommerce

  # Cart
  @deprecated "Use PhoenixKitEcommerce.get_or_create_cart/1 instead"
  defdelegate get_or_create_cart(opts), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.get_cart/1 instead"
  defdelegate get_cart(id), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.get_cart!/1 instead"
  defdelegate get_cart!(id), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.find_active_cart/1 instead"
  defdelegate find_active_cart(opts), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.create_cart/1 instead"
  defdelegate create_cart(attrs), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.add_to_cart/4 instead"
  defdelegate add_to_cart(cart, product_uuid, quantity, opts \\ []), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.remove_from_cart/1 instead"
  defdelegate remove_from_cart(item), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.update_cart_item/2 instead"
  defdelegate update_cart_item(item, quantity), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.clear_cart/1 instead"
  defdelegate clear_cart(cart), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.merge_guest_cart/2 instead"
  defdelegate merge_guest_cart(session_id, user), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.refresh_cart_rate/1 instead"
  defdelegate refresh_cart_rate(cart), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.cart_rate_drift/1 instead"
  defdelegate cart_rate_drift(cart), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.rebase_cart/1 instead"
  defdelegate rebase_cart(cart), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.set_cart_shipping/3 instead"
  defdelegate set_cart_shipping(cart, method_uuid, cost), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.set_cart_shipping_country/2 instead"
  defdelegate set_cart_shipping_country(cart, country_code), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.set_cart_payment_option/2 instead"
  defdelegate set_cart_payment_option(cart, payment_option_uuid), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.auto_select_shipping_method/2 instead"
  defdelegate auto_select_shipping_method(cart, shipping_methods), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.refresh_pay_on_delivery_shipping/1 instead"
  defdelegate refresh_pay_on_delivery_shipping(cart), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.auto_select_payment_option/2 instead"
  defdelegate auto_select_payment_option(cart, payment_options), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.convert_cart_to_order/2 instead"
  defdelegate convert_cart_to_order(cart, opts), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.list_carts_with_count/1 instead"
  defdelegate list_carts_with_count(opts), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.count_active_carts/0 instead"
  defdelegate count_active_carts(), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.expire_old_carts/0 instead"
  defdelegate expire_old_carts(), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.mark_abandoned_carts/0 instead"
  defdelegate mark_abandoned_carts(), to: PhoenixKitEcommerce

  # Shipping Methods
  @deprecated "Use PhoenixKitEcommerce.list_shipping_methods/1 instead"
  defdelegate list_shipping_methods(opts \\ []), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.get_shipping_method/1 instead"
  defdelegate get_shipping_method(id), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.get_shipping_method!/1 instead"
  defdelegate get_shipping_method!(id), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.get_shipping_method_by_slug/1 instead"
  defdelegate get_shipping_method_by_slug(slug), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.get_available_shipping_methods/1 instead"
  defdelegate get_available_shipping_methods(cart), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.present_shipping_method/2 instead"
  defdelegate present_shipping_method(cart, method), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.change_shipping_method/2 instead"
  defdelegate change_shipping_method(method, attrs \\ %{}), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.create_shipping_method/1 instead"
  defdelegate create_shipping_method(attrs), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.update_shipping_method/2 instead"
  defdelegate update_shipping_method(method, attrs), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.delete_shipping_method/1 instead"
  defdelegate delete_shipping_method(method), to: PhoenixKitEcommerce

  # Calculated shipping
  @deprecated "Use PhoenixKitEcommerce.shipping_parcel_defaults/0 instead"
  defdelegate shipping_parcel_defaults(), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.update_shipping_parcel_defaults/1 instead"
  defdelegate update_shipping_parcel_defaults(attrs), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.cart_parcels/1 instead"
  defdelegate cart_parcels(cart), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.cart_declared_value/1 instead"
  defdelegate cart_declared_value(cart), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.cart_shipping_destination/1 instead"
  defdelegate cart_shipping_destination(cart), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.set_cart_shipping_destination/2 instead"
  defdelegate set_cart_shipping_destination(cart, destination), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.build_cart_rate_request/1 instead"
  defdelegate build_cart_rate_request(cart), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.quote_cart_shipping/2 instead"
  defdelegate quote_cart_shipping(cart, opts \\ []), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.shipping_quote_status/1 instead"
  defdelegate shipping_quote_status(cart), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.cart_shipping_quote/1 instead"
  defdelegate cart_shipping_quote(cart), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.shipping_quote_blocks_checkout?/1 instead"
  defdelegate shipping_quote_blocks_checkout?(cart), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.shipping_quote_snapshot/2 instead"
  defdelegate shipping_quote_snapshot(cart, method \\ :selected), to: PhoenixKitEcommerce

  # Imports
  @deprecated "Use PhoenixKitEcommerce.list_import_configs/1 instead"
  defdelegate list_import_configs(opts \\ []), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.get_import_config/1 instead"
  defdelegate get_import_config(id), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.get_import_config!/1 instead"
  defdelegate get_import_config!(id), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.get_import_config_by_name/1 instead"
  defdelegate get_import_config_by_name(name), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.get_default_import_config/0 instead"
  defdelegate get_default_import_config(), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.ensure_default_import_config/0 instead"
  defdelegate ensure_default_import_config(), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.ensure_prom_ua_import_config/0 instead"
  defdelegate ensure_prom_ua_import_config(), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.change_import_config/2 instead"
  defdelegate change_import_config(config, attrs \\ %{}), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.create_import_config/1 instead"
  defdelegate create_import_config(attrs), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.update_import_config/2 instead"
  defdelegate update_import_config(config, attrs), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.delete_import_config/1 instead"
  defdelegate delete_import_config(config), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.list_import_logs/1 instead"
  defdelegate list_import_logs(opts \\ []), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.get_import_log/1 instead"
  defdelegate get_import_log(id), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.get_import_log!/1 instead"
  defdelegate get_import_log!(id), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.create_import_log/1 instead"
  defdelegate create_import_log(attrs), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.update_import_log/2 instead"
  defdelegate update_import_log(log, attrs), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.update_import_progress/2 instead"
  defdelegate update_import_progress(log, attrs), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.delete_import_log/1 instead"
  defdelegate delete_import_log(log), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.start_import/2 instead"
  defdelegate start_import(import_log, total_rows), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.complete_import/2 instead"
  defdelegate complete_import(log, attrs), to: PhoenixKitEcommerce
  @deprecated "Use PhoenixKitEcommerce.fail_import/2 instead"
  defdelegate fail_import(log, reason), to: PhoenixKitEcommerce
end
