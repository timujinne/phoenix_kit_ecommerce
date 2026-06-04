defmodule PhoenixKitEcommerce.Web.ShippingMethodForm do
  @moduledoc """
  Shipping method create/edit form LiveView.
  """

  use PhoenixKitEcommerce.Web, :live_view

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Activity
  alias PhoenixKitEcommerce.ShippingMethod

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = apply_action(socket, socket.assigns.live_action, params)
    {:noreply, socket}
  end

  defp apply_action(socket, :new, _params) do
    default_currency = Billing.get_default_currency()
    default_currency_code = if default_currency, do: default_currency.code, else: "USD"

    method = %ShippingMethod{currency: default_currency_code}
    changeset = Shop.change_shipping_method(method)
    currencies = load_currencies()

    socket
    |> assign(:page_title, "New Shipping Method")
    |> assign(:method, method)
    |> assign(:currencies, currencies)
    |> assign(:default_currency, default_currency)
    |> assign_form(changeset)
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    method = Shop.get_shipping_method!(id)
    changeset = Shop.change_shipping_method(method)
    currencies = load_currencies()
    default_currency = Billing.get_default_currency()

    socket
    |> assign(:page_title, "Edit #{method.name}")
    |> assign(:method, method)
    |> assign(:currencies, currencies)
    |> assign(:default_currency, default_currency)
    |> assign_form(changeset)
  end

  @impl true
  def handle_event("validate", %{"shipping_method" => params}, socket) do
    changeset =
      socket.assigns.method
      |> Shop.change_shipping_method(params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  @impl true
  def handle_event("save", %{"shipping_method" => params}, socket) do
    save_method(socket, socket.assigns.live_action, params)
  end

  defp save_method(socket, :new, params) do
    case Shop.create_shipping_method(params) do
      {:ok, method} ->
        Activity.log("shop.shipping_method_created",
          actor_uuid: Activity.actor_uuid(socket),
          actor_role: Activity.actor_role(socket),
          resource_type: "shipping_method",
          resource_uuid: method.uuid,
          metadata: %{"slug" => method.slug, "active" => method.active}
        )

        {:noreply,
         socket
         |> put_flash(:info, "Shipping method created")
         |> push_navigate(to: Routes.path("/admin/shop/shipping"))}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp save_method(socket, :edit, params) do
    case Shop.update_shipping_method(socket.assigns.method, params) do
      {:ok, method} ->
        Activity.log("shop.shipping_method_updated",
          actor_uuid: Activity.actor_uuid(socket),
          actor_role: Activity.actor_role(socket),
          resource_type: "shipping_method",
          resource_uuid: method.uuid,
          metadata: %{"slug" => method.slug, "active" => method.active}
        )

        {:noreply,
         socket
         |> put_flash(:info, "Shipping method updated")
         |> push_navigate(to: Routes.path("/admin/shop/shipping"))}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
      <div class="container flex-col mx-auto px-4 py-6 max-w-5xl">
        <.admin_page_header
          back={Routes.path("/admin/shop/shipping")}
          title={@page_title}
          subtitle="Configure shipping method details"
        />

        <.form for={@form} phx-change="validate" phx-submit="save" class="space-y-6">
          <%!-- Basic Info --%>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h2 class="card-title text-xl mb-6">Basic Information</h2>

              <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
                <div class="form-control w-full">
                  <.input
                    field={@form[:name]}
                    type="text"
                    label="Name *"
                    placeholder="Standard Shipping"
                    required
                  />
                </div>

                <div class="form-control w-full">
                  <.input
                    field={@form[:slug]}
                    type="text"
                    label="Slug"
                    placeholder="auto-generated if empty"
                  />
                </div>

                <div class="form-control w-full md:col-span-2">
                  <.textarea
                    field={@form[:description]}
                    label="Description"
                    placeholder="Delivery in 3-5 business days"
                    rows="2"
                  />
                </div>
              </div>
            </div>
          </div>

          <%!-- Pricing --%>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h2 class="card-title text-xl mb-6">Pricing</h2>

              <div class="grid grid-cols-1 md:grid-cols-3 gap-6">
                <div class="form-control w-full">
                  <.input
                    field={@form[:price]}
                    type="number"
                    label="Price *"
                    step="0.01"
                    min="0"
                    required
                  />
                </div>

                <div class="form-control w-full">
                  <label class="label">
                    <span class="label-text font-medium">Currency</span>
                  </label>
                  <%= if @currencies == [] do %>
                    <div class="input input-bordered flex items-center bg-base-200">
                      {if @default_currency,
                        do: "#{@default_currency.code} - #{@default_currency.name}",
                        else: "USD"}
                    </div>
                    <input
                      type="hidden"
                      name="shipping_method[currency]"
                      value={if @default_currency, do: @default_currency.code, else: "USD"}
                    />
                  <% else %>
                    <.select
                      field={@form[:currency]}
                      options={Enum.map(@currencies, &{"#{&1.code} - #{&1.name}", &1.code})}
                    />
                  <% end %>
                </div>

                <div class="form-control w-full">
                  <.input
                    field={@form[:free_above_amount]}
                    type="number"
                    label="Free above"
                    step="0.01"
                    min="0"
                    placeholder="No threshold"
                  />
                </div>
              </div>
            </div>
          </div>

          <%!-- Constraints --%>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h2 class="card-title text-xl mb-6">Constraints</h2>

              <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
                <div class="form-control w-full">
                  <.input
                    field={@form[:min_weight_grams]}
                    type="number"
                    label="Min weight (g)"
                    min="0"
                    placeholder="0"
                  />
                </div>

                <div class="form-control w-full">
                  <.input
                    field={@form[:max_weight_grams]}
                    type="number"
                    label="Max weight (g)"
                    min="0"
                    placeholder="No limit"
                  />
                </div>

                <div class="form-control w-full">
                  <.input
                    field={@form[:min_order_amount]}
                    type="number"
                    label="Min order"
                    step="0.01"
                    min="0"
                    placeholder="No min"
                  />
                </div>

                <div class="form-control w-full">
                  <.input
                    field={@form[:max_order_amount]}
                    type="number"
                    label="Max order"
                    step="0.01"
                    min="0"
                    placeholder="No max"
                  />
                </div>
              </div>
            </div>
          </div>

          <%!-- Delivery & Status --%>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h2 class="card-title text-xl mb-6">Delivery & Status</h2>

              <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
                <div class="form-control w-full">
                  <.input
                    field={@form[:estimated_days_min]}
                    type="number"
                    label="Est. days (min)"
                    min="0"
                    placeholder="1"
                  />
                </div>

                <div class="form-control w-full">
                  <.input
                    field={@form[:estimated_days_max]}
                    type="number"
                    label="Est. days (max)"
                    min="0"
                    placeholder="5"
                  />
                </div>

                <div class="form-control w-full">
                  <.input
                    field={@form[:position]}
                    type="number"
                    label="Position"
                    min="0"
                  />
                </div>

                <div class="form-control w-full">
                  <label class="label">
                    <span class="label-text font-medium">Status</span>
                  </label>
                  <label class="label cursor-pointer justify-start gap-3 h-12">
                    <input type="hidden" name="shipping_method[active]" value="false" />
                    <input
                      type="checkbox"
                      name="shipping_method[active]"
                      value="true"
                      checked={Ecto.Changeset.get_field(@changeset, :active)}
                      class="toggle toggle-success"
                    />
                    <span class="label-text">Active</span>
                  </label>
                </div>
              </div>

              <div class="divider my-2"></div>

              <div class="form-control">
                <label class="label cursor-pointer justify-start gap-3">
                  <input type="hidden" name="shipping_method[tracking_supported]" value="false" />
                  <input
                    type="checkbox"
                    name="shipping_method[tracking_supported]"
                    value="true"
                    checked={Ecto.Changeset.get_field(@changeset, :tracking_supported)}
                    class="checkbox checkbox-primary"
                  />
                  <span class="label-text font-medium">Tracking supported</span>
                </label>
              </div>
            </div>
          </div>

          <%!-- Submit --%>
          <div class="flex justify-end gap-4">
            <.link navigate={Routes.path("/admin/shop/shipping")} class="btn btn-outline">
              Cancel
            </.link>
            <button type="submit" class="btn btn-primary">
              <.icon name="hero-check" class="w-4 h-4 mr-2" />
              {if @live_action == :new, do: "Create Method", else: "Update Method"}
            </button>
          </div>
        </.form>
      </div>
    """
  end

  defp load_currencies do
    Billing.list_currencies(enabled: true)
  rescue
    _ -> []
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    socket
    |> assign(:changeset, changeset)
    |> assign(:form, to_form(changeset))
  end
end
