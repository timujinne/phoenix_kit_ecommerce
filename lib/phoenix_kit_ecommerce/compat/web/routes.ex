defmodule PhoenixKit.Modules.Shop.Web.Routes do
  @moduledoc """
  Compat alias for PhoenixKitEcommerce.Web.Routes.
  """

  defdelegate public_live_routes(), to: PhoenixKitEcommerce.Web.Routes
  defdelegate public_live_locale_routes(), to: PhoenixKitEcommerce.Web.Routes
  defdelegate admin_routes(), to: PhoenixKitEcommerce.Web.Routes
  defdelegate admin_locale_routes(), to: PhoenixKitEcommerce.Web.Routes
end
