defmodule PhoenixKitEcommerce.Shopify.VariantMapper do
  @moduledoc """
  Pure mapping from a Shopify Admin API product payload's `"options"`/
  `"variants"` into the shape `PhoenixKitEcommerce.Catalogue.Writer.
  sync_variants/2` attaches as catalogue attribute sets: one set per real
  option (Shopify's auto-generated single-option "no variants" product —
  option name `"Title"`, its lone value `"Default Title"` — is skipped,
  same as it never becomes a `_option_slots` entry on the legacy CSV
  path), values in the order they first appear across `variants[]`, and
  a per-value price modifier.

  No I/O, no catalogue/entities lookups — `build/1` never needs a live
  set to exist. `slug` (both the set's and each modifier map's key) is
  `PhoenixKitEcommerce.Catalogue.SetSlug.normalise/1` of the option's
  OWN name; resolving a raw variant-option VALUE label to a value slug
  is a separate, stateful step (`PhoenixKitEcommerce.Catalogue.
  ValueResolver`) `Writer.sync_variants/2` runs afterward, against
  whatever catalogue set that slug now names.

  ## Modifier rule

  For each option, group `variants[]` by that option's value
  (`variant["option<position>"]`); a value's modifier is
  `min(price of variants carrying that value) − min(price of every
  priced variant on the product)`. Grouping by MIN rather than "first
  variant seen" (the legacy `Import.OptionBuilder`'s rule, correct only
  when a single option drives price) matters here because two options
  combine on one variant — the cheapest variant carrying value X is the
  fair anchor for X's modifier regardless of what its OTHER option
  happened to be. The overall cheapest value's modifier is exactly
  `Decimal.new("0.00")` (equal minima, not a rounded near-zero) as long
  as Shopify's own price strings carry two decimals, which
  `Decimal.sub/2` preserves.
  """

  alias PhoenixKitEcommerce.Catalogue.SetSlug

  @default_option_names ["Title", "Default Title"]

  @type set :: %{
          name: String.t(),
          slug: String.t(),
          values: [String.t()],
          position: pos_integer()
        }
  @type t :: %{sets: [set()], modifiers: %{String.t() => %{String.t() => Decimal.t()}}}

  @doc """
  Builds `%{sets: [...], modifiers: %{set_slug => %{label => Decimal}}}`
  from `shopify_product`'s `"options"` and `"variants"`. Both keys
  default to `[]` when absent (a payload with no options at all — every
  variant on the default "Title" option — yields `sets: [], modifiers:
  %{}`).
  """
  @spec build(map()) :: t()
  def build(shopify_product) when is_map(shopify_product) do
    options = List.wrap(shopify_product["options"])
    variants = List.wrap(shopify_product["variants"])
    min_all_price = variants |> variant_prices() |> decimal_min()

    {sets, modifiers} =
      options
      |> Enum.with_index(1)
      |> Enum.reject(fn {option, _fallback_position} -> default_option?(option) end)
      |> Enum.reduce({[], %{}}, fn {option, fallback_position}, {sets_acc, modifiers_acc} ->
        position = option["position"] || fallback_position
        name = option["name"]
        slug = SetSlug.normalise(name)
        field = "option#{position}"

        values = ordered_values(variants, field)
        value_modifiers = build_modifiers(variants, field, min_all_price)

        set = %{name: name, slug: slug, values: values, position: position}

        {[set | sets_acc], Map.put(modifiers_acc, slug, value_modifiers)}
      end)

    %{sets: Enum.reverse(sets), modifiers: modifiers}
  end

  defp default_option?(%{"name" => name}) when name in @default_option_names, do: true
  defp default_option?(_option), do: false

  defp ordered_values(variants, field) do
    variants
    |> Enum.map(&Map.get(&1, field))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp build_modifiers(variants, field, min_all_price) do
    variants
    |> Enum.group_by(&Map.get(&1, field), &variant_price/1)
    |> Enum.reject(fn {value, _prices} -> is_nil(value) end)
    |> Map.new(fn {value, prices} ->
      {value, modifier_for(prices, min_all_price)}
    end)
  end

  defp modifier_for(prices, min_all_price) do
    case {decimal_min(Enum.reject(prices, &is_nil/1)), min_all_price} do
      {nil, _} -> Decimal.new("0.00")
      {_min_for_value, nil} -> Decimal.new("0.00")
      {min_for_value, min_all_price} -> Decimal.sub(min_for_value, min_all_price)
    end
  end

  defp variant_price(variant), do: parse_price(variant["price"])

  defp variant_prices(variants),
    do: variants |> Enum.map(&variant_price/1) |> Enum.reject(&is_nil/1)

  defp parse_price(%Decimal{} = decimal), do: decimal

  defp parse_price(price) when is_binary(price) do
    case Decimal.parse(price) do
      {decimal, ""} -> decimal
      _ -> nil
    end
  end

  defp parse_price(_price), do: nil

  defp decimal_min([]), do: nil
  defp decimal_min([first | rest]), do: Enum.reduce(rest, first, &Decimal.min/2)
end
