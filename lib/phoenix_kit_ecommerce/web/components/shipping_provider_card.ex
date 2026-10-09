defmodule PhoenixKitEcommerce.Web.Components.ShippingProviderCard do
  @moduledoc """
  The "Shipping cost calculation" card of the shipping method form: provider,
  service, the provider's own settings, markup and the state of its
  Integrations connection.

  Everything is posted under `shipping_method[shipping_provider]`; the locality
  search boxes are the only inputs outside it (`shipping_locality_query[key]`),
  so a half-typed query never becomes a setting. The events (`pick_locality`,
  `clear_locality`) are handled by `PhoenixKitEcommerce.Web.ShippingMethodForm`.
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
  alias PhoenixKitEcommerce.Shipping.{Field, Locality}
  alias PhoenixKitEcommerce.Web.ShippingProviderState, as: State

  @prefix "shipping_method[shipping_provider]"

  attr :state, :map, required: true, doc: "`ShippingProviderState.t/0`"
  attr :provider_options, :list, required: true, doc: "`[{label, key}]`"
  attr :service_options, :list, default: [], doc: "`[{label, key}]`"
  attr :services_error, :boolean, default: false
  attr :fields, :list, default: [], doc: "`Field` structs of the chosen provider"
  attr :integration, :map, default: nil, doc: "`%{name:, connected?:}` or `nil`"
  attr :locality_results, :map, default: %{}
  attr :locality_loading, :map, default: %{}
  attr :errors, :list, default: [], doc: "changeset errors on `:shipping_provider`"

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
          </div>

          <div :if={@calculated?} class="fieldset w-full">
            <.select
              id="shipping-service-select"
              name={"#{prefix()}[service]"}
              value={@state.service}
              label={gettext("Service")}
              prompt={gettext("Select a service")}
              options={@service_options}
            />
            <p :if={@services_error} id="shipping-services-error" class="text-warning text-sm mt-1">
              {gettext("The carrier's services could not be loaded. Try again in a moment.")}
            </p>
          </div>
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
          />
        </div>

        <%= if @calculated? do %>
          <div class="divider my-2"></div>

          <div id="shipping-provider-pricing">
            <h3 class="font-medium mb-3">{gettext("Markup on the carrier's price")}</h3>
            <div class="grid grid-cols-1 md:grid-cols-3 gap-6">
              <.decimal_input
                id="shipping-pricing-markup_percent"
                name={"#{prefix()}[pricing][markup_percent]"}
                value={@state.pricing["markup_percent"]}
                label={gettext("Markup, %")}
                placeholder="0"
              />
              <.decimal_input
                id="shipping-pricing-markup_fixed"
                name={"#{prefix()}[pricing][markup_fixed]"}
                value={@state.pricing["markup_fixed"]}
                label={gettext("Fixed markup")}
                placeholder="0"
              />
              <.decimal_input
                id="shipping-pricing-round_to"
                name={"#{prefix()}[pricing][round_to]"}
                value={@state.pricing["round_to"]}
                label={gettext("Round up to a multiple of")}
                placeholder="1"
              />
            </div>
          </div>

          <p id="shipping-provider-fallback-hint" class="text-sm text-base-content/60 mt-4">
            <.icon name="hero-information-circle" class="w-4 h-4 inline mr-1" />
            {gettext(
              "The price in the Pricing card is the fallback price: the customer pays it when the carrier does not answer."
            )}
          </p>
        <% end %>

        <div :if={@errors != []} id="shipping-provider-errors" class="alert alert-error mt-4">
          <ul class="list-disc list-inside">
            <li :for={error <- @errors}>{translate_error(error)}</li>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  attr :field, Field, required: true
  attr :state, :map, required: true
  attr :results, :any, default: nil
  attr :loading, :boolean, default: false

  def setting_field(%{field: %Field{type: :locality}} = assigns) do
    assigns =
      assigns
      |> assign(:selected, State.field_value(assigns.state, assigns.field))
      |> assign(:query, Map.get(assigns.state.queries, assigns.field.key, ""))

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
        <span class="badge badge-primary badge-lg">{@selected["name"]}</span>
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

      <.input
        id={"shipping-locality-query-#{@field.key}"}
        name={"shipping_locality_query[#{@field.key}]"}
        value={@query}
        type="text"
        placeholder={gettext("Start typing a city")}
        autocomplete="off"
        phx-debounce="300"
        onkeydown="if (event.key === 'Enter') event.preventDefault()"
      />

      <div id={"shipping-locality-results-#{@field.key}"} class="mt-1">
        <span :if={@loading} class="loading loading-spinner loading-sm"></span>
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
          <li :for={{locality, index} <- Enum.with_index(locality_list(@results))}>
            <button
              type="button"
              id={"shipping-locality-option-#{@field.key}-#{index}"}
              phx-click="pick_locality"
              phx-value-key={@field.key}
              phx-value-index={index}
            >
              <span>{locality.name}</span>
              <span :if={locality_hint(locality)} class="text-xs text-base-content/60">
                {locality_hint(locality)}
              </span>
            </button>
          </li>
        </ul>
      </div>

      <p :if={@field.help} class="text-sm text-base-content/60 mt-1">{@field.help}</p>
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

  defp locality_list(results) when is_list(results), do: results
  defp locality_list(_other), do: []

  defp locality_hint(%Locality{region: region}) when is_binary(region) and region != "",
    do: region

  defp locality_hint(_locality), do: nil
end
