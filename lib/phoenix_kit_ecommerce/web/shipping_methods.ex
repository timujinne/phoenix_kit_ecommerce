defmodule PhoenixKitEcommerce.Web.ShippingMethods do
  @moduledoc """
  Shipping methods list LiveView for E-Commerce module admin.
  """

  use PhoenixKitEcommerce.Web, :live_view

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling.Currency
  alias PhoenixKitEcommerce, as: Shop

  @impl true
  def mount(_params, _session, socket) do
    methods = Shop.list_shipping_methods()
    currency = Shop.get_default_currency()

    socket =
      socket
      |> assign(:page_title, "Shipping Methods")
      |> assign(:methods, methods)
      |> assign(:currency, currency)

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_active", %{"uuid" => uuid}, socket) do
    method = Shop.get_shipping_method!(uuid)
    {:ok, updated} = Shop.update_shipping_method(method, %{active: !method.active})

    methods =
      Enum.map(socket.assigns.methods, fn m ->
        if m.uuid == updated.uuid, do: updated, else: m
      end)

    {:noreply, assign(socket, :methods, methods)}
  end

  @impl true
  def handle_event("delete", %{"uuid" => uuid}, socket) do
    method = Shop.get_shipping_method!(uuid)

    case Shop.delete_shipping_method(method) do
      {:ok, _} ->
        methods = Enum.reject(socket.assigns.methods, &(&1.uuid == method.uuid))

        {:noreply,
         socket
         |> assign(:methods, methods)
         |> put_flash(:info, "Shipping method deleted")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete shipping method")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
      <div class="p-6 max-w-6xl mx-auto">
        <.admin_page_header back={Routes.path("/admin/shop")}>
          <h1 class="text-xl sm:text-2xl lg:text-3xl font-bold text-base-content">
            Shipping Methods
          </h1>
          <p class="text-sm sm:text-base text-base-content/60 mt-0.5">
            {length(@methods)} methods configured
          </p>
          <:actions>
            <.link navigate={Routes.path("/admin/shop/shipping/new")} class="btn btn-primary btn-sm">
              <.icon name="hero-plus" class="w-4 h-4 mr-2" /> Add Method
            </.link>
          </:actions>
        </.admin_page_header>

        <.table_default
          id="shipping-methods-table"
          variant="zebra"
          class="w-full"
          toggleable={true}
          items={@methods}
          card_fields={fn method ->
            [
              %{label: "Price", value: format_price(method.price, @currency)},
              %{
                label: "Delivery",
                value:
                  PhoenixKitEcommerce.ShippingMethod.delivery_estimate(method) || "-"
              }
            ]
          end}
        >
          <:card_header :let={method}>
            <div class="font-bold">{method.name}</div>
            <%= if method.description do %>
              <div class="text-sm text-base-content/60">{method.description}</div>
            <% end %>
          </:card_header>

          <:card_actions :let={method}>
            <.table_row_menu id={"card-menu-#{method.uuid}"}>
              <.table_row_menu_link
                navigate={Routes.path("/admin/shop/shipping/#{method.uuid}/edit")}
                icon="hero-pencil"
                label="Edit"
              />
              <.table_row_menu_divider />
              <.table_row_menu_button
                phx-click="delete"
                phx-value-uuid={method.uuid}
                data-confirm="Delete this shipping method?"
                icon="hero-trash"
                label="Delete"
                variant="error"
              />
            </.table_row_menu>
          </:card_actions>

          <.table_default_header>
            <.table_default_row>
              <.table_default_header_cell>Method</.table_default_header_cell>
              <.table_default_header_cell>Price</.table_default_header_cell>
              <.table_default_header_cell>Constraints</.table_default_header_cell>
              <.table_default_header_cell>Delivery</.table_default_header_cell>
              <.table_default_header_cell>Status</.table_default_header_cell>
              <.table_default_header_cell class="text-right">Actions</.table_default_header_cell>
            </.table_default_row>
          </.table_default_header>

          <.table_default_body>
            <%= if @methods == [] do %>
              <.table_default_row>
                <.table_default_cell colspan={6} class="text-center py-12 text-base-content/50">
                  <.icon name="hero-truck" class="w-12 h-12 mx-auto mb-3 opacity-50" />
                  <p class="text-lg">No shipping methods</p>
                  <p class="text-sm">Create your first shipping method to get started</p>
                </.table_default_cell>
              </.table_default_row>
            <% else %>
              <%= for method <- @methods do %>
                <.table_default_row class="hover">
                  <.table_default_cell>
                    <div class="font-bold">{method.name}</div>
                    <%= if method.description do %>
                      <div class="text-sm text-base-content/60 max-w-xs truncate">
                        {method.description}
                      </div>
                    <% end %>
                  </.table_default_cell>
                  <.table_default_cell>
                    <div class="font-semibold">{format_price(method.price, @currency)}</div>
                    <%= if method.free_above_amount do %>
                      <div class="text-xs text-success">
                        Free above {format_price(method.free_above_amount, @currency)}
                      </div>
                    <% end %>
                  </.table_default_cell>
                  <.table_default_cell>
                    <div class="flex flex-wrap gap-1">
                      <%= if method.max_weight_grams do %>
                        <span class="badge badge-outline badge-sm">
                          Max {format_weight(method.max_weight_grams)}
                        </span>
                      <% end %>
                      <%= if method.countries != [] do %>
                        <span class="badge badge-outline badge-sm">
                          {length(method.countries)} countries
                        </span>
                      <% end %>
                      <%= if method.countries == [] && is_nil(method.max_weight_grams) do %>
                        <span class="text-base-content/50 text-sm">No limits</span>
                      <% end %>
                    </div>
                  </.table_default_cell>
                  <.table_default_cell>
                    <%= if estimate = PhoenixKitEcommerce.ShippingMethod.delivery_estimate(method) do %>
                      <span class="text-sm">{estimate}</span>
                    <% else %>
                      <span class="text-base-content/50 text-sm">-</span>
                    <% end %>
                  </.table_default_cell>
                  <.table_default_cell>
                    <input
                      type="checkbox"
                      class="toggle toggle-success toggle-sm"
                      checked={method.active}
                      phx-click="toggle_active"
                      phx-value-uuid={method.uuid}
                    />
                  </.table_default_cell>
                  <.table_default_cell>
                    <div class="flex justify-end">
                      <.table_row_menu id={"menu-#{method.uuid}"}>
                        <.table_row_menu_link
                          navigate={Routes.path("/admin/shop/shipping/#{method.uuid}/edit")}
                          icon="hero-pencil"
                          label="Edit"
                        />
                        <.table_row_menu_divider />
                        <.table_row_menu_button
                          phx-click="delete"
                          phx-value-uuid={method.uuid}
                          data-confirm="Delete this shipping method?"
                          icon="hero-trash"
                          label="Delete"
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
      </div>
    """
  end

  defp format_price(nil, _currency), do: "—"

  defp format_price(amount, nil) do
    "$#{Decimal.round(amount || Decimal.new("0"), 2)}"
  end

  defp format_price(amount, currency) do
    Currency.format_amount(amount, currency)
  end

  defp format_weight(grams) when grams >= 1000, do: "#{Float.round(grams / 1000, 1)} kg"
  defp format_weight(grams), do: "#{grams} g"
end
