defmodule PhoenixKitEcommerce.Shipping.RateRequest do
  @moduledoc """
  A request for the price of one delivery.

    * `service` - the service key: the one the shopper chose among those the
      method allows
    * `origin` - the sender settings of the shipping method (a map)
    * `destination` - where the parcels go
    * `parcels` - what is sent
    * `declared_value` - declared (insured) value, a `Decimal`
    * `cod_amount` - cash-on-delivery amount, or `nil`
    * `currency` - ISO 4217 code of `declared_value` and `cod_amount`
    * `country` - ISO 3166-1 alpha-2 code of the destination country, or `nil`
      while the shopper has not given one (the cart page); it is part of
      `Shipping.request_hash/1` only when present
  """

  alias PhoenixKitEcommerce.Shipping.{Codec, Destination, Parcel}

  defstruct service: nil,
            origin: %{},
            destination: %Destination{},
            parcels: [],
            declared_value: Decimal.new(0),
            cod_amount: nil,
            currency: nil,
            country: nil

  @type t :: %__MODULE__{
          service: String.t() | nil,
          origin: map(),
          destination: Destination.t(),
          parcels: [Parcel.t()],
          declared_value: Decimal.t(),
          cod_amount: Decimal.t() | nil,
          currency: String.t() | nil,
          country: String.t() | nil
        }

  @doc "Serialises the request into a JSON-safe map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = request), do: Codec.encode(request)

  @doc "Builds a request from a map with string or atom keys; garbage becomes `nil`."
  @spec from_map(term()) :: t() | nil
  def from_map(%__MODULE__{} = request), do: request

  def from_map(map) when is_map(map) do
    %__MODULE__{
      service: map |> Codec.get(:service) |> Codec.string(),
      origin: map |> Codec.get(:origin) |> Codec.string_map(),
      destination:
        map |> Codec.get(:destination) |> Codec.struct_from(Destination) || %Destination{},
      parcels: map |> Codec.get(:parcels) |> Codec.list(&Codec.struct_from(&1, Parcel)),
      declared_value: map |> Codec.get(:declared_value) |> Codec.decimal() || Decimal.new(0),
      cod_amount: map |> Codec.get(:cod_amount) |> Codec.decimal(),
      currency: map |> Codec.get(:currency) |> Codec.string(),
      country: map |> Codec.get(:country) |> Codec.country()
    }
  end

  def from_map(_other), do: nil
end
