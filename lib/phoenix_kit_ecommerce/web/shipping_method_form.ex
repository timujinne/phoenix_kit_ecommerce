defmodule PhoenixKitEcommerce.Web.ShippingMethodForm do
  @moduledoc """
  Shipping method create/edit form LiveView.
  """

  use PhoenixKitEcommerce.Web, :live_view

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Activity
  alias PhoenixKitEcommerce.Shipping
  alias PhoenixKitEcommerce.ShippingMethod
  alias PhoenixKitEcommerce.Web.Authz
  alias PhoenixKitEcommerce.Web.ShippingProviderState, as: ProviderState

  import PhoenixKitEcommerce.Web.Components.ShippingProviderCard,
    only: [shipping_provider_card: 1]

  # How long the form waits for a carrier before it shows what it has.
  @lookup_timeout 3_000

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
    default_currency = Shop.get_base_currency()
    # §7.3/N3: no literal fallback — an unconfigured currency table leaves
    # `default_currency_code` nil and the form submits no currency, so the
    # method is stored without one instead of being seeded with "USD".
    # `ShippingMethod.changeset/2` does NOT reject that: `validate_length`
    # skips nil, and the hidden input's "" is an Ecto empty value. A
    # shipping method with no currency is the honest record of a shop that
    # has configured no currency; nothing downstream reads it as a number.
    default_currency_code = if default_currency, do: default_currency.code

    method = %ShippingMethod{currency: default_currency_code}
    changeset = Shop.change_shipping_method(method)
    currencies = load_currencies()

    socket
    |> assign_shop_trail(gettext("New shipping method"), [shipping_crumb()])
    |> assign(:heading, gettext("New shipping method"))
    |> assign(:method, method)
    |> assign(:currencies, currencies)
    |> assign(:default_currency, default_currency)
    |> assign_form(changeset)
    |> assign_provider_state(method)
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    method = Shop.get_shipping_method!(id)
    changeset = Shop.change_shipping_method(method)
    currencies = load_currencies()
    default_currency = Shop.get_base_currency()

    socket
    |> assign_shop_trail(gettext("Edit"), [shipping_crumb(), crumb(method.name)])
    |> assign(:heading, gettext("Edit %{name}", name: method.name))
    |> assign(:method, method)
    |> assign(:currencies, currencies)
    |> assign(:default_currency, default_currency)
    |> assign_form(changeset)
    |> assign_provider_state(method)
  end

  @impl true
  def handle_event("validate", %{"shipping_method" => params} = posted, socket) do
    {socket, change} = sync_provider(socket, params, Map.get(posted, "shipping_locality_query"))
    params = provider_params(socket, params)

    # Right after another provider is chosen its (empty) settings are not
    # "wrong" yet: no errors until the admin has had a chance to fill them in.
    action = if change == :provider_changed, do: nil, else: :validate

    changeset =
      socket.assigns.method
      |> Shop.change_shipping_method(params)
      |> Map.put(:action, action)

    {:noreply,
     socket
     |> assign(:form_params, params)
     |> assign_form(changeset)}
  end

  def handle_event("pick_locality", %{"key" => key, "index" => index}, socket) do
    with true <- locality_key?(socket, key),
         [_ | _] = results <- Map.get(socket.assigns.locality_results, key),
         {position, ""} <- Integer.parse(index),
         %{id: id, name: name} when is_binary(id) and is_binary(name) <-
           Enum.at(results, position) do
      {:noreply, put_locality(socket, key, %{"id" => id, "name" => name})}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("clear_locality", %{"key" => key}, socket) do
    if locality_key?(socket, key),
      do: {:noreply, put_locality(socket, key, nil)},
      else: {:noreply, socket}
  end

  @impl true
  def handle_event("save", params, socket) do
    Authz.authorize(socket, :manage_settings, fn -> gated_event("save", params, socket) end)
  end

  @impl true
  def handle_async({:locality_search, key}, result, socket) do
    {:noreply, finish_locality_search(socket, key, result)}
  end

  defp save_method(socket, :new, params) do
    case Shop.create_shipping_method(params) do
      {:ok, method} ->
        Activity.log("shop.shipping_method_created",
          actor_uuid: Activity.actor_uuid(socket),
          actor_role: Activity.actor_role(socket),
          resource_type: "shipping_method",
          resource_uuid: method.uuid,
          metadata: %{
            "slug" => method.slug,
            "active" => method.active,
            "pay_on_delivery" => ShippingMethod.pay_on_delivery?(method)
          }
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Shipping method created"))
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
          metadata: %{
            "slug" => method.slug,
            "active" => method.active,
            "pay_on_delivery" => ShippingMethod.pay_on_delivery?(method)
          }
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Shipping method updated"))
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
          title={@heading}
          subtitle={gettext("Configure shipping method details")}
        />

        <.form
          for={@form}
          id="shipping-method-form"
          phx-change="validate"
          phx-submit="save"
          class="space-y-6"
        >
          <%!-- Basic Info --%>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h2 class="card-title text-xl mb-6">{gettext("Basic Information")}</h2>

              <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
                <div class="fieldset w-full">
                  <.input
                    field={@form[:name]}
                    type="text"
                    label={gettext("Name") <> " *"}
                    placeholder={gettext("Standard Shipping")}
                    required
                  />
                </div>

                <div class="fieldset w-full">
                  <.input
                    field={@form[:slug]}
                    type="text"
                    label={gettext("Slug")}
                    placeholder={gettext("auto-generated if empty")}
                  />
                </div>

                <div class="fieldset w-full md:col-span-2">
                  <.textarea
                    field={@form[:description]}
                    label={gettext("Description")}
                    placeholder={gettext("Delivery in 3-5 business days")}
                    rows="2"
                  />
                </div>
              </div>
            </div>
          </div>

          <%!-- Pricing --%>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h2 class="card-title text-xl mb-6">{gettext("Pricing")}</h2>

              <div class="grid grid-cols-1 md:grid-cols-3 gap-6">
                <div class="fieldset w-full">
                  <.input
                    field={@form[:price]}
                    type="number"
                    label={gettext("Price")}
                    step="0.01"
                    min="0"
                    required={!@pay_on_delivery}
                    disabled={@pay_on_delivery}
                    {if @pay_on_delivery, do: %{value: "0"}, else: %{}}
                  />
                </div>

                <div class="fieldset w-full">
                  <label class="label">
                    <span class="fieldset-legend font-medium">{gettext("Currency")}</span>
                  </label>
                  <%= if @currencies == [] do %>
                    <div class="input flex items-center bg-base-200">
                      {if @default_currency,
                        do: "#{@default_currency.code} - #{@default_currency.name}",
                        else: gettext("No default currency configured")}
                    </div>
                    <input
                      type="hidden"
                      name="shipping_method[currency]"
                      value={if @default_currency, do: @default_currency.code}
                    />
                  <% else %>
                    <.select
                      field={@form[:currency]}
                      options={Enum.map(@currencies, &{"#{&1.code} - #{&1.name}", &1.code})}
                    />
                  <% end %>
                </div>

                <div class="fieldset w-full">
                  <.input
                    field={@form[:free_above_amount]}
                    type="number"
                    label={gettext("Free above")}
                    step="0.01"
                    min="0"
                    placeholder={gettext("No threshold")}
                    disabled={@pay_on_delivery}
                    {if @pay_on_delivery, do: %{value: nil}, else: %{}}
                  />
                </div>
              </div>

              <div class="divider my-2"></div>

              <div class="fieldset">
                <.checkbox
                  name="shipping_method[pay_on_delivery]"
                  checked={@pay_on_delivery}
                >
                  <span class="font-medium">{gettext("Paid on delivery at carrier rates")}</span>
                </.checkbox>
                <p class="text-sm text-base-content/60 mt-1">
                  {gettext(
                    "The customer pays the carrier at their rates on delivery. The shop charges nothing for shipping: the price is saved as 0 and the free-shipping threshold is cleared."
                  )}
                </p>
              </div>
            </div>
          </div>

          <%!-- Shipping cost calculation --%>
          <.shipping_provider_card
            state={@sp}
            provider_options={provider_select_options(@provider_options, @sp.provider)}
            service_options={service_select_options(@services, @sp.service)}
            services_error={@services_error}
            fields={ProviderState.fields(@sp.provider)}
            integration={@integration}
            locality_results={@locality_results}
            locality_loading={@locality_loading}
            errors={provider_errors(@changeset)}
          />

          <%!-- Constraints --%>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h2 class="card-title text-xl mb-6">{gettext("Constraints")}</h2>

              <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
                <div class="fieldset w-full">
                  <.input
                    field={@form[:min_weight_grams]}
                    type="number"
                    label={gettext("Min weight (g)")}
                    min="0"
                    placeholder="0"
                  />
                </div>

                <div class="fieldset w-full">
                  <.input
                    field={@form[:max_weight_grams]}
                    type="number"
                    label={gettext("Max weight (g)")}
                    min="0"
                    placeholder={gettext("No limit")}
                  />
                </div>

                <div class="fieldset w-full">
                  <.input
                    field={@form[:min_order_amount]}
                    type="number"
                    label={gettext("Min order")}
                    step="0.01"
                    min="0"
                    placeholder={gettext("No min")}
                  />
                </div>

                <div class="fieldset w-full">
                  <.input
                    field={@form[:max_order_amount]}
                    type="number"
                    label={gettext("Max order")}
                    step="0.01"
                    min="0"
                    placeholder={gettext("No max")}
                  />
                </div>
              </div>
            </div>
          </div>

          <%!-- Delivery & Status --%>
          <div class="card bg-base-100 shadow-xl">
            <div class="card-body">
              <h2 class="card-title text-xl mb-6">{gettext("Delivery & Status")}</h2>

              <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
                <div class="fieldset w-full">
                  <.input
                    field={@form[:estimated_days_min]}
                    type="number"
                    label={gettext("Est. days (min)")}
                    min="0"
                    placeholder="1"
                  />
                </div>

                <div class="fieldset w-full">
                  <.input
                    field={@form[:estimated_days_max]}
                    type="number"
                    label={gettext("Est. days (max)")}
                    min="0"
                    placeholder="5"
                  />
                </div>

                <div class="fieldset w-full">
                  <.input
                    field={@form[:position]}
                    type="number"
                    label={gettext("Position")}
                    min="0"
                  />
                </div>

                <div class="fieldset w-full">
                  <label class="label">
                    <span class="fieldset-legend font-medium">{gettext("Status")}</span>
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
                    <span class="fieldset-legend">{gettext("Active")}</span>
                  </label>
                </div>
              </div>

              <div class="divider my-2"></div>

              <div class="fieldset">
                <.checkbox
                  name="shipping_method[tracking_supported]"
                  checked={Ecto.Changeset.get_field(@changeset, :tracking_supported)}
                >
                  <span class="font-medium">{gettext("Tracking supported")}</span>
                </.checkbox>
              </div>
            </div>
          </div>

          <%!-- Submit --%>
          <div class="flex justify-end gap-4">
            <.link navigate={Routes.path("/admin/shop/shipping")} class="btn btn-outline">
              {gettext("Cancel")}
            </.link>
            <button type="submit" class="btn btn-primary">
              <.icon name="hero-check" class="w-4 h-4 mr-2" />
              {if @live_action == :new, do: gettext("Create Method"), else: gettext("Update Method")}
            </button>
          </div>
        </.form>
      </div>
    """
  end

  defp provider_errors(%Ecto.Changeset{action: nil}), do: []

  defp provider_errors(%Ecto.Changeset{errors: errors}),
    do: for({:shipping_provider, error} <- errors, do: error)

  defp load_currencies do
    Billing.list_currencies(enabled: true)
  rescue
    _ -> []
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    # Drives the checkbox and locks Price / Free above while it is on: the
    # changeset forces both (0 and none) on save, so an editable field would
    # show a value that is never stored. Disabled inputs are not submitted,
    # which the changeset is fine with.
    pay_on_delivery = ShippingMethod.pay_on_delivery?(Ecto.Changeset.apply_changes(changeset))

    socket
    |> assign(:changeset, changeset)
    |> assign(:pay_on_delivery, pay_on_delivery)
    |> assign(:form, to_form(changeset))
  end

  defp gated_event("save", %{"shipping_method" => params}, socket) do
    {socket, _change} = sync_provider(socket, params, nil)
    save_method(socket, socket.assigns.live_action, provider_params(socket, params))
  end

  # -- shipping cost calculation card --------------------------------------

  defp assign_provider_state(socket, method) do
    socket
    |> assign(:sp, ProviderState.from_method(method))
    |> assign(:form_params, %{})
    |> assign(:provider_options, provider_options())
    |> assign(:services_key, nil)
    |> assign(:services, [])
    |> assign(:services_error, false)
    |> assign(:integration, nil)
    |> assign(:locality_results, %{})
    |> assign(:locality_loading, %{})
    |> refresh_services()
  end

  defp provider_options do
    Enum.map(Shipping.providers(), &{&1.label(), &1.key()})
  end

  # A stored provider the host no longer registers stays selectable, so the
  # form does not silently switch the method to another one.
  defp provider_select_options(options, provider) do
    if Enum.any?(options, &(elem(&1, 1) == provider)),
      do: options,
      else: options ++ [{gettext("%{provider} (unavailable)", provider: provider), provider}]
  end

  defp service_select_options(services, service) do
    options = Enum.map(services, &{&1.label || &1.key, &1.key})

    if service in ["", nil] or Enum.any?(options, &(elem(&1, 1) == service)),
      do: options,
      else: options ++ [{gettext("%{service} (unavailable)", service: service), service}]
  end

  # Folds the posted provider card into the state, reloads what depends on it
  # and starts the locality searches the post asks for. Returns the socket and
  # whether another provider was chosen.
  defp sync_provider(socket, params, queries) do
    {state, change} = ProviderState.apply_params(socket.assigns.sp, params["shipping_provider"])

    # What was typed into the previous provider's search boxes is not a query
    # of the new one.
    queries = if change == :provider_changed, do: nil, else: queries

    socket =
      socket
      |> assign(:sp, state)
      |> refresh_services()
      |> search_localities(queries)

    {socket, change}
  end

  defp provider_params(socket, params) do
    Map.put(params, "shipping_provider", ProviderState.to_param(socket.assigns.sp))
  end

  defp provider_context(state) do
    Shipping.context(nil,
      provider: state.provider,
      settings: state.settings,
      service: if(state.service == "", do: nil),
      timeout: @lookup_timeout
    )
  end

  # The services (and whether the provider's connection is there) depend on
  # the provider and its settings only, so keystrokes in other inputs cost
  # nothing.
  defp refresh_services(socket) do
    %{provider: provider, settings: settings} = state = socket.assigns.sp
    key = {provider, settings}

    if socket.assigns.services_key == key do
      socket
    else
      ctx = provider_context(state)
      {services, error?} = load_services(provider, ctx)

      socket
      |> assign(:services_key, key)
      |> assign(:services, services)
      |> assign(:services_error, error?)
      |> assign(:integration, integration_status(ctx))
      |> assign(:sp, pick_service(state, services))
    end
  end

  defp load_services(provider, ctx) do
    with true <- provider != ProviderState.fixed(),
         {:ok, services} <- Shipping.services(ctx) do
      {services, false}
    else
      false -> {[], false}
      {:error, _reason} -> {[], true}
    end
  end

  # No service chosen yet: the first one the provider offers.
  defp pick_service(%{provider: provider, service: ""} = state, [%{key: key} | _])
       when provider != "fixed" do
    %{state | service: key}
  end

  defp pick_service(state, _services), do: state

  defp integration_status(%{provider: provider} = ctx)
       when is_atom(provider) and provider != nil do
    with true <- Code.ensure_loaded?(provider),
         true <- function_exported?(provider, :integration, 0),
         %{} = integration <- provider.integration() do
      %{
        name: Map.get(integration, :name) || Map.get(integration, "name") || provider.label(),
        connected?: not is_nil(ctx.credentials)
      }
    else
      _ -> nil
    end
  rescue
    _error -> nil
  end

  defp integration_status(_ctx), do: nil

  defp locality_key?(socket, key) do
    socket.assigns.sp.provider
    |> ProviderState.fields()
    |> Enum.any?(&(&1.type == :locality and &1.key == key))
  end

  defp search_localities(socket, %{} = queries) do
    state = socket.assigns.sp

    Enum.reduce(queries, socket, fn {key, query}, acc ->
      query = if is_binary(query), do: query, else: ""

      if Map.get(state.queries, key, "") != query and locality_key?(acc, key),
        do: start_locality_search(acc, key, query),
        else: acc
    end)
  end

  defp search_localities(socket, _queries), do: socket

  defp start_locality_search(socket, key, query) do
    socket = update(socket, :sp, &%{&1 | queries: Map.put(&1.queries, key, query)})

    if String.length(String.trim(query)) < 2 do
      socket
      |> assign(:locality_results, Map.delete(socket.assigns.locality_results, key))
      |> assign(:locality_loading, Map.delete(socket.assigns.locality_loading, key))
    else
      ctx = provider_context(socket.assigns.sp)

      socket
      |> assign(:locality_loading, Map.put(socket.assigns.locality_loading, key, true))
      |> start_async({:locality_search, key}, fn ->
        {query, Shipping.search_localities(ctx, query)}
      end)
    end
  end

  # An answer to a query the admin has already typed past is dropped.
  defp finish_locality_search(socket, key, {:ok, {query, result}}) do
    if Map.get(socket.assigns.sp.queries, key) == query do
      results =
        case result do
          {:ok, localities} -> localities
          {:error, _reason} -> :error
        end

      socket
      |> assign(:locality_results, Map.put(socket.assigns.locality_results, key, results))
      |> assign(:locality_loading, Map.delete(socket.assigns.locality_loading, key))
    else
      socket
    end
  end

  defp finish_locality_search(socket, key, {:exit, _reason}) do
    socket
    |> assign(:locality_results, Map.put(socket.assigns.locality_results, key, :error))
    |> assign(:locality_loading, Map.delete(socket.assigns.locality_loading, key))
  end

  defp put_locality(socket, key, value) do
    settings =
      if value,
        do: Map.put(socket.assigns.sp.settings, key, value),
        else: Map.delete(socket.assigns.sp.settings, key)

    socket =
      socket
      |> update(:sp, &%{&1 | settings: settings, queries: Map.delete(&1.queries, key)})
      |> assign(:locality_results, Map.delete(socket.assigns.locality_results, key))
      |> assign(:locality_loading, Map.delete(socket.assigns.locality_loading, key))
      |> cancel_async({:locality_search, key})
      |> refresh_services()

    changeset =
      socket.assigns.method
      |> Shop.change_shipping_method(provider_params(socket, socket.assigns.form_params))
      |> Map.put(:action, :validate)

    assign_form(socket, changeset)
  end
end
