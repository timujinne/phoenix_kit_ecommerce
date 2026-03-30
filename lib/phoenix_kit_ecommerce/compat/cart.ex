defmodule PhoenixKit.Modules.Shop.Cart do
  @moduledoc """
  Compat alias for PhoenixKitEcommerce.Cart.
  Used as Ecto schema in queries (from(c in PhoenixKit.Modules.Shop.Cart, ...)).
  """

  use Ecto.Schema

  # Delegate __schema__/1 and __schema__/2 so Ecto queries work
  defdelegate __schema__(query_type), to: PhoenixKitEcommerce.Cart
  defdelegate __schema__(query_type, arg), to: PhoenixKitEcommerce.Cart
end
