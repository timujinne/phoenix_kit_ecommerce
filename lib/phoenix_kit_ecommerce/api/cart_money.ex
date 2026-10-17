defmodule PhoenixKitEcommerce.API.CartMoney do
  @moduledoc """
  The money object of the API: `%{amount: "12.50", currency: "EUR"}`, the
  amount a decimal string rounded half up to the currency's own
  `decimal_places` (two when the currency is unknown), so `unit_price`,
  `line_total` and the totals can never be mistaken for one another or for a
  float.

  It converts nothing: every amount in a cart is already in the cart's own
  currency (core's `add_to_cart` stores it through the cart's frozen rate), so
  this is only the last rounding step.
  """

  alias PhoenixKitEcommerce, as: Shop

  @type t :: %{amount: String.t(), currency: String.t() | nil}

  @doc "Builds a money object; `nil` stays `nil`."
  @spec new(Decimal.t() | nil, String.t() | nil) :: t() | nil
  def new(nil, _currency), do: nil

  def new(%Decimal{} = amount, currency) when is_binary(currency) or is_nil(currency) do
    %{
      amount: amount |> Decimal.round(places(currency)) |> Decimal.to_string(:normal),
      currency: currency
    }
  end

  defp places(nil), do: 2

  defp places(code) do
    case Shop.currency_for_code(code) do
      %{decimal_places: places} when is_integer(places) and places >= 0 -> places
      _ -> 2
    end
  end
end
