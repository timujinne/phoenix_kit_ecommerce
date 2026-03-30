defmodule PhoenixKit.Modules.Shop.Web.UserOrders do
  @moduledoc """
  Compat alias for PhoenixKitEcommerce.Web.UserOrders.
  LiveView — delegates mount, handle_params, handle_event.
  """

  use Phoenix.LiveView

  defdelegate mount(params, session, socket), to: PhoenixKitEcommerce.Web.UserOrders
  defdelegate handle_params(params, uri, socket), to: PhoenixKitEcommerce.Web.UserOrders
  defdelegate handle_event(event, params, socket), to: PhoenixKitEcommerce.Web.UserOrders

  defdelegate render(assigns), to: PhoenixKitEcommerce.Web.UserOrders
end
