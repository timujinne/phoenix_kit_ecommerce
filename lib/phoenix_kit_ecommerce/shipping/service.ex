defmodule PhoenixKitEcommerce.Shipping.Service do
  @moduledoc """
  One delivery service offered by a shipping provider (for example
  "to a branch" or "courier to the door").

    * `key` - provider-scoped identifier, stored on the shipping method
    * `label` - human readable name
    * `destination` - what the customer has to give: a pickup point, an
      address, or nothing
    * `lookup` - `:search` when the provider can search localities and pickup
      points, `:manual` when the customer types the data in
    * `point_code_label` / `point_code_format` - label and optional regex
      (as a string) of the manually entered pickup point code
  """

  alias PhoenixKitEcommerce.Shipping.Codec

  @destinations [:pickup_point, :address, :none]
  @lookups [:search, :manual]

  defstruct key: nil,
            label: nil,
            destination: :none,
            lookup: :manual,
            point_code_label: nil,
            point_code_format: nil

  @type destination :: :pickup_point | :address | :none
  @type lookup :: :search | :manual

  @type t :: %__MODULE__{
          key: String.t() | nil,
          label: String.t() | nil,
          destination: destination(),
          lookup: lookup(),
          point_code_label: String.t() | nil,
          point_code_format: String.t() | nil
        }

  @doc "Serialises the service into a JSON-safe map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = service), do: Codec.encode(service)

  @doc "Builds a service from a map with string or atom keys; garbage becomes `nil`."
  @spec from_map(term()) :: t() | nil
  def from_map(%__MODULE__{} = service), do: service

  def from_map(map) when is_map(map) do
    %__MODULE__{
      key: map |> Codec.get(:key) |> Codec.string(),
      label: map |> Codec.get(:label) |> Codec.string(),
      destination: map |> Codec.get(:destination) |> Codec.atom(@destinations) || :none,
      lookup: map |> Codec.get(:lookup) |> Codec.atom(@lookups) || :manual,
      point_code_label: map |> Codec.get(:point_code_label) |> Codec.string(),
      point_code_format: map |> Codec.get(:point_code_format) |> Codec.string()
    }
  end

  def from_map(_other), do: nil
end
