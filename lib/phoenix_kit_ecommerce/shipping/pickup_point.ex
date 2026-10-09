defmodule PhoenixKitEcommerce.Shipping.PickupPoint do
  @moduledoc """
  A branch, parcel locker or cargo office the customer collects a parcel from.

  `limits` describes what the point accepts; a limit that is `nil` does not
  restrict anything:

    * `max_weight_g` - heaviest single parcel, grams
    * `max_dims_mm` - `[l, w, h]` sorted from the longest side, millimetres
    * `max_declared` - highest declared value, a `Decimal`

  `extra` is provider-private; its values are strings once the point has been
  through JSON (a cart or an order).

  For a service with `lookup: :manual` the customer types a code instead of
  choosing from a list, and the UI builds the point with `manual/1`; adapters
  read `pickup_point.id` (the code).
  """

  alias PhoenixKitEcommerce.Shipping.Codec

  @kinds [:branch, :locker, :cargo, :other]

  defstruct id: nil,
            name: nil,
            number: nil,
            address: nil,
            postcode: nil,
            kind: :other,
            lat: nil,
            lng: nil,
            limits: %{max_weight_g: nil, max_dims_mm: nil, max_declared: nil},
            extra: %{}

  @type kind :: :branch | :locker | :cargo | :other

  @type limits :: %{
          max_weight_g: non_neg_integer() | nil,
          max_dims_mm: [non_neg_integer()] | nil,
          max_declared: Decimal.t() | nil
        }

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t() | nil,
          number: String.t() | nil,
          address: String.t() | nil,
          postcode: String.t() | nil,
          kind: kind(),
          lat: float() | nil,
          lng: float() | nil,
          limits: limits(),
          extra: map()
        }

  @doc """
  A pickup point known only by the code the customer typed. The trimmed code
  is the `id`, `number` and `name`; nothing else is derived from it (what a
  code means, a postcode included, is up to the carrier adapter).
  `extra["manual"]` is `"true"`.

  A blank code (empty, whitespace or not a string) has no point: `nil`.
  """
  @spec manual(term()) :: t() | nil
  def manual(code) when is_binary(code) do
    case String.trim(code) do
      "" ->
        nil

      code ->
        %__MODULE__{
          id: code,
          number: code,
          name: code,
          kind: :other,
          extra: %{"manual" => "true"}
        }
    end
  end

  def manual(_other), do: nil

  @doc "Serialises the point into a JSON-safe map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = point), do: Codec.encode(point)

  @doc "Builds a point from a map with string or atom keys; garbage becomes `nil`."
  @spec from_map(term()) :: t() | nil
  def from_map(%__MODULE__{} = point), do: point

  def from_map(map) when is_map(map) do
    %__MODULE__{
      id: map |> Codec.get(:id) |> Codec.string(),
      name: map |> Codec.get(:name) |> Codec.string(),
      number: map |> Codec.get(:number) |> Codec.string(),
      address: map |> Codec.get(:address) |> Codec.string(),
      postcode: map |> Codec.get(:postcode) |> Codec.string(),
      kind: map |> Codec.get(:kind) |> Codec.atom(@kinds) || :other,
      lat: map |> Codec.get(:lat) |> Codec.float(),
      lng: map |> Codec.get(:lng) |> Codec.float(),
      limits: map |> Codec.get(:limits) |> limits_from(),
      extra: map |> Codec.get(:extra) |> Codec.string_map()
    }
  end

  def from_map(_other), do: nil

  defp limits_from(limits) do
    %{
      max_weight_g: limits |> Codec.get(:max_weight_g) |> Codec.integer(),
      max_dims_mm: limits |> Codec.get(:max_dims_mm) |> dims_from(),
      max_declared: limits |> Codec.get(:max_declared) |> Codec.decimal()
    }
  end

  defp dims_from(dims) when is_list(dims) do
    parsed = Enum.map(dims, &Codec.integer/1)

    if length(parsed) == 3 and Enum.all?(parsed, &is_integer/1) do
      Enum.sort(parsed, :desc)
    end
  end

  defp dims_from(_other), do: nil
end
