defmodule PhoenixKitEcommerce.Shipping.Quote do
  @moduledoc """
  A priced delivery option returned by a provider.

    * `amount` - the carrier price, a `Decimal`, in `currency`
    * `cod_fee` - the cash-on-delivery fee, or `nil`; paid by the recipient to
      the carrier, so it is shown separately and never added to `amount`
    * `eta` - `%{min_days, max_days, date}` or `nil`
    * `source` - `:api` (carrier answer), `:table` (rate table), `:fixed`
      (price of the method) or `:fallback` (the carrier could not be reached)
    * `breakdown` - provider-specific details, JSON-safe
    * `expires_at` - when the price stops being valid, if the carrier says
    * `note` - free text for the customer
  """

  alias PhoenixKitEcommerce.Shipping.Codec

  @sources [:api, :table, :fixed, :fallback]

  defstruct amount: nil,
            currency: nil,
            cod_fee: nil,
            eta: nil,
            source: :api,
            breakdown: %{},
            expires_at: nil,
            note: nil

  @type source :: :api | :table | :fixed | :fallback

  @type eta :: %{
          min_days: non_neg_integer() | nil,
          max_days: non_neg_integer() | nil,
          date: Date.t() | nil
        }

  @type t :: %__MODULE__{
          amount: Decimal.t() | nil,
          currency: String.t() | nil,
          cod_fee: Decimal.t() | nil,
          eta: eta() | nil,
          source: source(),
          breakdown: map(),
          expires_at: DateTime.t() | nil,
          note: String.t() | nil
        }

  @doc "Serialises the quote into a JSON-safe map."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = value), do: Codec.encode(value)

  @doc "Builds a quote from a map with string or atom keys; garbage becomes `nil`."
  @spec from_map(term()) :: t() | nil
  def from_map(%__MODULE__{} = value), do: value

  def from_map(map) when is_map(map) do
    %__MODULE__{
      amount: map |> Codec.get(:amount) |> Codec.decimal(),
      currency: map |> Codec.get(:currency) |> Codec.string(),
      cod_fee: map |> Codec.get(:cod_fee) |> Codec.decimal(),
      eta: map |> Codec.get(:eta) |> eta_from(),
      source: map |> Codec.get(:source) |> Codec.atom(@sources) || :api,
      breakdown: map |> Codec.get(:breakdown) |> Codec.string_map(),
      expires_at: map |> Codec.get(:expires_at) |> Codec.datetime(),
      note: map |> Codec.get(:note) |> Codec.string()
    }
  end

  def from_map(_other), do: nil

  defp eta_from(eta) when is_map(eta) do
    %{
      min_days: eta |> Codec.get(:min_days) |> Codec.integer(),
      max_days: eta |> Codec.get(:max_days) |> Codec.integer(),
      date: eta |> Codec.get(:date) |> Codec.date()
    }
  end

  defp eta_from(_other), do: nil
end
