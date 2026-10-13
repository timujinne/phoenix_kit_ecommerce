defmodule PhoenixKitEcommerce.Shipping.Destination do
  @moduledoc """
  Where a parcel goes: a locality, and depending on the service either a
  pickup point or an address within it.
  """

  alias PhoenixKitEcommerce.Shipping.{Address, Codec, Locality, PickupPoint}

  defstruct locality: nil, pickup_point: nil, address: nil

  @type t :: %__MODULE__{
          locality: Locality.t() | nil,
          pickup_point: PickupPoint.t() | nil,
          address: Address.t() | nil
        }

  @doc "Serialises the destination into a JSON-safe map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = destination), do: Codec.encode(destination)

  @doc "Builds a destination from a map with string or atom keys; garbage becomes `nil`."
  @spec from_map(term()) :: t() | nil
  def from_map(%__MODULE__{} = destination), do: destination

  def from_map(map) when is_map(map) do
    %__MODULE__{
      locality: map |> Codec.get(:locality) |> Codec.struct_from(Locality),
      pickup_point: map |> Codec.get(:pickup_point) |> Codec.struct_from(PickupPoint),
      address: map |> Codec.get(:address) |> Codec.struct_from(Address)
    }
  end

  def from_map(_other), do: nil
end
