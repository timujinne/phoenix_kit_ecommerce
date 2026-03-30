defmodule PhoenixKit.Modules.Shop.Web.UserOrderDetails do
  @moduledoc """
  Compat alias for PhoenixKitEcommerce.Web.UserOrderDetails.
  LiveView — delegates mount, handle_params.
  """

  use Phoenix.LiveView

  defdelegate mount(params, session, socket), to: PhoenixKitEcommerce.Web.UserOrderDetails
  defdelegate handle_params(params, uri, socket), to: PhoenixKitEcommerce.Web.UserOrderDetails

  defdelegate render(assigns), to: PhoenixKitEcommerce.Web.UserOrderDetails
end
