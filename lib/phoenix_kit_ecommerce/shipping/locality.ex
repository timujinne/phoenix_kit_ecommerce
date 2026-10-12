defmodule PhoenixKitEcommerce.Shipping.Locality do
  @moduledoc """
  A city, town or village a parcel can be sent to or from.

  `id` is whatever the provider needs to refer to it again; provider-private
  references (for example a settlement ref next to a city ref) go into `extra`.
  Its values are strings once the locality has been through JSON.

  `country` is the ISO 3166-1 alpha-2 code of the country the locality is in.
  A provider that serves more than one country sets it, so that the same
  name in two countries stays two localities.
  """

  alias PhoenixKitEcommerce.Shipping.Codec

  defstruct id: nil, name: nil, region: nil, postcode: nil, country: nil, extra: %{}

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t() | nil,
          region: String.t() | nil,
          postcode: String.t() | nil,
          country: String.t() | nil,
          extra: map()
        }

  @doc "Serialises the locality into a JSON-safe map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = locality), do: Codec.encode(locality)

  @doc "Builds a locality from a map with string or atom keys; garbage becomes `nil`."
  @spec from_map(term()) :: t() | nil
  def from_map(%__MODULE__{} = locality), do: locality

  def from_map(map) when is_map(map) do
    %__MODULE__{
      id: map |> Codec.get(:id) |> Codec.string(),
      name: map |> Codec.get(:name) |> Codec.string(),
      region: map |> Codec.get(:region) |> Codec.string(),
      postcode: map |> Codec.get(:postcode) |> Codec.string(),
      country: map |> Codec.get(:country) |> Codec.country(),
      extra: map |> Codec.get(:extra) |> Codec.string_map()
    }
  end

  def from_map(_other), do: nil
end
