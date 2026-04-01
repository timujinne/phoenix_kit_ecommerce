defmodule PhoenixKitEcommerce.Web.Categories do
  @moduledoc """
  Categories list LiveView for Shop module.

  Provides search, filtering, pagination, and bulk operations
  for category management.
  """

  use PhoenixKitEcommerce.Web, :live_view

  import PhoenixKitWeb.Components.Core.TableDefault
  import PhoenixKitWeb.Components.Core.TableRowMenu

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Category
  alias PhoenixKitEcommerce.Events
  alias PhoenixKitEcommerce.Translations

  @per_page 25

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Events.subscribe_categories()
    end

    current_language = Translations.default_language()

    socket =
      socket
      |> assign(:page_title, "Categories")
      |> assign(:page, 1)
      |> assign(:per_page, @per_page)
      |> assign(:search, "")
      |> assign(:status_filter, nil)
      |> assign(:parent_filter, nil)
      |> assign(:current_language, current_language)
      |> assign(:selected_uuids, MapSet.new())
      |> assign(:show_bulk_modal, nil)
      |> load_static_category_data()
      |> load_filtered_categories()

    {:ok, socket}
  end

  # ============================================
  # EVENT HANDLERS
  # ============================================

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    socket =
      socket
      |> assign(:search, search)
      |> assign(:page, 1)
      |> load_filtered_categories()

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter_status", %{"status" => status}, socket) do
    status = if status == "", do: nil, else: status

    socket =
      socket
      |> assign(:status_filter, status)
      |> assign(:page, 1)
      |> load_filtered_categories()

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter_parent", %{"parent" => parent}, socket) do
    parent = if parent == "", do: nil, else: parent

    socket =
      socket
      |> assign(:parent_filter, parent)
      |> assign(:page, 1)
      |> load_filtered_categories()

    {:noreply, socket}
  end

  @impl true
  def handle_event("change_page", %{"page" => page}, socket) do
    page = String.to_integer(page)

    socket =
      socket
      |> assign(:page, page)
      |> load_filtered_categories()

    {:noreply, socket}
  end

  @impl true
  def handle_event("delete", %{"uuid" => uuid}, socket) do
    if Scope.admin?(socket.assigns.phoenix_kit_current_scope) do
      category = Shop.get_category!(uuid)

      case Shop.delete_category(category) do
        {:ok, _} ->
          {:noreply,
           socket
           |> load_static_category_data()
           |> load_filtered_categories()
           |> put_flash(:info, "Category deleted")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to delete category")}
      end
    else
      {:noreply, put_flash(socket, :error, "Not authorized")}
    end
  end

  # Bulk selection events

  @impl true
  def handle_event("toggle_select", %{"uuid" => uuid}, socket) do
    selected = socket.assigns.selected_uuids

    selected =
      if MapSet.member?(selected, uuid) do
        MapSet.delete(selected, uuid)
      else
        MapSet.put(selected, uuid)
      end

    {:noreply, assign(socket, :selected_uuids, selected)}
  end

  @impl true
  def handle_event("select_all", _params, socket) do
    all_uuids = Enum.map(socket.assigns.categories, & &1.uuid) |> MapSet.new()
    current = socket.assigns.selected_uuids

    selected =
      if MapSet.subset?(all_uuids, current) do
        MapSet.difference(current, all_uuids)
      else
        MapSet.union(current, all_uuids)
      end

    {:noreply, assign(socket, :selected_uuids, selected)}
  end

  @impl true
  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, :selected_uuids, MapSet.new())}
  end

  # Bulk action modals

  @impl true
  def handle_event("show_bulk_modal", %{"action" => action}, socket) do
    {:noreply, assign(socket, :show_bulk_modal, action)}
  end

  @impl true
  def handle_event("close_bulk_modal", _params, socket) do
    {:noreply, assign(socket, :show_bulk_modal, nil)}
  end

  # Bulk actions (require admin role)

  @impl true
  def handle_event("bulk_change_status", %{"status" => status}, socket) do
    if Scope.admin?(socket.assigns.phoenix_kit_current_scope) do
      uuids = MapSet.to_list(socket.assigns.selected_uuids)
      count = Shop.bulk_update_category_status(uuids, status)

      {:noreply,
       socket
       |> load_static_category_data()
       |> load_filtered_categories()
       |> assign(:selected_uuids, MapSet.new())
       |> assign(:show_bulk_modal, nil)
       |> put_flash(:info, "#{count} categories updated to #{status}")}
    else
      {:noreply, put_flash(socket, :error, "Not authorized")}
    end
  end

  @impl true
  def handle_event("bulk_change_parent", %{"parent_uuid" => parent_uuid}, socket) do
    if Scope.admin?(socket.assigns.phoenix_kit_current_scope) do
      uuids = MapSet.to_list(socket.assigns.selected_uuids)
      parent_uuid = if parent_uuid == "", do: nil, else: parent_uuid
      count = Shop.bulk_update_category_parent(uuids, parent_uuid)

      {:noreply,
       socket
       |> load_static_category_data()
       |> load_filtered_categories()
       |> assign(:selected_uuids, MapSet.new())
       |> assign(:show_bulk_modal, nil)
       |> put_flash(:info, "#{count} categories updated")}
    else
      {:noreply, put_flash(socket, :error, "Not authorized")}
    end
  end

  @impl true
  def handle_event("bulk_delete", _params, socket) do
    if Scope.admin?(socket.assigns.phoenix_kit_current_scope) do
      uuids = MapSet.to_list(socket.assigns.selected_uuids)
      count = Shop.bulk_delete_categories(uuids)

      {:noreply,
       socket
       |> load_static_category_data()
       |> load_filtered_categories()
       |> assign(:selected_uuids, MapSet.new())
       |> assign(:show_bulk_modal, nil)
       |> put_flash(:info, "#{count} categories deleted")}
    else
      {:noreply, put_flash(socket, :error, "Not authorized")}
    end
  end

  # ============================================
  # PUBSUB HANDLERS
  # ============================================

  @impl true
  def handle_info({:category_created, _category}, socket) do
    {:noreply, socket |> load_static_category_data() |> load_filtered_categories()}
  end

  @impl true
  def handle_info({:category_updated, _category}, socket) do
    {:noreply, socket |> load_static_category_data() |> load_filtered_categories()}
  end

  @impl true
  def handle_info({:category_deleted, _category_uuid}, socket) do
    {:noreply, socket |> load_static_category_data() |> load_filtered_categories()}
  end

  @impl true
  def handle_info({:categories_bulk_status_changed, _uuids, _status}, socket) do
    {:noreply, socket |> load_static_category_data() |> load_filtered_categories()}
  end

  @impl true
  def handle_info({:categories_bulk_parent_changed, _uuids, _parent_uuid}, socket) do
    {:noreply, socket |> load_static_category_data() |> load_filtered_categories()}
  end

  @impl true
  def handle_info({:categories_bulk_deleted, _uuids}, socket) do
    {:noreply, socket |> load_static_category_data() |> load_filtered_categories()}
  end

  # ============================================
  # PRIVATE HELPERS
  # ============================================

  defp load_static_category_data(socket) do
    all_categories = Shop.list_categories(preload: [:parent])
    product_counts = Shop.product_counts_by_category()

    socket
    |> assign(:all_categories, all_categories)
    |> assign(:product_counts, product_counts)
  end

  defp load_filtered_categories(socket) do
    parent_uuid_opt =
      case socket.assigns.parent_filter do
        nil -> :skip
        "root" -> nil
        uuid -> uuid
      end

    opts = [
      page: socket.assigns.page,
      per_page: @per_page,
      search: socket.assigns.search,
      status: socket.assigns.status_filter,
      parent_uuid: parent_uuid_opt,
      preload: [:parent, :featured_product]
    ]

    {categories, total} = Shop.list_categories_with_count(opts)

    socket
    |> assign(:categories, categories)
    |> assign(:total, total)
  end

  defp all_selected?(categories, selected_uuids) do
    categories != [] and
      Enum.all?(categories, fn c -> MapSet.member?(selected_uuids, c.uuid) end)
  end

  defp status_badge_class("active"), do: "badge badge-success"
  defp status_badge_class("unlisted"), do: "badge badge-warning"
  defp status_badge_class("hidden"), do: "badge badge-error"
  defp status_badge_class(_), do: "badge badge-success"

  # ============================================
  # RENDER
  # ============================================

  @impl true
  def render(assigns) do
    ~H"""
      <div class="container flex-col mx-auto px-4 py-6 max-w-6xl">
        <.admin_page_header back={Routes.path("/admin/shop")}>
          <h1 class="text-xl sm:text-2xl lg:text-3xl font-bold text-base-content">Categories</h1>
          <p class="text-sm sm:text-base text-base-content/60 mt-0.5">
            {if @total == 1, do: "1 category", else: "#{@total} categories"}
          </p>
        </.admin_page_header>

        <%!-- Controls Bar --%>
        <div class="bg-base-200 rounded-lg p-6 mb-6">
          <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-5 gap-4 items-end">
            <%!-- Search --%>
            <div class="lg:col-span-2">
              <label class="label"><span class="label-text">Search</span></label>
              <form phx-submit="search" phx-change="search">
                <input
                  type="text"
                  name="search"
                  value={@search}
                  placeholder="Search categories..."
                  class="input input-bordered w-full focus:input-primary"
                  phx-debounce="300"
                />
              </form>
            </div>

            <%!-- Status Filter --%>
            <div>
              <label class="label"><span class="label-text">Status</span></label>
              <form phx-change="filter_status">
                <select class="select select-bordered w-full focus:select-primary" name="status">
                  <option value="" selected={is_nil(@status_filter)}>All Status</option>
                  <option value="active" selected={@status_filter == "active"}>Active</option>
                  <option value="unlisted" selected={@status_filter == "unlisted"}>Unlisted</option>
                  <option value="hidden" selected={@status_filter == "hidden"}>Hidden</option>
                </select>
              </form>
            </div>

            <%!-- Parent Filter --%>
            <div>
              <label class="label"><span class="label-text">Parent</span></label>
              <form phx-change="filter_parent">
                <select class="select select-bordered w-full focus:select-primary" name="parent">
                  <option value="" selected={is_nil(@parent_filter)}>All Categories</option>
                  <option value="root" selected={@parent_filter == "root"}>Root Only</option>
                  <%= for category <- @all_categories do %>
                    <option value={category.uuid} selected={@parent_filter == category.uuid}>
                      {Translations.get(category, :name, @current_language)}
                    </option>
                  <% end %>
                </select>
              </form>
            </div>

            <%!-- Add Button --%>
            <div>
              <label class="label"><span class="label-text">&nbsp;</span></label>
              <.link
                navigate={Routes.path("/admin/shop/categories/new")}
                class="btn btn-primary w-full"
              >
                <.icon name="hero-plus" class="w-4 h-4 mr-2" /> Add Category
              </.link>
            </div>
          </div>
        </div>

        <%!-- Bulk Actions Bar --%>
        <%= if MapSet.size(@selected_uuids) > 0 do %>
          <div class="bg-primary/10 border border-primary/30 rounded-lg p-4 mb-6">
            <div class="flex flex-wrap items-center justify-between gap-4">
              <div class="flex items-center gap-2">
                <span class="badge badge-primary badge-lg">
                  {MapSet.size(@selected_uuids)} selected
                </span>
                <button phx-click="clear_selection" class="btn btn-ghost btn-sm">
                  Clear selection
                </button>
              </div>
              <div class="flex flex-wrap gap-2">
                <button
                  phx-click="show_bulk_modal"
                  phx-value-action="status"
                  class="btn btn-sm btn-outline"
                >
                  <.icon name="hero-arrow-path" class="w-4 h-4 mr-1" /> Change Status
                </button>
                <button
                  phx-click="show_bulk_modal"
                  phx-value-action="parent"
                  class="btn btn-sm btn-outline"
                >
                  <.icon name="hero-folder" class="w-4 h-4 mr-1" /> Change Parent
                </button>
                <button
                  phx-click="show_bulk_modal"
                  phx-value-action="delete"
                  class="btn btn-sm btn-outline btn-error"
                >
                  <.icon name="hero-trash" class="w-4 h-4 mr-1" /> Delete
                </button>
              </div>
            </div>
          </div>
        <% end %>

        <%!-- Categories Table --%>
        <.table_default id="categories-table" variant="zebra" class="w-full" toggleable={true} items={@categories}
          card_fields={fn category -> [
            %{label: "Status", value: category.status || "active"},
            %{label: "Position", value: category.position}
          ] end}>

          <:card_header :let={category}>
            <div class="font-bold">{Translations.get(category, :name, @current_language)}</div>
            <div class="text-sm text-base-content/60">
              {Translations.get(category, :slug, @current_language)}
            </div>
          </:card_header>

          <:card_actions :let={category}>
            <.table_row_menu id={"card-menu-#{category.uuid}"}>
              <.table_row_menu_link
                navigate={Routes.path("/admin/shop/categories/#{category.uuid}/edit")}
                icon="hero-pencil"
                label={gettext("Edit")}
              />
              <.table_row_menu_divider />
              <.table_row_menu_button
                phx-click="delete"
                phx-value-uuid={category.uuid}
                data-confirm={gettext("Delete this category?")}
                icon="hero-trash"
                label={gettext("Delete")}
                variant="error"
              />
            </.table_row_menu>
          </:card_actions>

          <.table_default_header>
            <.table_default_row>
              <.table_default_header_cell class="w-12">
                <label class="cursor-pointer">
                  <input
                    type="checkbox"
                    class="checkbox checkbox-sm"
                    phx-click="select_all"
                    checked={all_selected?(@categories, @selected_uuids)}
                  />
                </label>
              </.table_default_header_cell>
              <.table_default_header_cell>Name</.table_default_header_cell>
              <.table_default_header_cell>Slug</.table_default_header_cell>
              <.table_default_header_cell>Parent</.table_default_header_cell>
              <.table_default_header_cell>Status</.table_default_header_cell>
              <.table_default_header_cell>Position</.table_default_header_cell>
              <.table_default_header_cell>Products</.table_default_header_cell>
              <.table_default_header_cell class="text-right">Actions</.table_default_header_cell>
            </.table_default_row>
          </.table_default_header>

          <.table_default_body>
            <%= if Enum.empty?(@categories) do %>
              <.table_default_row>
                <.table_default_cell class="text-center py-12 text-base-content/50">
                  <.icon name="hero-folder" class="w-12 h-12 mx-auto mb-3 opacity-50" />
                  <p class="text-lg">No categories found</p>
                  <p class="text-sm">Create your first category to organize products</p>
                </.table_default_cell>
              </.table_default_row>
            <% else %>
              <%= for category <- @categories do %>
                <% cat_name = Translations.get(category, :name, @current_language) %>
                <% cat_slug = Translations.get(category, :slug, @current_language) %>
                <.table_default_row class={"hover #{if MapSet.member?(@selected_uuids, category.uuid), do: "bg-primary/5", else: ""}"}>
                  <.table_default_cell>
                    <label class="cursor-pointer">
                      <input
                        type="checkbox"
                        class="checkbox checkbox-sm"
                        phx-click="toggle_select"
                        phx-value-uuid={category.uuid}
                        checked={MapSet.member?(@selected_uuids, category.uuid)}
                      />
                    </label>
                  </.table_default_cell>
                  <.table_default_cell>
                    <div class="flex items-center gap-3">
                      <div class="avatar placeholder">
                        <div class="bg-base-300 text-base-content/50 w-10 h-10 rounded">
                          <%= if image_url = Category.get_image_url(category, size: "thumbnail") do %>
                            <img src={image_url} alt={cat_name} />
                          <% else %>
                            <.icon name="hero-folder" class="w-5 h-5" />
                          <% end %>
                        </div>
                      </div>
                      <span class="font-medium">{cat_name}</span>
                    </div>
                  </.table_default_cell>
                  <.table_default_cell class="text-base-content/60">{cat_slug}</.table_default_cell>
                  <.table_default_cell>
                    <%= if category.parent do %>
                      <span class="badge badge-ghost">
                        {Translations.get(category.parent, :name, @current_language)}
                      </span>
                    <% else %>
                      <span class="text-base-content/40">&mdash;</span>
                    <% end %>
                  </.table_default_cell>
                  <.table_default_cell>
                    <span class={status_badge_class(category.status)}>
                      {category.status || "active"}
                    </span>
                  </.table_default_cell>
                  <.table_default_cell>{category.position}</.table_default_cell>
                  <.table_default_cell>
                    <span class="badge badge-ghost badge-sm">
                      {Map.get(@product_counts, category.uuid, 0)}
                    </span>
                  </.table_default_cell>
                  <.table_default_cell>
                    <div class="flex justify-end">
                      <.table_row_menu id={"menu-#{category.uuid}"}>
                        <.table_row_menu_link
                          navigate={Routes.path("/admin/shop/categories/#{category.uuid}/edit")}
                          icon="hero-pencil"
                          label={gettext("Edit")}
                        />
                        <.table_row_menu_divider />
                        <.table_row_menu_button
                          phx-click="delete"
                          phx-value-uuid={category.uuid}
                          data-confirm={gettext("Delete this category?")}
                          icon="hero-trash"
                          label={gettext("Delete")}
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

        <%!-- Pagination --%>
        <%= if @total > @per_page do %>
          <div class="flex justify-center mt-6">
            <div class="join">
              <%= for page <- 1..ceil(@total / @per_page) do %>
                <button
                  phx-click="change_page"
                  phx-value-page={page}
                  class={[
                    "join-item btn btn-sm",
                    if(@page == page, do: "btn-active", else: "")
                  ]}
                >
                  {page}
                </button>
              <% end %>
            </div>
          </div>
        <% end %>
      </div>

      <%!-- Bulk Status Change Modal --%>
      <%= if @show_bulk_modal == "status" do %>
        <div class="modal modal-open">
          <div class="modal-box">
            <h3 class="font-bold text-lg mb-4">Change Status</h3>
            <p class="text-base-content/70 mb-4">
              Update status for {MapSet.size(@selected_uuids)} selected categories
            </p>
            <div class="flex flex-col gap-2">
              <button
                phx-click="bulk_change_status"
                phx-value-status="active"
                class="btn btn-success btn-outline justify-start"
              >
                <.icon name="hero-check-circle" class="w-5 h-5 mr-2" /> Set Active
              </button>
              <button
                phx-click="bulk_change_status"
                phx-value-status="unlisted"
                class="btn btn-warning btn-outline justify-start"
              >
                <.icon name="hero-eye-slash" class="w-5 h-5 mr-2" /> Set Unlisted
              </button>
              <button
                phx-click="bulk_change_status"
                phx-value-status="hidden"
                class="btn btn-error btn-outline justify-start"
              >
                <.icon name="hero-x-circle" class="w-5 h-5 mr-2" /> Set Hidden
              </button>
            </div>
            <div class="modal-action">
              <button phx-click="close_bulk_modal" class="btn">Cancel</button>
            </div>
          </div>
          <div class="modal-backdrop" phx-click="close_bulk_modal"></div>
        </div>
      <% end %>

      <%!-- Bulk Parent Change Modal --%>
      <%= if @show_bulk_modal == "parent" do %>
        <div class="modal modal-open">
          <div class="modal-box">
            <h3 class="font-bold text-lg mb-4">Change Parent</h3>
            <p class="text-base-content/70 mb-4">
              Set parent for {MapSet.size(@selected_uuids)} selected categories
            </p>
            <div class="flex flex-col gap-2 max-h-96 overflow-y-auto">
              <button
                phx-click="bulk_change_parent"
                phx-value-parent_uuid=""
                class="btn btn-ghost justify-start"
              >
                <.icon name="hero-x-mark" class="w-5 h-5 mr-2" /> Make Root (No Parent)
              </button>
              <%= for category <- @all_categories,
                      !MapSet.member?(@selected_uuids, category.uuid) do %>
                <button
                  phx-click="bulk_change_parent"
                  phx-value-parent_uuid={category.uuid}
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
              <button phx-click="close_bulk_modal" class="btn">Cancel</button>
            </div>
          </div>
          <div class="modal-backdrop" phx-click="close_bulk_modal"></div>
        </div>
      <% end %>

      <%!-- Bulk Delete Confirmation Modal --%>
      <%= if @show_bulk_modal == "delete" do %>
        <div class="modal modal-open">
          <div class="modal-box">
            <h3 class="font-bold text-lg text-error mb-4">Delete Categories</h3>
            <p class="text-base-content/70 mb-4">
              Are you sure you want to delete {MapSet.size(@selected_uuids)} categories?
              This action cannot be undone.
            </p>
            <div class="modal-action">
              <button phx-click="close_bulk_modal" class="btn">Cancel</button>
              <button phx-click="bulk_delete" class="btn btn-error">
                <.icon name="hero-trash" class="w-4 h-4 mr-2" /> Delete Categories
              </button>
            </div>
          </div>
          <div class="modal-backdrop" phx-click="close_bulk_modal"></div>
        </div>
      <% end %>
    """
  end
end
