defmodule PhoenixKitEcommerce.Web.Components.ShippingProviderCard do
  @moduledoc """
  The "Shipping cost calculation" card of the shipping method form: provider,
  service, the provider's own settings, markup and the state of its
  Integrations connection.

  Everything is posted under `shipping_method[shipping_provider]`. The locality
  and pickup point search boxes (the pickup point of a field is listed for the
  city picked in the locality field it names) sit in this card but belong to
  their own sibling forms
  (`locality_search_forms/1`, outside the main form, tied to the input by its
  `form` attribute), so typing a query neither validates nor submits the
  method. The events (`search_locality`, `pick_locality`, `clear_locality`) are
  handled by `PhoenixKitEcommerce.Web.ShippingMethodForm`.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitEcommerce.Gettext

  import PhoenixKitWeb.Components.Core.Checkbox
  import PhoenixKitWeb.Components.Core.DecimalInput
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Input
  import PhoenixKitWeb.Components.Core.Select
  import PhoenixKitWeb.Components.Core.Textarea

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitEcommerce.Shipping.{Field, Locality, PickupPoint}
  alias PhoenixKitEcommerce.Web.ShippingProviderState, as: State

  @prefix "shipping_method[shipping_provider]"
  @query_length 64

  attr :state, :map, required: true, doc: "`ShippingProviderState.t/0`"
  attr :provider_options, :list, required: true, doc: "`[{label, key}]`"
  attr :provider_known?, :boolean, default: true, doc: "whether the host still registers it"

  attr :countries, :list,
    default: [],
    doc: "ISO 3166-1 alpha-2 codes of the countries the provider delivers to; `[]` for any"

  attr :service_options, :list, default: [], doc: "`[{label, key}]`"

  attr :services_status, :atom,
    default: :idle,
    values: [:idle, :loading, :ok, :error],
    doc: "the state of the carrier's service list"

  attr :pay_on_delivery, :boolean,
    default: false,
    doc: "the method is paid on delivery: the Pricing card price is not a fallback then"

  attr :fields, :list, default: [], doc: "`Field` structs of the chosen provider"
  attr :integration, :map, default: nil, doc: "`%{name:, connected?:}` or `nil`"
  attr :locality_results, :map, default: %{}
  attr :locality_loading, :map, default: %{}

  attr :field_errors, :map,
    default: %{},
    doc: "messages per input: `\"service\"`, `\"setting:<key>\"`, `\"pricing:<key>\"`"

  attr :errors, :list, default: [], doc: "messages that belong to no input"

  def shipping_provider_card(assigns) do
    assigns = assign(assigns, :calculated?, assigns.state.provider != State.fixed())

    ~H"""
    <div class="card bg-base-100 shadow-xl" id="shipping-provider-card">
      <div class="card-body">
        <h2 class="card-title text-xl mb-2">{gettext("Shipping cost calculation")}</h2>
        <p class="text-sm text-base-content/60 mb-4">
          {gettext("Where the price of this method comes from.")}
        </p>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-6">
          <div class="fieldset w-full">
            <.select
              id="shipping-provider-select"
              name={"#{prefix()}[provider]"}
              value={@state.provider}
              label={gettext("Provider")}
              options={@provider_options}
            />
            <p
              :if={@countries != []}
              id="shipping-provider-countries"
              class="text-sm text-base-content/60 mt-1"
            >
              {gettext("Delivers to: %{countries}", countries: Enum.join(@countries, ", "))}
            </p>
          </div>

          <div :if={@calculated? and @provider_known?} class="fieldset w-full">
            <.select
              id="shipping-service-select"
              name={"#{prefix()}[service]"}
              value={@state.service}
              label={gettext("Service")}
              prompt={gettext("Select a service")}
              options={@service_options}
              errors={Map.get(@field_errors, "service", [])}
            />
            <p
              :if={@services_status == :loading}
              id="shipping-services-loading"
              role="status"
              class="text-sm text-base-content/60 mt-1"
            >
              <span class="loading loading-spinner loading-xs"></span>
              {gettext("Loading the carrier's services")}
            </p>
            <p
              :if={@services_status == :error}
              id="shipping-services-error"
              role="alert"
              class="text-warning text-sm mt-1"
            >
              {gettext(
                "The carrier's services could not be loaded. Reload the page to try again; the saved service is kept."
              )}
            </p>
          </div>
        </div>

        <div
          :if={not @provider_known?}
          id="shipping-provider-unknown"
          role="alert"
          class="alert alert-warning mt-4"
        >
          <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
          <span>
            {gettext(
              "This provider is no longer installed. Choose another one; until then the method keeps its fixed price."
            )}
          </span>
        </div>

        <div
          :if={@integration}
          id="shipping-provider-integration"
          class={[
            "alert mt-4 flex flex-wrap items-center justify-between gap-2",
            if(@integration.connected?, do: "alert-success", else: "alert-warning")
          ]}
        >
          <span class="flex items-center gap-2">
            <.icon
              name={if @integration.connected?, do: "hero-check-circle", else: "hero-exclamation-triangle"}
              class="w-5 h-5"
            />
            <span id="shipping-provider-integration-status">
              <%= if @integration.connected? do %>
                {gettext("%{name}: connected", name: @integration.name)}
              <% else %>
                {gettext("%{name}: not connected", name: @integration.name)}
              <% end %>
            </span>
          </span>
          <.link
            id="shipping-provider-integration-link"
            navigate={Routes.path("/admin/settings/integrations")}
            class="link link-hover text-sm"
          >
            {gettext("Manage integrations")}
          </.link>
        </div>

        <div
          :if={@fields != []}
          id="shipping-provider-settings"
          class="grid grid-cols-1 md:grid-cols-2 gap-6 mt-4"
        >
          <.setting_field
            :for={field <- @fields}
            field={field}
            state={@state}
            results={Map.get(@locality_results, field.key)}
            loading={Map.get(@locality_loading, field.key, false)}
            errors={Map.get(@field_errors, "setting:" <> field.key, [])}
          />
        </div>

        <%= if @calculated? do %>
          <div class="divider my-2"></div>

          <div id="shipping-provider-pricing">
            <h3 class="font-medium mb-3">{gettext("Markup on the carrier's price")}</h3>
            <div class="grid grid-cols-1 md:grid-cols-3 gap-6">
              <.decimal_input
                :for={key <- State.pricing_keys()}
                id={"shipping-pricing-#{key}"}
                name={"#{prefix()}[pricing][#{key}]"}
                value={@state.pricing[key]}
                label={State.pricing_label(key)}
                placeholder={if key == "round_to", do: gettext("No rounding"), else: "0"}
                errors={Map.get(@field_errors, "pricing:" <> key, [])}
              />
            </div>
            <p id="shipping-pricing-round-to-help" class="text-sm text-base-content/60 mt-2">
              {gettext("Leave the rounding empty for no rounding.")}
            </p>
          </div>

          <p
            :if={not @pay_on_delivery}
            id="shipping-provider-fallback-hint"
            class="text-sm text-base-content/60 mt-4"
          >
            <.icon name="hero-information-circle" class="w-4 h-4 inline mr-1" />
            {gettext(
              "The price in the Pricing card is the fallback price: the customer pays it when the carrier does not answer."
            )}
          </p>
        <% end %>

        <div
          :if={@errors != []}
          id="shipping-provider-errors"
          role="alert"
          class="alert alert-error mt-4"
        >
          <ul class="list-disc list-inside">
            <li :for={error <- @errors}>{error}</li>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  attr :fields, :list,
    required: true,
    doc: "`Field` structs; one search form per locality or pickup point field"

  @doc """
  The sibling forms the locality and pickup point search inputs belong to.
  Render them OUTSIDE the main form: forms do not nest.
  """
  def locality_search_forms(assigns) do
    assigns =
      assign(
        assigns,
        :lookups,
        Enum.filter(assigns.fields, &(&1.type in [:locality, :pickup_point]))
      )

    ~H"""
    <.form
      :for={field <- @lookups}
      for={%{}}
      id={"shipping-locality-search-#{field.key}"}
      phx-change="search_locality"
      phx-submit="search_locality"
    >
    </.form>
    """
  end

  attr :field, Field, required: true
  attr :state, :map, required: true
  attr :results, :any, default: nil
  attr :loading, :boolean, default: false
  attr :errors, :list, default: []

  # A locality is searched by name; a pickup point is listed for the city picked
  # in the locality field it names, so it waits for that city.
  def setting_field(%{field: %Field{type: type}} = assigns)
      when type in [:locality, :pickup_point] do
    assigns =
      assigns
      |> assign(:selected, State.field_value(assigns.state, assigns.field))
      |> assign(:query, Map.get(assigns.state.queries, assigns.field.key, ""))
      |> assign(:query_length, @query_length)
      |> assign(:waiting?, waiting_for_city?(assigns.field, assigns.state))
      |> assign(:placeholder, lookup_placeholder(type))

    ~H"""
    <div id={"shipping-provider-setting-#{@field.key}"} class="fieldset w-full">
      <label class="label mb-2" for={"shipping-locality-query-#{@field.key}"}>
        <span class="font-semibold">{@field.label}</span>
        <span :if={@field.required} class="text-error ml-0.5" aria-hidden="true">*</span>
      </label>

      <div
        :if={selected?(@selected)}
        id={"shipping-locality-selected-#{@field.key}"}
        class="flex items-center gap-2 mb-2"
      >
        <span class="badge badge-primary badge-lg h-auto whitespace-normal text-left py-1">
          {@selected["name"]}
        </span>
        <button
          type="button"
          id={"shipping-locality-clear-#{@field.key}"}
          phx-click="clear_locality"
          phx-value-key={@field.key}
          class="btn btn-ghost btn-xs"
          aria-label={gettext("Clear")}
        >
          <.icon name="hero-x-mark" class="w-4 h-4" />
        </button>
        <input
          type="hidden"
          id={"shipping-provider-setting-#{@field.key}-id"}
          name={"#{prefix()}[settings][#{@field.key}][id]"}
          value={@selected["id"]}
        />
        <input
          type="hidden"
          id={"shipping-provider-setting-#{@field.key}-name"}
          name={"#{prefix()}[settings][#{@field.key}][name]"}
          value={@selected["name"]}
        />
      </div>

      <p
        :if={@waiting?}
        id={"shipping-locality-waiting-#{@field.key}"}
        class="text-sm text-base-content/60"
      >
        {gettext("Choose the city first.")}
      </p>

      <.input
        :if={not @waiting?}
        id={"shipping-locality-query-#{@field.key}"}
        name={"locality_query[#{@field.key}]"}
        form={"shipping-locality-search-#{@field.key}"}
        value={@query}
        type="text"
        placeholder={@placeholder}
        autocomplete="off"
        maxlength={@query_length}
        phx-debounce="300"
      />

      <div
        :if={not @waiting?}
        id={"shipping-locality-results-#{@field.key}"}
        class="mt-1"
        aria-live="polite"
      >
        <p :if={@loading} role="status" class="text-sm text-base-content/60">
          <span class="loading loading-spinner loading-sm"></span>
          <span class="sr-only">{gettext("Searching")}</span>
        </p>
        <p :if={@results == :error} class="text-warning text-sm">
          {gettext("The search is unavailable right now.")}
        </p>
        <p :if={@results == [] and not @loading} class="text-sm text-base-content/60">
          {gettext("Nothing found.")}
        </p>
        <ul
          :if={is_list(@results) and @results != []}
          class="menu menu-sm bg-base-200 rounded-box w-full max-h-64 overflow-y-auto flex-nowrap"
        >
          <li :for={{item, index} <- Enum.with_index(shown_results(@field, @results))}>
            <button
              type="button"
              id={"shipping-locality-option-#{@field.key}-#{index}"}
              phx-click="pick_locality"
              phx-value-key={@field.key}
              phx-value-index={index}
              phx-value-id={item.id}
              phx-value-provider={@state.provider}
            >
              <span>{item.name}</span>
              <span :if={lookup_hint(item)} class="text-xs text-base-content/60">
                {lookup_hint(item)}
              </span>
            </button>
          </li>
        </ul>
        <p
          :if={cut?(@field, @results)}
          id={"shipping-locality-truncated-#{@field.key}"}
          class="text-xs text-base-content/60 mt-1"
        >
          {gettext("Only the first %{count} points are shown. Narrow the search to see others.",
            count: max_points()
          )}
        </p>
      </div>

      <p :if={@field.help} class="text-sm text-base-content/60 mt-1">{@field.help}</p>
      <p
        :for={error <- @errors}
        id={"shipping-provider-error-setting-#{@field.key}"}
        role="alert"
        class="text-error text-sm mt-1"
      >
        {error}
      </p>
    </div>
    """
  end

  def setting_field(%{field: %Field{type: :boolean}} = assigns) do
    assigns = assign(assigns, :value, State.field_value(assigns.state, assigns.field))

    ~H"""
    <div class="fieldset w-full">
      <.checkbox
        id={"shipping-provider-setting-#{@field.key}"}
        name={"#{prefix()}[settings][#{@field.key}]"}
        checked={@value in [true, "true"]}
        label={@field.label}
        errors={@errors}
      />
      <p :if={@field.help} class="text-sm text-base-content/60 mt-1">{@field.help}</p>
    </div>
    """
  end

  def setting_field(%{field: %Field{type: :select}} = assigns) do
    assigns = assign(assigns, :value, State.field_value(assigns.state, assigns.field))

    ~H"""
    <div class="fieldset w-full">
      <.select
        id={"shipping-provider-setting-#{@field.key}"}
        name={"#{prefix()}[settings][#{@field.key}]"}
        value={@value}
        label={@field.label}
        options={@field.options}
        errors={@errors}
      />
      <p :if={@field.help} class="text-sm text-base-content/60 mt-1">{@field.help}</p>
    </div>
    """
  end

  def setting_field(%{field: %Field{type: :textarea}} = assigns) do
    assigns = assign(assigns, :value, State.field_value(assigns.state, assigns.field))

    ~H"""
    <div class="fieldset w-full md:col-span-2">
      <.textarea
        id={"shipping-provider-setting-#{@field.key}"}
        name={"#{prefix()}[settings][#{@field.key}]"}
        value={@value}
        label={required_label(@field)}
        rows="5"
        errors={@errors}
      />
      <p :if={@field.help} class="text-sm text-base-content/60 mt-1">{@field.help}</p>
    </div>
    """
  end

  def setting_field(%{field: %Field{type: :decimal}} = assigns) do
    assigns = assign(assigns, :value, State.field_value(assigns.state, assigns.field))

    ~H"""
    <div class="fieldset w-full">
      <.decimal_input
        id={"shipping-provider-setting-#{@field.key}"}
        name={"#{prefix()}[settings][#{@field.key}]"}
        value={@value}
        label={required_label(@field)}
        errors={@errors}
      />
      <p :if={@field.help} class="text-sm text-base-content/60 mt-1">{@field.help}</p>
    </div>
    """
  end

  def setting_field(%{field: %Field{type: type}} = assigns) do
    assigns =
      assigns
      |> assign(:value, State.field_value(assigns.state, assigns.field))
      |> assign(:input_type, if(type == :integer, do: "number", else: "text"))

    ~H"""
    <div class="fieldset w-full">
      <.input
        id={"shipping-provider-setting-#{@field.key}"}
        name={"#{prefix()}[settings][#{@field.key}]"}
        value={@value}
        type={@input_type}
        label={required_label(@field)}
        errors={@errors}
      />
      <p :if={@field.help} class="text-sm text-base-content/60 mt-1">{@field.help}</p>
    </div>
    """
  end

  defp prefix, do: @prefix

  defp required_label(%Field{required: true, label: label}), do: label <> " *"
  defp required_label(%Field{label: label}), do: label

  defp selected?(%{"id" => id, "name" => name}), do: id not in [nil, ""] and name not in [nil, ""]
  defp selected?(_other), do: false

  @max_points 50

  @doc "How many branches a point list shows (the shopper's picker shows as many)."
  @spec max_points() :: pos_integer()
  def max_points, do: @max_points

  defp shown_results(%Field{type: :pickup_point}, results),
    do: results |> locality_list() |> Enum.take(@max_points)

  defp shown_results(_field, results), do: locality_list(results)

  defp cut?(%Field{type: :pickup_point}, results),
    do: length(locality_list(results)) > @max_points

  defp cut?(_field, _results), do: false

  defp locality_list(results) when is_list(results), do: results
  defp locality_list(_other), do: []

  defp lookup_hint(%Locality{region: region}) when is_binary(region) and region != "",
    do: region

  defp lookup_hint(%PickupPoint{address: address}) when is_binary(address) and address != "",
    do: address

  defp lookup_hint(_item), do: nil

  defp lookup_placeholder(:pickup_point), do: gettext("Search by number, name or address")
  defp lookup_placeholder(_type), do: gettext("Start typing a city")

  defp waiting_for_city?(%Field{type: :pickup_point, locality_key: key}, state),
    do: not selected?(Map.get(state.settings, key))

  defp waiting_for_city?(_field, _state), do: false
end
