defmodule PhoenixKitEcommerce.Shipping.Parcel do
  @moduledoc """
  One parcel to ship: weight in grams, sides in millimetres. Dimensions are
  `nil` when nothing is known about them, in which case the carrier is
  expected to price by weight alone.
  """

  alias PhoenixKitEcommerce.Shipping.Codec

  defstruct weight_g: 0, length_mm: nil, width_mm: nil, height_mm: nil

  @type t :: %__MODULE__{
          weight_g: non_neg_integer(),
          length_mm: pos_integer() | nil,
          width_mm: pos_integer() | nil,
          height_mm: pos_integer() | nil
        }

  @doc "Serialises the parcel into a JSON-safe map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = parcel), do: Codec.encode(parcel)

  @doc "Builds a parcel from a map with string or atom keys; garbage becomes `nil`."
  @spec from_map(term()) :: t() | nil
  def from_map(%__MODULE__{} = parcel), do: parcel

  def from_map(map) when is_map(map) do
    %__MODULE__{
      weight_g: map |> Codec.get(:weight_g) |> Codec.integer() || 0,
      length_mm: map |> Codec.get(:length_mm) |> Codec.integer(),
      width_mm: map |> Codec.get(:width_mm) |> Codec.integer(),
      height_mm: map |> Codec.get(:height_mm) |> Codec.integer()
    }
  end

  def from_map(_other), do: nil
end
