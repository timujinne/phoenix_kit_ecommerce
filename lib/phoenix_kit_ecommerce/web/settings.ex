defmodule PhoenixKitEcommerce.Web.Settings do
  @moduledoc """
  E-Commerce module settings LiveView.

  Allows configuration of e-commerce settings including inventory tracking.
  """

  use PhoenixKitEcommerce.Web, :live_view

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Activity
  alias PhoenixKitEcommerce.Notifications, as: ShopNotifications
  alias PhoenixKitEcommerce.Policy
  alias PhoenixKitEcommerce.TranslationSweepSettings
  alias PhoenixKitEcommerce.Vocabulary
  alias PhoenixKitEcommerce.Web.Authz
  alias PhoenixKitEcommerce.Web.Helpers

  # phoenix_kit_ai is an OPTIONAL dependency (see mix.exs) — this page must
  # compile and render fine without it. See `ai_translations_available?/0`.
  @compile {:no_warn_undefined, PhoenixKitAI.Translations}

  @impl true
  def mount(_params, _session, socket) do
    config = Shop.get_config()

    # Load storefront filter configuration; surface built-in filters
    # (e.g. search) missing from configs saved before they existed
    storefront_filters =
      Shop.get_storefront_filters()
      |> Shop.merge_missing_builtin_filters()

    discovered_options = Shop.discover_filterable_options()

    socket =
      socket
      |> assign(:page_title, gettext("E-Commerce Settings"))
      |> assign(:enabled, config.enabled)
      |> assign(:inventory_tracking, config.inventory_tracking)
      |> assign(:billing_enabled, billing_enabled?())
      |> assign(:category_name_display, get_category_name_display())
      |> assign(:catalog_vocabulary, Vocabulary.current())
      |> assign(:hide_zero_decimals, Helpers.hide_zero_decimals?())
      |> assign(:category_icon_mode, get_category_icon_mode())
      |> assign(:sidebar_show_categories, get_sidebar_show_categories())
      |> assign(:show_cart_bar, get_show_cart_bar())
      |> assign(:storefront_filters, storefront_filters)
      |> assign(:discovered_options, discovered_options)
      |> assign(
        :notify_cart_first_item,
        Settings.get_setting_cached("shop_notify_cart_first_item", "false") == "true"
      )
      |> assign(
        :notify_cart_item,
        Settings.get_setting_cached("shop_notify_cart_item", "false") == "true"
      )
      |> assign(
        :notify_checkout_started,
        Settings.get_setting_cached("shop_notify_checkout_started", "false") == "true"
      )
      |> assign(:notification_recipients, notification_recipients())
      |> assign(:recipient_candidates, load_recipient_candidates())
      |> assign(:shipping_skip_mode, to_string(Shop.shipping_skip_mode()))
      |> assign(:shipping_selection_position, to_string(Shop.shipping_selection_position()))
      |> assign(:shop_translations_enabled, TranslationSweepSettings.translations_enabled?())
      |> assign(:ai_translations_available, ai_translations_available?())
      |> assign_policy()

    {:ok, socket}
  end

  # Guarded the same way `Web.Translations` and `TranslationSweepWorker`
  # guard it — `phoenix_kit_ai` is an OPTIONAL dependency (mix.exs), so a
  # host without it installed must see this toggle rendered disabled with
  # an explanation, never crash the settings page.
  defp ai_translations_available? do
    Code.ensure_loaded?(PhoenixKitAI.Translations) and
      function_exported?(PhoenixKitAI.Translations, :available?, 0) and
      PhoenixKitAI.Translations.available?() and
      not is_nil(PhoenixKitAI.Translations.default_endpoint_uuid())
  end

  # Stored as `%{"uuids" => [...]}` — core's `value_json` column casts
  # through an Ecto `:map` field, which rejects a top-level list at the
  # changeset (see `PhoenixKitEcommerce.Notifications.shop_recipients/0`).
  defp notification_recipients do
    case Settings.get_json_setting_cached("shop_notification_recipients", %{}) do
      %{"uuids" => uuids} when is_list(uuids) -> uuids
      _ -> []
    end
  end

  defp load_recipient_candidates do
    ShopNotifications.admin_recipients("shop.manage_carts")
    |> Enum.map(&Auth.get_user/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.email)
  end

  # Read every policy toggle through PhoenixKitEcommerce.Policy so the admin
  # UI and the enforcement points can never disagree about a default.
  defp assign_policy(socket) do
    socket
    |> assign(:order_lookup_strict, Policy.order_lookup_policy() == :strict)
    |> assign(:allow_raw_html, Policy.allow_raw_html_descriptions?())
    |> assign(:allow_svg, Policy.allow_svg_uploads?())
    |> assign(:allow_private_networks, Policy.image_import_allow_private_networks?())
    |> assign(:cleanup_auto_created_only, Policy.import_cleanup_scope() == :auto_created)
    |> assign(:default_tax_country, Policy.default_tax_country() || "")
  end

  defp get_category_name_display do
    Settings.get_setting_cached("shop_category_name_display", "truncate")
  end

  defp get_category_icon_mode do
    Settings.get_setting_cached("shop_category_icon_mode", "none")
  end

  defp get_show_cart_bar do
    Settings.get_setting_cached("shop_show_cart_bar", "true") == "true"
  end

  defp get_sidebar_show_categories do
    Settings.get_setting_cached("shop_sidebar_show_categories", "true") == "true"
  end

  @impl true
  def handle_event("toggle_order_lookup_policy", params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      gated_event("toggle_order_lookup_policy", params, socket)
    end)
  end

  @impl true
  def handle_event("toggle_allow_raw_html", params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      gated_event("toggle_allow_raw_html", params, socket)
    end)
  end

  @impl true
  def handle_event("toggle_allow_svg", params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      gated_event("toggle_allow_svg", params, socket)
    end)
  end

  @impl true
  def handle_event("toggle_allow_private_networks", params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      gated_event("toggle_allow_private_networks", params, socket)
    end)
  end

  @impl true
  def handle_event("toggle_import_cleanup_scope", params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      gated_event("toggle_import_cleanup_scope", params, socket)
    end)
  end

  @impl true
  def handle_event("save_default_tax_country", params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      gated_event("save_default_tax_country", params, socket)
    end)
  end

  @impl true
  def handle_event("toggle_inventory_tracking", params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      gated_event("toggle_inventory_tracking", params, socket)
    end)
  end

  @impl true
  def handle_event("toggle_notify_cart_first_item", params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      gated_event("toggle_notify_cart_first_item", params, socket)
    end)
  end

  @impl true
  def handle_event("toggle_notify_cart_item", params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      gated_event("toggle_notify_cart_item", params, socket)
    end)
  end

  @impl true
  def handle_event("toggle_notify_checkout_started", params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      gated_event("toggle_notify_checkout_started", params, socket)
    end)
  end

  @impl true
  def handle_event("save_notification_recipients", params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      gated_event("save_notification_recipients", params, socket)
    end)
  end

  @impl true
  def handle_event("update_shipping_skip_mode", params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      gated_event("update_shipping_skip_mode", params, socket)
    end)
  end

  @impl true
  def handle_event("update_shipping_selection_position", params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      gated_event("update_shipping_selection_position", params, socket)
    end)
  end

  @impl true
  def handle_event("toggle_hide_zero_decimals", params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      gated_event("toggle_hide_zero_decimals", params, socket)
    end)
  end

  @impl true
  def handle_event("update_catalog_vocabulary", params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      gated_event("update_catalog_vocabulary", params, socket)
    end)
  end

  @impl true
  def handle_event("update_category_display", params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      gated_event("update_category_display", params, socket)
    end)
  end

  @impl true
  def handle_event("toggle_sidebar_categories", params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      gated_event("toggle_sidebar_categories", params, socket)
    end)
  end

  @impl true
  def handle_event("toggle_cart_bar", params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      gated_event("toggle_cart_bar", params, socket)
    end)
  end

  @impl true
  def handle_event("toggle_shop_translations_enabled", params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      gated_event("toggle_shop_translations_enabled", params, socket)
    end)
  end

  @impl true
  def handle_event("update_category_icon", params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      gated_event("update_category_icon", params, socket)
    end)
  end

  @impl true
  def handle_event("toggle_storefront_filter", params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      gated_event("toggle_storefront_filter", params, socket)
    end)
  end

  @impl true
  def handle_event("update_filter_label", params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      gated_event("update_filter_label", params, socket)
    end)
  end

  @impl true
  def handle_event("add_metadata_filter", params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      gated_event("add_metadata_filter", params, socket)
    end)
  end

  @impl true
  def handle_event("remove_filter", params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      gated_event("remove_filter", params, socket)
    end)
  end

  @impl true
  def handle_event("reset_default_filters", params, socket) do
    Authz.authorize(socket, :manage_settings, fn ->
      gated_event("reset_default_filters", params, socket)
    end)
  end

  defp flip(true), do: "false"
  defp flip(false), do: "true"

  # Every policy change is audited.
  #
  # These six toggles flip SSRF protection, raw-HTML rendering, SVG
  # uploads, order-lookup authorization, import cleanup scope and the tax
  # fallback — precisely the settings an audit trail exists for. "Who
  # turned off description sanitizing, and when" is the first question
  # anyone asks after an incident, and without this the answer was
  # nowhere. All six funnel through here, so one call covers them.
  #
  # The value is safe to record: these are policy names and a country
  # code, never user data.
  defp save_policy(socket, key, value, message) do
    case Settings.update_setting(key, value) do
      {:ok, _} ->
        Activity.log("shop.policy_updated",
          actor_uuid: Activity.actor_uuid(socket),
          actor_role: Activity.actor_role(socket),
          resource_type: "setting",
          metadata: %{"setting" => key, "value" => value}
        )

        {:noreply, socket |> assign_policy() |> put_flash(:info, message)}

      {:error, _} ->
        Activity.log("shop.policy_update_failed",
          actor_uuid: Activity.actor_uuid(socket),
          actor_role: Activity.actor_role(socket),
          resource_type: "setting",
          metadata: %{"setting" => key, "value" => value}
        )

        {:noreply, put_flash(socket, :error, gettext("Failed to update setting"))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
      <div class="container flex-col mx-auto px-4 py-6 max-w-5xl">
        <.admin_page_header
          back={Routes.path("/admin/shop")}
          title={gettext("E-Commerce Settings")}
          subtitle={gettext("Configure your e-commerce store")}
        />

        <%!-- Inventory Settings (toggle pattern) --%>
        <div class="card bg-base-100 shadow-xl mb-6">
          <div class="card-body">
            <h2 class="card-title text-xl mb-6">
              <.icon name="hero-archive-box" class="w-6 h-6" /> Inventory
            </h2>

            <div class="fieldset">
              <label class="label cursor-pointer justify-between">
                <span class="fieldset-legend text-lg">
                  <span class="font-semibold">{gettext("Track Inventory")}</span>
                  <div class="text-sm text-base-content/70 mt-1">
                    {gettext("Enable stock tracking for products (Phase 2)")}
                  </div>
                </span>
                <input
                  type="checkbox"
                  class="toggle toggle-secondary"
                  checked={@inventory_tracking}
                  phx-click="toggle_inventory_tracking"
                />
              </label>
            </div>
          </div>
        </div>

        <%!-- Shipping requirement & where it is picked. Both settings were
             read by the storefront and the conversion from the day they
             landed, but had no UI at all — the only way to change them was
             to write the setting row by hand. --%>
        <div class="card bg-base-100 shadow-xl mb-6" id="shop-shipping-modes-card">
          <div class="card-body">
            <h2 class="card-title">{gettext("Shipping requirement")}</h2>

            <div class="fieldset">
              <p class="text-sm text-base-content/70 mb-3">
                {gettext(
                  "What happens when no active shipping method covers the buyer's country."
                )}
              </p>
              <div class="flex flex-col gap-2">
                <label
                  :for={
                    {value, label} <- [
                      {"off", gettext("Require a shipping method (default)")},
                      {"fallback",
                       gettext(
                         "Allow the order through when nothing covers the country - contact the buyer afterwards"
                       )},
                      {"always", gettext("Never ask for a shipping method")}
                    ]
                  }
                  class="label cursor-pointer justify-start gap-3"
                >
                  <input
                    type="radio"
                    name="shipping_skip_mode"
                    class="radio radio-primary"
                    id={"shipping-skip-mode-#{value}"}
                    value={value}
                    checked={@shipping_skip_mode == value}
                    phx-click="update_shipping_skip_mode"
                    phx-value-mode={value}
                  />
                  <span class="fieldset-legend">{label}</span>
                </label>
              </div>
            </div>

            <div class="divider"></div>

            <div class="fieldset">
              <label class="label">
                <span class="fieldset-legend text-lg font-semibold">
                  {gettext("Where the buyer picks a shipping method")}
                </span>
              </label>
              <p class="text-sm text-base-content/70 mb-3">
                {gettext(
                  "On the cart page the destination country is not known yet, so every method is listed. As a checkout step after billing, methods are filtered by the real country."
                )}
              </p>
              <div class="flex flex-col gap-2">
                <label
                  :for={
                    {value, label} <- [
                      {"cart", gettext("Cart page (default)")},
                      {"checkout", gettext("Checkout step, after billing")}
                    ]
                  }
                  class="label cursor-pointer justify-start gap-3"
                >
                  <input
                    type="radio"
                    name="shipping_selection_position"
                    class="radio radio-primary"
                    id={"shipping-position-#{value}"}
                    value={value}
                    checked={@shipping_selection_position == value}
                    phx-click="update_shipping_selection_position"
                    phx-value-position={value}
                  />
                  <span class="fieldset-legend">{label}</span>
                </label>
              </div>
            </div>
          </div>
        </div>

        <%!-- Storefront notifications --%>
        <div class="card bg-base-100 shadow-xl mb-6" id="shop-notifications-card">
          <div class="card-body">
            <h2 class="card-title">{gettext("Storefront notifications")}</h2>
            <p class="text-sm text-base-content/60">
              {gettext(
                "Notify shop operators about cart activity. Delivery uses each recipient's own notification channels (email, Telegram, in-app)."
              )}
            </p>

            <div class="fieldset">
              <label class="label cursor-pointer justify-between">
                <span class="fieldset-legend">{gettext("First item added to a cart")}</span>
                <input
                  type="checkbox"
                  class="toggle toggle-secondary"
                  id="toggle-notify-cart-first-item"
                  checked={@notify_cart_first_item}
                  phx-click="toggle_notify_cart_first_item"
                />
              </label>
            </div>
            <div class="fieldset">
              <label class="label cursor-pointer justify-between">
                <span class="fieldset-legend">{gettext("Every item added to a cart")}</span>
                <input
                  type="checkbox"
                  class="toggle toggle-secondary"
                  id="toggle-notify-cart-item"
                  checked={@notify_cart_item}
                  phx-click="toggle_notify_cart_item"
                />
              </label>
            </div>
            <div class="fieldset">
              <label class="label cursor-pointer justify-between">
                <span class="fieldset-legend">{gettext("Buyer proceeded to checkout")}</span>
                <input
                  type="checkbox"
                  class="toggle toggle-secondary"
                  id="toggle-notify-checkout-started"
                  checked={@notify_checkout_started}
                  phx-click="toggle_notify_checkout_started"
                />
              </label>
            </div>

            <form
              phx-submit="save_notification_recipients"
              id="shop-notification-recipients-form"
              class="mt-4"
            >
              <h3 class="font-medium mb-1">{gettext("Recipients")}</h3>
              <p class="text-xs text-base-content/60 mb-2">
                {gettext(
                  "Applies to the cart-activity notifications above. Leave all unchecked to notify every shop administrator."
                )}
              </p>
              <%= for user <- @recipient_candidates do %>
                <label class="label cursor-pointer justify-start gap-3">
                  <input
                    type="checkbox"
                    class="checkbox checkbox-sm"
                    name={"recipients[#{user.uuid}]"}
                    value="true"
                    checked={user.uuid in @notification_recipients}
                  />
                  <span class="fieldset-legend">{user.email}</span>
                </label>
              <% end %>
              <button type="submit" class="btn btn-primary btn-sm mt-2">
                {gettext("Save recipients")}
              </button>
            </form>
          </div>
        </div>

        <%!-- Security & Privacy --%>
        <div class="card bg-base-100 shadow-xl mb-6">
          <div class="card-body">
            <h2 class="card-title text-xl mb-2">
              <.icon name="hero-shield-check" class="w-6 h-6" />
              {gettext("Security & Privacy")}
            </h2>
            <p class="text-sm text-base-content/70 mb-6">
              {gettext(
                "These default to the safe option. Change one only if you understand what it opens up — each is explained below."
              )}
            </p>

            <div class="fieldset mb-4">
              <label class="label cursor-pointer justify-between">
                <span class="fieldset-legend text-lg">
                  <span class="font-semibold">{gettext("Order pages need the buyer's session")}</span>
                  <div class="text-sm text-base-content/70 mt-1">
                    {gettext(
                      "On: an order confirmation page opens only for the person who placed the order. Off: anyone with the order link can read its name, address, phone and email — turn this off only if you deliberately mail shareable order links."
                    )}
                  </div>
                </span>
                <input
                  type="checkbox"
                  class="toggle toggle-secondary"
                  checked={@order_lookup_strict}
                  phx-click="toggle_order_lookup_policy"
                />
              </label>
            </div>

            <div class="fieldset mb-4">
              <label class="label cursor-pointer justify-between">
                <span class="fieldset-legend text-lg">
                  <span class="font-semibold">{gettext("Allow raw HTML in product descriptions")}</span>
                  <div class="text-sm text-base-content/70 mt-1">
                    {gettext(
                      "Off (recommended): descriptions are sanitized before display. On: descriptions render as-is, which trusts everyone who can edit a product — or supply a CSV import — with running scripts in every shopper's browser."
                    )}
                  </div>
                </span>
                <input
                  type="checkbox"
                  class="toggle toggle-warning"
                  checked={@allow_raw_html}
                  phx-click="toggle_allow_raw_html"
                />
              </label>
            </div>

            <div class="fieldset mb-4">
              <label class="label cursor-pointer justify-between">
                <span class="fieldset-legend text-lg">
                  <span class="font-semibold">{gettext("Allow SVG images from import")}</span>
                  <div class="text-sm text-base-content/70 mt-1">
                    {gettext(
                      "Off (recommended): SVG files are rejected by the image importer. SVG can carry scripts and stored images are served inline."
                    )}
                  </div>
                </span>
                <input
                  type="checkbox"
                  class="toggle toggle-warning"
                  checked={@allow_svg}
                  phx-click="toggle_allow_svg"
                />
              </label>
            </div>

            <div class="fieldset">
              <label class="label cursor-pointer justify-between">
                <span class="fieldset-legend text-lg">
                  <span class="font-semibold">
                    {gettext("Let image import reach internal addresses")}
                  </span>
                  <div class="text-sm text-base-content/70 mt-1">
                    {gettext(
                      "Off (recommended): the importer refuses private and loopback addresses. Turn on only when importing from an image host inside your own network."
                    )}
                  </div>
                </span>
                <input
                  type="checkbox"
                  class="toggle toggle-warning"
                  checked={@allow_private_networks}
                  phx-click="toggle_allow_private_networks"
                />
              </label>
            </div>
          </div>
        </div>

        <%!-- Import behaviour --%>
        <div class="card bg-base-100 shadow-xl mb-6">
          <div class="card-body">
            <h2 class="card-title text-xl mb-6">
              <.icon name="hero-arrow-down-tray" class="w-6 h-6" />
              {gettext("Import Behaviour")}
            </h2>

            <div class="fieldset">
              <label class="label cursor-pointer justify-between">
                <span class="fieldset-legend text-lg">
                  <span class="font-semibold">
                    {gettext("Cleanup removes only categories the import created")}
                  </span>
                  <div class="text-sm text-base-content/70 mt-1">
                    {gettext(
                      "On (recommended): the post-import cleanup only deletes empty categories that the import itself created. Off: it deletes every empty category in your catalog, including ones you left empty on purpose."
                    )}
                  </div>
                </span>
                <input
                  type="checkbox"
                  class="toggle toggle-secondary"
                  checked={@cleanup_auto_created_only}
                  phx-click="toggle_import_cleanup_scope"
                />
              </label>
            </div>
          </div>
        </div>

        <%!-- AI Translations existence toggle (design §4.6). The operational
             knobs (sweep on/off, interval, batch, ceiling, languages,
             statuses) live on the translations page itself, not here — the
             operator changes the sweep's pace where they see its effect
             (design §4.5). This card owns only whether the feature EXISTS
             at all: the page, the sidebar entry, the manual actions. --%>
        <div class="card bg-base-100 shadow-xl mb-6" id="shop-translations-card">
          <div class="card-body">
            <h2 class="card-title text-xl mb-2">
              <.icon name="hero-language" class="w-6 h-6" />
              {gettext("AI Translations")}
            </h2>
            <p class="text-sm text-base-content/70 mb-4">
              {gettext(
                "Turns on AI-powered translation of products and categories: the management page, its sidebar entry, and manual translate/stamp/reset actions. Requires a configured AI endpoint."
              )}
            </p>

            <div class="fieldset">
              <label class="label cursor-pointer justify-between">
                <span class="fieldset-legend text-lg">
                  <span class="font-semibold">{gettext("Enable shop translations")}</span>
                  <div :if={not @ai_translations_available} class="text-sm text-warning mt-1">
                    {gettext(
                      "Configure an enabled AI endpoint in the AI section first — this stays off until one exists."
                    )}
                  </div>
                </span>
                <input
                  id="toggle-shop-translations-enabled"
                  type="checkbox"
                  class="toggle toggle-secondary"
                  checked={@shop_translations_enabled}
                  disabled={not @ai_translations_available and not @shop_translations_enabled}
                  phx-click="toggle_shop_translations_enabled"
                />
              </label>
            </div>

            <.link
              :if={@shop_translations_enabled}
              navigate={Routes.path("/admin/shop/translations")}
              class="link link-primary text-sm"
            >
              {gettext("Open the translations page →")}
            </.link>
          </div>
        </div>

        <%!-- Tax fallback --%>
        <div class="card bg-base-100 shadow-xl mb-6">
          <div class="card-body">
            <h2 class="card-title text-xl mb-2">
              <.icon name="hero-receipt-percent" class="w-6 h-6" />
              {gettext("Tax Fallback Country")}
            </h2>
            <p class="text-sm text-base-content/70 mb-4">
              {gettext(
                "Optional. Tax is normally calculated from the address collected at checkout. Set a two-letter country code here if your shop is single-jurisdiction and should charge tax even before an address is supplied. Leave blank to charge tax only against a real address."
              )}
            </p>
            <form phx-submit="save_default_tax_country" class="flex gap-2 items-center">
              <input
                type="text"
                name="country"
                value={@default_tax_country}
                maxlength="2"
                placeholder={gettext("e.g. EE")}
                class="input w-32 uppercase"
              />
              <button type="submit" class="btn btn-primary btn-sm">{gettext("Save")}</button>
            </form>
          </div>
        </div>

        <%!-- Info about Billing --%>
        <div class="alert alert-info mb-6">
          <.icon name="hero-information-circle" class="w-6 h-6" />
          <div>
            <h3 class="font-bold">{gettext("Currency & Tax Settings")}</h3>
            <p class="text-sm">
              {gettext("Currency and tax configuration is managed in the")}
              <.link navigate={Routes.path("/admin/settings/billing")} class="link font-medium">
                {gettext("Billing module settings")}
              </.link>
            </p>
          </div>
        </div>

        <%!-- Product Options --%>
        <div class="card bg-base-100 shadow-xl mb-6">
          <div class="card-body">
            <h2 class="card-title text-xl mb-6">
              <.icon name="hero-tag" class="w-6 h-6" /> {gettext("Product Options")}
            </h2>

            <div class="fieldset">
              <label class="label cursor-pointer justify-between">
                <span class="fieldset-legend text-lg">
                  <span class="font-semibold">{gettext("Global Product Options")}</span>
                  <div class="text-sm text-base-content/70 mt-1">
                    {gettext("Define options that apply to all products (size, color, material, etc.)")}
                  </div>
                  <div class="text-xs text-base-content/50 mt-1">
                    {gettext("Price override is configured per-option in the options settings.")}
                  </div>
                </span>
                <.link
                  navigate={Routes.path("/admin/shop/settings/options")}
                  class="btn btn-primary"
                >
                  <.icon name="hero-cog-6-tooth" class="w-4 h-4 mr-2" /> {gettext("Configure")}
                </.link>
              </label>
            </div>
          </div>
        </div>

        <%!-- Import Configurations --%>
        <div class="card bg-base-100 shadow-xl mb-6">
          <div class="card-body">
            <h2 class="card-title text-xl mb-6">
              <.icon name="hero-funnel" class="w-6 h-6" /> {gettext("Import Configurations")}
            </h2>

            <div class="fieldset">
              <label class="label cursor-pointer justify-between">
                <span class="fieldset-legend text-lg">
                  <span class="font-semibold">{gettext("CSV Import Filters")}</span>
                  <div class="text-sm text-base-content/70 mt-1">
                    {gettext("Configure keyword filters and category rules for CSV product imports")}
                  </div>
                </span>
                <.link
                  navigate={Routes.path("/admin/shop/settings/import-configs")}
                  class="btn btn-primary"
                >
                  <.icon name="hero-cog-6-tooth" class="w-4 h-4 mr-2" /> {gettext("Configure")}
                </.link>
              </label>
            </div>
          </div>
        </div>

        <%!-- Shopify Sync --%>
        <div class="card bg-base-100 shadow-xl mb-6">
          <div class="card-body">
            <h2 class="card-title text-xl mb-6">
              <.icon name="hero-arrow-path" class="w-6 h-6" /> {gettext("Shopify Sync")}
            </h2>

            <div class="fieldset">
              <label class="label cursor-pointer justify-between">
                <span class="fieldset-legend text-lg">
                  <span class="font-semibold">{gettext("One-way sync from Shopify")}</span>
                  <div class="text-sm text-base-content/70 mt-1">
                    {gettext(
                      "Connect a Shopify Admin API token in Integrations settings, then review and apply catalog changes from the Shopify Sync page."
                    )}
                  </div>
                </span>
                <div class="flex gap-2">
                  <.link
                    navigate={Routes.path("/admin/settings/integrations/website")}
                    class="btn btn-ghost"
                  >
                    {gettext("Connect")}
                  </.link>
                  <.link navigate={Routes.path("/admin/shop/shopify-sync")} class="btn btn-primary">
                    <.icon name="hero-arrow-path" class="w-4 h-4 mr-2" /> {gettext("Open Sync")}
                  </.link>
                </div>
              </label>
            </div>
          </div>
        </div>

        <%!-- Storefront Filters --%>
        <div class="card bg-base-100 shadow-xl mb-6">
          <div class="card-body">
            <div class="flex items-center justify-between mb-6">
              <h2 class="card-title text-xl">
                <.icon name="hero-funnel" class="w-6 h-6" /> {gettext("Storefront Filters")}
              </h2>
              <button phx-click="reset_default_filters" class="btn btn-ghost btn-xs">
                {gettext("Reset to defaults")}
              </button>
            </div>

            <p class="text-sm text-base-content/70 mb-4">
              {gettext(
                "Configure product filters shown on the storefront sidebar. Customers can search by name, SKU, or tags, and filter by price, vendor, and product options."
              )}
            </p>

            <%!-- Current Filters Table --%>
            <div class="overflow-x-auto">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>{gettext("Filter")}</th>
                    <th>{gettext("Type")}</th>
                    <th>{gettext("Label")}</th>
                    <th>{gettext("Enabled")}</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  <%= for filter <- @storefront_filters do %>
                    <tr>
                      <td class="font-mono text-sm">{filter["key"]}</td>
                      <td>
                        <span class="badge badge-ghost badge-sm">{filter["type"]}</span>
                      </td>
                      <td>
                        <form phx-change="update_filter_label" phx-debounce="500">
                          <input type="hidden" name="key" value={filter["key"]} />
                          <input
                            type="text"
                            name="label"
                            value={filter["label"]}
                            class="input input-xs w-32"
                          />
                        </form>
                      </td>
                      <td>
                        <input
                          type="checkbox"
                          class="toggle toggle-primary toggle-sm"
                          checked={filter["enabled"]}
                          phx-click="toggle_storefront_filter"
                          phx-value-key={filter["key"]}
                        />
                      </td>
                      <td>
                        <%= if filter["type"] == "metadata_option" do %>
                          <button
                            phx-click="remove_filter"
                            phx-value-key={filter["key"]}
                            class="btn btn-outline btn-error btn-xs tooltip tooltip-bottom"
                            data-tip={gettext("Remove")}
                            data-confirm={gettext("Remove this filter?")}
                          >
                            <.icon name="hero-trash" class="w-4 h-4 hidden sm:inline" />
                            <span class="sm:hidden whitespace-nowrap">{gettext("Remove")}</span>
                          </button>
                        <% end %>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>

            <%!-- Auto-discovered option keys --%>
            <%= if @discovered_options != [] do %>
              <div class="divider">{gettext("Available Product Options")}</div>
              <p class="text-sm text-base-content/70 mb-3">
                {gettext("These option keys were found in product metadata. Click to add as a filter.")}
              </p>
              <div class="flex flex-wrap gap-2">
                <% existing_keys = Enum.map(@storefront_filters, & &1["key"]) %>
                <%= for opt <- @discovered_options do %>
                  <%= if opt.key not in existing_keys do %>
                    <button
                      phx-click="add_metadata_filter"
                      phx-value-key={opt.key}
                      class="btn btn-outline btn-sm gap-1"
                    >
                      <.icon name="hero-plus" class="w-3 h-3" />
                      {opt.key}
                      <span class="badge badge-ghost badge-xs">{opt.count} products</span>
                    </button>
                  <% end %>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Sidebar Display Settings --%>
        <div class="card bg-base-100 shadow-xl mb-6">
          <div class="card-body">
            <h2 class="card-title text-xl mb-6">
              <.icon name="hero-bars-3" class="w-6 h-6" /> {gettext("Sidebar Display")}
            </h2>

            <%!-- Show Categories in Shop --%>
            <div class="fieldset mb-6">
              <label class="label cursor-pointer justify-between">
                <span class="fieldset-legend text-lg">
                  <span class="font-semibold">{gettext("Show Categories in Shop")}</span>
                  <div class="text-sm text-base-content/70 mt-1">
                    {gettext("Display category cards above products in the main shop page")}
                  </div>
                </span>
                <input
                  type="checkbox"
                  class="toggle toggle-primary"
                  checked={@sidebar_show_categories}
                  phx-click="toggle_sidebar_categories"
                />
              </label>
            </div>

            <div class="divider"></div>

            <%!-- Storefront cart bar --%>
            <div class="fieldset mb-6">
              <label class="label cursor-pointer justify-between">
                <span class="fieldset-legend text-lg">
                  <span class="font-semibold">{gettext("Show the storefront cart bar")}</span>
                  <div class="text-sm text-base-content/70 mt-1">
                    {gettext(
                      "A compact Shop / Cart bar on catalog pages. Turn it off if your own site header already links to the cart."
                    )}
                  </div>
                </span>
                <input
                  type="checkbox"
                  class="toggle toggle-primary"
                  checked={@show_cart_bar}
                  phx-click="toggle_cart_bar"
                />
              </label>
            </div>

            <div class="divider"></div>

            <%!-- Category Name Display --%>
            <div class="fieldset mb-6">
              <label class="label">
                <span class="fieldset-legend text-lg font-semibold">{gettext("Category Name Display")}</span>
              </label>
              <p class="text-sm text-base-content/70 mb-3">
                {gettext("How category names should be displayed in the sidebar")}
              </p>
              <div class="flex gap-4">
                <label class="label cursor-pointer gap-2">
                  <input
                    type="radio"
                    name="category_display"
                    class="radio radio-primary"
                    value="truncate"
                    checked={@category_name_display == "truncate"}
                    phx-click="update_category_display"
                    phx-value-display="truncate"
                  />
                  <span class="fieldset-legend">{gettext("Truncate (single line)")}</span>
                </label>
                <label class="label cursor-pointer gap-2">
                  <input
                    type="radio"
                    name="category_display"
                    class="radio radio-primary"
                    value="wrap"
                    checked={@category_name_display == "wrap"}
                    phx-click="update_category_display"
                    phx-value-display="wrap"
                  />
                  <span class="fieldset-legend">{gettext("Wrap (multi-line)")}</span>
                </label>
              </div>
            </div>

            <div class="divider"></div>

            <div>
              <h3 class="font-medium mb-1">{gettext("Price format")}</h3>
              <p class="text-sm text-base-content/60 mb-3">
                {gettext(
                  "Storefront only. Invoices and receipts always keep two decimals."
                )}
              </p>
              <label class="label cursor-pointer gap-2 justify-start">
                <input
                  type="checkbox"
                  class="checkbox checkbox-primary"
                  checked={@hide_zero_decimals}
                  phx-click="toggle_hide_zero_decimals"
                />
                <span class="fieldset-legend">{gettext("Hide .00 on whole prices (40 instead of 40.00)")}</span>
              </label>
            </div>

            <div class="divider"></div>

            <div>
              <h3 class="font-medium mb-1">{gettext("Catalogue vocabulary")}</h3>
              <p class="text-sm text-base-content/60 mb-3">
                {gettext(
                  "What the storefront calls what you sell. Each option is separately translated, not a swapped word, so it reads correctly in every language."
                )}
              </p>
              <div class="flex gap-4">
                <%!-- Driven by Vocabulary.options/0, the same list the handler
                     validates against, so a new value cannot validate and then
                     be missing from the UI. --%>
                <%= for value <- Vocabulary.options() do %>
                  <% label = vocabulary_label(value) %>
                  <label class="label cursor-pointer gap-2">
                    <input
                      type="radio"
                      name="catalog_vocabulary"
                      class="radio radio-primary"
                      value={value}
                      checked={@catalog_vocabulary == value}
                      phx-click="update_catalog_vocabulary"
                      phx-value-vocabulary={value}
                    />
                    <span class="fieldset-legend">{label}</span>
                  </label>
                <% end %>
              </div>
            </div>

            <div class="divider"></div>

            <%!-- Category Icon Mode --%>
            <div class="fieldset">
              <label class="label">
                <span class="fieldset-legend text-lg font-semibold">{gettext("Category Icons")}</span>
              </label>
              <p class="text-sm text-base-content/70 mb-3">
                {gettext("Show icons next to category names in sidebar")}
              </p>
              <div class="flex gap-4">
                <label class="label cursor-pointer gap-2">
                  <input
                    type="radio"
                    name="category_icon"
                    class="radio radio-primary"
                    value="none"
                    checked={@category_icon_mode == "none"}
                    phx-click="update_category_icon"
                    phx-value-mode="none"
                  />
                  <span class="fieldset-legend">{gettext("No icons")}</span>
                </label>
                <label class="label cursor-pointer gap-2">
                  <input
                    type="radio"
                    name="category_icon"
                    class="radio radio-primary"
                    value="folder"
                    checked={@category_icon_mode == "folder"}
                    phx-click="update_category_icon"
                    phx-value-mode="folder"
                  />
                  <span class="fieldset-legend">{gettext("Folder icon")}</span>
                </label>
                <label class="label cursor-pointer gap-2">
                  <input
                    type="radio"
                    name="category_icon"
                    class="radio radio-primary"
                    value="category"
                    checked={@category_icon_mode == "category"}
                    phx-click="update_category_icon"
                    phx-value-mode="category"
                  />
                  <span class="fieldset-legend">{gettext("Category image")}</span>
                </label>
              </div>
            </div>
          </div>
        </div>
      </div>
    """
  end

  defp billing_enabled? do
    Code.ensure_loaded?(Billing) and
      function_exported?(Billing, :enabled?, 0) and
      Billing.enabled?()
  rescue
    _ -> false
  end

  defp gated_event("toggle_order_lookup_policy", _params, socket) do
    # Checkbox ON means the SAFE value, so the stored value is inverted
    # relative to the toggle: checked -> "strict".
    next = if socket.assigns.order_lookup_strict, do: "link", else: "strict"

    save_policy(
      socket,
      "shop_order_lookup_policy",
      next,
      gettext("Order access policy updated")
    )
  end

  defp gated_event("toggle_allow_raw_html", _params, socket) do
    save_policy(
      socket,
      "shop_allow_raw_html_descriptions",
      flip(socket.assigns.allow_raw_html),
      gettext("Product description rendering updated")
    )
  end

  defp gated_event("toggle_allow_svg", _params, socket) do
    save_policy(
      socket,
      "shop_allow_svg_uploads",
      flip(socket.assigns.allow_svg),
      gettext("SVG import policy updated")
    )
  end

  defp gated_event("toggle_allow_private_networks", _params, socket) do
    save_policy(
      socket,
      "shop_image_import_allow_private_networks",
      flip(socket.assigns.allow_private_networks),
      gettext("Image import network policy updated")
    )
  end

  defp gated_event("toggle_import_cleanup_scope", _params, socket) do
    next = if socket.assigns.cleanup_auto_created_only, do: "all_empty", else: "auto_created"

    save_policy(
      socket,
      "shop_import_cleanup_scope",
      next,
      gettext("Import cleanup scope updated")
    )
  end

  defp gated_event("save_default_tax_country", %{"country" => country}, socket) do
    normalized = country |> to_string() |> String.trim() |> String.upcase()

    # Only a blank value or a two-letter code; anything else is a typo, and a
    # bad country code silently means "no tax" rather than a visible error.
    if normalized == "" or normalized =~ ~r/^[A-Z]{2}$/ do
      save_policy(
        socket,
        "shop_default_tax_country",
        normalized,
        gettext("Tax fallback country updated")
      )
    else
      {:noreply,
       put_flash(socket, :error, gettext("Enter a two-letter country code, or leave it blank."))}
    end
  end

  defp gated_event("toggle_inventory_tracking", _params, socket) do
    new_value = !socket.assigns.inventory_tracking
    value_str = if(new_value, do: "true", else: "false")

    case Settings.update_setting("shop_inventory_tracking", value_str) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:inventory_tracking, new_value)
         |> put_flash(
           :info,
           if(new_value,
             do: gettext("Inventory tracking enabled"),
             else: gettext("Inventory tracking disabled")
           )
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update inventory setting"))}
    end
  end

  defp gated_event("toggle_notify_cart_first_item", _params, socket) do
    new_value = !socket.assigns.notify_cart_first_item
    value_str = if(new_value, do: "true", else: "false")

    case Settings.update_setting_with_module("shop_notify_cart_first_item", value_str, "shop") do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:notify_cart_first_item, new_value)
         |> put_flash(:info, gettext("Notification setting updated"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update notification setting"))}
    end
  end

  defp gated_event("toggle_notify_cart_item", _params, socket) do
    new_value = !socket.assigns.notify_cart_item
    value_str = if(new_value, do: "true", else: "false")

    case Settings.update_setting_with_module("shop_notify_cart_item", value_str, "shop") do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:notify_cart_item, new_value)
         |> put_flash(:info, gettext("Notification setting updated"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update notification setting"))}
    end
  end

  defp gated_event("toggle_notify_checkout_started", _params, socket) do
    new_value = !socket.assigns.notify_checkout_started
    value_str = if(new_value, do: "true", else: "false")

    case Settings.update_setting_with_module("shop_notify_checkout_started", value_str, "shop") do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:notify_checkout_started, new_value)
         |> put_flash(:info, gettext("Notification setting updated"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update notification setting"))}
    end
  end

  defp gated_event("save_notification_recipients", params, socket) do
    candidate_uuids = MapSet.new(socket.assigns.recipient_candidates, & &1.uuid)

    selected =
      params
      |> Map.get("recipients", %{})
      |> Enum.filter(fn {_uuid, v} -> v == "true" end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.filter(&MapSet.member?(candidate_uuids, &1))

    case Settings.update_json_setting_with_module(
           "shop_notification_recipients",
           %{"uuids" => selected},
           "shop"
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:notification_recipients, selected)
         |> put_flash(:info, gettext("Notification recipients updated"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update recipients"))}
    end
  end

  # Closed enums, validated here for the same reason the vocabulary setting
  # is: `PhoenixKitEcommerce.shipping_skip_mode/0` and
  # `shipping_selection_position/0` fall back to the safe legacy value on
  # anything they do not recognise, so an unknown value would read as the
  # setting being silently ignored.
  @shipping_skip_modes ~w(off fallback always)
  @shipping_positions ~w(cart checkout)

  defp gated_event("update_shipping_skip_mode", %{"mode" => mode}, socket)
       when mode in @shipping_skip_modes do
    case Settings.update_setting_with_module("shop_shipping_skip_mode", mode, "shop") do
      {:ok, _} ->
        # A manage_settings-gated write that decides whether an order can be
        # placed with no shipping method at all — exactly the setting an
        # operator asks "who changed this" about after a pending order shows up.
        Activity.log("shop.shipping_skip_mode_changed",
          actor_uuid: Activity.actor_uuid(socket),
          actor_role: Activity.actor_role(socket),
          resource_type: "setting",
          metadata: %{"mode" => mode}
        )

        {:noreply,
         socket
         |> assign(:shipping_skip_mode, mode)
         |> put_flash(:info, gettext("Shipping requirement updated"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update shipping requirement"))}
    end
  end

  defp gated_event("update_shipping_skip_mode", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("Failed to update shipping requirement"))}
  end

  defp gated_event("update_shipping_selection_position", %{"position" => position}, socket)
       when position in @shipping_positions do
    case Settings.update_setting_with_module(
           "shop_shipping_selection_position",
           position,
           "shop"
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:shipping_selection_position, position)
         |> put_flash(:info, gettext("Shipping selection step updated"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update shipping selection step"))}
    end
  end

  defp gated_event("update_shipping_selection_position", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("Failed to update shipping selection step"))}
  end

  defp gated_event("toggle_hide_zero_decimals", _params, socket) do
    value = to_string(!socket.assigns.hide_zero_decimals)

    case Settings.update_setting("shop_hide_zero_decimals", value) do
      {:ok, _} ->
        Activity.log("shop.price_format_changed",
          actor_uuid: Activity.actor_uuid(socket),
          actor_role: Activity.actor_role(socket),
          resource_type: "setting",
          metadata: %{"hide_zero_decimals" => value}
        )

        {:noreply,
         socket
         |> assign(:hide_zero_decimals, value == "true")
         |> put_flash(:info, gettext("Price format updated"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update price format"))}
    end
  end

  # Design §4.6: `shop_translations_enabled` gates the feature's mere
  # EXISTENCE (page, sidebar entry, manual actions) — a toggle that only
  # ever turns ON when AI is actually usable (never lifted server-side just
  # because a stale client sent the click; the `disabled` attribute in the
  # template is a UX hint, not the enforcement). Turning it OFF also turns
  # `shop_translation_sweep_enabled` off (design §12.4's one-directional
  # link: the sweep can never run without the section, the section can
  # exist with the sweep off) — a background actor must never keep working
  # after the operator switched the whole feature off. Both writes land in
  # `Activity.log`, same as the existence flag itself.
  defp gated_event("toggle_shop_translations_enabled", _params, socket) do
    new_value = !socket.assigns.shop_translations_enabled

    if new_value and not ai_translations_available?() do
      {:noreply,
       put_flash(
         socket,
         :error,
         gettext("Configure an enabled AI endpoint in the AI section before enabling this.")
       )}
    else
      do_toggle_shop_translations_enabled(new_value, socket)
    end
  end

  defp gated_event("update_catalog_vocabulary", %{"vocabulary" => vocabulary}, socket) do
    if vocabulary in Vocabulary.options() do
      case Settings.update_setting(Vocabulary.setting_key(), vocabulary) do
        {:ok, _} ->
          # A manage_settings-gated global write that changes every heading and
          # empty state on the public storefront. "Who changed this, and when" is
          # the first question after someone notices — the value is a closed
          # enum, so recording it carries no user data.
          Activity.log("shop.catalog_vocabulary_changed",
            actor_uuid: Activity.actor_uuid(socket),
            actor_role: Activity.actor_role(socket),
            resource_type: "setting",
            metadata: %{"vocabulary" => vocabulary}
          )

          {:noreply,
           socket
           |> assign(:catalog_vocabulary, vocabulary)
           |> put_flash(:info, gettext("Catalogue vocabulary updated"))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to update catalogue vocabulary"))}
      end
    else
      # Closed list: an unknown value would silently fall back to "products"
      # on every read, which reads as the setting being ignored.
      {:noreply, put_flash(socket, :error, gettext("Failed to update catalogue vocabulary"))}
    end
  end

  defp gated_event("update_category_display", %{"display" => display}, socket) do
    case Settings.update_setting("shop_category_name_display", display) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:category_name_display, display)
         |> put_flash(:info, gettext("Category display setting updated"))}

      {:error, _} ->
        {:noreply,
         put_flash(socket, :error, gettext("Failed to update category display setting"))}
    end
  end

  defp gated_event("toggle_sidebar_categories", _params, socket) do
    new_value = !socket.assigns.sidebar_show_categories
    value_str = if(new_value, do: "true", else: "false")

    case Settings.update_setting("shop_sidebar_show_categories", value_str) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:sidebar_show_categories, new_value)
         |> put_flash(
           :info,
           if(new_value,
             do: gettext("Categories in shop enabled"),
             else: gettext("Categories in shop disabled")
           )
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update setting"))}
    end
  end

  defp gated_event("toggle_cart_bar", _params, socket) do
    new_value = !socket.assigns.show_cart_bar
    value_str = if(new_value, do: "true", else: "false")

    case Settings.update_setting("shop_show_cart_bar", value_str) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:show_cart_bar, new_value)
         |> put_flash(
           :info,
           if(new_value,
             do: gettext("Storefront cart bar enabled"),
             else: gettext("Storefront cart bar disabled")
           )
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update setting"))}
    end
  end

  defp gated_event("update_category_icon", %{"mode" => mode}, socket) do
    case Settings.update_setting("shop_category_icon_mode", mode) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:category_icon_mode, mode)
         |> put_flash(:info, gettext("Category icon setting updated"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update category icon setting"))}
    end
  end

  defp gated_event("toggle_storefront_filter", %{"key" => key}, socket) do
    filters =
      Enum.map(socket.assigns.storefront_filters, fn f ->
        if f["key"] == key, do: Map.put(f, "enabled", !f["enabled"]), else: f
      end)

    case Shop.update_storefront_filters(filters) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:storefront_filters, filters)
         |> put_flash(:info, gettext("Storefront filter updated"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update filter"))}
    end
  end

  defp gated_event("update_filter_label", %{"key" => key, "label" => label}, socket) do
    filters =
      Enum.map(socket.assigns.storefront_filters, fn f ->
        if f["key"] == key, do: Map.put(f, "label", label), else: f
      end)

    case Shop.update_storefront_filters(filters) do
      {:ok, _} ->
        {:noreply, assign(socket, :storefront_filters, filters)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update filter label"))}
    end
  end

  defp gated_event("add_metadata_filter", %{"key" => option_key}, socket) do
    existing_keys = Enum.map(socket.assigns.storefront_filters, & &1["key"])

    if option_key in existing_keys do
      {:noreply,
       put_flash(socket, :error, gettext("Filter for '%{key}' already exists", key: option_key))}
    else
      max_pos =
        socket.assigns.storefront_filters
        |> Enum.map(& &1["position"])
        |> Enum.max(fn -> 0 end)

      new_filter = %{
        "key" => option_key,
        "type" => "metadata_option",
        "option_key" => option_key,
        "label" => String.capitalize(option_key),
        "enabled" => true,
        "position" => max_pos + 1
      }

      filters = socket.assigns.storefront_filters ++ [new_filter]

      case Shop.update_storefront_filters(filters) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(:storefront_filters, filters)
           |> put_flash(:info, gettext("Filter '%{key}' added", key: option_key))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to add filter"))}
      end
    end
  end

  defp gated_event("remove_filter", %{"key" => key}, socket) do
    filters = Enum.reject(socket.assigns.storefront_filters, &(&1["key"] == key))

    case Shop.update_storefront_filters(filters) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:storefront_filters, filters)
         |> put_flash(:info, gettext("Filter removed"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to remove filter"))}
    end
  end

  defp gated_event("reset_default_filters", _params, socket) do
    filters = Shop.default_storefront_filters()

    case Shop.update_storefront_filters(filters) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:storefront_filters, filters)
         |> put_flash(:info, gettext("Filters reset to defaults"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to reset filters"))}
    end
  end

  defp do_toggle_shop_translations_enabled(new_value, socket) do
    case Settings.update_boolean_setting_with_module(
           "shop_translations_enabled",
           new_value,
           "shop"
         ) do
      {:ok, _} ->
        Activity.log("shop.translations_enabled_changed",
          actor_uuid: Activity.actor_uuid(socket),
          actor_role: Activity.actor_role(socket),
          resource_type: "setting",
          metadata: %{"enabled" => new_value}
        )

        socket = maybe_disable_sweep(new_value, socket)

        {:noreply,
         socket
         |> assign(:shop_translations_enabled, new_value)
         |> put_flash(
           :info,
           if(new_value,
             do: gettext("Shop translations enabled"),
             else: gettext("Shop translations disabled")
           )
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to update shop translations"))}
    end
  end

  defp maybe_disable_sweep(true, socket), do: socket

  defp maybe_disable_sweep(false, socket) do
    if TranslationSweepSettings.sweep_enabled?() do
      Settings.update_boolean_setting_with_module("shop_translation_sweep_enabled", false, "shop")

      Activity.log("shop.translation_sweep_settings_changed",
        actor_uuid: Activity.actor_uuid(socket),
        actor_role: Activity.actor_role(socket),
        resource_type: "setting",
        metadata: %{"sweep_enabled" => false, "reason" => "shop_translations_disabled"}
      )
    end

    socket
  end

  defp vocabulary_label("services"), do: gettext("Services")
  defp vocabulary_label("mixed"), do: gettext("Both (neutral wording)")
  defp vocabulary_label(_), do: gettext("Products")
end
