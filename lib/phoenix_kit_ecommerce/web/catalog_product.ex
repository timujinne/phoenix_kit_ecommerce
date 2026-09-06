defmodule PhoenixKitEcommerce.Web.CatalogProduct do
  @moduledoc """
  Public product detail page with add-to-cart functionality.

  Supports dynamic option-based pricing with fixed and percent modifiers.
  """

  use PhoenixKitEcommerce.Web, :live_view

  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKitBilling.Currency
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Events
  alias PhoenixKitEcommerce.Options
  alias PhoenixKitEcommerce.Policy
  alias PhoenixKitEcommerce.PriceDisplay
  alias PhoenixKitEcommerce.SlugResolver
  alias PhoenixKitEcommerce.Translations
  alias PhoenixKitEcommerce.Web.Components.CatalogSidebar
  alias PhoenixKitEcommerce.Web.Components.FilterHelpers
  alias PhoenixKitEcommerce.Web.Components.ShopCards
  alias PhoenixKitEcommerce.Web.Components.ShopLayouts
  alias PhoenixKitEcommerce.Web.Helpers
  alias PhoenixKitEcommerce.Web.SEOHelpers
  import PhoenixKitEcommerce.Web.Helpers, only: [format_price: 2]
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitEcommerce.Vocabulary

  # Data URI placeholder for broken images - works without external file serving
  @placeholder_data_uri "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='400' height='400' viewBox='0 0 400 400'%3E%3Crect width='400' height='400' fill='%23e5e7eb'/%3E%3Cg fill='%239ca3af'%3E%3Crect x='160' y='140' width='80' height='60' rx='4'/%3E%3Ccircle cx='180' cy='160' r='8'/%3E%3Cpath d='M160 190 l25-20 l15 15 l20-25 l20 30 v10 h-80 z'/%3E%3C/g%3E%3C/svg%3E"

  @impl true
  def mount(params, session, socket) do
    # The storefront of a DISABLED shop must not be browsable or purchasable;
    # only the order-confirmation page stays reachable (it is a receipt for an
    # already-placed order, not shopping). Admin pages are unaffected - that is
    # where the module gets re-enabled.
    if Shop.enabled?() do
      do_mount(params, session, socket)
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("The shop is currently unavailable"))
       # The HOST's root, not Routes.path("/") - that prepends the
       # PhoenixKit prefix ("/phoenix_kit/"), which no route serves.
       |> push_navigate(to: "/")}
    end
  end

  defp do_mount(%{"slug" => slug} = params, session, socket) do
    current_language =
      params |> Helpers.get_language_from_params_or_default() |> Helpers.put_content_locale()

    case Shop.get_product_by_slug_localized(slug, current_language,
           preload: [:category],
           language: current_language
         ) do
      {:error, :not_found} ->
        handle_cross_language_redirect(slug, current_language, params, session, socket)

      {:ok, %{category: %{status: "hidden"}}} ->
        {:ok,
         socket
         |> put_flash(:error, Vocabulary.not_found())
         |> push_navigate(to: Shop.catalog_url(current_language))}

      {:ok, %{status: status}} when status != "active" ->
        # The storefront must only serve ACTIVE products. `SlugResolver`
        # applies a status filter only when a `:status` option is passed,
        # and this call passes only `:preload` — so draft, inactive and
        # archived products were reachable by URL, and since neither
        # add-to-cart nor cart→order conversion re-checks status, they were
        # also purchasable. The category's hidden status was checked; the
        # product's own never was.
        {:ok,
         socket
         |> put_flash(:error, Vocabulary.not_found())
         |> push_navigate(to: Shop.catalog_url(current_language))}

      {:ok, product} ->
        mount_product(product, params, session, socket, current_language)
    end
  end

  defp mount_product(product, params, session, socket, current_language) do
    session_id = session["shop_session_id"] || generate_session_id()
    user = Helpers.get_current_user(socket)
    user_uuid = if user, do: user.uuid, else: nil

    selectable_specs = Shop.get_selectable_specs(product)
    selected_specs = build_default_specs(selectable_specs, product.metadata || %{})

    category_uuid = if product.category, do: product.category.uuid, else: nil

    {enabled_filters, _fv} =
      FilterHelpers.load_filter_data(
        category_uuid: category_uuid,
        category: product.category,
        language: current_language
      )

    active_filters = FilterHelpers.parse_filter_params(params, enabled_filters)

    localized_title = Translations.get(product, :title, current_language)

    if connected?(socket) do
      Events.subscribe_product(product.uuid)
      Events.subscribe_inventory()
    end

    seo = SEOHelpers.product_seo(product, current_language)

    socket =
      socket
      |> assign(:page_title, seo.page_title)
      |> assign(:canonical_url, seo.canonical_url)
      |> assign(:hreflang_links, seo.hreflang_links)
      |> assign(:og, seo.og)
      |> assign(:cart_count, storefront_cart_count(session_id, user_uuid))
      |> assign(:product, product)
      |> assign(:current_language, current_language)
      |> assign(:localized_title, localized_title)
      |> assign(:localized_description, Translations.get(product, :description, current_language))
      |> assign(:localized_body, Translations.get(product, :body_html, current_language))
      |> assign(:currency, Shop.get_display_currency_code())
      |> assign(:quantity, 1)
      |> assign(:session_id, session_id)
      |> assign(:user_uuid, user_uuid)
      |> assign(:selected_image, first_image(product))
      |> assign(:adding_to_cart, false)
      |> assign(:authenticated, not is_nil(socket.assigns[:phoenix_kit_current_user]))
      |> assign(
        :cart_item,
        find_cart_item_with_specs(user_uuid, session_id, product.uuid, selected_specs)
      )
      |> assign(:specifications, build_specifications(product))
      |> assign(:price_affecting_specs, Shop.get_price_affecting_specs(product))
      |> assign(:selectable_specs, selectable_specs)
      |> assign(:selected_specs, selected_specs)
      |> assign(:calculated_price, Shop.calculate_product_price(product, selected_specs))
      |> assign(
        :missing_required_specs,
        get_missing_required_specs(selected_specs, selectable_specs)
      )
      |> assign(
        :current_path,
        socket.assigns[:url_path] || Shop.product_url(product, current_language)
      )
      |> assign(:categories, Shop.list_active_categories(preload: [:featured_product]))
      |> assign(:filter_qs, FilterHelpers.build_query_string(active_filters, enabled_filters))
      |> assign(
        :category_name_wrap,
        Settings.get_setting_cached("shop_category_name_display", "truncate") == "wrap"
      )
      |> assign(
        :category_icon_mode,
        Settings.get_setting_cached("shop_category_icon_mode", "none")
      )
      |> assign(:admin_edit_url, Routes.path("/admin/shop/products/#{product.uuid}/edit"))
      |> assign(:admin_edit_label, gettext("Edit Product"))

    {:ok, socket}
  end

  # Handle cross-language slug redirect
  # When user visits with a slug from a different language, redirect to correct localized URL
  defp handle_cross_language_redirect(slug, current_language, params, session, socket) do
    case Shop.get_product_by_any_slug(slug, preload: [:category], language: current_language) do
      {:error, :not_found} ->
        # Product truly not found
        {:ok,
         socket
         |> put_flash(:error, Vocabulary.not_found())
         |> push_navigate(to: Shop.catalog_url(current_language))}

      {:ok, product, _matched_lang} ->
        if publicly_visible?(product) do
          resolve_language_redirect(product, current_language, params, session, socket)
        else
          not_found(socket, current_language)
        end
    end
  end

  # One visibility rule for the storefront, shared by both slug paths.
  #
  # `mount/3` rejected non-active products, but this cross-language path —
  # reached whenever the visitor's slug resolves in another language —
  # checked only the CATEGORY's status and handed the product straight to
  # `mount_with_product/5`. A draft product stayed publicly reachable, and
  # purchasable, through its other-language slug. Keeping the rule in one
  # predicate is what stops the two paths drifting apart again.
  defp publicly_visible?(%{status: "active"} = product) do
    case product do
      %{category: %{status: "hidden"}} -> false
      _ -> true
    end
  end

  defp publicly_visible?(_product), do: false

  defp not_found(socket, current_language) do
    {:ok,
     socket
     |> put_flash(:error, Vocabulary.not_found())
     |> push_navigate(to: Shop.catalog_url(current_language))}
  end

  defp resolve_language_redirect(product, current_language, params, session, socket) do
    redirect_lang = Helpers.best_redirect_language(product.slug || %{})

    # Normalize both languages to compare (e.g., "en" <-> "en-US")
    current_base = DialectMapper.extract_base(current_language)
    redirect_base = redirect_lang && DialectMapper.extract_base(redirect_lang)

    # The language the user explicitly requested via the URL locale prefix,
    # IF the product is actually translated into it. Without this the
    # language switcher can never leave the slug's own language: a
    # `/fr/<en-slug>` request bounces to `best_redirect_language` (which
    # prefers the default) → back to `/en/…`, so the visitor sees English
    # even though a French translation exists.
    requested_lang = requested_translation_lang(product, current_language)

    cond do
      # No valid redirect language found
      is_nil(redirect_lang) ->
        not_found(socket, current_language)

      # Product IS translated into the requested language — honor the
      # explicit choice and redirect to that language's slug.
      not is_nil(requested_lang) ->
        slug = SlugResolver.product_slug(product, requested_lang)

        {:ok,
         push_navigate(socket,
           to: Helpers.build_lang_url("/shop/product/#{slug}", requested_lang)
         )}

      # Same base language (e.g., "en" vs "en-US") - use product without redirect
      current_base == redirect_base ->
        # Re-run mount with found product to avoid redirect loop
        mount_with_product(product, current_language, params, session, socket)

      # Different language - redirect to correct URL
      true ->
        slug = SlugResolver.product_slug(product, redirect_lang)

        {:ok,
         push_navigate(socket,
           to: Helpers.build_lang_url("/shop/product/#{slug}", redirect_lang)
         )}
    end
  end

  # The requested language (base-matched) when the product has a non-empty
  # slug for it — i.e. it is genuinely translated into what the URL asked for.
  # Returns the product's own language code (e.g. "fr-FR") or nil.
  defp requested_translation_lang(product, current_language) do
    base = DialectMapper.extract_base(current_language)
    slug_map = product.slug || %{}

    Enum.find(Map.keys(slug_map), fn code ->
      DialectMapper.extract_base(code) == base and Map.get(slug_map, code) not in [nil, ""]
    end)
  end

  # Mount product page using already-found product (avoids redirect loop)
  # Used when cross-language lookup finds a product with same base language
  defp mount_with_product(product, current_language, params, session, socket) do
    # Use the visitor's REAL shop session, same as the direct path.
    #
    # This used to mint a random id, with a comment claiming the session
    # was unavailable here — it was not; `mount/3` receives it and simply
    # did not thread it through `handle_cross_language_redirect/5`. The
    # consequence was silent and expensive: a guest arriving via a
    # same-base-language slug got a cart keyed to an id their browser has
    # never held, so their existing cart was invisible and anything they
    # added went into an orphan cart they could never reach again.
    session_id = session["shop_session_id"] || generate_session_id()
    user = Helpers.get_current_user(socket)
    user_uuid = if user, do: user.uuid, else: nil

    currency = Shop.get_display_currency_code()
    authenticated = not is_nil(socket.assigns[:phoenix_kit_current_user])

    # Build specifications
    specifications = build_specifications(product)
    price_affecting_specs = Shop.get_price_affecting_specs(product)
    selectable_specs = Shop.get_selectable_specs(product)
    selected_specs = build_default_specs(selectable_specs, product.metadata || %{})
    calculated_price = Shop.calculate_product_price(product, selected_specs)
    cart_item = find_cart_item_with_specs(user_uuid, session_id, product.uuid, selected_specs)
    missing_required_specs = get_missing_required_specs(selected_specs, selectable_specs)

    all_categories = Shop.list_active_categories(preload: [:featured_product])

    # Compute filter_qs from URL params (preserves filters across cross-language redirect)
    category_uuid = if product.category, do: product.category.uuid, else: nil

    {enabled_filters, _fv} =
      FilterHelpers.load_filter_data(
        category_uuid: category_uuid,
        category: product.category,
        language: current_language
      )

    active_filters = FilterHelpers.parse_filter_params(params, enabled_filters)
    filter_qs = FilterHelpers.build_query_string(active_filters, enabled_filters)

    # Get localized content
    localized_title = Translations.get(product, :title, current_language)
    localized_description = Translations.get(product, :description, current_language)
    localized_body = Translations.get(product, :body_html, current_language)
    current_path = socket.assigns[:url_path] || Shop.product_url(product, current_language)

    # Subscribe to updates
    if connected?(socket) do
      Events.subscribe_product(product.uuid)
      Events.subscribe_inventory()
    end

    seo = SEOHelpers.product_seo(product, current_language)

    socket =
      socket
      |> assign(:page_title, seo.page_title)
      |> assign(:canonical_url, seo.canonical_url)
      |> assign(:hreflang_links, seo.hreflang_links)
      |> assign(:og, seo.og)
      |> assign(:product, product)
      |> assign(:current_language, current_language)
      |> assign(:localized_title, localized_title)
      |> assign(:localized_description, localized_description)
      |> assign(:localized_body, localized_body)
      |> assign(:currency, currency)
      |> assign(:quantity, 1)
      |> assign(:session_id, session_id)
      |> assign(:user_uuid, user_uuid)
      |> assign(:selected_image, first_image(product))
      |> assign(:adding_to_cart, false)
      |> assign(:authenticated, authenticated)
      |> assign(:cart_item, cart_item)
      |> assign(:specifications, specifications)
      |> assign(:price_affecting_specs, price_affecting_specs)
      |> assign(:selectable_specs, selectable_specs)
      |> assign(:selected_specs, selected_specs)
      |> assign(:calculated_price, calculated_price)
      |> assign(:missing_required_specs, missing_required_specs)
      |> assign(:current_path, current_path)
      |> assign(:categories, all_categories)
      |> assign(:filter_qs, filter_qs)
      |> assign(
        :category_name_wrap,
        Settings.get_setting_cached("shop_category_name_display", "truncate") == "wrap"
      )
      |> assign(
        :category_icon_mode,
        Settings.get_setting_cached("shop_category_icon_mode", "none")
      )
      |> assign(:admin_edit_url, Routes.path("/admin/shop/products/#{product.uuid}/edit"))
      |> assign(:admin_edit_label, gettext("Edit Product"))

    {:ok, socket}
  end

  @impl true
  def handle_event("set_quantity", %{"quantity" => quantity}, socket) do
    quantity = Helpers.parse_int(quantity, 1) |> max(1)
    {:noreply, assign(socket, :quantity, quantity)}
  end

  @impl true
  def handle_event("increment", _params, socket) do
    {:noreply, assign(socket, :quantity, socket.assigns.quantity + 1)}
  end

  @impl true
  def handle_event("decrement", _params, socket) do
    quantity = max(socket.assigns.quantity - 1, 1)
    {:noreply, assign(socket, :quantity, quantity)}
  end

  @impl true
  def handle_event("select_image", %{"url" => url}, socket) do
    {:noreply, assign(socket, :selected_image, url)}
  end

  @impl true
  def handle_event("select_spec", params, socket) do
    key = params["key"] || ""
    value = params["opt"] || ""

    selected_specs = Map.put(socket.assigns.selected_specs, key, value)
    product = socket.assigns.product
    selectable_specs = socket.assigns.selectable_specs

    # Recalculate price with new spec selection
    calculated_price = Shop.calculate_product_price(product, selected_specs)

    # Check for image mapping - update selected_image if mapping exists
    selected_image = get_mapped_image(product, key, value, socket.assigns.selected_image)

    # Check if this combination is in cart
    cart_item =
      find_cart_item_with_specs(
        socket.assigns.user_uuid,
        socket.assigns.session_id,
        product.uuid,
        selected_specs
      )

    # Update missing required specs for UI (check all selectable specs)
    missing_required_specs = get_missing_required_specs(selected_specs, selectable_specs)

    socket =
      socket
      |> assign(:selected_specs, selected_specs)
      |> assign(:calculated_price, calculated_price)
      |> assign(:selected_image, selected_image)
      |> assign(:cart_item, cart_item)
      |> assign(:missing_required_specs, missing_required_specs)

    {:noreply, socket}
  end

  @impl true
  def handle_event("select_storage_image", %{"uuid" => uuid}, socket) do
    url = get_storage_image_url(uuid, "large")
    {:noreply, assign(socket, :selected_image, url)}
  end

  @impl true
  def handle_event("add_to_cart", _params, socket) do
    do_add_to_cart(socket)
  end

  defp do_add_to_cart(socket) do
    %{
      selected_specs: selected_specs,
      selectable_specs: selectable_specs
    } = socket.assigns

    # Validate required options before proceeding (check all selectable specs)
    case validate_required_specs(selected_specs, selectable_specs) do
      :ok ->
        do_add_to_cart_impl(socket)

      {:error, missing_labels} ->
        message = "Please select: #{Enum.join(missing_labels, ", ")}"
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  # Options selected or not, the cart line is created the same way; the
  # opts differ only by the specs map.
  defp add_to_cart(cart, product, quantity, selected_specs, socket) do
    opts = [language: socket.assigns.current_language]

    opts =
      if selected_specs != %{} and map_size(selected_specs) > 0 do
        Keyword.put(opts, :selected_specs, selected_specs)
      else
        opts
      end

    Shop.add_to_cart(cart, product, quantity, opts)
  end

  defp do_add_to_cart_impl(socket) do
    socket = assign(socket, :adding_to_cart, true)

    # Get or create cart. Opening one requires a currency since
    # `Cart.changeset/2` started validating it (§4.2), so a shop with no
    # default currency configured in Billing gets the same "unavailable"
    # flash the disabled-shop branch below gets — never a MatchError.
    case Shop.get_or_create_cart(
           user_uuid: socket.assigns.user_uuid,
           session_id: socket.assigns.session_id
         ) do
      {:ok, cart} ->
        add_to_cart_with(socket, cart)

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:adding_to_cart, false)
         |> put_flash(:error, gettext("The shop is currently unavailable"))}
    end
  end

  defp add_to_cart_with(socket, cart) do
    %{
      product: product,
      quantity: quantity,
      currency: currency,
      selected_specs: selected_specs,
      price_affecting_specs: price_affecting_specs
    } = socket.assigns

    add_result = add_to_cart(cart, product, quantity, selected_specs, socket)

    case add_result do
      {:ok, updated_cart} ->
        # The STORED line item, not a fresh live-amount conversion: this is
        # what the shopper was actually charged, so the flash cannot drift
        # from the snapshot even by a rounding cent (review follow-up on
        # Э1-E4).
        updated_cart_item =
          find_cart_item_after_add(
            updated_cart.items,
            product.uuid,
            selected_specs,
            price_affecting_specs
          )

        display_name = build_cart_display_name(product, price_affecting_specs, selected_specs)

        message =
          build_cart_message(
            display_name,
            quantity,
            updated_cart_item,
            updated_cart.total,
            currency
          )

        {:noreply,
         socket
         |> assign(:adding_to_cart, false)
         |> assign(:quantity, 1)
         |> assign(:cart_item, updated_cart_item)
         |> put_flash(:info, message)
         |> push_event("cart_updated", %{})}

      {:error, :shop_disabled} ->
        {:noreply,
         socket
         |> assign(:adding_to_cart, false)
         |> put_flash(:error, gettext("The shop is currently unavailable"))}

      {:error, :product_not_available} ->
        {:noreply,
         socket
         |> assign(:adding_to_cart, false)
         |> put_flash(:error, Vocabulary.unavailable_gone())}

      {:error, {:product_not_available, _uuid}} ->
        {:noreply,
         socket
         |> assign(:adding_to_cart, false)
         |> put_flash(:error, Vocabulary.unavailable_gone())}

      {:error, reason} ->
        # Log error for admin monitoring
        log_cart_error(
          "Failed to add to cart",
          reason,
          socket.assigns.product.uuid,
          socket.assigns.user_uuid
        )

        {:noreply,
         socket
         |> assign(:adding_to_cart, false)
         |> put_flash(
           :error,
           Vocabulary.add_failed()
         )}

      {:error, code, detail} ->
        # Log detailed error for admin monitoring
        log_cart_error(
          "Failed to add to cart",
          {code, detail},
          socket.assigns.product.uuid,
          socket.assigns.user_uuid
        )

        # Show user-friendly message based on error code
        user_message = get_user_friendly_error_message(code, detail)

        {:noreply,
         socket
         |> assign(:adding_to_cart, false)
         |> put_flash(:error, user_message)}
    end
  end

  # Get user-friendly error message based on error code and details
  # Keep messages concise for toast display (max ~80 chars per line)
  #
  # These are flash messages a SHOPPER sees, so they are wrapped for the same
  # reason the markup around them is: an untranslated toast is as visible as an
  # untranslated heading. Interpolated values (an option key, a stock count)
  # ride as bindings rather than being built into the msgid, or the translator
  # gets a different string for every product.
  defp get_user_friendly_error_message(:invalid_option_value, detail) do
    option_name = detail[:key] || gettext("option")

    case detail[:value] do
      nil ->
        gettext("Selected options are no longer available.\nPlease refresh and select again.")

      val ->
        gettext(
          "Option \"%{option}: %{value}\" is no longer available.\nPlease refresh the page for current options.",
          option: option_name,
          value: val
        )
    end
  end

  defp get_user_friendly_error_message(:unknown_option_key, detail) do
    option_name = detail[:key] || gettext("option")

    gettext(
      "Option \"%{option}\" does not exist.\nProduct was updated - please reload the page.",
      option: option_name
    )
  end

  defp get_user_friendly_error_message(:missing_required_option, detail) do
    missing_option = if is_binary(detail), do: detail, else: gettext("required option")

    gettext("Missing required option: %{option}.\nPlease select all required parameters.",
      option: missing_option
    )
  end

  defp get_user_friendly_error_message(:out_of_stock, _detail) do
    gettext("This item is out of stock.\nPlease try again later or choose another one.")
  end

  defp get_user_friendly_error_message(:insufficient_stock, detail) do
    available = detail[:available] || 0

    gettext("Insufficient stock (only %{count} available).\nPlease reduce quantity.",
      count: available
    )
  end

  defp get_user_friendly_error_message(:price_changed, _detail) do
    gettext("The price has changed.\nPlease refresh to see the current price.")
  end

  defp get_user_friendly_error_message(_code, _detail) do
    gettext("Unable to add to cart.\nPlease try again or contact support.")
  end

  # Log cart errors for admin monitoring and debugging
  # In production, this could trigger alerts via email, Slack, or error tracking service
  defp log_cart_error(message, error_details, product_uuid, user_uuid) do
    require Logger

    error_info = %{
      message: message,
      error: error_details,
      product_uuid: product_uuid,
      user_uuid: user_uuid,
      timestamp: UtilsDate.utc_now()
    }

    # Log as warning level (not error) since it's gracefully handled
    Logger.warning("[Shop] Cart operation failed: #{inspect(error_info)}")

    :ok
  end

  defp build_cart_display_name(product, _price_affecting_specs, selected_specs) do
    # Get localized title (use default language for cart display)
    title = Translations.get(product, :title, Translations.default_language())

    if map_size(selected_specs) > 0 do
      specs_str = selected_specs |> Map.values() |> Enum.join(", ")
      "#{title} (#{specs_str})"
    else
      title
    end
  end

  defp build_cart_message(display_name, quantity, cart_item, cart_total, currency) do
    # `cart_item.unit_price` is the STORED snapshot — already converted and
    # rounded at add-to-cart time, in the cart's own currency — not a fresh
    # live conversion recomputed here. That is what the shopper was
    # actually charged, so the flash cannot drift from the persisted line
    # even by a rounding cent (review follow-up on Э1-E4). `cart_total` is
    # likewise already a stored snapshot; neither is converted again (N1).
    unit_price = cart_item.unit_price
    line_total = Decimal.mult(unit_price, quantity)
    line_str = format_price(line_total, currency)
    cart_total_str = format_price(cart_total, currency)
    unit_price_str = format_price(unit_price, currency)

    "#{display_name} (#{quantity} × #{unit_price_str} = #{line_str}) added to cart.\nCart total: #{cart_total_str}"
  end

  defp find_cart_item_after_add(items, product_uuid, selected_specs, _price_affecting_specs) do
    if map_size(selected_specs) > 0 do
      Enum.find(
        items,
        &(cart_item_matches_product?(&1, product_uuid) && &1.selected_specs == selected_specs)
      )
    else
      Enum.find(items, &cart_item_matches_product?(&1, product_uuid))
    end
  end

  # `product_uuid` here is always the product's real identifying uuid — for
  # a catalogue-backed product that's the catalogue item's own uuid, which
  # `CartItem.from_product/3` snapshots into `metadata["catalogue_item_uuid"]`
  # rather than the row's `product_uuid` column (nil for those rows). Without
  # this fallback, every post-add lookup for a catalogue product (the "added
  # to cart" flash, the existing-item check before a repeat add) would come
  # back nil even though the row is right there in `items`.
  defp cart_item_matches_product?(item, product_uuid) do
    item.product_uuid == product_uuid or
      (item.metadata || %{})["catalogue_item_uuid"] == product_uuid
  end

  @impl true
  def render(assigns) do
    ~H"""
    <ShopLayouts.shop_layout {assigns}>
      <div class="container flex-col mx-auto px-4 py-6 max-w-7xl">
        
        <ShopCards.storefront_bar language={@current_language} cart_count={@cart_count} />
        <%!-- Breadcrumbs --%>
        <div class="breadcrumbs text-sm mb-6">
          <ul>
            <li>
              <.link navigate={Shop.catalog_url(@current_language) <> @filter_qs}>
                {gettext("Shop")}
              </.link>
            </li>
            <%= if @product.category do %>
              <% cat_name = Translations.get(@product.category, :name, @current_language) %>
              <li>
                <.link navigate={Shop.category_url(@product.category, @current_language) <> @filter_qs}>
                  {cat_name}
                </.link>
              </li>
            <% end %>
            <li class="font-medium truncate max-w-[10rem] sm:max-w-xs">{@localized_title}</li>
          </ul>
        </div>

        <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-[1fr_2fr_2fr] gap-6 lg:gap-8">
          <%!-- Category navigation (no filters on product page) --%>
          <aside class="hidden lg:block">
            <div class="card bg-base-100 shadow-lg sticky top-6 max-h-[calc(100vh-3rem)] overflow-y-auto">
              <div class="card-body p-4">
                <CatalogSidebar.category_nav
                  categories={@categories}
                  current_category={@product.category}
                  current_language={@current_language}
                  category_icon_mode={@category_icon_mode}
                  category_name_wrap={@category_name_wrap}
                  open={true}
                  filter_qs={@filter_qs}
                />
              </div>
            </div>
          </aside>
          <%!-- Product Images --%>
          <div class="space-y-4">
            <%!-- Main Image --%>
            <div class="aspect-square bg-base-200 rounded-lg overflow-hidden">
              <%= if @selected_image do %>
                <img
                  src={@selected_image}
                  alt={@localized_title}
                  class="w-full h-full object-cover"
                  onerror={"this.src='#{placeholder_image_url()}'"}
                />
              <% else %>
                <div class="w-full h-full flex items-center justify-center">
                  <.icon name="hero-cube" class="w-32 h-32 opacity-30" />
                </div>
              <% end %>
            </div>

            <%!-- Thumbnails from Storage --%>
            <% display_images = get_display_images(@product) %>
            <%= if display_images != [] do %>
              <div class="flex gap-2 overflow-x-auto py-2">
                <%= for image_uuid <- display_images do %>
                  <% thumb_url = get_storage_image_url(image_uuid, "thumbnail") %>
                  <% large_url = get_storage_image_url(image_uuid, "large") %>
                  <button
                    phx-click="select_storage_image"
                    phx-value-uuid={image_uuid}
                    class={[
                      "w-16 h-16 rounded-lg overflow-hidden flex-shrink-0 border-2 transition-colors",
                      if(@selected_image == large_url,
                        do: "border-primary",
                        else: "border-transparent hover:border-base-300"
                      )
                    ]}
                  >
                    <img
                      src={thumb_url}
                      alt="Thumbnail"
                      class="w-full h-full object-cover"
                      onerror={"this.src='#{placeholder_image_url()}'"}
                    />
                  </button>
                <% end %>
              </div>
            <% end %>

            <%!-- Legacy URL-based thumbnails (only show if no Storage images) --%>
            <%= if has_multiple_images?(@product) and get_display_images(@product) == [] do %>
              <div class="flex gap-2 overflow-x-auto py-2">
                <%= for {image, _idx} <- Enum.with_index(@product.images || []) do %>
                  <% url = image_url(image) %>
                  <%= if url do %>
                    <button
                      phx-click="select_image"
                      phx-value-url={url}
                      class={[
                        "w-16 h-16 rounded-lg overflow-hidden flex-shrink-0 border-2 transition-colors",
                        if(@selected_image == url,
                          do: "border-primary",
                          else: "border-transparent hover:border-base-300"
                        )
                      ]}
                    >
                      <img
                        src={url}
                        alt="Thumbnail"
                        class="w-full h-full object-cover"
                        onerror={"this.src='#{placeholder_image_url()}'"}
                      />
                    </button>
                  <% end %>
                <% end %>
              </div>
            <% end %>
          </div>

          <%!-- Product Info --%>
          <div class="space-y-6">
            <div>
              <h1 class="text-3xl font-bold mb-2">{@localized_title}</h1>

              <%= if @product.vendor do %>
                <p class="text-base-content/60">by {@product.vendor}</p>
              <% end %>
            </div>

            <%!-- Price --%>
            <div class="flex items-baseline gap-3">
              <%= if @price_affecting_specs != [] do %>
                <%!-- Has price-affecting specs - show calculated price --%>
                <span class="text-3xl font-bold text-primary">
                  {PriceDisplay.render(@product, @currency, :selected,
                    amount: @calculated_price,
                    language: @current_language
                  )}
                </span>
                <%= if cmp = PriceDisplay.compare_at(@product, @currency, :selected, amount: @calculated_price) do %>
                  <span class="text-xl text-base-content/40 line-through">
                    {cmp.price}
                  </span>
                  <span class="badge badge-success">
                    {cmp.percent}% OFF
                  </span>
                <% end %>
              <% else %>
                <%!-- Simple product - show base price --%>
                <span class="text-3xl font-bold text-primary">
                  {PriceDisplay.render(@product, @currency, :catalog, language: @current_language)}
                </span>
                <%= if cmp = PriceDisplay.compare_at(@product, @currency, :catalog, []) do %>
                  <span class="text-xl text-base-content/40 line-through">
                    {cmp.price}
                  </span>
                  <span class="badge badge-success">
                    {cmp.percent}% OFF
                  </span>
                <% end %>
              <% end %>
            </div>

            <%!-- Description --%>
            <%!-- Sanitized unless an admin has explicitly opted into raw HTML.
                  This renders on the UNAUTHENTICATED storefront, and product
                  descriptions are writable by anyone holding the "shop"
                  permission and by whoever supplies a CSV import file — so
                  `sanitize={false}` here was a path from "can edit a product"
                  to script execution in every shopper's and the Owner's
                  browser. See PhoenixKitEcommerce.Policy. --%>
            <%= if @localized_description do %>
              <.markdown
                content={@localized_description}
                sanitize={not Policy.allow_raw_html_descriptions?()}
                compact
              />
            <% end %>

            <%!-- Full body (imports put the complete supplier description in
                  body_html and only a short extract in description). Same
                  sanitization policy as the description above. --%>
            <%= if @localized_body && @localized_body != "" do %>
              <div class="mt-4">
                <.markdown
                  content={@localized_body}
                  sanitize={not Policy.allow_raw_html_descriptions?()}
                />
              </div>
            <% end %>

            <%!-- Product Details --%>
            <div class="divider"></div>

            <div class="grid grid-cols-2 gap-4 text-sm">
              <%= if @product.weight_grams && @product.weight_grams > 0 do %>
                <div>
                  <span class="text-base-content/60">{gettext("Weight:")}</span>
                  <span class="ml-2 font-medium">{@product.weight_grams}g</span>
                </div>
              <% end %>

              <%= if @product.category do %>
                <% cat_name = Translations.get(@product.category, :name, @current_language) %>
                <div>
                  <span class="text-base-content/60">{gettext("Category:")}</span>
                  <.link
                    navigate={Shop.category_url(@product.category, @current_language) <> @filter_qs}
                    class="ml-2 link link-primary"
                  >
                    {cat_name}
                  </.link>
                </div>
              <% end %>
            </div>

            <%!-- Specifications Table --%>
            <%= if @specifications != [] do %>
              <div class="divider"></div>

              <h3 class="font-semibold text-lg mb-3">
                <.icon name="hero-tag" class="w-5 h-5 inline" /> {gettext("Specifications")}
              </h3>

              <div class="overflow-x-auto">
                <table class="table table-zebra table-sm">
                  <tbody>
                    <%= for {label, value, unit} <- @specifications do %>
                      <tr>
                        <td class="font-medium w-1/3 text-base-content/70">{label}</td>
                        <td>
                          {format_spec_value(value)}
                          <%= if unit do %>
                            <span class="text-base-content/50 ml-1">{unit}</span>
                          <% end %>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>

            <div class="divider"></div>

            <%!-- Add to Cart Section --%>
            <%= if @product.status == "active" do %>
              <div class="space-y-4">
                <%!-- Option Selector (All Selectable Options) --%>
                <%= if @selectable_specs != [] do %>
                  <div class="space-y-4">
                    <h3 class="font-semibold text-lg">
                      <.icon name="hero-adjustments-horizontal" class="w-5 h-5 inline" />
                      {gettext("Choose Options")}
                    </h3>

                    <%= for attr <- @selectable_specs do %>
                      <% is_missing = MapSet.member?(@missing_required_specs, attr["key"]) %>
                      <% affects_price = attr["affects_price"] == true %>
                      <fieldset class="fieldset">
                        <legend class={[
                          "fieldset-legend font-medium",
                          is_missing && "text-error"
                        ]}>
                          {attr["label"]}
                          <%= if attr["required"] do %>
                            <span class="text-error ml-1">*</span>
                          <% end %>
                        </legend>
                        <%= if is_missing do %>
                          <p class="fieldset-label text-error">{gettext("Please select an option")}</p>
                        <% end %>
                        <div class="flex flex-wrap gap-2">
                          <%= for opt_value <- get_option_values(@product, attr) do %>
                            <%= if affects_price do %>
                              <.option_button
                                option_key={attr["key"]}
                                option_value={opt_value}
                                price={
                                  calculate_option_total_price(
                                    @product,
                                    @price_affecting_specs,
                                    @selected_specs,
                                    attr["key"],
                                    opt_value
                                  )
                                }
                                selected={@selected_specs[attr["key"]] == opt_value}
                                is_missing={is_missing}
                                currency={@currency}
                              />
                            <% else %>
                              <.option_button_simple
                                option_key={attr["key"]}
                                option_value={opt_value}
                                selected={@selected_specs[attr["key"]] == opt_value}
                                is_missing={is_missing}
                              />
                            <% end %>
                          <% end %>
                        </div>
                      </fieldset>
                    <% end %>
                  </div>
                <% end %>

                <%!-- Quantity Selector --%>
                <fieldset class="fieldset">
                  <legend class="fieldset-legend">{gettext("Quantity")}</legend>
                  <div class="flex flex-wrap items-center gap-2 sm:gap-3">
                    <div class="flex items-center gap-1">
                      <button
                        type="button"
                        phx-click="decrement"
                        class="btn btn-square btn-outline btn-sm"
                        disabled={@quantity <= 1}
                      >
                        <.icon name="hero-minus" class="w-4 h-4" />
                      </button>
                      <form phx-change="set_quantity" class="inline">
                        <input
                          type="number"
                          value={@quantity}
                          name="quantity"
                          min="1"
                          class="input w-20 text-center"
                        />
                      </form>
                      <button
                        type="button"
                        phx-click="increment"
                        class="btn btn-square btn-outline btn-sm"
                      >
                        <.icon name="hero-plus" class="w-4 h-4" />
                      </button>
                    </div>
                    <span class="text-base-content/60">×</span>
                    <span class="text-base-content/60">
                      {PriceDisplay.render(nil, @currency, :selected,
                        amount:
                          current_display_price(@product, @calculated_price, @price_affecting_specs)
                      )}
                    </span>
                    <span class="text-base-content/60">=</span>
                    <span class="text-xl font-bold text-primary">
                      {format_price(
                        line_total(
                          Currency.present(
                            current_display_price(
                              @product,
                              @calculated_price,
                              @price_affecting_specs
                            ),
                            @currency
                          ),
                          @quantity
                        ),
                        @currency
                      )}
                    </span>
                  </div>
                </fieldset>

                <%!-- Already in Cart Notice --%>
                <%= if @cart_item do %>
                  <div class="alert alert-info">
                    <.icon name="hero-shopping-cart" class="w-5 h-5" />
                    <div>
                      <span class="font-medium">{gettext("Already in cart:")}</span>
                      <%!-- The line's OWN flag. An on-request line stores 0, so
                            formatting it printed "1 × 0.00 = 0.00" directly under
                            a headline price reading "Price on request". --%>
                      <span>
                        <%= if PriceDisplay.line_on_request?(@cart_item) do %>
                          {gettext("Qty: %{count}", count: @cart_item.quantity)}
                        <% else %>
                          {@cart_item.quantity} × {format_price(@cart_item.unit_price, @currency)} = {format_price(
                            @cart_item.line_total,
                            @currency
                          )}
                        <% end %>
                      </span>
                    </div>
                  </div>
                <% end %>

                <%!-- Add to Cart Button --%>
                <button
                  phx-click="add_to_cart"
                  class={["btn btn-primary btn-lg w-full"]}
                  disabled={@adding_to_cart}
                >
                  <%= if @adding_to_cart do %>
                    <span class="loading loading-spinner loading-sm"></span> {gettext("Adding...")}
                  <% else %>
                    <.icon name="hero-shopping-cart" class="w-5 h-5 mr-2" />
                    <%= if @cart_item do %>
                      {gettext("Add More to Cart")}
                    <% else %>
                      {gettext("Add to Cart")}
                    <% end %>
                  <% end %>
                </button>

                <%!-- View Cart Link --%>
                <.link navigate={Shop.cart_url(@current_language)} class="btn btn-outline w-full">
                  <.icon name="hero-eye" class="w-5 h-5 mr-2" /> {gettext("View Cart")}
                </.link>
              </div>
            <% else %>
              <div class="alert alert-warning">
                <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
                <span>{Vocabulary.unavailable_now()}</span>
              </div>
            <% end %>

            <%!-- Tags --%>
            <%= if @product.tags && @product.tags != [] do %>
              <div class="flex flex-wrap gap-2 mt-4">
                <%= for tag <- @product.tags do %>
                  <span class="badge badge-ghost">{tag}</span>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </ShopLayouts.shop_layout>
    """
  end

  # Option button component - isolated for better debugging
  attr :option_key, :any, required: true
  attr :option_value, :any, required: true
  attr :price, :any, required: true
  attr :selected, :boolean, default: false
  attr :is_missing, :boolean, default: false
  attr :currency, :any, required: true

  defp option_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="select_spec"
      phx-value-key={@option_key}
      phx-value-opt={@option_value}
      class={[
        "btn btn-sm gap-1",
        @selected && "btn-primary",
        !@selected && "btn-outline",
        !@selected && @is_missing && "btn-error btn-outline"
      ]}
    >
      {@option_value} — {PriceDisplay.render(nil, @currency, :selected, amount: @price)}
    </button>
    """
  end

  # Simple option button without price - for non-price-affecting options
  attr :option_key, :any, required: true
  attr :option_value, :any, required: true
  attr :selected, :boolean, default: false
  attr :is_missing, :boolean, default: false

  defp option_button_simple(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="select_spec"
      phx-value-key={@option_key}
      phx-value-opt={@option_value}
      class={[
        "btn btn-sm",
        @selected && "btn-primary",
        !@selected && "btn-outline",
        !@selected && @is_missing && "btn-error btn-outline"
      ]}
    >
      {@option_value}
    </button>
    """
  end

  # Private helpers

  defp generate_session_id do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  # Image helpers - prefer Storage images over legacy URL-based images

  # Get mapped image URL for selected option value, or keep current image if no mapping
  # Supports both Storage IDs and legacy URLs (from Shopify imports)
  defp get_mapped_image(product, option_key, option_value, current_image) do
    case get_in(product.metadata || %{}, ["_image_mappings", option_key, option_value]) do
      nil -> current_image
      "" -> current_image
      # If it's a URL (starts with http), use directly
      "http" <> _ = url -> url
      # Otherwise it's a Storage ID
      image_uuid -> get_storage_image_url(image_uuid, "large")
    end
  end

  defp first_image(%{featured_image_uuid: id}) when is_binary(id) do
    get_storage_image_url(id, "large")
  end

  defp first_image(%{image_uuids: [id | _]}) when is_binary(id) do
    get_storage_image_url(id, "large")
  end

  defp first_image(%{images: [%{"src" => src} | _]}), do: src
  defp first_image(%{images: [first | _]}) when is_binary(first), do: first
  defp first_image(_), do: nil

  # Extract URL from image (handles both map and string formats)
  defp image_url(%{"src" => src}), do: src
  defp image_url(url) when is_binary(url), do: url
  defp image_url(_), do: nil

  defp has_storage_images?(%{featured_image_uuid: id}) when is_binary(id), do: true
  defp has_storage_images?(%{image_uuids: [_ | _]}), do: true
  defp has_storage_images?(_), do: false

  defp has_multiple_images?(%{images: [_, _ | _]}), do: true
  defp has_multiple_images?(_), do: false

  # Get display images for gallery
  defp get_display_images(product) do
    if has_storage_images?(product) do
      product_image_uuids(product)
    else
      []
    end
  end

  # Get all product Storage image IDs (featured + gallery, no duplicates)
  defp product_image_uuids(%{featured_image_uuid: nil, image_uuids: ids}), do: ids || []

  defp product_image_uuids(%{featured_image_uuid: featured, image_uuids: ids}) do
    # Ensure featured is first, but don't duplicate if already in ids
    all_ids = ids || []

    if featured in all_ids do
      # Move featured to front if not already there
      [featured | Enum.reject(all_ids, &(&1 == featured))]
    else
      [featured | all_ids]
    end
  end

  defp product_image_uuids(_), do: []

  defp get_storage_image_url(nil, _variant), do: placeholder_image_url()

  defp get_storage_image_url(file_uuid, variant) do
    case Storage.get_file(file_uuid) do
      %{uuid: uuid} ->
        resolve_image_variant(file_uuid, uuid, variant)

      nil ->
        placeholder_image_url()
    end
  end

  defp resolve_image_variant(file_uuid, uuid, variant) do
    case Storage.get_file_instance_by_name(uuid, variant) do
      nil ->
        case Storage.get_file_instance_by_name(uuid, "original") do
          nil -> placeholder_image_url()
          _instance -> URLSigner.signed_url(file_uuid, "original")
        end

      _instance ->
        URLSigner.signed_url(file_uuid, variant)
    end
  end

  defp placeholder_image_url, do: @placeholder_data_uri

  # Get option values for a product, with fallback to schema defaults
  # Allows per-product customization of available option values via metadata
  defp get_option_values(product, option) do
    key = option["key"]

    case product.metadata do
      %{"_option_values" => %{^key => values}} when is_list(values) and values != [] ->
        values

      _ ->
        option["options"] || []
    end
  end

  defp line_total(price, quantity) when not is_nil(price) do
    Decimal.mult(price, quantity)
  end

  defp line_total(_, _), do: Decimal.new("0")

  # Build specifications list from product options (for display only)
  defp build_specifications(product) do
    schema = Options.get_option_schema_for_product(product)
    metadata = product.metadata || %{}

    schema
    |> Enum.filter(fn opt ->
      value = Map.get(metadata, opt["key"])
      value != nil and value != "" and value != []
    end)
    |> Enum.sort_by(& &1["position"])
    |> Enum.map(fn opt ->
      {opt["label"], Map.get(metadata, opt["key"]), opt["unit"]}
    end)
  end

  # Format specification value for display
  defp format_spec_value(true), do: "Yes"
  defp format_spec_value(false), do: "No"
  defp format_spec_value("true"), do: "Yes"
  defp format_spec_value("false"), do: "No"
  defp format_spec_value(list) when is_list(list), do: Enum.join(list, ", ")
  defp format_spec_value(value) when is_binary(value), do: value
  defp format_spec_value(value) when is_number(value), do: to_string(value)
  defp format_spec_value(value), do: inspect(value)

  # Get current display price
  defp current_display_price(_product, calculated_price, price_affecting_specs)
       when price_affecting_specs != [] do
    calculated_price
  end

  defp current_display_price(%{price: price}, _, _), do: price

  # Get set of missing required spec keys for UI highlighting
  defp get_missing_required_specs(selected_specs, price_affecting_specs) do
    price_affecting_specs
    |> Enum.filter(fn attr -> attr["required"] == true end)
    |> Enum.reject(fn attr ->
      value = Map.get(selected_specs, attr["key"])
      value != nil and value != ""
    end)
    |> Enum.map(& &1["key"])
    |> MapSet.new()
  end

  # Validate that all required specs have been selected
  defp validate_required_specs(selected_specs, price_affecting_specs) do
    missing =
      price_affecting_specs
      |> Enum.filter(fn attr -> attr["required"] == true end)
      |> Enum.reject(fn attr ->
        value = Map.get(selected_specs, attr["key"])
        value != nil and value != ""
      end)
      |> Enum.map(fn attr -> attr["label"] || attr["key"] end)

    case missing do
      [] -> :ok
      labels -> {:error, labels}
    end
  end

  # Build default specs from product metadata, schema defaults, or first option
  defp build_default_specs(price_affecting_specs, metadata) do
    Enum.reduce(price_affecting_specs, %{}, fn attr, acc ->
      key = attr["key"]
      default_value = Map.get(metadata, key)
      schema_default = attr["default"]

      cond do
        # 1. Product metadata override
        default_value && default_value != "" ->
          Map.put(acc, key, default_value)

        # 2. Schema default value
        schema_default && schema_default != "" ->
          Map.put(acc, key, schema_default)

        # 3. First option for required fields
        attr["required"] == true && is_list(attr["options"]) && attr["options"] != [] ->
          [first | _] = attr["options"]
          Map.put(acc, key, first)

        true ->
          acc
      end
    end)
  end

  # Find cart item matching selected specs
  defp find_cart_item_with_specs(user_uuid, session_id, product_uuid, selected_specs) do
    case Shop.find_active_cart(user_uuid: user_uuid, session_id: session_id) do
      %{items: items} when is_list(items) ->
        Enum.find(items, fn item ->
          cart_item_matches_product?(item, product_uuid) &&
            specs_match?(item.selected_specs, selected_specs)
        end)

      _ ->
        nil
    end
  end

  # Safe comparison of specs maps (handles nil and empty maps)
  defp specs_match?(nil, specs) when is_map(specs) and map_size(specs) == 0, do: true
  defp specs_match?(specs, nil) when is_map(specs) and map_size(specs) == 0, do: true
  defp specs_match?(nil, nil), do: true
  defp specs_match?(%{} = a, %{} = b), do: Map.equal?(a, b)
  defp specs_match?(_, _), do: false

  # Calculate total price when a specific option value is selected
  # This shows what the customer would pay if they select this option
  defp calculate_option_total_price(
         product,
         price_affecting_specs,
         current_selected,
         option_key,
         option_value
       ) do
    # Create a temporary specs map with the specific option selected
    temp_specs = Map.put(current_selected, option_key, option_value)

    # Fill in defaults for other required options that aren't selected
    temp_specs =
      Enum.reduce(price_affecting_specs, temp_specs, fn attr, acc ->
        fill_default_spec(acc, attr)
      end)

    Shop.calculate_product_price(product, temp_specs)
  end

  defp fill_default_spec(acc, attr) do
    key = attr["key"]

    if Map.has_key?(acc, key) and Map.get(acc, key) != nil and Map.get(acc, key) != "" do
      acc
    else
      case attr["options"] || [] do
        [first | _] -> Map.put(acc, key, first)
        _ -> acc
      end
    end
  end

  # Determine language from URL params - use locale param if present, otherwise default
  # This ensures non-localized routes (/shop/...) always use default language,
  # regardless of what's stored in session from previous visits

  # PubSub event handlers
  #
  # Both handlers RELOAD the canonical product with its preloads and
  # recompute every derived assign rather than trusting the broadcast
  # payload. The previous versions swapped in the payload (or a bare
  # `get_product!/1` without `preload: :category`) — the template branches
  # on `@product.category`, and an `%Ecto.Association.NotLoaded{}` is
  # truthy, so the next render crashed; the localized text, option specs
  # and calculated price also went stale because only `:product` changed.
  @impl true
  def handle_info({:product_updated, %{uuid: uuid}}, socket) do
    if uuid == socket.assigns.product.uuid do
      {:noreply, refresh_product(socket)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:inventory_updated, product_uuid, _change}, socket) do
    if product_uuid == socket.assigns.product.uuid do
      {:noreply, refresh_product(socket)}
    else
      {:noreply, socket}
    end
  end

  # Catch-all: an unrecognised message must not take the LiveView down.
  #
  # Every clause above matches a specific broadcast shape, so ANY message
  # outside that set — a new event added to `Events`, a late reply, a
  # library-sent message — crashed the mounted view. `Events` already
  # publishes some events to two topics, and this module subscribes to
  # more than one, so adding a single new event shape would have started
  # crashing live sessions with no change here at all.
  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  # Reload the canonical product (with preloads) and recompute every assign
  # derived from it. The visitor's in-progress option selection is kept where
  # the refreshed option set still allows it. A product that vanished or left
  # "active" sends the shopper back to the catalog instead of a crash or a
  # stale purchasable page.
  defp refresh_product(socket) do
    product = Shop.get_product(socket.assigns.product.uuid, preload: [:category])

    # The SAME rule mount applies - `publicly_visible?/1` also rejects a
    # product whose category is hidden. Checking only the product's own
    # status let an admin move an open product into a hidden category and
    # leave it purchasable.
    if product && publicly_visible?(product) do
      do_refresh_product(socket, product)
    else
      socket
      |> put_flash(:info, Vocabulary.unavailable_gone())
      |> push_navigate(to: Shop.catalog_url(socket.assigns.current_language))
    end
  end

  defp do_refresh_product(socket, product) do
    current_language = socket.assigns.current_language
    selectable_specs = Shop.get_selectable_specs(product)
    localized_title = Translations.get(product, :title, current_language)

    selected_specs = retained_specs(socket.assigns.selected_specs, selectable_specs, product)

    socket
    |> assign(:product, product)
    |> assign(:page_title, localized_title)
    |> assign(:selected_image, refreshed_image(socket, product))
    |> assign(:localized_title, localized_title)
    |> assign(:localized_description, Translations.get(product, :description, current_language))
    |> assign(:localized_body, Translations.get(product, :body_html, current_language))
    |> assign(:specifications, build_specifications(product))
    |> assign(:price_affecting_specs, Shop.get_price_affecting_specs(product))
    |> assign(:selectable_specs, selectable_specs)
    |> assign(:selected_specs, selected_specs)
    |> assign(:calculated_price, Shop.calculate_product_price(product, selected_specs))
    |> assign(
      :missing_required_specs,
      get_missing_required_specs(selected_specs, selectable_specs)
    )
  end

  # Keep the shopper's choices only where they are STILL OFFERED. Keeping a
  # value merely because its key survived left an invisible selection: no
  # button appeared chosen, the price was computed from the removed value,
  # and add-to-cart then rejected it as invalid.
  defp retained_specs(selected, selectable_specs, product) do
    allowed =
      Map.new(selectable_specs, fn spec -> {spec["key"], spec["options"] || []} end)

    kept =
      selected
      |> Enum.filter(fn {key, value} ->
        case Map.get(allowed, key) do
          values when is_list(values) and values != [] -> value in values
          # An option with no enumerated values (free text, number) keeps
          # whatever the shopper entered.
          [] -> true
          nil -> false
        end
      end)
      |> Map.new()

    Map.merge(build_default_specs(selectable_specs, product.metadata || %{}), kept)
  end

  # A removed image must not stay on screen as a broken thumbnail.
  defp refreshed_image(socket, product) do
    current = socket.assigns[:selected_image]

    still_present? =
      is_binary(current) and
        Enum.any?(get_display_images(product), fn uuid ->
          current == image_url(uuid) or current == uuid
        end)

    if still_present?, do: current, else: first_image(product)
  end

  defp storefront_cart_count(session_id, user_uuid) do
    case Shop.find_active_cart(user_uuid: user_uuid, session_id: session_id) do
      %{items_count: n} when is_integer(n) -> n
      _ -> 0
    end
  rescue
    _ -> 0
  end
end
