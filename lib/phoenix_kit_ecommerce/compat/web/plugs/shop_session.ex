defmodule PhoenixKit.Modules.Shop.Web.Plugs.ShopSession do
  @moduledoc """
  Deprecated name of `PhoenixKitEcommerce.Web.Plugs.ShopSession`. A real Plug,
  so a host pipeline that still names it in `plug` keeps working while it
  switches.
  """
  @moduledoc deprecated: "Use PhoenixKitEcommerce.Web.Plugs.ShopSession instead"

  use Plug.Builder

  defdelegate init(opts), to: PhoenixKitEcommerce.Web.Plugs.ShopSession
  defdelegate call(conn, opts), to: PhoenixKitEcommerce.Web.Plugs.ShopSession
end
