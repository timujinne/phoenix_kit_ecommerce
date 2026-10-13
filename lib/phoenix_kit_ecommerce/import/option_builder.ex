defmodule PhoenixKitEcommerce.Import.OptionBuilder do
  @moduledoc """
  Build option values and price modifiers from Shopify variant rows.

  Extracts Option1..Option10 names and values from CSV rows,
  calculates base price (minimum) and price modifiers (deltas from base).

  ## Extended Support

  - Supports Option1 through Option10 (Shopify standard)
  - Accepts option_mappings for slot-based options
  - Builds _option_slots structure for products using global options
  """

  alias PhoenixKitEcommerce.Import.Money

  @max_options 10
  @placeholder_option_names ["Title", "Default Title"]

  @doc """
  Build options data from variant rows (legacy format).

  Returns a map with:
  - base_price: minimum variant price (Decimal)
  - option1_name: name of first option (e.g., "Size")
  - option1_values: list of unique values for option1
  - option1_modifiers: map of value => price delta from base
  - option2_name: name of second option (e.g., "Color")
  - option2_values: list of unique values for option2

  ## Examples

      OptionBuilder.build_from_variants(rows)
      # => %{
      #   base_price: Decimal.new("22.80"),
      #   option1_name: "Size",
      #   option1_values: ["4 inches (10 cm)", "5 inches (13 cm)", ...],
      #   option1_modifiers: %{"4 inches (10 cm)" => "0", "5 inches (13 cm)" => "5.00", ...},
      #   option2_name: "Color",
      #   option2_values: ["Black", "White", ...]
      # }
  """
  def build_from_variants(rows) when is_list(rows) do
    # Get option names from first row
    first_row = List.first(rows)
    option1_name = get_non_empty(first_row, "Option1 Name")
    option2_name = get_non_empty(first_row, "Option2 Name")

    # Extract variants with prices
    variants =
      rows
      |> Enum.map(fn row ->
        %{
          option1_value: get_non_empty(row, "Option1 Value"),
          option2_value: get_non_empty(row, "Option2 Value"),
          price: parse_price(row["Variant Price"])
        }
      end)
      |> Enum.filter(& &1.price)

    # Calculate base price (minimum)
    base_price =
      variants
      |> Enum.map(& &1.price)
      |> decimal_min()

    # Build option1 data (typically Size - affects price)
    {option1_values, option1_modifiers} = build_option_data(variants, :option1_value, base_price)

    # Build option2 values (typically Color - no price impact, just values)
    option2_values = get_unique_values(variants, :option2_value)

    option1 =
      if placeholder_option?(option1_name, option1_values),
        do: {nil, [], %{}},
        else: {option1_name, option1_values, option1_modifiers}

    {option1_name, option1_values, option1_modifiers} = option1

    %{
      base_price: base_price,
      option1_name: option1_name,
      option1_values: option1_values,
      option1_modifiers: option1_modifiers,
      option2_name: option2_name,
      option2_values: option2_values
    }
  end

  @doc """
  Build extended options data from variant rows.

  Supports Option1 through Option10 and optional slot mappings.

  ## Arguments

  - `rows` - List of CSV row maps for a single product
  - `opts` - Keyword options:
    - `:option_mappings` - List of mapping configs from ImportConfig

  ## Returns

  Map with:
  - `base_price` - Minimum variant price
  - `options` - List of option data for each option found
  - `option_slots` - Slot definitions if mappings provided

  ## Examples

      # Without mappings (standard import)
      OptionBuilder.build_extended(rows)
      # => %{
      #   base_price: Decimal.new("22.80"),
      #   options: [
      #     %{position: 1, name: "Size", values: [...], modifiers: %{...}},
      #     %{position: 2, name: "Cup Color", values: [...]},
      #     %{position: 3, name: "Liquid Color", values: [...]}
      #   ],
      #   option_slots: []
      # }

      # With mappings (slot-based import)
      mappings = [
        %{"csv_name" => "Cup Color", "slot_key" => "cup_color", "source_key" => "color"},
        %{"csv_name" => "Liquid Color", "slot_key" => "liquid_color", "source_key" => "color"}
      ]
      OptionBuilder.build_extended(rows, option_mappings: mappings)
      # => %{
      #   base_price: Decimal.new("22.80"),
      #   options: [...],
      #   option_slots: [
      #     %{slot: "cup_color", source_key: "color", label: "Cup Color", values: [...]},
      #     %{slot: "liquid_color", source_key: "color", label: "Liquid Color", values: [...]}
      #   ]
      # }
  """
  def build_extended(rows, opts \\ []) when is_list(rows) do
    option_mappings = Keyword.get(opts, :option_mappings, [])
    first_row = List.first(rows)

    # Extract variants with prices and all option values
    variants = extract_all_variants(rows)

    # Calculate base price (minimum)
    base_price =
      variants
      |> Enum.map(& &1.price)
      |> Enum.filter(& &1)
      |> decimal_min()

    # Build option data for each option position
    options =
      for i <- 1..@max_options,
          name = get_option_name(first_row, i),
          name != nil,
          field = String.to_atom("option#{i}_value"),
          {values, modifiers} = build_option_data(variants, field, base_price),
          not placeholder_option?(name, values) do
        # Only include modifiers if they have non-zero values
        has_price_impact = Enum.any?(modifiers, fn {_k, v} -> v != "0" end)

        %{
          position: i,
          name: name,
          values: values,
          modifiers: if(has_price_impact, do: modifiers, else: %{})
        }
      end

    # Build option slots from mappings
    option_slots = build_option_slots_from_mappings(options, option_mappings)

    %{
      base_price: base_price,
      options: options,
      option_slots: option_slots
    }
  end

  # Shopify exports a product WITHOUT variants as one option named "Title"
  # with the single value "Default Title". It is not a choice: imported as
  # an option it becomes a required one-value picker on the product page.
  # `Shopify.VariantMapper` skips the same pair on the API path.
  defp placeholder_option?(name, values),
    do:
      name in @placeholder_option_names and Enum.all?(values, &(&1 in @placeholder_option_names))

  # Extract all option values (Option1..Option10) from variant rows
  defp extract_all_variants(rows) do
    Enum.map(rows, fn row ->
      base = %{price: parse_price(row["Variant Price"])}

      # Add option values for each position
      Enum.reduce(1..@max_options, base, fn i, acc ->
        key = String.to_atom("option#{i}_value")
        value = get_non_empty(row, "Option#{i} Value")
        Map.put(acc, key, value)
      end)
    end)
    |> Enum.filter(& &1.price)
  end

  # Get option name for a position
  defp get_option_name(row, position) do
    get_non_empty(row, "Option#{position} Name")
  end

  # Build option slots from mappings
  defp build_option_slots_from_mappings(options, mappings) when is_list(mappings) do
    mappings
    |> Enum.map(fn mapping ->
      csv_name = mapping["csv_name"]
      slot_key = mapping["slot_key"]
      source_key = mapping["source_key"]
      label = mapping["label"] || csv_name

      # Find the option with matching name
      option = Enum.find(options, fn opt -> opt.name == csv_name end)

      if option && slot_key do
        %{
          slot: slot_key,
          source_key: source_key,
          label: label,
          values: option.values,
          position: option.position
        }
      else
        nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp build_option_slots_from_mappings(_, _), do: []

  # Private helpers

  defp get_non_empty(row, key) do
    case row[key] do
      nil -> nil
      "" -> nil
      value -> String.trim(value)
    end
  end

  # Shopify's "Variant Price" goes through the shared supplier-money parser.
  #
  # This used to match `{decimal, _}` on `Decimal.parse/1` and throw the
  # remainder away — the identical wrong-money defect that was fixed on the
  # Prom.ua side and left standing here. A feed re-exported from a
  # comma-decimal locale imported "12,50" as 12 and "1,234.56" as 1, and
  # since `base_price` is the MINIMUM variant price, one mangled row set the
  # product's price for every variant. Nothing errored; the product just
  # went on sale at a fraction of its price.
  #
  # `nil` is preserved for an unreadable cell: callers already reject those
  # variants rather than treating them as free.
  defp parse_price(str), do: Money.parse(str)

  defp build_option_data(variants, field, base_price) do
    # Get unique values preserving order of first appearance
    values =
      variants
      |> Enum.map(&Map.get(&1, field))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    # Build price modifiers for each value
    # Group by value and take the first price for each
    price_by_value =
      variants
      |> Enum.reduce(%{}, fn v, acc ->
        value = Map.get(v, field)

        if value && !Map.has_key?(acc, value) do
          Map.put(acc, value, v.price)
        else
          acc
        end
      end)

    # Calculate modifiers as delta from base price
    modifiers =
      price_by_value
      |> Enum.reduce(%{}, fn {value, price}, acc ->
        modifier = Decimal.sub(price, base_price)
        Map.put(acc, value, Decimal.to_string(modifier))
      end)

    {values, modifiers}
  end

  defp get_unique_values(variants, field) do
    variants
    |> Enum.map(&Map.get(&1, field))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # Numeric minimum over Decimals; `Enum.min/2` uses Erlang term ordering,
  # which compares %Decimal{} structs structurally rather than by value and
  # picks the wrong element (10 over 9.99).
  #
  # No readable price at all yields nil, not zero. Zero imported cleanly and
  # published a FREE product: a feed whose price column is empty, "N/A" or
  # otherwise unparseable is a broken feed, and `price` is required, so the
  # row now fails and is reported instead of silently listing at 0.
  defp decimal_min([]), do: nil
  defp decimal_min([first | rest]), do: Enum.reduce(rest, first, &Decimal.min/2)
end
