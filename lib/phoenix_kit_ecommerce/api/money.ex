defmodule PhoenixKitEcommerce.API.Money do
  @moduledoc """
  Decimal strings of the admin API: parsing what a client sends and
  formatting what the API answers.

  Money crosses the API as a decimal string (`"12.50"`), never as a float.
  A price has at most 10 integer digits and 2 decimals, which is the
  `numeric(12,2)` column of a catalogue item's `base_price`; a third decimal
  is refused instead of being rounded, because a silent rounding is a price
  the client did not ask for. The regular expressions use `\\z`, not `$`, so a
  trailing newline does not slip through.
  """

  @amount ~r/\A(0|[1-9][0-9]{0,9})(\.[0-9]{1,2})?\z/
  @delta ~r/\A-?(0|[1-9][0-9]{0,9})(\.[0-9]{1,2})?\z/

  @message "must be a decimal string with at most 2 decimals, for example \"12.50\""

  @doc "JSON Schema `pattern` of a price (the executor's first line of defence)."
  @spec amount_pattern() :: String.t()
  def amount_pattern, do: "^(0|[1-9][0-9]{0,9})(\\.[0-9]{1,2})?$"

  @doc "JSON Schema `pattern` of a price modifier, which may be negative."
  @spec delta_pattern() :: String.t()
  def delta_pattern, do: "^-?(0|[1-9][0-9]{0,9})(\\.[0-9]{1,2})?$"

  @doc "Parses a price: a non-negative decimal string."
  @spec parse(term()) :: {:ok, Decimal.t()} | {:error, String.t()}
  def parse(value), do: parse_with(@amount, value)

  @doc "Parses a price modifier: a decimal string that may start with `-`."
  @spec parse_delta(term()) :: {:ok, Decimal.t()} | {:error, String.t()}
  def parse_delta(value) do
    case parse_with(@delta, value) do
      {:ok, decimal} -> {:ok, if(Decimal.eq?(decimal, 0), do: Decimal.new(0), else: decimal)}
      error -> error
    end
  end

  defp parse_with(regex, value) when is_binary(value) do
    if Regex.match?(regex, value), do: {:ok, Decimal.new(value)}, else: {:error, @message}
  end

  defp parse_with(_regex, _value), do: {:error, "must be a decimal string"}

  @doc "Formats a decimal with two decimals (`nil` stays `nil`)."
  @spec format(Decimal.t() | nil) :: String.t() | nil
  def format(nil), do: nil
  def format(%Decimal{} = amount), do: amount |> Decimal.round(2) |> Decimal.to_string(:normal)

  @doc ~S|`%{"amount" => "12.50", "currency" => "EUR"}`, or `nil` without an amount.|
  @spec money(Decimal.t() | nil, String.t() | nil) :: map() | nil
  def money(nil, _currency), do: nil

  def money(%Decimal{} = amount, currency),
    do: %{"amount" => format(amount), "currency" => currency}

  @doc """
  Reads a stored value (a decimal string, a number, a `Decimal`) leniently.
  Returns `nil` for anything that is not a finite number (`"abc"`, `"NaN"`,
  `"Infinity"`): the caller keeps the raw value in that case and never
  rewrites what it did not parse.
  """
  @spec to_decimal(term()) :: Decimal.t() | nil
  def to_decimal(%Decimal{} = value), do: finite(value)
  def to_decimal(value) when is_integer(value), do: Decimal.new(value)
  def to_decimal(value) when is_float(value), do: Decimal.from_float(value)

  def to_decimal(value) when is_binary(value) do
    case Decimal.parse(String.trim(value)) do
      {%Decimal{} = decimal, ""} -> finite(decimal)
      _ -> nil
    end
  end

  def to_decimal(_value), do: nil

  defp finite(%Decimal{} = decimal),
    do: if(Decimal.nan?(decimal) or Decimal.inf?(decimal), do: nil, else: decimal)
end
