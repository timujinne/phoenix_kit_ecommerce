defmodule PhoenixKitEcommerce.API.Fingerprint do
  @moduledoc """
  The value fingerprint of a dry run: a hash of the **current
  values** of the fields an operation would touch, for the rows it would
  touch. Core stores it with the confirmation code and asks for it again when
  the code is used; if anything the operation reads has changed since the
  preview, the hashes differ and the code is refused.

  The hash is taken over a plain, sorted list of strings, never over a map
  or a struct, so the same values give the same hash on every node, and
  `updated_at` is deliberately not part of it. It is only ever compared with
  one taken minutes earlier by the same system: it is not a stored format,
  and `:erlang.term_to_binary/1` does not promise the same bytes across
  Erlang releases. A confirmation that crosses a release change would be
  refused, never wrongly accepted.
  """

  alias PhoenixKitEcommerce.API.Money

  @doc """
  Fingerprint of `rows`, a list of `{id, fields}` where `fields` is a map of
  field name to a `Decimal`, a string, a boolean, `nil`, or a nested map of
  those (price modifiers).
  """
  @spec compute([{String.t(), map()}]) :: String.t()
  def compute(rows) when is_list(rows) do
    rows
    |> Enum.map(fn {id, fields} -> {id, canonical(fields)} end)
    |> Enum.sort()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical(%Decimal{} = value), do: Money.format(value)

  defp canonical(%{} = map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), canonical(value)} end)
    |> Enum.sort()
  end

  defp canonical(value) when is_binary(value) or is_boolean(value) or is_nil(value), do: value

  defp canonical(value) when is_integer(value) or is_float(value) do
    case Money.to_decimal(value) do
      %Decimal{} = decimal -> Money.format(decimal)
      nil -> inspect(value)
    end
  end

  defp canonical(value), do: inspect(value)
end
