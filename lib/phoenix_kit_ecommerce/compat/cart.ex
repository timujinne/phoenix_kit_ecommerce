defmodule PhoenixKit.Modules.Shop.Cart do
  @moduledoc """
  Deprecated name of `PhoenixKitEcommerce.Cart`, kept so a query written
  against it (`from(c in PhoenixKit.Modules.Shop.Cart, ...)`) keeps working
  while the host switches to the new name.
  """
  @moduledoc deprecated: "Use PhoenixKitEcommerce.Cart instead"

  use Ecto.Schema

  @type t :: PhoenixKitEcommerce.Cart.t()

  # Delegate __schema__/1 and __schema__/2 so Ecto queries work
  defdelegate __schema__(query_type), to: PhoenixKitEcommerce.Cart
  defdelegate __schema__(query_type, arg), to: PhoenixKitEcommerce.Cart
end
