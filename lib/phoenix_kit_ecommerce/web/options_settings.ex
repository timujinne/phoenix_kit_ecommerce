defmodule PhoenixKitEcommerce.Web.OptionsSettings do
  @moduledoc """
  Global product options settings LiveView.

  Allows administrators to manage global options that apply to all products.
  Supports both fixed and percentage-based price modifiers.
  """

  use PhoenixKitEcommerce.Web, :live_view

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitEcommerce.Activity
  alias PhoenixKitEcommerce.Errors
  alias PhoenixKitEcommerce.Options
  alias PhoenixKitEcommerce.OptionTypes
  alias PhoenixKitEcommerce.Web.Authz
  alias PhoenixKitEcommerce.Web.Helpers

  @impl true
  def mount(_params, _session, socket) do
    options = Options.get_global_options()

    socket =
      socket
      |> assign_shop_trail(gettext("Options"), [settings_crumb()])
      |> assign(:options, options)
      |> assign(:show_modal, false)
      |> assign(:editing_option, nil)
      |> assign(:form_data, initial_form_data())
      |> assign(:supported_types, OptionTypes.supported_types())
      |> assign(:modifier_types, OptionTypes.modifier_types())

    {:ok, socket}
  end

  @impl true
  def handle_event("show_add_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_modal, true)
     |> assign(:editing_option, nil)
     |> assign(:form_data, initial_form_data())}
  end

  @impl true
  def handle_event("show_edit_modal", %{"key" => key}, socket) do
    option = Enum.find(socket.assigns.options, &(&1["key"] == key))

    if option do
      form_data = %{
        key: option["key"],
        label: option["label"],
        type: option["type"],
        options: option["options"] || [],
        required: option["required"] || false,
        unit: option["unit"] || "",
        affects_price: option["affects_price"] || false,
        modifier_type: option["modifier_type"] || "fixed",
        price_modifiers: option["price_modifiers"] || %{},
        allow_override: option["allow_override"] || false,
        enabled: Map.get(option, "enabled", true)
      }

      {:noreply,
       socket
       |> assign(:show_modal, true)
       |> assign(:editing_option, option)
       |> assign(:form_data, form_data)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("close_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_modal, false)
     |> assign(:editing_option, nil)
     |> assign(:form_data, initial_form_data())}
  end

  @impl true
  def handle_event("validate_form", %{"option" => params}, socket) do
    options = parse_options(params["options"])

    form_data = %{
      key: params["key"] || "",
      label: params["label"] || "",
      type: params["type"] || "text",
      options: options,
      required: params["required"] == "true",
      unit: params["unit"] || "",
      affects_price: params["affects_price"] == "true",
      modifier_type: params["modifier_type"] || "fixed",
      price_modifiers: parse_price_modifiers(params["price_modifiers"], options),
      allow_override: params["allow_override"] == "true"
    }

    # Auto-generate key from label if creating new
    form_data =
      if socket.assigns.editing_option == nil and form_data.key == "" do
        %{form_data | key: slugify_key(form_data.label)}
      else
        form_data
      end

    {:noreply, assign(socket, :form_data, form_data)}
  end

  @impl true
  def handle_event("toggle_affects_price", _params, socket) do
    form_data = socket.assigns.form_data
    updated = %{form_data | affects_price: !form_data.affects_price}

    # Initialize price modifiers with "0" for all options when enabling
    updated =
      if updated.affects_price and map_size(updated.price_modifiers) == 0 do
        modifiers = Map.new(updated.options, fn opt -> {opt, "0"} end)
        %{updated | price_modifiers: modifiers}
      else
        updated
      end

    {:noreply, assign(socket, :form_data, updated)}
  end

  @impl true
  def handle_event("set_modifier_type", %{"type" => type}, socket) do
    form_data = socket.assigns.form_data
    updated = %{form_data | modifier_type: type}
    {:noreply, assign(socket, :form_data, updated)}
  end

  @impl true
  def handle_event("toggle_allow_override", _params, socket) do
    form_data = socket.assigns.form_data
    updated = %{form_data | allow_override: !form_data.allow_override}
    {:noreply, assign(socket, :form_data, updated)}
  end

  @impl true
  def handle_event("save_option", params, socket) do
    Authz.authorize(socket, :manage_settings, fn -> gated_event("save_option", params, socket) end)
  end

  @impl true
  def handle_event("delete_option", params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      gated_event("delete_option", params, socket)
    end)
  end

  @impl true
  def handle_event("toggle_enabled", params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      gated_event("toggle_enabled", params, socket)
    end)
  end

  @impl true
  def handle_event("reorder_options", params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      gated_event("reorder_options", params, socket)
    end)
  end

  @impl true
  def handle_event("add_option", _params, socket) do
    form_data = socket.assigns.form_data
    updated = %{form_data | options: form_data.options ++ [""]}
    {:noreply, assign(socket, :form_data, updated)}
  end

  @impl true
  def handle_event("remove_option", %{"index" => idx}, socket) do
    form_data = socket.assigns.form_data
    index = Helpers.parse_int(idx, -1)

    if index < 0 do
      {:noreply, socket}
    else
      updated = %{form_data | options: List.delete_at(form_data.options, index)}
      {:noreply, assign(socket, :form_data, updated)}
    end
  end

  # The key never changes on an edit: the form's key input is disabled, so a
  # browser does not submit it and `build_option/1` would derive a new key
  # from the label — renaming the option (possibly onto another option's
  # key) while products keep their selections under the old one.
  defp keep_editing_key(opt, %{"key" => key}), do: Map.put(opt, "key", key)
  defp keep_editing_key(opt, _editing), do: opt

  defp save_option_change(nil, opt), do: Options.add_global_option(opt)

  # `base: editing` — the option as this page loaded it, so values added to
  # it since (a CSV import does that) survive the save.
  defp save_option_change(editing, opt),
    do: Options.update_global_option(editing["key"], opt, base: editing)

  # One audit row per mutation of the global options. The key is the option's
  # machine name, never customer data.
  defp log_option(socket, action, key, metadata \\ %{}) do
    Activity.log(action,
      actor_uuid: Activity.actor_uuid(socket),
      actor_role: Activity.actor_role(socket),
      resource_type: "global_option",
      metadata: Map.put(metadata, "key", key)
    )
  end

  defp log_option_failed(socket, action, key, reason) do
    Activity.log_failed(action, reason,
      actor_uuid: Activity.actor_uuid(socket),
      actor_role: Activity.actor_role(socket),
      resource_type: "global_option",
      metadata: %{"key" => key}
    )
  end

  defp reload_options(socket), do: assign(socket, :options, Options.get_global_options())

  @impl true
  def render(assigns) do
    ~H"""
      <div class="container flex-col mx-auto px-4 py-6 max-w-5xl">
        <.admin_page_header
          back={Routes.path("/admin/shop/settings")}
          title={gettext("Product Options")}
          subtitle={gettext("Define global options that apply to all products")}
        />

        <%!-- Controls Bar --%>
        <div class="bg-base-200 rounded-lg p-4 mb-6">
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-2 text-sm text-base-content/70">
              <.icon name="hero-information-circle" class="w-4 h-4" />
              <span>
                {gettext("Global options apply to all products. Categories can override or add their own.")}
              </span>
            </div>
            <button type="button" phx-click="show_add_modal" class="btn btn-primary btn-sm">
              <.icon name="hero-plus" class="w-4 h-4 mr-1" /> {gettext("Add Option")}
            </button>
          </div>
        </div>

        <%!-- Options List --%>
        <div class="card bg-base-100 shadow-xl">
          <div class="card-body">
            <div class="flex items-center justify-between mb-4">
              <h2 class="card-title text-lg">
                <.icon name="hero-adjustments-horizontal" class="w-5 h-5" /> {gettext("Global Options")}
              </h2>
              <span class="text-sm text-base-content/60">
                {ngettext("%{count} option", "%{count} options", length(@options))}
              </span>
            </div>

            <%= if @options == [] do %>
              <div class="text-center py-12">
                <.icon
                  name="hero-adjustments-horizontal"
                  class="w-16 h-16 mx-auto text-base-content/30 mb-4"
                />
                <h3 class="text-lg font-medium text-base-content mb-2">
                  {gettext("No options defined yet")}
                </h3>
                <p class="text-base-content/60 mb-4">
                  {gettext("Add your first global option to get started")}
                </p>
                <button type="button" phx-click="show_add_modal" class="btn btn-primary">
                  <.icon name="hero-plus" class="w-4 h-4 mr-2" /> {gettext("Create First Option")}
                </button>
              </div>
            <% else %>
              <%!-- Table Header --%>
              <div class="hidden sm:flex items-center px-4 py-2 text-xs font-semibold text-base-content/50 uppercase tracking-wider">
                <div class="flex-1">{gettext("Option")}</div>
                <div class="w-52 text-right">{gettext("Actions")}</div>
              </div>

              <div class="flex flex-col gap-2">
                <%= for opt <- @options do %>
                  <% enabled = Map.get(opt, "enabled", true) != false %>
                  <div class={[
                    "flex flex-col sm:flex-row sm:items-center p-4 rounded-lg border transition-all",
                    if(enabled,
                      do: "bg-base-200/60 border-base-300 hover:bg-base-200",
                      else: "bg-base-200/30 border-base-300/50 opacity-60"
                    )
                  ]}>
                    <%!-- Content --%>
                    <div class="flex-1 min-w-0">
                      <div class="flex flex-wrap items-center gap-2">
                        <span class={[
                          "font-semibold",
                          if(!enabled, do: "line-through text-base-content/50")
                        ]}>
                          {opt["label"]}
                        </span>
                        <span class="badge badge-ghost badge-sm font-mono">{opt["type"]}</span>
                        <%= if !enabled do %>
                          <span class="badge badge-neutral badge-sm">{gettext("Disabled")}</span>
                        <% end %>
                        <%= if opt["required"] do %>
                          <span class="badge badge-warning badge-sm">{gettext("Required")}</span>
                        <% end %>
                        <%= if opt["unit"] do %>
                          <span class="badge badge-outline badge-sm">{opt["unit"]}</span>
                        <% end %>
                        <%= if opt["affects_price"] do %>
                          <span class="badge badge-success badge-sm">
                            {opt["modifier_type"] || "fixed"}
                          </span>
                          <%= if opt["allow_override"] do %>
                            <span class="badge badge-info badge-sm">{gettext("Override")}</span>
                          <% end %>
                        <% end %>
                      </div>
                      <div class="flex flex-wrap items-center gap-x-3 gap-y-1 mt-1 text-sm text-base-content/50">
                        <code class="bg-base-300/60 px-1.5 py-0.5 rounded text-xs">
                          {opt["key"]}
                        </code>
                        <%= if opt["options"] && opt["options"] != [] do %>
                          <span class="truncate max-w-xs" title={format_options_with_modifiers(opt)}>
                            {format_options_with_modifiers(opt)}
                          </span>
                        <% end %>
                      </div>
                    </div>

                    <%!-- Actions Column --%>
                    <div class="flex items-center gap-1 mt-3 sm:mt-0 sm:ml-4 shrink-0">
                      <label
                        class="swap swap-rotate btn btn-ghost btn-sm tooltip tooltip-bottom"
                        data-tip={if enabled, do: gettext("Disable"), else: gettext("Enable")}
                      >
                        <input
                          type="checkbox"
                          checked={enabled}
                          phx-click="toggle_enabled"
                          phx-value-key={opt["key"]}
                        />
                        <.icon name="hero-eye" class="swap-on w-4 h-4 text-success" />
                        <.icon name="hero-eye-slash" class="swap-off w-4 h-4 text-base-content/40" />
                      </label>
                      <button
                        type="button"
                        phx-click="show_edit_modal"
                        phx-value-key={opt["key"]}
                        class="btn btn-ghost btn-sm tooltip tooltip-bottom"
                        data-tip={gettext("Edit")}
                      >
                        <.icon name="hero-pencil" class="w-4 h-4" />
                      </button>
                      <button
                        type="button"
                        phx-click="delete_option"
                        phx-disable-with="…"
                        phx-value-key={opt["key"]}
                        data-confirm={gettext("Delete this option? This cannot be undone.")}
                        class="btn btn-ghost btn-sm text-error tooltip tooltip-bottom"
                        data-tip={gettext("Delete")}
                      >
                        <.icon name="hero-trash" class="w-4 h-4" />
                      </button>
                    </div>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Reference Section (collapsible) --%>
        <div class="collapse collapse-arrow bg-base-200/50 mt-6">
          <input type="checkbox" />
          <div class="collapse-title font-medium text-sm flex items-center gap-2">
            <.icon name="hero-book-open" class="w-4 h-4" /> {gettext("Option Types Reference")}
          </div>
          <div class="collapse-content">
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-4 pt-2">
              <div>
                <h4 class="text-xs font-semibold text-base-content/50 uppercase tracking-wider mb-2">
                  {gettext("Input Types")}
                </h4>
                <div class="flex flex-wrap gap-1.5">
                  <span class="badge badge-sm">text</span>
                  <span class="badge badge-sm">number</span>
                  <span class="badge badge-sm">boolean</span>
                  <span class="badge badge-sm">select</span>
                  <span class="badge badge-sm">multiselect</span>
                </div>
              </div>
              <div>
                <h4 class="text-xs font-semibold text-base-content/50 uppercase tracking-wider mb-2">
                  {gettext("Price Modifiers")}
                </h4>
                <div class="flex flex-wrap gap-1.5">
                  <span class="badge badge-success badge-sm">fixed (+10)</span>
                  <span class="badge badge-info badge-sm">percent (+20%)</span>
                </div>
                <p class="text-xs text-base-content/50 mt-1.5">
                  {gettext("Enable \"Allow Override\" for per-product values")}
                </p>
              </div>
            </div>
          </div>
        </div>
      </div>

      <%!-- Modal for Add/Edit Option --%>
      <%= if @show_modal do %>
        <div class="modal modal-open">
          <div class="modal-box max-w-lg">
            <button
              type="button"
              phx-click="close_modal"
              class="btn btn-sm btn-circle btn-ghost absolute right-2 top-2"
            >
              <.icon name="hero-x-mark" class="w-4 h-4" />
            </button>
            <h3 class="font-bold text-lg mb-4">
              {if @editing_option, do: gettext("Edit Option"), else: gettext("Add Option")}
            </h3>

            <.form for={%{}} phx-change="validate_form" phx-submit="save_option" class="space-y-4">
              <%!-- Label --%>
              <div class="fieldset">
                <label class="label"><span class="fieldset-legend">{gettext("Label")} *</span></label>
                <input
                  type="text"
                  name="option[label]"
                  value={@form_data.label}
                  class="input"
                  placeholder={gettext("e.g., Material")}
                  required
                />
              </div>

              <%!-- Key --%>
              <div class="fieldset">
                <label class="label"><span class="fieldset-legend">{gettext("Key")}</span></label>
                <input
                  type="text"
                  name="option[key]"
                  value={@form_data.key}
                  class="input font-mono"
                  placeholder={gettext("Auto-generated from label")}
                  disabled={@editing_option != nil}
                />
                <label class="label">
                  <span class="fieldset-label text-base-content/60">
                    {gettext("Lowercase with underscores, auto-generated from label")}
                  </span>
                </label>
              </div>

              <%!-- Type --%>
              <div class="fieldset">
                <label class="label"><span class="fieldset-legend">{gettext("Type")} *</span></label>
                <select name="option[type]" class="select">
                  <%= for type <- @supported_types do %>
                    <option value={type} selected={@form_data.type == type}>
                      {type}
                    </option>
                  <% end %>
                </select>
              </div>

              <%!-- Options (for select/multiselect) --%>
              <%= if @form_data.type in ["select", "multiselect"] do %>
                <div class="fieldset">
                  <label class="label">
                    <span class="fieldset-legend">{gettext("Options")} *</span>
                    <button
                      type="button"
                      phx-click="add_option"
                      class="btn btn-ghost btn-xs"
                    >
                      <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Add")}
                    </button>
                  </label>
                  <div class="space-y-2">
                    <%= for {opt, idx} <- Enum.with_index(@form_data.options) do %>
                      <div class="flex gap-2">
                        <input
                          type="text"
                          name={"option[options][#{idx}]"}
                          value={opt}
                          class="input input-sm flex-1"
                          placeholder={gettext("Option value")}
                        />
                        <button
                          type="button"
                          phx-click="remove_option"
                          phx-value-index={idx}
                          class="btn btn-ghost btn-sm text-error"
                        >
                          <.icon name="hero-x-mark" class="w-4 h-4" />
                        </button>
                      </div>
                    <% end %>
                    <%= if @form_data.options == [] do %>
                      <p class="text-sm text-warning">{gettext("Add at least one option")}</p>
                    <% end %>
                  </div>
                </div>

                <%!-- Affects Price Toggle --%>
                <div class="fieldset">
                  <label class="label cursor-pointer justify-start gap-3">
                    <input
                      type="checkbox"
                      name="option[affects_price]"
                      value="true"
                      checked={@form_data.affects_price}
                      phx-click="toggle_affects_price"
                      class="checkbox checkbox-primary"
                    />
                    <span class="fieldset-legend">{gettext("Affects Price")}</span>
                  </label>
                  <label class="label pt-0">
                    <span class="fieldset-label text-base-content/60">
                      {gettext("Enable to add price modifiers for each option")}
                    </span>
                  </label>
                </div>

                <%!-- Modifier Type and Price Modifiers (when affects_price is true) --%>
                <%= if @form_data.affects_price and @form_data.options != [] do %>
                  <%!-- Modifier Type Selector --%>
                  <div class="fieldset">
                    <label class="label">
                      <span class="fieldset-legend">{gettext("Modifier Type")}</span>
                    </label>
                    <div class="flex flex-wrap gap-4">
                      <label class="label cursor-pointer gap-2">
                        <input
                          type="radio"
                          name="option[modifier_type]"
                          value="fixed"
                          checked={@form_data.modifier_type != "percent"}
                          phx-click="set_modifier_type"
                          phx-value-type="fixed"
                          class="radio radio-primary"
                        />
                        <span class="fieldset-legend">{gettext("Fixed (+10)")}</span>
                      </label>
                      <label class="label cursor-pointer gap-2">
                        <input
                          type="radio"
                          name="option[modifier_type]"
                          value="percent"
                          checked={@form_data.modifier_type == "percent"}
                          phx-click="set_modifier_type"
                          phx-value-type="percent"
                          class="radio radio-primary"
                        />
                        <span class="fieldset-legend">{gettext("Percent (+20%)")}</span>
                      </label>
                    </div>
                  </div>

                  <%!-- Price Modifiers --%>
                  <div class="fieldset">
                    <label class="label">
                      <span class="fieldset-legend">{gettext("Price Modifiers (Default Values)")}</span>
                    </label>
                    <div class="p-4 bg-base-200 rounded-lg space-y-3">
                      <p class="text-sm text-base-content/70 mb-3">
                        <%= if @form_data.modifier_type == "percent" do %>
                          {gettext("Set percentage adjustment for each option (use 0 for no change)")}
                        <% else %>
                          {gettext("Set price adjustment for each option (use 0 for no change)")}
                        <% end %>
                      </p>
                      <%= for opt <- @form_data.options do %>
                        <div class="flex items-center gap-3">
                          <span class="w-32 font-medium truncate" title={opt}>{opt}</span>
                          <span class="text-base-content/60">+</span>
                          <div class="join">
                            <input
                              type="number"
                              step="0.01"
                              min="0"
                              name={"option[price_modifiers][#{opt}]"}
                              value={Map.get(@form_data.price_modifiers, opt, "0")}
                              class="input input-sm join-item w-24"
                              placeholder="0"
                            />
                            <%= if @form_data.modifier_type == "percent" do %>
                              <span class="join-item btn btn-sm btn-disabled">%</span>
                            <% end %>
                          </div>
                        </div>
                      <% end %>
                    </div>
                  </div>

                  <%!-- Allow Override Toggle --%>
                  <div class="fieldset mt-4">
                    <label class="label cursor-pointer justify-start gap-3">
                      <input type="hidden" name="option[allow_override]" value="false" />
                      <input
                        type="checkbox"
                        name="option[allow_override]"
                        value="true"
                        checked={@form_data.allow_override}
                        phx-click="toggle_allow_override"
                        class="checkbox checkbox-primary"
                      />
                      <div>
                        <span class="fieldset-legend font-medium">{gettext("Allow Override Per-Product")}</span>
                        <p class="text-xs text-base-content/60">
                          {gettext("Enable editing price modifiers for each individual product")}
                        </p>
                      </div>
                    </label>
                  </div>
                <% end %>
              <% end %>

              <%!-- Warning for non-select types with affects_price --%>
              <%= if @form_data.affects_price && @form_data.type not in ["select", "multiselect"] do %>
                <div class="alert alert-warning">
                  <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
                  <span>{gettext("Price modifiers only work with Select or Multiselect types")}</span>
                </div>
              <% end %>

              <%!-- Unit --%>
              <div class="fieldset">
                <label class="label"><span class="fieldset-legend">{gettext("Unit (optional)")}</span></label>
                <input
                  type="text"
                  name="option[unit]"
                  value={@form_data.unit}
                  class="input input-sm w-32"
                  placeholder={gettext("e.g., cm, kg")}
                />
              </div>

              <%!-- Required --%>
              <div class="fieldset">
                <label class="label cursor-pointer justify-start gap-3">
                  <input
                    type="checkbox"
                    name="option[required]"
                    value="true"
                    checked={@form_data.required}
                    class="checkbox checkbox-primary"
                  />
                  <span class="fieldset-legend">{gettext("Required field")}</span>
                </label>
              </div>

              <%!-- Actions --%>
              <div class="modal-action">
                <button type="button" phx-click="close_modal" class="btn btn-ghost">
                  {gettext("Cancel")}
                </button>
                <button type="submit" phx-disable-with={gettext("Saving…")} class="btn btn-primary">
                  {if @editing_option, do: gettext("Update"), else: gettext("Create")}
                </button>
              </div>
            </.form>
          </div>
          <div class="modal-backdrop" phx-click="close_modal"></div>
        </div>
      <% end %>
    """
  end

  # Private helpers

  defp initial_form_data do
    %{
      key: "",
      label: "",
      type: "text",
      options: [],
      required: false,
      unit: "",
      affects_price: false,
      modifier_type: "fixed",
      price_modifiers: %{},
      allow_override: false,
      enabled: true
    }
  end

  defp slugify_key(""), do: ""

  defp slugify_key(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s]/, "")
    |> String.replace(~r/\s+/, "_")
    |> String.replace(~r/_+/, "_")
    |> String.trim("_")
  end

  defp parse_form_params(params) do
    options = parse_options(params["options"])

    %{
      key: params["key"] || "",
      label: params["label"] || "",
      type: params["type"] || "text",
      options: options,
      required: params["required"] == "true",
      unit: params["unit"] || "",
      affects_price: params["affects_price"] == "true",
      modifier_type: params["modifier_type"] || "fixed",
      price_modifiers: parse_price_modifiers(params["price_modifiers"], options),
      allow_override: params["allow_override"] == "true"
    }
  end

  defp build_option(form_data) do
    key = if form_data.key == "", do: slugify_key(form_data.label), else: form_data.key

    %{
      "key" => key,
      "label" => form_data.label,
      "type" => form_data.type,
      "required" => form_data.required
    }
    |> maybe_put_options(form_data)
    |> maybe_put_unit(form_data)
    |> maybe_put_price_modifiers(form_data)
  end

  defp maybe_put_options(opt, %{type: type, options: options})
       when type in ["select", "multiselect"],
       do: Map.put(opt, "options", options)

  defp maybe_put_options(opt, _), do: opt

  defp maybe_put_unit(opt, %{unit: ""}), do: opt
  defp maybe_put_unit(opt, %{unit: unit}), do: Map.put(opt, "unit", unit)

  defp maybe_put_price_modifiers(
         opt,
         %{
           type: type,
           affects_price: true,
           modifier_type: modifier_type,
           price_modifiers: mods,
           allow_override: allow_override
         }
       )
       when type in ["select", "multiselect"] do
    opt
    |> Map.put("affects_price", true)
    |> Map.put("modifier_type", modifier_type)
    |> Map.put("price_modifiers", mods)
    |> Map.put("allow_override", allow_override)
  end

  defp maybe_put_price_modifiers(opt, _), do: Map.put(opt, "affects_price", false)

  defp parse_options(nil), do: []

  defp parse_options(options) when is_map(options) do
    options
    # Filter out Phoenix LiveView's hidden _unused_ fields
    |> Enum.reject(fn {k, _v} -> String.starts_with?(k, "_unused") end)
    |> Enum.sort_by(fn {k, _v} ->
      case Integer.parse(k) do
        {num, ""} -> num
        _ -> 0
      end
    end)
    |> Enum.map(fn {_k, v} -> v end)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_options(options) when is_list(options), do: options
  defp parse_options(_), do: []

  defp parse_price_modifiers(nil, _options), do: %{}

  defp parse_price_modifiers(modifiers, options) when is_map(modifiers) do
    # Only keep modifiers for valid options, with valid decimal values
    Enum.reduce(options, %{}, fn opt, acc ->
      value = Map.get(modifiers, opt, "0")
      # Normalize the value to a valid decimal string
      normalized = normalize_price_modifier(value)
      Map.put(acc, opt, normalized)
    end)
  end

  defp parse_price_modifiers(_, _), do: %{}

  defp normalize_price_modifier(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} -> Decimal.to_string(decimal)
      _ -> "0"
    end
  end

  defp normalize_price_modifier(_), do: "0"

  defp format_options_with_modifiers(%{
         "affects_price" => true,
         "options" => options,
         "modifier_type" => modifier_type,
         "price_modifiers" => modifiers
       })
       when is_list(options) and is_map(modifiers) do
    suffix = if modifier_type == "percent", do: "%", else: ""

    Enum.map_join(options, ", ", fn opt ->
      case Map.get(modifiers, opt) do
        nil -> opt
        "0" -> opt
        mod -> "#{opt} (+#{mod}#{suffix})"
      end
    end)
  end

  defp format_options_with_modifiers(%{
         "affects_price" => true,
         "options" => options,
         "price_modifiers" => modifiers
       })
       when is_list(options) and is_map(modifiers) do
    # Default to fixed for backward compatibility
    Enum.map_join(options, ", ", fn opt ->
      case Map.get(modifiers, opt) do
        nil -> opt
        "0" -> opt
        mod -> "#{opt} (+#{mod})"
      end
    end)
  end

  defp format_options_with_modifiers(%{"options" => options}) when is_list(options) do
    Enum.join(options, ", ")
  end

  defp format_options_with_modifiers(_), do: ""

  defp gated_event("save_option", %{"option" => params}, socket) do
    form_data = parse_form_params(params)
    editing = socket.assigns.editing_option
    opt = form_data |> build_option() |> keep_editing_key(editing)
    action = if editing, do: "shop.global_option_updated", else: "shop.global_option_created"

    case save_option_change(editing, opt) do
      {:ok, _} ->
        log_option(socket, action, opt["key"], %{"type" => opt["type"]})

        {:noreply,
         socket
         |> reload_options()
         |> assign(:show_modal, false)
         |> assign(:editing_option, nil)
         |> assign(:form_data, initial_form_data())
         |> put_flash(
           :info,
           if(editing, do: gettext("Option updated"), else: gettext("Option created"))
         )}

      {:error, reason} ->
        log_option_failed(socket, action, opt["key"], reason)
        {:noreply, socket |> reload_options() |> put_flash(:error, Errors.message(reason))}
    end
  end

  defp gated_event("delete_option", %{"key" => key}, socket) do
    case Options.remove_global_option(key) do
      {:ok, _} ->
        log_option(socket, "shop.global_option_deleted", key)

        {:noreply, socket |> reload_options() |> put_flash(:info, gettext("Option deleted"))}

      {:error, reason} ->
        log_option_failed(socket, "shop.global_option_deleted", key, reason)
        {:noreply, socket |> reload_options() |> put_flash(:error, Errors.message(reason))}
    end
  end

  defp gated_event("toggle_enabled", %{"key" => key}, socket) do
    case Options.toggle_global_option(key) do
      {:ok, _} ->
        socket = reload_options(socket)
        toggled = Enum.find(socket.assigns.options, &(&1["key"] == key)) || %{}
        enabled? = Map.get(toggled, "enabled", true)
        log_option(socket, "shop.global_option_toggled", key, %{"enabled" => enabled?})

        message =
          if enabled?,
            do: gettext("Option %{key} enabled", key: key),
            else: gettext("Option %{key} disabled", key: key)

        {:noreply, put_flash(socket, :info, message)}

      {:error, reason} ->
        log_option_failed(socket, "shop.global_option_toggled", key, reason)
        {:noreply, socket |> reload_options() |> put_flash(:error, Errors.message(reason))}
    end
  end

  defp gated_event("reorder_options", %{"ordered_ids" => ordered_keys}, socket)
       when is_list(ordered_keys) do
    ordered_keys = Enum.filter(ordered_keys, &is_binary/1)

    case Options.reorder_global_options(ordered_keys) do
      {:ok, _} ->
        Activity.log("shop.global_options_reordered",
          actor_uuid: Activity.actor_uuid(socket),
          actor_role: Activity.actor_role(socket),
          resource_type: "global_option",
          metadata: %{"count" => length(ordered_keys)}
        )

        {:noreply, reload_options(socket)}

      {:error, reason} ->
        log_option_failed(socket, "shop.global_options_reordered", nil, reason)
        {:noreply, socket |> reload_options() |> put_flash(:error, Errors.message(reason))}
    end
  end

  defp gated_event(_event, _params, socket), do: {:noreply, socket}
end
