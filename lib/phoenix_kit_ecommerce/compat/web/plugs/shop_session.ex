defmodule PhoenixKit.Modules.Shop.Web.Plugs.ShopSession do
  @moduledoc """
  Compat alias for PhoenixKitEcommerce.Web.Plugs.ShopSession.
  Must be a real Plug so `plug` macro works.
  """

  use Plug.Builder

  defdelegate init(opts), to: PhoenixKitEcommerce.Web.Plugs.ShopSession
  defdelegate call(conn, opts), to: PhoenixKitEcommerce.Web.Plugs.ShopSession
end
