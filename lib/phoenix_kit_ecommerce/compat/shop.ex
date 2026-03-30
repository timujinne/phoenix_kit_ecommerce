defmodule PhoenixKit.Modules.Shop do
  @moduledoc """
  Compat alias for PhoenixKitEcommerce.
  Delegates all public functions so core can reference the old namespace.
  """

  defdelegate enabled?(), to: PhoenixKitEcommerce
  defdelegate merge_guest_cart(session_id, user), to: PhoenixKitEcommerce
end
