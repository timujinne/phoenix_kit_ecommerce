defmodule PhoenixKitEcommerce.API.CartOptions do
  @moduledoc """
  Language-neutral cart options of the public cart API.

  In input and output an option is `%{attribute_key, value_key}`. `add_to_cart`
  stores and prices by `selected_specs`, a map of attribute key to the value
  as the product source identifies it: the catalogue's value key, or on a
  legacy product the value's label. This module converts both ways:

    * the keys are the ones the product card announces: `Search.OptionKeys`
      (the attribute key with a colon turned into an underscore, the value's
      catalogue key, else the slugified label). This module has no key rule of
      its own; it only maps a key back to the value `add_to_cart` stores.

  A product offers the options `Options.get_selectable_specs_for_product/1`
  returns; the ones flagged `"required"` must be given (the same rule
  `add_to_cart` enforces, so an accepted line is an addable line).

  The writer stores the neutral options on the line (`metadata["api_options"]`)
  so that a cart written in one language reads the same in another;
  `from_item/2` prefers them.

  A line stored before the catalogue's value keys were its identity holds the
  labels of the language it was added in; `to_options/2` maps those back
  through the product.
  """

  alias PhoenixKitEcommerce.CartItem
  alias PhoenixKitEcommerce.Options
  alias PhoenixKitEcommerce.Product
  alias PhoenixKitEcommerce.Search.OptionKeys

  @type option :: %{attribute_key: String.t(), value_key: String.t()}
  @type labelled :: %{
          attribute_key: String.t(),
          value_key: String.t(),
          attribute_label: String.t(),
          value_label: String.t()
        }

  @doc """
  Normalizes the caller's `options` (string-keyed maps from JSON, or
  atom-keyed maps) into sorted `%{attribute_key, value_key}` maps. `nil` means
  no options; anything malformed is `:error`.
  """
  @spec normalize(term()) :: {:ok, [option()]} | :error
  def normalize(nil), do: {:ok, []}

  def normalize(options) when is_list(options) do
    options
    |> Enum.reduce_while({:ok, []}, fn option, {:ok, acc} ->
      case pair(option) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, sort(list)}
      :error -> :error
    end
  end

  def normalize(_other), do: :error

  defp pair(%{"attribute_key" => key, "value_key" => value}), do: build(key, value)
  defp pair(%{attribute_key: key, value_key: value}), do: build(key, value)
  defp pair(_other), do: :error

  defp build(key, value) when is_binary(key) and is_binary(value) and key != "" and value != "",
    do: {:ok, %{attribute_key: key, value_key: value}}

  defp build(_key, _value), do: :error

  @doc """
  The `selected_specs` for a product from neutral options, or the first thing
  wrong: `{:error, :option_invalid | :option_required, context}`.
  """
  @spec to_specs(Product.t(), [option()]) ::
          {:ok, %{String.t() => String.t()}} | {:error, :option_invalid | :option_required, map()}
  def to_specs(%Product{} = product, options) when is_list(options) do
    schema = Options.get_selectable_specs_for_product(product)
    by_key = Map.new(schema, &{OptionKeys.neutral_key(&1["key"]), &1})

    with :ok <- no_duplicate_keys(options),
         {:ok, specs} <- map_options(options, by_key, product) do
      check_required(schema, specs, product)
    end
  end

  defp no_duplicate_keys(options) do
    keys = Enum.map(options, & &1.attribute_key)

    case keys -- Enum.uniq(keys) do
      [] ->
        :ok

      [key | _] ->
        {:error, :option_invalid, %{attribute_key: key, reason: "duplicate_attribute_key"}}
    end
  end

  # The accumulator holds the RAW attribute key (what `add_to_cart` validates
  # against), the options hold the neutral one.
  defp map_options(options, by_key, product) do
    Enum.reduce_while(options, {:ok, %{}}, fn option, {:ok, acc} ->
      case map_option(option, by_key, product) do
        {:ok, raw_key, stored} -> {:cont, {:ok, Map.put(acc, raw_key, stored)}}
        {:error, _code, _context} = error -> {:halt, error}
      end
    end)
  end

  defp map_option(%{attribute_key: key, value_key: value}, by_key, product) do
    case Map.fetch(by_key, key) do
      :error ->
        {:error, :option_invalid,
         %{
           attribute_key: key,
           value_key: value,
           allowed_attribute_keys: by_key |> Map.keys() |> Enum.sort()
         }}

      {:ok, spec} ->
        stored_for(key, value, spec, product)
    end
  end

  defp stored_for(key, value, spec, product) do
    pairs = value_pairs(spec, product)

    case List.keyfind(pairs, value, 0) do
      {_value_key, stored} -> {:ok, spec["key"], stored}
      nil when pairs == [] -> {:ok, spec["key"], value}
      nil -> invalid(key, value, Enum.map(pairs, &elem(&1, 0)))
    end
  end

  defp invalid(key, value, allowed),
    do: {:error, :option_invalid, %{attribute_key: key, value_key: value, allowed: allowed}}

  defp check_required(schema, specs, product) do
    case Enum.find(schema, &(&1["required"] == true and not Map.has_key?(specs, &1["key"]))) do
      nil ->
        {:ok, specs}

      spec ->
        {:error, :option_required,
         %{
           attribute_key: OptionKeys.neutral_key(spec["key"]),
           allowed: spec |> value_pairs(product) |> Enum.map(&elem(&1, 0))
         }}
    end
  end

  # `[{value_key, stored}]` this product offers for an option: the values of
  # its option list, each under the key the product card announces for it.
  # `stored` is what `selected_specs` holds for it.
  defp value_pairs(spec, product) do
    raw_key = spec["key"]

    values =
      case spec["options"] do
        list when is_list(list) -> Enum.filter(list, &is_binary/1)
        _ -> []
      end

    Enum.map(values, &{OptionKeys.product_value_key(product, raw_key, &1), &1})
  end

  @doc "The neutral options of a `selected_specs` map for a product."
  @spec to_options(Product.t() | map(), %{String.t() => String.t()}) :: [option()]
  def to_options(%{metadata: _} = product, specs) when is_map(specs) do
    specs
    |> Enum.map(fn {key, value} ->
      %{
        attribute_key: OptionKeys.neutral_key(to_string(key)),
        value_key: OptionKeys.product_value_key(product, key, to_string(value))
      }
    end)
    |> sort()
  end

  @doc """
  The neutral options of a cart line: the ones the API stored on it, else its
  values mapped through `product` (when given), else through the key rule alone.
  """
  @spec from_item(CartItem.t(), Product.t() | nil) :: [option()]
  def from_item(%CartItem{} = item, product) do
    case stored(item) do
      [_ | _] = stored -> stored
      [] -> to_options(product || %{metadata: %{}}, item.selected_specs || %{})
    end
  end

  @doc """
  `options` with the labels a buyer reads, in the language `product` was loaded
  for: `attribute_label` (the option's name) and `value_label` (what the value
  is shown as). They come from the product's own options
  (`Search.OptionKeys.extract/1`), the ones its card announces.

  A line whose product is gone (`nil`), or no longer offers that option or value,
  keeps what it can: the option's name from its key (`Options.humanize_key/1`) and
  the value as the line shows it, `stored` (`SelectedSpecs.labels/1`: the label
  snapshot taken when a catalogue line was added, or the label a legacy line was
  added under), else the key.
  """
  @spec labelled([option()], Product.t() | map() | nil, %{String.t() => String.t()} | nil) ::
          [labelled()]
  def labelled(options, product, stored \\ %{}) do
    offered = if product, do: OptionKeys.extract(product), else: []
    stored = stored_values(stored)

    Enum.map(options, fn %{attribute_key: key, value_key: value_key} = option ->
      found = Enum.find(offered, &(&1.key == key))
      value = found && Enum.find(found.values, &(&1.key == value_key))

      Map.merge(option, %{
        attribute_label: (found && found.label) || Options.humanize_key(key),
        value_label: (value && value.label) || Map.get(stored, key, value_key)
      })
    end)
  end

  defp stored_values(specs) when is_map(specs),
    do:
      Map.new(specs, fn {key, value} ->
        {OptionKeys.neutral_key(to_string(key)), to_string(value)}
      end)

  defp stored_values(_none), do: %{}

  @doc "The neutral options the API stored on a line (`metadata[\"api_options\"]`), or `[]`."
  @spec stored(CartItem.t()) :: [option()]
  def stored(%CartItem{metadata: metadata}) do
    with list when is_list(list) <- (metadata || %{})["api_options"],
         {:ok, options} <- normalize(list) do
      options
    else
      _ -> []
    end
  end

  @doc "The JSON form stored on a line."
  @spec stored_form([option()]) :: [%{String.t() => String.t()}]
  def stored_form(options) do
    Enum.map(options, &%{"attribute_key" => &1.attribute_key, "value_key" => &1.value_key})
  end

  @doc "Sorted `[attribute_key, value_key]` pairs: the form options are compared and hashed in."
  @spec canonical([option()]) :: [[String.t()]]
  def canonical(options) do
    options |> sort() |> Enum.map(&[&1.attribute_key, &1.value_key])
  end

  defp sort(options), do: Enum.sort_by(options, &{&1.attribute_key, &1.value_key})
end
