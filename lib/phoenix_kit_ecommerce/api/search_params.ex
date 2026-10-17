defmodule PhoenixKitEcommerce.API.SearchParams do
  @moduledoc """
  Turns one search query (decoded JSON, string keys) into the params of
  `PhoenixKitEcommerce.Search.Query.run/2`.

  Every problem is collected, so a client fixes its input in one round trip;
  an error path carries the prefix of the batch query it belongs to
  (`"queries[3].category_id"`). The executor has already checked the types the
  tool's schema declares; this module checks what a schema cannot (a UUID, a
  price that parses, a minimum above the maximum, a cursor that is ours) and
  never trusts a value it did not parse itself.

  Price bounds arrive in the response currency and leave in the base currency,
  each widened by how far the response currency's display rounding can move a
  price from its converted figure (half of its smallest unit; half a unit for
  `integer` and `charm_90`; one unit upwards for `charm_99`, which rounds down
  to the next X.99) so a product whose price is *displayed* at the edge is
  inside the filter (a bound of 18.18 EUR must find the product shown as 18.18
  EUR). A product shown just outside the bound can be inside the filter too.
  """

  alias PhoenixKitEcommerce.API.Context
  alias PhoenixKitEcommerce.API.Loader
  alias PhoenixKitEcommerce.Search.Query

  @default_limit 20
  @max_limit 100
  @max_option_keys 20
  @max_option_values 50
  @max_text_length 200
  # The longest option key echoed in an error path, in bytes.
  @max_path_key 64
  # A price above this is refused before it is turned into a Decimal.
  @max_price 1_000_000_000_000_000

  @sorts %{
    "relevance" => :relevance,
    "price_asc" => :price_asc,
    "price_desc" => :price_desc,
    "discount_desc" => :discount_desc,
    "newest" => :newest
  }

  @doc "The longest vendor, option key or option value, in characters."
  @spec max_text_length() :: pos_integer()
  def max_text_length, do: @max_text_length

  @doc "How many values one option key may list."
  @spec max_option_values() :: pos_integer()
  def max_option_values, do: @max_option_values

  @doc "Allowed values of `sort`."
  @spec sorts() :: [String.t()]
  def sorts, do: @sorts |> Map.keys() |> Enum.sort()

  @spec normalize(map(), Context.t(), String.t()) :: {:ok, map(), [map()]} | {:error, [map()]}
  def normalize(input, %Context{} = context, prefix \\ "")
      when is_map(input) and is_binary(prefix) do
    state =
      %{params: %{}, warnings: [], errors: [], prefix: prefix}
      |> put_q(input)
      |> put_category(input)
      |> put_prices(input, context)
      |> put_options(input)
      |> put_vendor(input)
      |> put_flags(input)
      |> put_sort(input)
      |> put_limit(input)
      |> put_offset(input)

    case state.errors do
      [] -> {:ok, state.params, Enum.reverse(state.warnings)}
      errors -> {:error, Enum.reverse(errors)}
    end
  end

  # --- fields ----------------------------------------------------------------

  defp put_q(state, input), do: put(state, :q, Query.clean_q(Map.get(input, "q")))

  defp put_category(state, input) do
    case Map.get(input, "category_id") do
      nil ->
        state

      id ->
        case Loader.canonical_uuid(id) do
          nil -> error(state, "category_id", "must be a UUID")
          uuid -> put(state, :category_id, uuid)
        end
    end
  end

  defp put_prices(state, input, context) do
    {state, min} = price(state, input, "price_min")
    {state, max} = price(state, input, "price_max")

    if min && max && Decimal.compare(min, max) == :gt do
      error(state, "price_min", "must not be greater than price_max")
    else
      state
      |> put_unless_nil(:price_min, min && bound(context, min, :min))
      |> put_unless_nil(:price_max, max && bound(context, max, :max))
    end
  end

  defp price(state, input, name) do
    case Map.get(input, name) do
      nil ->
        {state, nil}

      value ->
        case parse_decimal(value) do
          {:ok, decimal} ->
            {state, decimal}

          :error ->
            {error(state, name, "must be a non-negative number of at most #{@max_price}"), nil}
        end
    end
  end

  defp bound(%Context{currency: %{code: code}, base: %{code: code}}, amount, _direction),
    do: amount

  defp bound(%Context{currency: currency} = context, amount, direction) do
    margin = margin(currency, direction)

    widened =
      if direction == :min, do: Decimal.sub(amount, margin), else: Decimal.add(amount, margin)

    base = Context.to_base(context, widened)
    if Decimal.compare(base, 0) == :lt, do: Decimal.new(0), else: base
  end

  # How far `Currency.present/3` can put a displayed price from the converted
  # figure, towards the side the bound is widened to.
  defp margin(%{rounding_rule: rule}, _direction) when rule in ["integer", "charm_90"],
    do: Decimal.new("0.5")

  defp margin(%{rounding_rule: "charm_99"}, :max), do: Decimal.new(1)

  defp margin(currency, _direction) do
    places = currency.decimal_places || 2
    Decimal.div(Decimal.new(1), Decimal.new(2 * Integer.pow(10, places)))
  end

  defp parse_decimal(value) when is_integer(value), do: non_negative(Decimal.new(value))
  defp parse_decimal(value) when is_float(value), do: non_negative(Decimal.from_float(value))

  defp parse_decimal(value) when is_binary(value) do
    case Decimal.parse(String.trim(value)) do
      {decimal, ""} -> non_negative(decimal)
      _other -> :error
    end
  end

  defp parse_decimal(_other), do: :error

  defp non_negative(%Decimal{} = decimal) do
    if Decimal.nan?(decimal) or Decimal.inf?(decimal) or Decimal.compare(decimal, 0) == :lt or
         Decimal.compare(decimal, @max_price) == :gt,
       do: :error,
       else: {:ok, decimal}
  end

  defp put_options(state, input) do
    case Map.get(input, "options") do
      nil -> state
      options when is_map(options) -> options(state, options)
      _other -> error(state, "options", "must be an object of value lists")
    end
  end

  defp options(state, options) when map_size(options) > @max_option_keys,
    do: error(state, "options", "has too many attributes", %{limit: @max_option_keys})

  defp options(state, options) do
    {parsed, state} = Enum.reduce(options, {%{}, state}, &option/2)

    if map_size(parsed) > 0, do: put(state, :options, parsed), else: put(state, :options, %{})
  end

  defp option({key, values}, {acc, state}) do
    cond do
      not valid_key?(key) ->
        {acc,
         error(
           state,
           "options",
           "attribute keys must be 1 to #{@max_text_length} characters with no colon"
         )}

      valid_values?(values) ->
        # The index keeps trimmed keys (`OptionKeys.neutral_key/1`); keys that
        # trim to the same one are the same option.
        {Map.update(acc, String.trim(key), Enum.uniq(values), &Enum.uniq(&1 ++ values)), state}

      true ->
        {acc,
         error(
           state,
           "options." <> path_key(key),
           "must be a list of 1 to #{@max_option_values} value keys of at most #{@max_text_length} characters",
           %{limit: @max_option_values}
         )}
    end
  end

  defp valid_key?(key) do
    is_binary(key) and String.trim(key) != "" and not String.contains?(key, ":") and
      text?(key, @max_text_length)
  end

  defp valid_values?(values) do
    is_list(values) and values != [] and length(values) <= @max_option_values and
      Enum.all?(values, &(is_binary(&1) and &1 != "" and text?(&1, @max_text_length)))
  end

  # A NUL byte is refused by Postgres (22021) and would be a 500 on every
  # request that carries it; `Query.clean_q/1` removes it from the search text,
  # the other text filters are refused here instead. A character is at most
  # four bytes, so a longer string is refused before its graphemes are counted:
  # one letter followed by a million combining marks costs a size check, not a
  # walk over the whole string.
  defp text?(value, max_length) do
    byte_size(value) <= 4 * max_length and not String.contains?(value, <<0>>) and
      String.length(value) <= max_length
  end

  # An error path carries a key the client chose; keep it as short as core
  # keeps its own paths.
  defp path_key(key) when byte_size(key) > @max_path_key,
    do: String.byte_slice(key, 0, @max_path_key) <> "..."

  defp path_key(key), do: key

  defp put_vendor(state, input) do
    case Map.get(input, "vendor") do
      nil -> state
      vendor when is_binary(vendor) -> vendor(state, String.trim(vendor))
      _other -> error(state, "vendor", "must be a string")
    end
  end

  defp vendor(state, ""), do: state

  defp vendor(state, trimmed) do
    if text?(trimmed, @max_text_length) do
      put(state, :vendor, trimmed)
    else
      error(state, "vendor", "must be at most #{@max_text_length} characters, with no NUL", %{
        limit: @max_text_length
      })
    end
  end

  defp put_flags(state, input) do
    Enum.reduce([:on_sale, :made_to_order], state, fn key, acc ->
      name = Atom.to_string(key)

      case Map.get(input, name) do
        nil -> acc
        value when is_boolean(value) -> put(acc, key, value)
        _other -> error(acc, name, "must be true or false")
      end
    end)
  end

  defp put_sort(state, input) do
    case Map.get(input, "sort") do
      nil ->
        put(state, :sort, :relevance)

      name when is_binary(name) and is_map_key(@sorts, name) ->
        put(state, :sort, Map.fetch!(@sorts, name))

      _other ->
        error(state, "sort", "is not a known sort order", %{allowed: sorts()})
    end
  end

  defp put_limit(state, input) do
    case Map.get(input, "limit") do
      nil ->
        put(state, :limit, @default_limit)

      n when is_integer(n) and n > @max_limit ->
        state
        |> put(:limit, @max_limit)
        |> warn("limit_trimmed", "limit was reduced to #{@max_limit}", %{
          "requested" => n,
          "applied" => @max_limit
        })

      n when is_integer(n) and n >= 1 ->
        put(state, :limit, n)

      _other ->
        error(state, "limit", "must be an integer of at least 1", %{limit: 1})
    end
  end

  defp put_offset(state, input) do
    case Query.decode_cursor(Map.get(input, "cursor")) do
      {:ok, offset} -> put(state, :offset, offset)
      :error -> error(state, "cursor", "is not a cursor this API issued")
    end
  end

  # --- state -----------------------------------------------------------------

  defp put(state, key, value), do: %{state | params: Map.put(state.params, key, value)}

  defp put_unless_nil(state, _key, nil), do: state
  defp put_unless_nil(state, key, value), do: put(state, key, value)

  defp error(state, name, message, extra \\ %{}) do
    entry = Map.merge(%{path: state.prefix <> name, message: message}, extra)
    %{state | errors: [entry | state.errors]}
  end

  defp warn(state, code, message, extra) do
    %{
      state
      | warnings: [Map.merge(%{"code" => code, "message" => message}, extra) | state.warnings]
    }
  end
end
