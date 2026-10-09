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
  alias PhoenixKitEcommerce.Shipping.MethodParams
  alias PhoenixKitEcommerce.ShippingMethod
  alias PhoenixKitEcommerce.Web.Authz
  alias PhoenixKitEcommerce.Web.ShippingProviderState, as: ProviderState

  import PhoenixKitEcommerce.Web.Components.ShippingProviderCard,
    only: [shipping_provider_card: 1, locality_search_forms: 1]

  # How long a lookup waits for a carrier. The same as the service check on
  # save (`Shipping.MethodParams`), so one slow carrier costs one wait.
  @lookup_timeout 2_000

  # What LiveView sends as the `_target` when the admin picks a provider.
  @provider_target ["shipping_method", "shipping_provider", "provider"]

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
    {socket, change} = sync_provider(socket, params, posted["_target"] == @provider_target)
    params = provider_params(socket, params)

    # Right after another provider is chosen its (empty) settings are not
    # "wrong" yet: no errors until the admin has had a chance to fill them in.
    action = if change == :provider_chosen, do: nil, else: :validate

    # `check_service: false`: validating while typing never waits for a carrier.
    changeset =
      socket.assigns.method
      |> ShippingMethod.changeset(params, check_service: false)
      |> Map.put(:action, action)

    {:noreply,
     socket
     |> assign(:form_params, params)
     |> assign_form_errors(changeset)}
  end

  def handle_event("search_locality", params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      gated_event("search_locality", params, socket)
    end)
  end

  def handle_event("pick_locality", params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      gated_event("pick_locality", params, socket)
    end)
  end

  def handle_event("clear_locality", params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      gated_event("clear_locality", params, socket)
    end)
  end

  @impl true
  def handle_event("save", params, socket) do
    Authz.authorize(socket, :manage_settings, fn -> gated_event("save", params, socket) end)
  end

  @impl true
  # A task that was cancelled (another provider was chosen, a locality picked)
  # reports its own death: not a failure.
  def handle_async(_name, {:exit, {:shutdown, :cancel}}, socket), do: {:noreply, socket}

  def handle_async(:services, result, socket) do
    {:noreply, finish_services(socket, result)}
  end

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
            "provider" => ShippingMethod.shipping_config(method).provider,
            "pay_on_delivery" => ShippingMethod.pay_on_delivery?(method)
          }
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Shipping method created"))
         |> push_navigate(to: Routes.path("/admin/shop/shipping"))}

      {:error, changeset} ->
        {:noreply, assign_form_errors(socket, changeset)}
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
            "provider" => ShippingMethod.shipping_config(method).provider,
            "pay_on_delivery" => ShippingMethod.pay_on_delivery?(method)
          }
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Shipping method updated"))
         |> push_navigate(to: Routes.path("/admin/shop/shipping"))}

      {:error, changeset} ->
        {:noreply, assign_form_errors(socket, changeset)}
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
            provider_known?={@provider_known?}
            service_options={service_select_options(@services, @sp.service, @services_status)}
            services_status={@services_status}
            fields={@provider_fields}
            integration={@integration}
            locality_results={@locality_results}
            locality_loading={@locality_loading}
            field_errors={@provider_errors.fields}
            errors={@provider_errors.general}
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

        <%!-- The locality search inputs belong to these forms (`form` attribute);
             they cannot live inside the main one. --%>
        <.locality_search_forms fields={@provider_fields} />
      </div>
    """
  end

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
    {socket, _change} = sync_provider(socket, params, false)
    save_method(socket, socket.assigns.live_action, provider_params(socket, params))
  end

  defp gated_event("search_locality", %{"locality_query" => %{} = queries}, socket) do
    {:noreply, search_localities(socket, queries)}
  end

  defp gated_event("pick_locality", %{"key" => key, "index" => index} = params, socket) do
    # Only a result of the provider on screen can be picked: a click on a
    # stale list, or an index that is not a position, selects nothing.
    with true <- Map.get(params, "provider") == socket.assigns.sp.provider,
         true <- locality_key?(socket, key),
         [_ | _] = results <- Map.get(socket.assigns.locality_results, key),
         {position, ""} when position >= 0 <- Integer.parse(to_string(index)),
         %{id: id, name: name} when is_binary(id) and is_binary(name) <-
           Enum.at(results, position) do
      {:noreply, put_locality(socket, key, %{"id" => id, "name" => name})}
    else
      _ -> {:noreply, socket}
    end
  end

  defp gated_event("clear_locality", %{"key" => key}, socket) do
    if locality_key?(socket, key),
      do: {:noreply, put_locality(socket, key, nil)},
      else: {:noreply, socket}
  end

  defp gated_event(_event, _params, socket), do: {:noreply, socket}

  # -- shipping cost calculation card --------------------------------------

  defp assign_provider_state(socket, method) do
    socket
    |> assign(:sp, ProviderState.from_method(method))
    |> assign(:form_params, %{})
    |> assign(:provider_options, provider_options())
    |> assign(:loaded_provider, nil)
    |> assign(:provider_known?, true)
    |> assign(:provider_fields, [])
    |> assign(:services, [])
    |> assign(:services_status, :idle)
    |> assign(:integration, nil)
    |> assign(:locality_results, %{})
    |> assign(:locality_loading, %{})
    |> assign(:provider_errors, %{fields: %{}, general: []})
    |> assign(:provider_error_list, [])
    |> refresh_provider()
  end

  defp provider_options do
    Enum.map(Shipping.providers(), &{&1.label(), &1.key()})
  end

  # A stored provider the host no longer registers stays selectable, so the
  # form does not silently switch the method to another one.
  defp provider_select_options(options, provider) do
    if Enum.any?(options, &(elem(&1, 1) == provider)),
      do: options,
      else: options ++ [{gettext("%{provider} (not installed)", provider: provider), provider}]
  end

  # The saved service is always offered as the current value. It is called
  # unavailable only when the carrier answered and does not list it: while the
  # list loads or the carrier is down nothing is known about it.
  defp service_select_options(services, service, status) do
    options = Enum.map(services, &{&1.label || &1.key, &1.key})

    cond do
      service in ["", nil] ->
        options

      Enum.any?(options, &(elem(&1, 1) == service)) ->
        options

      status == :ok and options != [] ->
        options ++ [{gettext("%{service} (unavailable)", service: service), service}]

      true ->
        options ++ [{service, service}]
    end
  end

  # Folds the posted provider card into the state and reloads what depends on
  # the provider. Returns the socket and whether the admin chose another
  # provider just now.
  defp sync_provider(socket, params, provider_chosen?) do
    {state, change} =
      ProviderState.apply_params(socket.assigns.sp, params["shipping_provider"], provider_chosen?)

    {socket |> assign(:sp, state) |> refresh_provider(), change}
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

  # Everything the card knows about a provider is loaded when the provider
  # changes, and only then: keystrokes in other inputs cost the carrier
  # nothing.
  defp refresh_provider(socket) do
    provider = socket.assigns.sp.provider

    if socket.assigns.loaded_provider == provider,
      do: socket,
      else: load_provider(socket, provider)
  end

  defp load_provider(socket, provider) do
    socket =
      socket
      |> cancel_lookups()
      |> assign(:loaded_provider, provider)
      |> assign(:provider_fields, ProviderState.fields(provider))
      |> assign(:provider_known?, match?({:ok, _}, Shipping.provider(provider)))
      |> assign(:services, [])
      |> assign(:services_status, :idle)
      |> assign(:integration, nil)
      |> assign(:locality_results, %{})
      |> assign(:locality_loading, %{})

    if provider == ProviderState.fixed() or not socket.assigns.provider_known?,
      do: socket,
      else: start_provider_lookups(socket, provider)
  end

  defp start_provider_lookups(socket, provider) do
    ctx = provider_context(socket.assigns.sp)
    socket = assign(socket, :integration, integration_status(ctx))

    # The carrier is called on behalf of an operator who may change settings.
    if Authz.can?(socket, :manage_settings) do
      socket
      |> assign(:services_status, :loading)
      |> start_async(:services, fn -> {provider, Shipping.services(ctx)} end)
    else
      socket
    end
  end

  defp cancel_lookups(socket) do
    socket.assigns
    |> Map.get(:locality_loading, %{})
    |> Map.keys()
    |> Enum.reduce(cancel_async(socket, :services), fn key, acc ->
      cancel_async(acc, {:locality_search, key})
    end)
  end

  defp finish_services(socket, {:ok, {provider, result}}) do
    if provider == socket.assigns.sp.provider do
      case result do
        {:ok, services} ->
          socket
          |> assign(:services, services)
          |> assign(:services_status, :ok)
          |> update(:sp, &pick_service(&1, services))

        {:error, _reason} ->
          assign(socket, :services_status, :error)
      end
    else
      socket
    end
  end

  defp finish_services(socket, {:exit, _reason}), do: assign(socket, :services_status, :error)

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
    Enum.any?(socket.assigns.provider_fields, &(&1.type == :locality and &1.key == key))
  end

  defp search_localities(socket, queries) do
    Enum.reduce(queries, socket, fn {key, query}, acc ->
      query = if is_binary(query), do: query, else: ""

      if Map.get(acc.assigns.sp.queries, key, "") != query and locality_key?(acc, key),
        do: start_locality_search(acc, key, query),
        else: acc
    end)
  end

  defp start_locality_search(socket, key, query) do
    socket = update(socket, :sp, &%{&1 | queries: Map.put(&1.queries, key, query)})

    if String.length(String.trim(query)) < 2 do
      socket
      |> cancel_async({:locality_search, key})
      |> update(:locality_results, &Map.delete(&1, key))
      |> update(:locality_loading, &Map.delete(&1, key))
    else
      ctx = provider_context(socket.assigns.sp)
      provider = socket.assigns.sp.provider

      socket
      |> update(:locality_loading, &Map.put(&1, key, true))
      |> start_async({:locality_search, key}, fn ->
        {provider, query, Shipping.search_localities(ctx, query)}
      end)
    end
  end

  # An answer to a query the admin has already typed past, or for a provider
  # no longer on screen, is dropped.
  defp finish_locality_search(socket, key, {:ok, {provider, query, result}}) do
    %{sp: sp} = socket.assigns

    if provider == sp.provider and Map.get(sp.queries, key) == query do
      results =
        case result do
          {:ok, localities} -> localities
          {:error, _reason} -> :error
        end

      socket
      |> update(:locality_results, &Map.put(&1, key, results))
      |> update(:locality_loading, &Map.delete(&1, key))
    else
      socket
    end
  end

  defp finish_locality_search(socket, key, {:exit, _reason}) do
    socket
    |> update(:locality_results, &Map.put(&1, key, :error))
    |> update(:locality_loading, &Map.delete(&1, key))
  end

  defp put_locality(socket, key, value) do
    settings =
      if value,
        do: Map.put(socket.assigns.sp.settings, key, value),
        else: Map.delete(socket.assigns.sp.settings, key)

    socket
    |> update(:sp, &%{&1 | settings: settings, queries: Map.delete(&1.queries, key)})
    |> cancel_async({:locality_search, key})
    |> update(:locality_results, &Map.delete(&1, key))
    |> update(:locality_loading, &Map.delete(&1, key))
    |> recheck_provider_errors(key)
  end

  # What the pick or the clear changes about the errors on the card, and
  # nothing else: errors on fields the admin has not touched yet (the name of
  # the method, other settings) stay hidden until they are validated.
  defp recheck_provider_errors(socket, key) do
    current =
      case MethodParams.build(ProviderState.to_param(socket.assigns.sp), check_service: false) do
        {:error, messages} -> messages
        _ -> []
      end

    shown = socket.assigns.provider_error_list

    visible =
      Enum.filter(current, fn error ->
        error in shown or error == {"required setting %{setting} is missing", [setting: key]}
      end)

    assign_provider_errors(socket, visible)
  end

  defp assign_form_errors(socket, %Ecto.Changeset{} = changeset) do
    raw =
      if changeset.action,
        do: for({:shipping_provider, error} <- changeset.errors, do: error),
        else: []

    socket |> assign_form(changeset) |> assign_provider_errors(raw)
  end

  defp assign_provider_errors(socket, raw) do
    socket
    |> assign(:provider_error_list, raw)
    |> assign(:provider_errors, ProviderState.errors(raw, socket.assigns.provider_fields))
  end
end
