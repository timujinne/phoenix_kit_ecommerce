defmodule PhoenixKitEcommerce.Web.Products do
  @moduledoc """
  Products list LiveView for Shop module.
  """

  use PhoenixKitEcommerce.Web, :live_view

  # Search, filters, and page live in the query string so a filtered list is a
  # real URL: shareable, reload-proof, and Back returns to the previous query
  # instead of leaving the page. `status_filter` and `type_filter` default to
  # nil (no filter), which is therefore omitted from the URL.
  use PhoenixKitWeb.Live.UrlState,
    params: [
      search: [default: "", url_key: "search"],
      status_filter: [default: nil, url_key: "status", in: ~w(active draft archived)],
      type_filter: [default: nil, url_key: "type", in: ~w(physical digital)],
      category_filter: [default: nil, url_key: "category"],
      page: [default: 1, cast: :integer, min: 1, url_key: "page"]
    ]

  import PhoenixKitWeb.Components.Core.BulkSelect
  import PhoenixKitWeb.Components.Core.TableDefault
  import PhoenixKitWeb.Components.Core.TableRowMenu

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Activity
  alias PhoenixKitEcommerce.Events
  alias PhoenixKitEcommerce.Translations
  alias PhoenixKitEcommerce.Web.Authz
  alias PhoenixKitEcommerce.Web.Helpers
  import PhoenixKitEcommerce.Web.Helpers, only: [format_price: 2]

  @per_page 25

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Events.subscribe_products()
      Events.subscribe_inventory()
    end

    # A product's own `price` is always BASE currency (admin authoring
    # screen, §4.5) - not "whatever the current display default resolves
    # to", which is what `get_default_currency/0` names ambiguously.
    currency = Shop.get_base_currency()
    categories = Shop.list_categories()

    # Get current language for admin (use default language)
    current_language = Translations.default_language()

    socket =
      socket
      |> assign(:page_title, gettext("Products"))
      # :page, :search, :status_filter, :type_filter, and :category_filter are
      # assigned from the query string by UrlState before mount/3 runs —
      # re-assigning them here would overwrite a shared link's state with defaults.
      |> assign(:products, [])
      |> assign(:total, 0)
      |> assign(:per_page, @per_page)
      |> assign(:categories, categories)
      |> assign(:currency, currency)
      |> assign(:bulk_uuids, [])
      |> assign(:show_bulk_modal, nil)
      |> assign(:current_language, current_language)
      |> assign(:delete_target, nil)
      |> assign(:delete_media_checked, false)
      |> assign(:bulk_delete_media, false)

    {:ok, socket}
  end

  # The list is loaded here rather than in mount/3: UrlState calls this after
  # mount and on every change to the query string, so one code path serves the
  # first render, a shared link, and the Back button alike.
  #
  # `category_filter` is re-parsed because the query string reaches it without
  # passing through `filter_category`: `?category=` is free text until it is
  # checked. A plain `assign` on a declared param is supported — the next
  # patch reads its merge base back from the assigns, so the URL drops the
  # rejected value rather than resurrecting it.
  @impl true
  def handle_url_state(_state, socket) do
    socket
    |> assign(:category_filter, parse_category_uuid(socket.assigns.category_filter))
    |> load_products()
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # `replace: true` — debounced box, so a typed-out query would otherwise leave
  # one history entry per pause and Back would walk the search string backwards.
  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    {:noreply, push_url_state(socket, [search: search], replace: true)}
  end

  @impl true
  def handle_event("filter_status", %{"status" => status}, socket) do
    {:noreply, push_url_state(socket, status_filter: if(status == "", do: nil, else: status))}
  end

  @impl true
  def handle_event("filter_type", %{"type" => type}, socket) do
    {:noreply, push_url_state(socket, type_filter: if(type == "", do: nil, else: type))}
  end

  @impl true
  def handle_event("filter_category", %{"category" => category}, socket) do
    {:noreply, push_url_state(socket, category_filter: parse_category_uuid(category))}
  end

  @impl true
  def handle_event("change_page", %{"page" => page}, socket) do
    {:noreply, push_url_state(socket, page: Helpers.parse_page(page))}
  end

  @impl true
  def handle_event("view_product", %{"uuid" => uuid}, socket) do
    {:noreply, push_navigate(socket, to: Routes.path("/admin/shop/products/#{uuid}"))}
  end

  @impl true
  def handle_event("confirm_delete", %{"uuid" => uuid}, socket) do
    product = Shop.get_product!(uuid)
    {:noreply, socket |> assign(:delete_target, product) |> assign(:delete_media_checked, false)}
  end

  @impl true
  def handle_event("toggle_delete_media", _params, socket) do
    {:noreply, assign(socket, :delete_media_checked, !socket.assigns.delete_media_checked)}
  end

  @impl true
  def handle_event("cancel_delete", _params, socket) do
    {:noreply, socket |> assign(:delete_target, nil) |> assign(:delete_media_checked, false)}
  end

  @impl true
  def handle_event("execute_delete", params, socket) do
    Authz.authorize(socket, :manage_catalog, fn ->
      gated_event("execute_delete", params, socket)
    end)
  end

  @impl true
  def handle_event("delete_product", params, socket) do
    Authz.authorize(socket, :manage_catalog, fn ->
      gated_event("delete_product", params, socket)
    end)
  end

  @impl true
  def handle_event("toggle_status", params, socket) do
    Authz.authorize(socket, :manage_catalog, fn ->
      gated_event("toggle_status", params, socket)
    end)
  end

  # Bulk action modals — capture-then-act. Selection lives client-side in the
  # BulkSelectScope hook; each of these events is fired by a distinct
  # `data-bulk-action` button and carries the hook's currently-selected UUIDs
  # in the payload. We "capture" them into `@bulk_uuids` here so the modal's
  # own `phx-submit` handler (a normal server round-trip) has something to
  # read at submit time, since by then the browser selection may have moved on.
  @impl true
  def handle_event("open_status_modal", %{"uuids" => uuids}, socket) do
    {:noreply,
     socket
     |> assign(:bulk_uuids, uuids)
     |> assign(:show_bulk_modal, "status")}
  end

  @impl true
  def handle_event("open_category_modal", %{"uuids" => uuids}, socket) do
    {:noreply,
     socket
     |> assign(:bulk_uuids, uuids)
     |> assign(:show_bulk_modal, "category")}
  end

  @impl true
  def handle_event("confirm_bulk_delete", %{"uuids" => uuids}, socket) do
    {:noreply,
     socket
     |> assign(:bulk_uuids, uuids)
     |> assign(:show_bulk_modal, "delete")}
  end

  @impl true
  def handle_event("close_bulk_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_bulk_modal, nil)
     |> assign(:bulk_uuids, [])
     |> assign(:bulk_delete_media, false)}
  end

  # Bulk actions
  @impl true
  def handle_event("bulk_change_status", params, socket) do
    Authz.authorize(socket, :manage_catalog, fn ->
      gated_event("bulk_change_status", params, socket)
    end)
  end

  @impl true
  def handle_event("bulk_change_category", params, socket) do
    Authz.authorize(socket, :manage_catalog, fn ->
      gated_event("bulk_change_category", params, socket)
    end)
  end

  @impl true
  def handle_event("toggle_bulk_delete_media", _params, socket) do
    {:noreply, assign(socket, :bulk_delete_media, !socket.assigns.bulk_delete_media)}
  end

  @impl true
  def handle_event("bulk_delete", params, socket) do
    Authz.authorize(socket, :manage_catalog, fn -> gated_event("bulk_delete", params, socket) end)
  end

  defp load_products(socket) do
    {products, total} =
      Shop.list_products_with_count(
        page: socket.assigns.page,
        per_page: @per_page,
        search: socket.assigns.search,
        status: socket.assigns.status_filter,
        product_type: socket.assigns.type_filter,
        category_uuid: socket.assigns.category_filter,
        preload: [:category]
      )

    socket
    |> assign(:products, products)
    |> assign(:total, total)
  end

  # PubSub event handlers
  @impl true
  def handle_info({:product_created, _product}, socket) do
    {:noreply, load_products(socket)}
  end

  @impl true
  def handle_info({:product_updated, _product}, socket) do
    {:noreply, load_products(socket)}
  end

  @impl true
  def handle_info({:product_deleted, _product_uuid}, socket) do
    {:noreply, load_products(socket)}
  end

  @impl true
  def handle_info({:products_bulk_status_changed, _ids, _status}, socket) do
    {:noreply, load_products(socket)}
  end

  @impl true
  def handle_info({:inventory_updated, _product_uuid, _change}, socket) do
    {:noreply, load_products(socket)}
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

  @impl true
  def render(assigns) do
    ~H"""
      <div class="container flex-col mx-auto px-4 py-6 max-w-7xl">
        <.admin_page_header back={Routes.path("/admin/shop")}>
          <h1 class="text-xl sm:text-2xl lg:text-3xl font-bold text-base-content">{gettext("Products")}</h1>
          <p class="text-sm sm:text-base text-base-content/60 mt-0.5">
            {ngettext("1 product", "%{count} products", @total, count: @total)}
          </p>
        </.admin_page_header>

        <%!-- Controls Bar --%>
        <div class="bg-base-200 rounded-lg p-6 mb-6">
          <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-6 gap-4 items-end">
            <%!-- Search --%>
            <div class="lg:col-span-2">
              <label class="label"><span class="fieldset-legend">{gettext("Search")}</span></label>
              <form phx-submit="search" phx-change="search">
                <input
                  type="text"
                  name="search"
                  value={@search}
                  placeholder={gettext("Search products...")}
                  class="input w-full focus:input-primary"
                  phx-debounce="300"
                />
              </form>
            </div>

            <%!-- Status Filter --%>
            <div>
              <label class="label"><span class="fieldset-legend">{gettext("Status")}</span></label>
              <form phx-change="filter_status">
                <select class="select w-full focus:select-primary" name="status">
                  <option value="" selected={is_nil(@status_filter)}>{gettext("All Status")}</option>
                  <option value="active" selected={@status_filter == "active"}>{gettext("Active")}</option>
                  <option value="draft" selected={@status_filter == "draft"}>{gettext("Draft")}</option>
                  <option value="archived" selected={@status_filter == "archived"}>{gettext("Archived")}</option>
                </select>
              </form>
            </div>

            <%!-- Type Filter --%>
            <div>
              <label class="label"><span class="fieldset-legend">{gettext("Type")}</span></label>
              <form phx-change="filter_type">
                <select class="select w-full focus:select-primary" name="type">
                  <option value="" selected={is_nil(@type_filter)}>{gettext("All Types")}</option>
                  <option value="physical" selected={@type_filter == "physical"}>{gettext("Physical")}</option>
                  <option value="digital" selected={@type_filter == "digital"}>{gettext("Digital")}</option>
                </select>
              </form>
            </div>

            <%!-- Category Filter --%>
            <div>
              <label class="label"><span class="fieldset-legend">{gettext("Category")}</span></label>
              <form phx-change="filter_category">
                <select class="select w-full focus:select-primary" name="category">
                  <option value="" selected={is_nil(@category_filter)}>{gettext("All Categories")}</option>
                  <%= for category <- @categories do %>
                    <option value={category.uuid} selected={@category_filter == category.uuid}>
                      {Translations.get(category, :name, @current_language)}
                    </option>
                  <% end %>
                </select>
              </form>
            </div>

            <%!-- Add Button --%>
            <div>
              <label class="label"><span class="fieldset-legend">&nbsp;</span></label>
              <.link
                navigate={Routes.path("/admin/shop/products/new")}
                class="btn btn-primary w-full"
              >
                <.icon name="hero-plus" class="w-4 h-4 mr-2" /> {gettext("Add Product")}
              </.link>
            </div>
          </div>
        </div>

        <.bulk_select_scope id="products-bulk" total_count={length(@products)}>
          <%!-- Bulk Actions Bar --%>
          <div
            class="bg-primary/10 border border-primary/30 rounded-lg p-4 mb-6"
            data-bulk-show="has-selection"
            style="display: none;"
          >
            <div class="flex flex-wrap items-center justify-between gap-4">
              <div class="flex items-center gap-2">
                <span class="badge badge-primary badge-lg" data-bulk-text-template={gettext("%{count} selected", count: "%{count}")}>
                  {gettext("%{count} selected", count: 0)}
                </span>
                <button type="button" data-bulk-clear="true" class="btn btn-ghost btn-sm">
                  {gettext("Clear selection")}
                </button>
              </div>
              <div class="flex flex-wrap gap-2">
                <button
                  type="button"
                  data-bulk-action="open_status_modal"
                  class="btn btn-sm btn-outline"
                >
                  <.icon name="hero-arrow-path" class="w-4 h-4 mr-1" /> {gettext("Change Status")}
                </button>
                <button
                  type="button"
                  data-bulk-action="open_category_modal"
                  class="btn btn-sm btn-outline"
                >
                  <.icon name="hero-folder" class="w-4 h-4 mr-1" /> {gettext("Move to Category")}
                </button>
                <button
                  type="button"
                  data-bulk-action="confirm_bulk_delete"
                  class="btn btn-sm btn-outline btn-error"
                >
                  <.icon name="hero-trash" class="w-4 h-4 mr-1" /> {gettext("Delete")}
                </button>
              </div>
            </div>
          </div>

          <%!-- Products Table --%>
          <.table_default
            id="products-table"
            variant="zebra"
            toggleable={true}
            items={@products}
            card_fields={fn product ->
              [
                %{label: gettext("Status"), value: product.status},
                %{label: gettext("Type"), value: product.product_type},
                %{
                  label: gettext("Category"),
                  value:
                    if(product.category,
                      do: Translations.get(product.category, :name, @current_language),
                      else: "—"
                    )
                },
                %{label: gettext("Price"), value: format_price(product.price, @currency)}
              ]
            end}
          >
            <:card_header :let={product}>
              <div class="flex items-start gap-3">
                <input
                  type="checkbox"
                  class="checkbox checkbox-sm mt-1"
                  data-bulk-role="row"
                  data-uuid={product.uuid}
                />
                <% product_title = Translations.get(product, :title, @current_language) %>
                <div class="avatar placeholder">
                  <div class="bg-base-300 text-base-content/50 w-10 h-10 rounded">
                    <%= if thumb_url = get_product_thumbnail(product) do %>
                      <img src={thumb_url} alt={product_title} />
                    <% else %>
                      <.icon name="hero-cube" class="w-5 h-5" />
                    <% end %>
                  </div>
                </div>
                <div>
                  <div class="font-bold text-sm">{product_title}</div>
                  <div class="text-xs text-base-content/60">
                    {Translations.get(product, :slug, @current_language)}
                  </div>
                </div>
              </div>
            </:card_header>

            <:card_actions :let={product}>
              <.table_row_menu id={"card-menu-#{product.uuid}"}>
                <.table_row_menu_link
                  navigate={Routes.path("/admin/shop/products/#{product.uuid}")}
                  icon="hero-eye"
                  label={Gettext.gettext(PhoenixKitWeb.Gettext, "View")}
                />
                <.table_row_menu_link
                  navigate={Routes.path("/admin/shop/products/#{product.uuid}/edit")}
                  icon="hero-pencil"
                  label={Gettext.gettext(PhoenixKitWeb.Gettext, "Edit")}
                />
                <.table_row_menu_divider />
                <.table_row_menu_button
                  phx-click="confirm_delete"
                  phx-value-uuid={product.uuid}
                  icon="hero-trash"
                  label={Gettext.gettext(PhoenixKitWeb.Gettext, "Delete")}
                  variant="error"
                />
              </.table_row_menu>
            </:card_actions>

            <.table_default_header>
              <.table_default_row hover={false}>
                <.bulk_select_header_cell id="products-select-all" aria_label={gettext("Select all products")} />
                <.table_default_header_cell>{gettext("Product")}</.table_default_header_cell>
                <.table_default_header_cell>{gettext("Status")}</.table_default_header_cell>
                <.table_default_header_cell>{gettext("Type")}</.table_default_header_cell>
                <.table_default_header_cell>{gettext("Category")}</.table_default_header_cell>
                <.table_default_header_cell class="text-right">{gettext("Price")}</.table_default_header_cell>
                <.table_default_header_cell class="text-right">{gettext("Actions")}</.table_default_header_cell>
              </.table_default_row>
            </.table_default_header>

            <.table_default_body>
              <%= if Enum.empty?(@products) do %>
                <.table_default_row hover={false}>
                  <.table_default_cell colspan={7} class="text-center py-12 text-base-content/50">
                    <.icon name="hero-cube" class="w-12 h-12 mx-auto mb-3 opacity-50" />
                    <p class="text-lg">{gettext("No products found")}</p>
                    <p class="text-sm">{gettext("Create your first product to get started")}</p>
                  </.table_default_cell>
                </.table_default_row>
              <% else %>
                <%= for product <- @products do %>
                  <.table_default_row class="has-[input:checked]:bg-primary/5">
                    <.bulk_select_cell value={product.uuid} />
                    <.table_default_cell
                      class="cursor-pointer"
                      phx-click="view_product"
                      phx-value-uuid={product.uuid}
                    >
                      <div class="flex items-center gap-3">
                        <% product_title = Translations.get(product, :title, @current_language) %>
                        <% product_slug = Translations.get(product, :slug, @current_language) %>
                        <div class="avatar placeholder">
                          <div class="bg-base-300 text-base-content/50 w-12 h-12 rounded">
                            <%= if thumb_url = get_product_thumbnail(product) do %>
                              <img src={thumb_url} alt={product_title} />
                            <% else %>
                              <.icon name="hero-cube" class="w-6 h-6" />
                            <% end %>
                          </div>
                        </div>
                        <div>
                          <div class="font-bold">{product_title}</div>
                          <div class="text-sm text-base-content/60">{product_slug}</div>
                        </div>
                      </div>
                    </.table_default_cell>
                    <%!-- Status is a one-click toggle, not a link into the product.
                         Changing active<->draft used to cost four steps: open the
                         product, open its edit form, pick from a select, save.
                         Deliberately does NOT carry the row's view_product click,
                         or every toggle would also navigate away. Archived is left
                         inert — leaving that state is a deliberate act, not a
                         toggle. --%>
                    <.table_default_cell>
                      <%= if product.status in ["active", "draft"] do %>
                        <button
                          type="button"
                          phx-click="toggle_status"
                          phx-value-uuid={product.uuid}
                          class={[status_badge_class(product.status), "cursor-pointer"]}
                          title={
                            if product.status == "active",
                              do: gettext("Click to make it a draft"),
                              else: gettext("Click to publish")
                          }
                        >
                          {product.status}
                        </button>
                      <% else %>
                        <span class={status_badge_class(product.status)}>{product.status}</span>
                      <% end %>
                    </.table_default_cell>
                    <.table_default_cell
                      class="cursor-pointer"
                      phx-click="view_product"
                      phx-value-uuid={product.uuid}
                    >
                      <span class={type_badge_class(product.product_type)}>
                        {product.product_type}
                      </span>
                    </.table_default_cell>
                    <.table_default_cell
                      class="cursor-pointer"
                      phx-click="view_product"
                      phx-value-uuid={product.uuid}
                    >
                      <%= if product.category do %>
                        <span class="badge badge-ghost">
                          {Translations.get(product.category, :name, @current_language)}
                        </span>
                      <% else %>
                        <span class="text-base-content/40">—</span>
                      <% end %>
                    </.table_default_cell>
                    <.table_default_cell
                      class="text-right font-mono cursor-pointer"
                      phx-click="view_product"
                      phx-value-uuid={product.uuid}
                    >
                      {format_price(product.price, @currency)}
                    </.table_default_cell>
                    <.table_default_cell class="text-right">
                      <div class="flex justify-end">
                        <.table_row_menu id={"menu-#{product.uuid}"}>
                          <.table_row_menu_link
                            navigate={Routes.path("/admin/shop/products/#{product.uuid}")}
                            icon="hero-eye"
                            label={Gettext.gettext(PhoenixKitWeb.Gettext, "View")}
                          />
                          <.table_row_menu_link
                            navigate={Routes.path("/admin/shop/products/#{product.uuid}/edit")}
                            icon="hero-pencil"
                            label={Gettext.gettext(PhoenixKitWeb.Gettext, "Edit")}
                          />
                          <.table_row_menu_divider />
                          <.table_row_menu_button
                            phx-click="confirm_delete"
                            phx-value-uuid={product.uuid}
                            icon="hero-trash"
                            label={Gettext.gettext(PhoenixKitWeb.Gettext, "Delete")}
                            variant="error"
                          />
                        </.table_row_menu>
                      </div>
                    </.table_default_cell>
                  </.table_default_row>
                <% end %>
              <% end %>
            </.table_default_body>
          </.table_default>
        </.bulk_select_scope>

        <%!-- Pagination --%>
        <%= if @total > @per_page do %>
          <div class="mt-4">
            <div class="flex justify-center">
              <div class="join">
                <%= for page <- 1..ceil(@total / @per_page) do %>
                  <button
                    phx-click="change_page"
                    phx-value-page={page}
                    class={["join-item btn btn-sm", if(@page == page, do: "btn-active", else: "")]}
                  >
                    {page}
                  </button>
                <% end %>
              </div>
            </div>
          </div>
        <% end %>
      </div>

      <%!-- Bulk Status Change Modal --%>
      <%= if @show_bulk_modal == "status" do %>
        <div class="modal modal-open">
          <div class="modal-box">
            <h3 class="font-bold text-lg mb-4">{gettext("Change Status")}</h3>
            <p class="text-base-content/70 mb-4">
              {gettext("Update status for %{count} selected products", count: length(@bulk_uuids))}
            </p>
            <div class="flex flex-col gap-2">
              <button
                phx-click="bulk_change_status"
                phx-value-status="active"
                class="btn btn-success btn-outline justify-start"
              >
                <.icon name="hero-check-circle" class="w-5 h-5 mr-2" /> {gettext("Set Active")}
              </button>
              <button
                phx-click="bulk_change_status"
                phx-value-status="draft"
                class="btn btn-warning btn-outline justify-start"
              >
                <.icon name="hero-pencil-square" class="w-5 h-5 mr-2" /> {gettext("Set Draft")}
              </button>
              <button
                phx-click="bulk_change_status"
                phx-value-status="archived"
                class="btn btn-neutral btn-outline justify-start"
              >
                <.icon name="hero-archive-box" class="w-5 h-5 mr-2" /> {gettext("Set Archived")}
              </button>
            </div>
            <div class="modal-action">
              <button phx-click="close_bulk_modal" class="btn">{gettext("Cancel")}</button>
            </div>
          </div>
          <div class="modal-backdrop" phx-click="close_bulk_modal"></div>
        </div>
      <% end %>

      <%!-- Bulk Category Change Modal --%>
      <%= if @show_bulk_modal == "category" do %>
        <div class="modal modal-open">
          <div class="modal-box">
            <h3 class="font-bold text-lg mb-4">{gettext("Move to Category")}</h3>
            <p class="text-base-content/70 mb-4">
              {gettext("Move %{count} selected products to a category", count: length(@bulk_uuids))}
            </p>
            <div class="flex flex-col gap-2">
              <button
                phx-click="bulk_change_category"
                phx-value-category_uuid=""
                class="btn btn-ghost justify-start"
              >
                <.icon name="hero-x-mark" class="w-5 h-5 mr-2" /> {gettext("No Category")}
              </button>
              <%= for category <- @categories do %>
                <button
                  phx-click="bulk_change_category"
                  phx-value-category_uuid={category.uuid}
                  class="btn btn-outline justify-start"
                >
                  <.icon name="hero-folder" class="w-5 h-5 mr-2" /> {Translations.get(
                    category,
                    :name,
                    @current_language
                  )}
                </button>
              <% end %>
            </div>
            <div class="modal-action">
              <button phx-click="close_bulk_modal" class="btn">{gettext("Cancel")}</button>
            </div>
          </div>
          <div class="modal-backdrop" phx-click="close_bulk_modal"></div>
        </div>
      <% end %>

      <%!-- Bulk Delete Confirmation Modal --%>
      <%= if @show_bulk_modal == "delete" do %>
        <div class="modal modal-open">
          <div class="modal-box">
            <h3 class="font-bold text-lg text-error mb-4">{gettext("Delete Products")}</h3>
            <p class="text-base-content/70 mb-4">
              {gettext(
                "Are you sure you want to delete %{count} products? This action cannot be undone.",
                count: length(@bulk_uuids)
              )}
            </p>
            <label class="label cursor-pointer justify-start gap-3">
              <input
                type="checkbox"
                class="checkbox checkbox-error"
                phx-click="toggle_bulk_delete_media"
                checked={@bulk_delete_media}
              />
              <span class="fieldset-legend">{gettext("Delete associated media files (orphaned only)")}</span>
            </label>
            <div class="modal-action">
              <button phx-click="close_bulk_modal" class="btn">{gettext("Cancel")}</button>
              <button phx-click="bulk_delete" class="btn btn-error">
                <.icon name="hero-trash" class="w-4 h-4 mr-2" /> {gettext("Delete Products")}
              </button>
            </div>
          </div>
          <div class="modal-backdrop" phx-click="close_bulk_modal"></div>
        </div>
      <% end %>

      <%!-- Single Product Delete Confirmation Modal --%>
      <%= if @delete_target do %>
        <div class="modal modal-open">
          <div class="modal-box">
            <h3 class="font-bold text-lg text-error mb-4">{gettext("Delete Product")}</h3>
            <p class="mb-4">{gettext("Are you sure you want to delete this product?")}</p>
            <label class="label cursor-pointer justify-start gap-3">
              <input
                type="checkbox"
                class="checkbox checkbox-error"
                phx-click="toggle_delete_media"
                checked={@delete_media_checked}
              />
              <span class="fieldset-legend">{gettext("Delete associated media files (orphaned only)")}</span>
            </label>
            <div class="modal-action">
              <button phx-click="cancel_delete" class="btn">{gettext("Cancel")}</button>
              <button phx-click="execute_delete" class="btn btn-error">{gettext("Delete")}</button>
            </div>
          </div>
          <div class="modal-backdrop" phx-click="cancel_delete"></div>
        </div>
      <% end %>
    """
  end

  # The value goes straight into `where p.category_uuid == ^uuid`, and Ecto
  # raises `Ecto.Query.CastError` on anything that is not a UUID — so a
  # hand-edited `?category=whatever` took the whole LiveView down rather than
  # showing an unfiltered list. Unparseable means "no filter".
  defp parse_category_uuid(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp parse_category_uuid(_), do: nil

  defp status_badge_class("active"), do: "badge badge-success"
  defp status_badge_class("draft"), do: "badge badge-warning"
  defp status_badge_class("archived"), do: "badge badge-neutral"
  defp status_badge_class(_), do: "badge"

  defp type_badge_class("physical"), do: "badge badge-info badge-outline"
  defp type_badge_class("digital"), do: "badge badge-secondary badge-outline"
  defp type_badge_class(_), do: "badge badge-outline"

  # Get product thumbnail - prefers Storage images over legacy URLs
  defp get_product_thumbnail(%{featured_image_uuid: id}) when is_binary(id) do
    get_storage_image_url(id, "small")
  end

  defp get_product_thumbnail(%{image_uuids: [id | _]}) when is_binary(id) do
    get_storage_image_url(id, "small")
  end

  defp get_product_thumbnail(%{featured_image: url}) when is_binary(url) and url != "" do
    url
  end

  defp get_product_thumbnail(%{images: [%{"src" => src} | _]}), do: src
  defp get_product_thumbnail(%{images: [first | _]}) when is_binary(first), do: first
  defp get_product_thumbnail(_), do: nil

  defp get_storage_image_url(file_uuid, variant) do
    case Storage.get_file(file_uuid) do
      %{uuid: uuid} ->
        resolve_file_variant(file_uuid, uuid, variant)

      nil ->
        nil
    end
  end

  defp resolve_file_variant(file_uuid, uuid, variant) do
    case Storage.get_file_instance_by_name(uuid, variant) do
      nil ->
        case Storage.get_file_instance_by_name(uuid, "original") do
          nil -> nil
          _instance -> URLSigner.signed_url(file_uuid, "original")
        end

      _instance ->
        URLSigner.signed_url(file_uuid, variant)
    end
  end

  defp gated_event("execute_delete", _params, socket) do
    product = socket.assigns.delete_target

    file_uuids =
      if socket.assigns.delete_media_checked,
        do: Shop.collect_product_file_uuids(product),
        else: []

    case Shop.delete_product(product) do
      {:ok, _} ->
        Activity.log("shop.product_deleted",
          actor_uuid: Activity.actor_uuid(socket),
          actor_role: Activity.actor_role(socket),
          resource_type: "product",
          resource_uuid: product.uuid,
          metadata: %{"status" => product.status}
        )

        if file_uuids != [], do: Storage.queue_file_cleanup(file_uuids)

        {products, total} =
          Shop.list_products_with_count(
            page: socket.assigns.page,
            per_page: @per_page,
            search: socket.assigns.search,
            status: socket.assigns.status_filter,
            product_type: socket.assigns.type_filter,
            category_uuid: socket.assigns.category_filter,
            preload: [:category]
          )

        {:noreply,
         socket
         |> assign(:products, products)
         |> assign(:total, total)
         |> assign(:delete_target, nil)
         |> assign(:delete_media_checked, false)
         |> put_flash(:info, gettext("Product deleted"))}

      {:error, _} ->
        {:noreply,
         socket
         |> assign(:delete_target, nil)
         |> put_flash(:error, gettext("Failed to delete product"))}
    end
  end

  defp gated_event("delete_product", %{"uuid" => uuid}, socket) do
    product = Shop.get_product!(uuid)

    case Shop.delete_product(product) do
      {:ok, _} ->
        Activity.log("shop.product_deleted",
          actor_uuid: Activity.actor_uuid(socket),
          actor_role: Activity.actor_role(socket),
          resource_type: "product",
          resource_uuid: product.uuid,
          metadata: %{"status" => product.status}
        )

        {products, total} =
          Shop.list_products_with_count(
            page: socket.assigns.page,
            per_page: @per_page,
            preload: [:category]
          )

        {:noreply,
         socket
         |> assign(:products, products)
         |> assign(:total, total)
         |> put_flash(:info, gettext("Product deleted"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to delete product"))}
    end
  end

  defp gated_event("toggle_status", %{"uuid" => uuid}, socket) do
    # Re-read rather than trusting socket.assigns, which is as old as the last
    # render. Deciding "is this active or draft" against a stale row means an
    # admin who archived it in another tab gets it silently un-archived — the
    # exact transition the clause below refuses to guess at.
    case Shop.get_product(uuid) do
      %{status: old} = product when old in ["active", "draft"] ->
        new = if old == "active", do: "draft", else: "active"

        case Shop.update_product(product, %{"status" => new}) do
          {:ok, _} ->
            Activity.log("shop.product_status_changed",
              actor_uuid: Activity.actor_uuid(socket),
              actor_role: Activity.actor_role(socket),
              resource_type: "product",
              resource_uuid: uuid,
              metadata: %{"from" => old, "to" => new}
            )

            {:noreply, load_products(socket)}

          {:error, reason} ->
            # Logged on BOTH branches: this handler turns a four-step change into
            # one click, so the volume is about to rise, and a rejected changeset
            # with no audit row leaves nothing to diagnose from.
            Activity.log_failed("shop.product_status_changed", reason,
              actor_uuid: Activity.actor_uuid(socket),
              resource_type: "product",
              resource_uuid: uuid,
              metadata: %{"from" => old, "to" => new}
            )

            {:noreply, put_flash(socket, :error, gettext("Failed to update status"))}
        end

      # Archived, or a row that is no longer on screen after a concurrent
      # change: do nothing rather than guess which transition was meant.
      _ ->
        {:noreply, socket}
    end
  end

  defp gated_event("bulk_change_status", %{"status" => status}, socket) do
    uuids = socket.assigns.bulk_uuids
    count = Shop.bulk_update_product_status(uuids, status)

    Activity.log("shop.products_status_changed",
      actor_uuid: Activity.actor_uuid(socket),
      actor_role: Activity.actor_role(socket),
      resource_type: "product",
      metadata: %{"status" => status, "count" => count}
    )

    socket = load_products(socket)

    {:noreply,
     socket
     |> assign(:bulk_uuids, [])
     |> assign(:show_bulk_modal, nil)
     |> put_flash(
       :info,
       gettext("%{count} products updated to %{status}", count: count, status: status)
     )}
  end

  defp gated_event("bulk_change_category", %{"category_uuid" => category_uuid}, socket) do
    uuids = socket.assigns.bulk_uuids
    category_uuid = if category_uuid == "", do: nil, else: category_uuid
    count = Shop.bulk_update_product_category(uuids, category_uuid)

    socket = load_products(socket)

    {:noreply,
     socket
     |> assign(:bulk_uuids, [])
     |> assign(:show_bulk_modal, nil)
     |> put_flash(:info, gettext("%{count} products moved", count: count))}
  end

  defp gated_event("bulk_delete", _params, socket) do
    uuids = socket.assigns.bulk_uuids

    file_uuids =
      if socket.assigns.bulk_delete_media,
        do: Shop.collect_products_file_uuids(uuids),
        else: []

    count = Shop.bulk_delete_products(uuids)
    if file_uuids != [], do: Storage.queue_file_cleanup(file_uuids)

    Activity.log("shop.products_bulk_deleted",
      actor_uuid: Activity.actor_uuid(socket),
      actor_role: Activity.actor_role(socket),
      resource_type: "product",
      metadata: %{"count" => count}
    )

    socket = load_products(socket)

    {:noreply,
     socket
     |> assign(:bulk_uuids, [])
     |> assign(:show_bulk_modal, nil)
     |> assign(:bulk_delete_media, false)
     |> put_flash(:info, gettext("%{count} products deleted", count: count))}
  end
end
