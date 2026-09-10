defmodule PhoenixKitEcommerce.Web.UserOrderDetails do
  @moduledoc """
  LiveView for displaying order details to the order owner.

  Users can view their own orders with full details including:
  - Order items and totals
  - Billing information
  - Order status

  Security:
  - Users can only view their own orders (user_uuid check)
  """
  use PhoenixKitEcommerce.Web, :live_view

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.NamePrefix
  alias PhoenixKitEcommerce.PriceDisplay
  alias PhoenixKitEcommerce.Web.Helpers, as: ShopHelpers

  import PhoenixKitEcommerce.Web.Helpers,
    only: [format_price: 2, profile_display_name: 1, profile_address: 1, profile_email: 1]

  @impl true
  def mount(%{"uuid" => uuid}, _session, socket) do
    # Point the module Gettext at a locale its catalogues contain — see
    # Helpers.put_content_locale/1. Without it this page renders English
    # while its siblings translate.
    _ = ShopHelpers.put_content_locale_from(socket)

    if Billing.enabled?() do
      mount_with_billing(uuid, socket)
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("Billing module is not enabled"))
       |> push_navigate(to: Routes.path("/dashboard"))}
    end
  end

  defp mount_with_billing(uuid, socket) do
    current_user = socket.assigns[:phoenix_kit_current_user]

    case Billing.get_order_by_uuid(uuid) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Order not found"))
         |> push_navigate(to: Routes.path("/dashboard/orders"))}

      order ->
        if order.user_uuid != current_user.uuid do
          {:ok,
           socket
           |> put_flash(:error, gettext("Access denied"))
           |> push_navigate(to: Routes.path("/dashboard/orders"))}
        else
          {:ok, setup_order_assigns(socket, order, current_user)}
        end
    end
  end

  defp setup_order_assigns(socket, order, current_user) do
    currency = Shop.currency_for_code(order.currency)
    billing_profile = get_billing_profile(order)

    socket
    |> assign(:page_title, gettext("Order %{number}", number: order.order_number))
    |> assign(:order, order)
    |> assign(:current_user, current_user)
    |> assign(:currency, currency)
    |> assign(:billing_profile, billing_profile)
  end

  # Snapshot first - see Helpers.order_billing_identity/1. This page had no
  # snapshot fallback at all, so a deleted profile rendered nothing.
  defp get_billing_profile(order) do
    ShopHelpers.order_billing_identity(order) || live_billing_profile(order)
  end

  defp live_billing_profile(%{billing_profile_uuid: nil}), do: nil
  defp live_billing_profile(%{billing_profile_uuid: uuid}), do: Billing.get_billing_profile(uuid)

  @impl true
  def handle_params(_params, uri, socket) do
    {:noreply, assign(socket, :url_path, URI.parse(uri).path)}
  end

  # View helpers

  defp status_badge_class("pending"), do: "badge-warning"
  defp status_badge_class("processing"), do: "badge-info"
  defp status_badge_class("completed"), do: "badge-success"
  defp status_badge_class("shipped"), do: "badge-info"
  defp status_badge_class("delivered"), do: "badge-success"
  defp status_badge_class("cancelled"), do: "badge-error"
  defp status_badge_class("refunded"), do: "badge-neutral"
  defp status_badge_class(_), do: "badge-ghost"

  defp format_date(nil), do: "-"

  defp format_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "%B %d, %Y at %H:%M")
  end

  defp format_date(%NaiveDateTime{} = dt) do
    Calendar.strftime(dt, "%B %d, %Y at %H:%M")
  end

  defp items_count(nil), do: 0
  defp items_count([]), do: 0

  defp items_count(items) do
    items
    |> Enum.filter(&(&1["type"] != "shipping"))
    |> length()
  end
end
