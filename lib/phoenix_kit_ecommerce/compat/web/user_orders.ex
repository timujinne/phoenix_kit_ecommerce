defmodule PhoenixKit.Modules.Shop.Web.UserOrders do
  @moduledoc """
  Deprecated name of `PhoenixKitEcommerce.Web.UserOrders`, for a host router
  that still declares the page under it. Core routes `/dashboard/orders` to
  the new name itself; a hand-written route switches by naming
  `PhoenixKitEcommerce.Web.UserOrders`.
  """
  @moduledoc deprecated: "Use PhoenixKitEcommerce.Web.UserOrders instead"

  use Phoenix.LiveView

  defdelegate mount(params, session, socket), to: PhoenixKitEcommerce.Web.UserOrders
  defdelegate handle_params(params, uri, socket), to: PhoenixKitEcommerce.Web.UserOrders
  defdelegate handle_event(event, params, socket), to: PhoenixKitEcommerce.Web.UserOrders

  defdelegate render(assigns), to: PhoenixKitEcommerce.Web.UserOrders
end
