defmodule PhoenixKitEcommerce.Shipping.Codec do
  @moduledoc false
  # Shared (de)serialisation helpers for the shipping structs.
  #
  # `dump/1` turns any term into something JSONB can hold (string keys,
  # Decimal as string, atoms as strings, DateTime as ISO 8601). The `from_*`
  # readers are the tolerant inverse: anything unparseable becomes `nil`.

  @doc "Encodes a struct as a JSON-safe map with string keys."
  @spec encode(struct()) :: %{optional(String.t()) => term()}
  def encode(%{__struct__: _} = struct) do
    struct
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), dump(value)} end)
  end

  @doc "Converts any term into a JSON-safe value."
  @spec dump(term()) :: term()
  def dump(nil), do: nil
  def dump(%Decimal{} = decimal), do: Decimal.to_string(decimal, :normal)
  def dump(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def dump(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  def dump(%Date{} = value), do: Date.to_iso8601(value)
  def dump(%Time{} = value), do: Time.to_iso8601(value)
  def dump(value) when is_boolean(value) or is_number(value) or is_binary(value), do: value
  def dump(value) when is_atom(value), do: Atom.to_string(value)

  def dump(%{__struct__: module} = struct) do
    if Code.ensure_loaded?(module) and function_exported?(module, :to_map, 1) do
      module.to_map(struct)
    else
      struct |> Map.from_struct() |> dump()
    end
  end

  def dump(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {key_to_string(key), dump(item)} end)
  end

  def dump(value) when is_list(value), do: Enum.map(value, &dump/1)
  def dump(value) when is_tuple(value), do: value |> Tuple.to_list() |> dump()
  def dump(value), do: inspect(value)

  @doc "Reads a key from a map that may use string or atom keys."
  @spec get(term(), atom()) :: term()
  def get(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, Atom.to_string(key)) do
      {:ok, value} -> value
      :error -> Map.get(map, key)
    end
  end

  def get(_other, _key), do: nil

  @doc "Parses a Decimal from a Decimal, integer, float or string (decimal comma allowed)."
  @spec decimal(term()) :: Decimal.t() | nil
  def decimal(%Decimal{} = value), do: finite(value)
  def decimal(value) when is_integer(value), do: Decimal.new(value)
  def decimal(value) when is_float(value), do: value |> Decimal.from_float() |> finite()

  def decimal(value) when is_binary(value) do
    cleaned = value |> String.replace(~r/\s+/u, "") |> String.replace(",", ".")

    case Decimal.parse(cleaned) do
      {%Decimal{} = decimal, ""} -> finite(decimal)
      _ -> nil
    end
  end

  def decimal(_other), do: nil

  defp finite(%Decimal{} = decimal) do
    if Decimal.nan?(decimal) or Decimal.inf?(decimal), do: nil, else: decimal
  end

  @doc "Parses an integer from an integer, float, Decimal or numeric string."
  @spec integer(term()) :: integer() | nil
  def integer(value) when is_integer(value), do: value
  def integer(value) when is_float(value), do: round(value)

  def integer(value) when is_binary(value) do
    value |> decimal() |> integer()
  end

  def integer(%Decimal{} = value) do
    case finite(value) do
      nil -> nil
      decimal -> decimal |> Decimal.round(0) |> Decimal.to_integer()
    end
  end

  def integer(_other), do: nil

  @doc "Parses a float from a number or numeric string."
  @spec float(term()) :: float() | nil
  def float(value) when is_float(value), do: value
  def float(value) when is_integer(value), do: value * 1.0

  def float(value) when is_binary(value) do
    case value |> String.trim() |> String.replace(",", ".") |> Float.parse() do
      {number, ""} -> number
      _ -> nil
    end
  end

  def float(_other), do: nil

  @doc "Parses a string from a binary, number or (non-nil, non-boolean) atom."
  @spec string(term()) :: String.t() | nil
  def string(value) when is_binary(value), do: value
  def string(value) when is_number(value), do: to_string(value)
  def string(value) when is_boolean(value) or is_nil(value), do: nil
  def string(value) when is_atom(value), do: Atom.to_string(value)
  def string(_other), do: nil

  @doc "Normalises an ISO 3166-1 alpha-2 country code: two letters in upper case, else `nil`."
  @spec country(term()) :: String.t() | nil
  def country(value) when is_binary(value) do
    code = value |> String.trim() |> String.upcase()
    if Regex.match?(~r/\A[A-Z]{2}\z/, code), do: code
  end

  def country(_other), do: nil

  @doc "A list of country codes: normalised, without duplicates; anything else is dropped."
  @spec countries(term()) :: [String.t()]
  def countries(value) when is_list(value) do
    value |> Enum.map(&country/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  def countries(_other), do: []

  @doc "Maps an atom or its string form onto one of the `allowed` atoms."
  @spec atom(term(), [atom()]) :: atom() | nil
  def atom(value, allowed) when is_atom(value) and not is_nil(value) do
    if value in allowed, do: value
  end

  def atom(value, allowed) when is_binary(value) do
    Enum.find(allowed, &(Atom.to_string(&1) == value))
  end

  def atom(_other, _allowed), do: nil

  @doc "Parses a DateTime from a DateTime or ISO 8601 string."
  @spec datetime(term()) :: DateTime.t() | nil
  def datetime(%DateTime{} = value), do: value

  def datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  def datetime(_other), do: nil

  @doc "Parses a Date from a Date or ISO 8601 string."
  @spec date(term()) :: Date.t() | nil
  def date(%Date{} = value), do: value

  def date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  def date(_other), do: nil

  @doc "Returns a map with string keys (deeply), or an empty map for anything else."
  @spec string_map(term()) :: map()
  def string_map(%{__struct__: _}), do: %{}

  def string_map(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {key_to_string(key), stringify(item)} end)
  end

  def string_map(_other), do: %{}

  defp stringify(%{__struct__: _} = struct), do: struct
  defp stringify(value) when is_map(value), do: string_map(value)
  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value), do: value

  @doc "Parses a list with `fun`, dropping elements that parse to `nil`."
  @spec list(term(), (term() -> term())) :: [term()]
  def list(value, fun) when is_list(value) do
    value |> Enum.map(fun) |> Enum.reject(&is_nil/1)
  end

  def list(_other, _fun), do: []

  @doc "Parses a nested struct through its own `from_map/1`."
  @spec struct_from(term(), module()) :: struct() | nil
  def struct_from(%{__struct__: module} = value, module), do: value
  def struct_from(value, module) when is_map(value), do: module.from_map(value)
  def struct_from(_other, _module), do: nil

  defp key_to_string(key) when is_binary(key), do: key
  defp key_to_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_to_string(key), do: inspect(key)
end
