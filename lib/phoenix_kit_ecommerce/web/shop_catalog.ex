defmodule PhoenixKitEcommerce.Web.ShopCatalog do
  @moduledoc """
  Public shop catalog main page.
  Shows categories and featured/active products.
  """

  use PhoenixKitEcommerce.Web, :live_view

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Translations
  alias PhoenixKitEcommerce.Vocabulary
  alias PhoenixKitEcommerce.Web.Components.CatalogSidebar
  alias PhoenixKitEcommerce.Web.Components.FilterHelpers
  alias PhoenixKitEcommerce.Web.Components.ShopCards
  alias PhoenixKitEcommerce.Web.Components.ShopLayouts
  alias PhoenixKitEcommerce.Web.Helpers
  alias PhoenixKitEcommerce.Web.SEOHelpers

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

  defp do_mount(params, _session, socket) do
    # Determine language: use URL locale param if present, otherwise default
    # This ensures /shop always uses default language, not session
    current_language =
      params |> Helpers.get_language_from_params_or_default() |> Helpers.put_content_locale()

    categories = Shop.list_active_categories(preload: [:parent, :featured_product])

    per_page = 24
    page = Helpers.parse_page(params["page"])

    # Load storefront filters — `exclude_hidden_categories: true` matches
    # the listing query just below so a hidden category's items can't
    # inflate a facet count past what the shopper's result list shows.
    {enabled_filters, filter_values} =
      FilterHelpers.load_filter_data(
        language: current_language,
        exclude_hidden_categories: true
      )

    active_filters = FilterHelpers.parse_filter_params(params, enabled_filters)
    filter_opts = FilterHelpers.build_query_opts(active_filters, enabled_filters)

    {products, total} =
      Shop.list_products_with_count(
        [
          status: "active",
          page: 1,
          per_page: page * per_page,
          exclude_hidden_categories: true,
          language: current_language
        ] ++ filter_opts
      )

    total_pages = max(1, ceil(total / per_page))
    page = min(page, total_pages)

    currency = Shop.get_display_currency_code()

    # Check if user is authenticated
    authenticated = not is_nil(socket.assigns[:phoenix_kit_current_user])

    # Get current path for language switcher
    current_path = socket.assigns[:url_path] || "/shop"

    seo = SEOHelpers.catalog_seo(current_language)

    socket =
      socket
      |> assign(:page_title, gettext("Shop"))
      |> assign(:canonical_url, seo.canonical_url)
      |> assign(:hreflang_links, seo.hreflang_links)
      |> assign(:og, seo.og)
      |> assign(:cart_count, storefront_cart_count(socket))
      |> assign(:categories, categories)
      |> assign(:products, products)
      |> assign(:total_products, total)
      |> assign(:page, page)
      |> assign(:per_page, per_page)
      |> assign(:total_pages, total_pages)
      |> assign(:currency, currency)
      |> assign(:current_language, current_language)
      |> assign(:authenticated, authenticated)
      |> assign(:current_path, current_path)
      |> assign(:enabled_filters, enabled_filters)
      |> assign(:filter_values, filter_values)
      |> assign(:active_filters, active_filters)
      |> assign(:filter_qs, FilterHelpers.build_query_string(active_filters, enabled_filters))
      |> assign(:show_mobile_filters, false)
      |> assign(
        :category_name_wrap,
        PhoenixKit.Settings.get_setting_cached("shop_category_name_display", "truncate") == "wrap"
      )
      |> assign(
        :category_icon_mode,
        PhoenixKit.Settings.get_setting_cached("shop_category_icon_mode", "none")
      )
      |> assign(
        :show_categories_grid,
        PhoenixKit.Settings.get_setting_cached("shop_sidebar_show_categories", "true") == "true"
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    page = Helpers.parse_page(params["page"])
    active_filters = FilterHelpers.parse_filter_params(params, socket.assigns.enabled_filters)
    filter_opts = FilterHelpers.build_query_opts(active_filters, socket.assigns.enabled_filters)

    filters_changed = active_filters != socket.assigns.active_filters
    page = min(page, max(1, socket.assigns.total_pages))

    if filters_changed || page != socket.assigns.page do
      effective_page = if filters_changed, do: 1, else: page

      {products, total} =
        Shop.list_products_with_count(
          [
            status: "active",
            page: 1,
            per_page: effective_page * socket.assigns.per_page,
            exclude_hidden_categories: true,
            language: socket.assigns.current_language
          ] ++ filter_opts
        )

      total_pages = max(1, ceil(total / socket.assigns.per_page))

      {:noreply,
       socket
       |> assign(:page, min(effective_page, total_pages))
       |> assign(:products, products)
       |> assign(:total_products, total)
       |> assign(:total_pages, total_pages)
       |> assign(:active_filters, active_filters)
       |> assign(
         :filter_qs,
         FilterHelpers.build_query_string(active_filters, socket.assigns.enabled_filters)
       )}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("filter_price", params, socket) do
    filter_key = params["filter_key"] || "price"

    active_filters =
      FilterHelpers.update_price_filter(
        socket.assigns.active_filters,
        filter_key,
        params["price_min"],
        params["price_max"]
      )

    path = build_filter_path(socket.assigns, active_filters)
    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("toggle_filter", %{"key" => key, "val" => value}, socket) do
    active_filters = FilterHelpers.toggle_filter_value(socket.assigns.active_filters, key, value)
    path = build_filter_path(socket.assigns, active_filters)
    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("filter_search", %{"filter_key" => key} = params, socket) do
    active_filters =
      FilterHelpers.update_search_filter(socket.assigns.active_filters, key, params[key])

    path = build_filter_path(socket.assigns, active_filters)
    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    base_path = Shop.catalog_url(socket.assigns.current_language)
    {:noreply, push_patch(socket, to: base_path)}
  end

  @impl true
  def handle_event("toggle_mobile_filters", _params, socket) do
    {:noreply, assign(socket, :show_mobile_filters, !socket.assigns.show_mobile_filters)}
  end

  @impl true
  def handle_event("load_more", _params, socket) do
    next_page = socket.assigns.page + 1
    path = build_filter_path(socket.assigns, socket.assigns.active_filters, page: next_page)
    {:noreply, push_patch(socket, to: path)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <ShopLayouts.shop_layout {assigns}>
      <%!-- Page container. `shop_layout` renders the slot bare into the HOST's
           app layout, so each public page brings its own wrapper; without it
           this page runs edge-to-edge on a host whose <main> has no padding.
           Matches catalog_category.ex. --%>
      <div class="p-6 max-w-7xl mx-auto">
        
        <ShopCards.storefront_bar language={@current_language} cart_count={@cart_count} />
        <%!-- Hero Section --%>
        <header class="w-full relative mb-6">
          <div class="text-center">
            <h1 class="text-3xl font-bold text-base-content mb-3">
              {gettext("Welcome to Our Shop")}
            </h1>
            <p class="text-lg text-base-content/70">
              {Vocabulary.collection_blurb()}
            </p>
          </div>
        </header>

        <%!-- Categories on mobile. The only other category list on this page is
             the desktop aside (`hidden lg:block`), and the category grid below
             is behind `shop_sidebar_show_categories` — so with that setting off,
             a phone had no way to reach a category at all. Deliberately NOT in
             the filter drawer: a visitor looking for categories does not tap a
             button labelled "Filters". The setting governs the big grid, not
             whether categories are reachable, which is why this ignores it. --%>
        <div class="lg:hidden mb-4">
          <CatalogSidebar.category_nav
            categories={@categories}
            current_category={nil}
            current_language={@current_language}
            category_icon_mode={@category_icon_mode}
            category_name_wrap={@category_name_wrap}
            open={false}
            filter_qs={@filter_qs}
          />
        </div>

        <%!-- Mobile filter toggle. Suppressed when no filters are configured:
             it used to render unconditionally and open an empty drawer. --%>
        <%= if @enabled_filters != [] do %>
          <div class="lg:hidden mb-4">
            <button phx-click="toggle_mobile_filters" class="btn btn-outline btn-sm gap-2">
              <.icon name="hero-funnel" class="w-4 h-4" />
              {gettext("Filters")} <% filter_count = FilterHelpers.active_filter_count(@active_filters) %>
              <%= if filter_count > 0 do %>
                <span class="badge badge-primary badge-xs">{filter_count}</span>
              <% end %>
            </button>
          </div>
        <% end %>

        <%!-- Mobile filter drawer (filters only, no categories) --%>
        <%= if @show_mobile_filters do %>
          <div class="lg:hidden mb-6">
            <div class="card bg-base-100 shadow-lg">
              <div class="card-body p-4">
                <CatalogSidebar.catalog_sidebar
                  filters={@enabled_filters}
                  filter_values={@filter_values}
                  active_filters={@active_filters}
                  categories={@categories}
                  current_category={nil}
                  current_language={@current_language}
                  category_icon_mode={@category_icon_mode}
                  category_name_wrap={@category_name_wrap}
                  show_categories={false}
                  filter_qs={@filter_qs}
                />
              </div>
            </div>
          </div>
        <% end %>

        <%!-- Main layout: 4-column grid, in-page sidebar for everyone --%>
        <div class="grid grid-cols-1 lg:grid-cols-4 gap-8">
          <%!-- Sidebar: filters + optional categories --%>
          <aside class="lg:col-span-1 hidden lg:block">
            <div class="card bg-base-100 shadow-lg sticky top-6 max-h-[calc(100vh-3rem)] overflow-y-auto">
              <div class="card-body p-4">
                <CatalogSidebar.catalog_sidebar
                  filters={@enabled_filters}
                  filter_values={@filter_values}
                  active_filters={@active_filters}
                  categories={@categories}
                  current_category={nil}
                  current_language={@current_language}
                  category_icon_mode={@category_icon_mode}
                  category_name_wrap={@category_name_wrap}
                  filter_qs={@filter_qs}
                />
              </div>
            </div>
          </aside>

          <div class="lg:col-span-3">
            <%!-- Category Grid (controlled by setting) --%>
            <%= if @show_categories_grid && @categories != [] do %>
              <div class="mb-8">
                <h2 class="text-2xl font-bold mb-4">{gettext("Categories")}</h2>
                <div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-4 gap-4">
                  <%= for cat <- @categories do %>
                    <.link
                      navigate={Shop.category_url(cat, @current_language) <> @filter_qs}
                      class="card bg-base-100 shadow-md hover:shadow-lg transition-all hover:-translate-y-1"
                    >
                      <figure class="h-28 bg-base-200">
                        <% cat_image = category_image(cat) %>
                        <%= if cat_image do %>
                          <img
                            src={cat_image}
                            alt={Translations.get(cat, :name, @current_language)}
                            class="w-full h-full object-cover"
                          />
                        <% else %>
                          <div class="w-full h-full flex items-center justify-center">
                            <.icon name="hero-folder" class="w-10 h-10 opacity-30" />
                          </div>
                        <% end %>
                      </figure>
                      <div class="card-body p-3 text-center">
                        <h3 class="text-sm font-semibold line-clamp-2">
                          {Translations.get(cat, :name, @current_language)}
                        </h3>
                      </div>
                    </.link>
                  <% end %>
                </div>
              </div>
            <% end %>

            <%!-- Products Section --%>
            <%!-- One cart link only. `storefront_bar` above already carries a
                 translated one; the button that used to sit here was hardcoded
                 English and rendered a second, identical cart affordance a few
                 hundred pixels below the first. --%>
            <div class="flex items-center justify-between mb-6">
              <h2 class="text-2xl font-bold">{Vocabulary.heading()}</h2>
            </div>

            <%= if @products == [] do %>
              <div class="card bg-base-100 shadow-xl">
                <div class="card-body text-center py-16">
                  <.icon name="hero-cube" class="w-16 h-16 mx-auto mb-4 opacity-30" />
                  <h3 class="text-xl font-medium text-base-content/60">
                    {Vocabulary.none_available()}
                  </h3>
                  <p class="text-base-content/50">
                    <%= if FilterHelpers.has_active_filters?(@active_filters) do %>
                      {Vocabulary.none_match_filters()}
                      <button phx-click="clear_filters" class="link link-primary">
                        {gettext("Clear filters")}
                      </button>
                    <% else %>
                      {gettext("Check back soon for new arrivals")}
                    <% end %>
                  </p>
                </div>
              </div>
            <% else %>
              <div class="grid gap-6 grid-cols-1 sm:grid-cols-2 xl:grid-cols-3">
                <%= for product <- @products do %>
                  <ShopCards.product_card
                    product={product}
                    currency={@currency}
                    language={@current_language}
                    filter_qs={@filter_qs}
                    show_category={true}
                  />
                <% end %>
              </div>

              <ShopCards.shop_pagination
                page={@page}
                total_pages={@total_pages}
                total_products={@total_products}
                per_page={@per_page}
                base_path={Shop.catalog_url(@current_language)}
                active_filters={@active_filters}
                enabled_filters={@enabled_filters}
              />
            <% end %>
          </div>
        </div>
      </div>
    </ShopLayouts.shop_layout>
    """
  end

  defp category_image(category) do
    Shop.category_image_url(category, size: "small")
  end

  # Build catalog path with filter params and optional page
  defp build_filter_path(assigns, active_filters, opts \\ []) do
    base_path = Shop.catalog_url(assigns.current_language)
    page = Keyword.get(opts, :page)

    FilterHelpers.build_filter_url(base_path, active_filters, assigns.enabled_filters, page: page)
  end

  # Cart badge for the storefront bar. Guests and users alike; a missing
  # cart is simply zero.
  defp storefront_cart_count(socket) do
    user = socket.assigns[:phoenix_kit_current_user]

    case Shop.find_active_cart(
           user_uuid: user && user.uuid,
           session_id: socket.assigns[:session_id]
         ) do
      %{items_count: n} when is_integer(n) -> n
      _ -> 0
    end
  rescue
    _ -> 0
  end
end
