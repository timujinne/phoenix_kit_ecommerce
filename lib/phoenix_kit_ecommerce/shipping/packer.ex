defmodule PhoenixKitEcommerce.Shipping.Packer do
  @moduledoc """
  Strategy that turns cart positions into the parcels sent to a carrier.

  The default is `PhoenixKitEcommerce.Shipping.Packer.SingleBox` (everything in
  one parcel). A shop with its own rules plugs another module in:

      config :phoenix_kit_ecommerce, shipping_packer: MyShop.Shipping.MyPacker

  The module implements `c:build/2`.
  """

  alias PhoenixKitEcommerce.Shipping.Packer.{Defaults, SingleBox}
  alias PhoenixKitEcommerce.Shipping.{PackItem, Parcel}

  @callback build([PackItem.t()], Defaults.t()) :: [Parcel.t()]

  @doc "Packs `items` with the configured packer (`:shipping_packer`, default `SingleBox`)."
  @spec pack([PackItem.t()], Defaults.t()) :: [Parcel.t()]
  def pack(items, %Defaults{} = defaults) when is_list(items) do
    packer = Application.get_env(:phoenix_kit_ecommerce, :shipping_packer, SingleBox)
    packer.build(items, defaults)
  end
end
