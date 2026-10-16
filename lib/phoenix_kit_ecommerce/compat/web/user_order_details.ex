defmodule PhoenixKit.Modules.Shop.Web.UserOrderDetails do
  @moduledoc """
  Deprecated name of `PhoenixKitEcommerce.Web.UserOrderDetails`, for a host
  router that still declares the page under it. Core routes
  `/dashboard/orders/:uuid` to the new name itself; a hand-written route
  switches by naming `PhoenixKitEcommerce.Web.UserOrderDetails`.
  """
  @moduledoc deprecated: "Use PhoenixKitEcommerce.Web.UserOrderDetails instead"

  use Phoenix.LiveView

  defdelegate mount(params, session, socket), to: PhoenixKitEcommerce.Web.UserOrderDetails
  defdelegate handle_params(params, uri, socket), to: PhoenixKitEcommerce.Web.UserOrderDetails

  defdelegate render(assigns), to: PhoenixKitEcommerce.Web.UserOrderDetails
end
