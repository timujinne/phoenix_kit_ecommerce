defmodule PhoenixKitEcommerce.Shipping.PackerTest do
  # Changes application env, so not async.
  use ExUnit.Case, async: false

  alias PhoenixKitEcommerce.Shipping.Packer
  alias PhoenixKitEcommerce.Shipping.Packer.Defaults
  alias PhoenixKitEcommerce.Shipping.{PackItem, Parcel}

  defmodule PerUnit do
    @behaviour PhoenixKitEcommerce.Shipping.Packer

    @impl true
    def build(items, _defaults) do
      for item <- items, _unit <- 1..item.quantity, do: %Parcel{weight_g: item.weight_g}
    end
  end

  setup do
    on_exit(fn -> Application.delete_env(:phoenix_kit_ecommerce, :shipping_packer) end)
  end

  test "uses the configured packer" do
    Application.put_env(:phoenix_kit_ecommerce, :shipping_packer, PerUnit)

    assert [%Parcel{weight_g: 100}, %Parcel{weight_g: 100}] =
             Packer.pack([%PackItem{weight_g: 100, quantity: 2}], %Defaults{})
  end

  test "falls back to SingleBox when nothing is configured" do
    assert [%Parcel{weight_g: 200}] =
             Packer.pack([%PackItem{weight_g: 100, quantity: 2}], %Defaults{})
  end
end
