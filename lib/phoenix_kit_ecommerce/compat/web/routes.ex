defmodule PhoenixKit.Modules.Shop.Web.Routes do
  @moduledoc """
  Deprecated name of `PhoenixKitEcommerce.Web.Routes`.
  """
  @moduledoc deprecated: "Use PhoenixKitEcommerce.Web.Routes instead"

  @deprecated "Use PhoenixKitEcommerce.Web.Routes.public_live_routes/0 instead"
  defdelegate public_live_routes(), to: PhoenixKitEcommerce.Web.Routes
  @deprecated "Use PhoenixKitEcommerce.Web.Routes.public_live_locale_routes/0 instead"
  defdelegate public_live_locale_routes(), to: PhoenixKitEcommerce.Web.Routes
  @deprecated "Use PhoenixKitEcommerce.Web.Routes.admin_routes/0 instead"
  defdelegate admin_routes(), to: PhoenixKitEcommerce.Web.Routes
  @deprecated "Use PhoenixKitEcommerce.Web.Routes.admin_locale_routes/0 instead"
  defdelegate admin_locale_routes(), to: PhoenixKitEcommerce.Web.Routes
end
