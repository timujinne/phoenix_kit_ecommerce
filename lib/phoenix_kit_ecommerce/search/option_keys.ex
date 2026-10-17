defmodule PhoenixKitEcommerce.Search.OptionKeys do
  @moduledoc """
  The language-neutral option keys of a product (an option is
  `{attribute_key, value_key}`), read from the metadata both product sources
  keep: `_option_values` (key to values), `_value_labels` (key to value key to
  label, in the language the view was built for; catalogue source),
  `_value_slugs` (key to label to value key; catalogue source),
  `_option_labels` (key to the set's display name) and `_price_modifiers`.

  On the catalogue source a value of `_option_values` is the catalogue's own
  value key, and `_value_labels` says what it is shown as. A legacy product
  has no `_value_labels`: its value is its label, and it has no slug entry
  unless `_value_slugs` gives one, so it gets
  `PhoenixKit.Utils.Slug.slugify/2` of the label, which makes both shapes
  expose the same option.
  """

  alias PhoenixKit.Utils.Slug
  alias PhoenixKitEcommerce.Options

  @type value :: %{key: String.t(), label: String.t()}
  @type option :: %{
          key: String.t(),
          label: String.t(),
          affects_price: boolean(),
          values: [value()]
        }

  @doc """
  The options of `product`, sorted by key; options without a usable value are
  left out, and sets whose keys collapse to one key (`"a:b"` and `"a_b"`) are
  merged into one option.
  """
  @spec extract(PhoenixKitEcommerce.Product.t()) :: [option()]
  def extract(product) do
    meta = map(product.metadata)
    values = map(meta["_option_values"])
    slugs = map(meta["_value_slugs"])
    shown = map(meta["_value_labels"])
    names = map(meta["_option_labels"])
    modifiers = map(meta["_price_modifiers"])

    values
    |> Enum.sort_by(fn {key, _labels} -> to_string(key) end)
    |> Enum.flat_map(fn {raw_key, labels} ->
      raw_key = to_string(raw_key)
      key = neutral_key(raw_key)
      entries = entries(slugs, shown, raw_key, key, labels)

      if entries == [] do
        []
      else
        [
          %{
            key: key,
            label: set_label(names, raw_key),
            affects_price: Options.has_nonzero_modifiers?(Map.get(modifiers, raw_key)),
            values: entries
          }
        ]
      end
    end)
    |> Enum.group_by(& &1.key)
    |> Enum.sort_by(fn {key, _group} -> key end)
    |> Enum.map(fn {_key, [first | rest]} -> Enum.reduce(rest, first, &merge/2) end)
  end

  @doc """
  The language-neutral form of an attribute key: trimmed, and without a colon,
  because the pair format is `key:value`.
  """
  @spec neutral_key(String.t()) :: String.t()
  def neutral_key(key) when is_binary(key), do: key |> String.trim() |> neutral()

  @doc """
  The value key `extract/1` announces for `value` of the option `raw_key` of
  `product` (any map with `:metadata`): `value` itself when it is one of the
  catalogue's value keys, else the catalogue's slug for the label `value`,
  else the slugified label. A caller that has to turn a key a client sends
  back into what the cart stores goes through this, never a rule of its own.
  """
  @spec product_value_key(map(), String.t(), String.t()) :: String.t()
  def product_value_key(%{metadata: metadata}, raw_key, value) do
    metadata = map(metadata)
    raw_key = to_string(raw_key)

    if keyed_value?(map(metadata["_value_labels"]), raw_key, value),
      do: neutral(value),
      else: value_key(map(metadata["_value_slugs"]), raw_key, value)
  end

  @doc "`[\"size:large\", ...]`, sorted and unique."
  @spec pairs([option()]) :: [String.t()]
  def pairs(options) do
    for(option <- options, value <- option.values, do: option.key <> ":" <> value.key)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc ~s|Labels for the set keys and the pairs: `%{"size" => "Size", "size:large" => "Large"}`.|
  @spec labels([option()]) :: %{String.t() => String.t()}
  def labels(options) do
    Enum.reduce(options, %{}, fn option, acc ->
      Enum.reduce(option.values, Map.put(acc, option.key, option.label), fn value, acc ->
        Map.put(acc, option.key <> ":" <> value.key, value.label)
      end)
    end)
  end

  defp entries(slugs, shown, raw_key, key, values) do
    entries =
      for value <- List.wrap(values), is_binary(value), String.trim(value) != "" do
        entry(slugs, shown, raw_key, value)
      end

    if key == "", do: [], else: Enum.uniq_by(entries, & &1.key)
  end

  defp entry(slugs, shown, raw_key, value) do
    case shown |> Map.get(raw_key) |> map() |> Map.get(value) do
      label when is_binary(label) and label != "" ->
        %{key: neutral(value), label: String.trim(label)}

      _none ->
        %{key: value_key(slugs, raw_key, value), label: String.trim(value)}
    end
  end

  defp keyed_value?(shown, raw_key, value) do
    case shown |> Map.get(raw_key) |> map() |> Map.get(value) do
      label when is_binary(label) and label != "" -> true
      _none -> false
    end
  end

  defp value_key(slugs, key, label) do
    case slugs |> map() |> Map.get(key) |> map() |> Map.get(label) do
      slug when is_binary(slug) and slug != "" -> neutral(slug)
      _none -> label |> String.trim() |> fallback_key() |> neutral()
    end
  end

  defp fallback_key(label) do
    case Slug.slugify(label) do
      "" -> label |> String.downcase() |> String.replace(~r/\s+/u, "-")
      slug -> slug
    end
  end

  # The pair format is `key:value`, so neither part may hold a colon.
  defp neutral(key), do: String.replace(key, ":", "_")

  # The set's display name, else the same humanised key the rest of the module shows.
  defp set_label(names, raw_key) do
    case Map.get(names, raw_key) do
      name when is_binary(name) and name != "" -> name
      _none -> Options.humanize_key(raw_key)
    end
  end

  defp merge(option, acc) do
    %{
      acc
      | affects_price: acc.affects_price or option.affects_price,
        values: Enum.uniq_by(acc.values ++ option.values, & &1.key)
    }
  end

  defp map(%{} = value), do: value
  defp map(_other), do: %{}
end
