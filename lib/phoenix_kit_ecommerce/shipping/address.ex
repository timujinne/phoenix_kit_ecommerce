defmodule PhoenixKitEcommerce.Shipping.Address do
  @moduledoc """
  A delivery address. Structured parts and the free-text `line` are all
  optional, since providers differ in what they ask for. `extra` values are
  strings once the address has been through JSON.
  """

  alias PhoenixKitEcommerce.Shipping.Codec

  defstruct postcode: nil, street: nil, house: nil, apartment: nil, line: nil, extra: %{}

  @type t :: %__MODULE__{
          postcode: String.t() | nil,
          street: String.t() | nil,
          house: String.t() | nil,
          apartment: String.t() | nil,
          line: String.t() | nil,
          extra: map()
        }

  @doc "Serialises the address into a JSON-safe map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = address), do: Codec.encode(address)

  @doc "Builds an address from a map with string or atom keys; garbage becomes `nil`."
  @spec from_map(term()) :: t() | nil
  def from_map(%__MODULE__{} = address), do: address

  def from_map(map) when is_map(map) do
    %__MODULE__{
      postcode: map |> Codec.get(:postcode) |> Codec.string(),
      street: map |> Codec.get(:street) |> Codec.string(),
      house: map |> Codec.get(:house) |> Codec.string(),
      apartment: map |> Codec.get(:apartment) |> Codec.string(),
      line: map |> Codec.get(:line) |> Codec.string(),
      extra: map |> Codec.get(:extra) |> Codec.string_map()
    }
  end

  def from_map(_other), do: nil
end
