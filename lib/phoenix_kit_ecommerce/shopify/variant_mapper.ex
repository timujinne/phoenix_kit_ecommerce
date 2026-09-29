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
  (`variant["option<position>"]`); a value's modifier `M_o(v)` is
  `min(price of variants carrying that value) − min(price of every
  priced variant on the product)`. Grouping by MIN rather than "first
  variant seen" (the legacy `Import.OptionBuilder`'s rule, correct only
  when a single option drives price) matters here because two options
  combine on one variant — the cheapest variant carrying value X is the
  fair anchor for X's modifier regardless of what its OTHER option
  happened to be. The overall cheapest value's modifier is exactly
  `Decimal.new("0.00")` (equal minima, not a rounded near-zero) as long
  as Shopify's own price strings carry two decimals, which
  `Decimal.sub/2` preserves. The base price is never touched — it stays
  `min_all` — so `ProductDiff`, which compares the base against the
  minimum variant price, never sees a false mismatch from this fit.

  ## Non-additive matrices: two rules, chosen per item

  Per-option modifiers can only ever express an ADDITIVE price matrix:
  the storefront prices a selection as `base + Σ M_o(value)`. A Shopify
  matrix that is not additive — S/L × Red/Blue at 10/12/15/20 gives
  S:0, L:5, Red:0, Blue:2 and predicts 17 for L-Blue, where Shopify
  charges 20 — is under-priced by that reconstruction. `build/2` fits
  the modifiers under a `rule:` option:

    * `:cheapest` — the raw `M_o` above, unchanged. Some combinations
      may come out cheaper than Shopify.
    * `:never_cheaper` (the default) — for every option `a` whose value
      is present on every priced variant (an "eligible absorber"), a
      candidate lets `a` absorb the shortfall:
      `A(v) = max(0, max over priced variants with a=v of
      (price − min_all − Σ_{o≠a} M_o(that variant's value)))`, merged
      over `M_o[a]`; the other options keep their plain `M_o`. By
      construction every priced variant's prediction is `≥` its
      Shopify price under any such candidate. The candidate with the
      least total overcharge (sum of the positive `predicted − actual`
      deviations) is picked; ties go to the option with the lower
      Shopify position. An option can never be the absorber if any
      priced variant is missing its value — that variant would not
      fall into any `A(v)` and the guarantee would not hold for it. If
      no option is eligible, the product falls back to `:cheapest` and
      `:fit.rule` reports the rule actually applied, not the one asked
      for.

  Either way, a product whose plain `M_o` already reconstructs every
  priced variant exactly is untouched — `build/2` returns the same
  modifiers under both rules, `:fit.exact?` is `true`, and there are no
  warnings.

  ## Fit summary and warnings

  `build/2` always returns a `:fit` summary (`t:fit/0`): whether the
  product came out exact, the rule actually applied, how many priced
  variants there are, how many ended up predicted above (`:over`) or
  below (`:under`) their Shopify price, and the largest such gap in
  each direction (`:max_over`/`:max_under`, both non-negative). A
  `:approximated?` says whether the modifiers themselves miss Shopify
  (an approximation under the rule); a fit that is non-exact only because
  of `:base_offset` is NOT an approximation. A
  non-exact product gets exactly ONE line in `:warnings` (and one
  `Logger.warning` call) naming the rule, the count and the largest
  gaps — never one line per variant; a caller writing an approximated
  product's prices must surface that line rather than let the write
  pass as clean.

  The fit is measured against `opts[:base_price]` when given (see
  `build/2`), and `:base_offset` is how far that base sits from Shopify's
  cheapest variant — `0.00` when they agree. A non-zero offset makes the
  fit non-exact on its own and is named in the warning: the variant sync
  never writes the base price (the Changes tab does), so this is the only
  place a drifted base becomes visible.
  """

  require Logger

  alias PhoenixKitEcommerce.Catalogue.SetSlug

  @default_option_names ["Title", "Default Title"]
  @zero Decimal.new("0.00")

  @type set :: %{
          name: String.t(),
          slug: String.t(),
          values: [String.t()],
          position: pos_integer()
        }
  @type rule :: :never_cheaper | :cheapest
  @type fit :: %{
          exact?: boolean(),
          rule: rule(),
          variants: non_neg_integer(),
          over: non_neg_integer(),
          under: non_neg_integer(),
          max_over: Decimal.t(),
          max_under: Decimal.t(),
          base_offset: Decimal.t(),
          approximated?: boolean()
        }
  @type t :: %{
          sets: [set()],
          modifiers: %{String.t() => %{String.t() => Decimal.t()}},
          fit: fit(),
          warnings: [String.t()]
        }

  @doc """
  Builds `%{sets: [...], modifiers: %{set_slug => %{label => Decimal}},
  fit: fit(), warnings: [...]}` from `shopify_product`'s `"options"`
  and `"variants"`. `sets`/`modifiers` default to `[]`/`%{}` when
  absent (a payload with no options at all — every variant on the
  default "Title" option — yields `sets: [], modifiers: %{}`, an exact
  `:fit`, `warnings: []`).

  `opts[:rule]` is `:never_cheaper` (default) or `:cheapest` — see the
  moduledoc. `build/1` is `build(shopify_product, [])`.

  `opts[:base_price]` is the base price the storefront actually adds the
  modifiers to (the item's stored one). The modifiers are always built
  against Shopify's cheapest variant; only the `:fit` is measured against
  `:base_price`, so a base that no longer equals Shopify's cheapest
  variant (a variant was removed in Shopify and the price change was not
  applied yet) shows up as a non-exact fit with `:base_offset` set,
  instead of the storefront drifting silently. Omitted, the fit assumes
  the base IS the cheapest variant.
  """
  @spec build(map(), keyword()) :: t()
  def build(shopify_product, opts \\ []) when is_map(shopify_product) do
    rule = Keyword.get(opts, :rule, :never_cheaper)
    options = List.wrap(shopify_product["options"])
    variants = List.wrap(shopify_product["variants"])
    min_all_price = variants |> variant_prices() |> decimal_min()

    {sets, modifiers, fields} =
      options
      |> Enum.with_index(1)
      |> Enum.reject(fn {option, _fallback_position} -> default_option?(option) end)
      |> Enum.reduce({[], %{}, []}, fn {option, fallback_position},
                                       {sets_acc, modifiers_acc, fields_acc} ->
        position = option["position"] || fallback_position
        name = option["name"]
        slug = SetSlug.normalise(name)
        field = "option#{position}"

        values = ordered_values(variants, field)
        value_modifiers = build_modifiers(variants, field, min_all_price)

        set = %{name: name, slug: slug, values: values, position: position}

        {[set | sets_acc], Map.put(modifiers_acc, slug, value_modifiers),
         [{slug, field} | fields_acc]}
      end)

    # Tie-break for `fit_modifiers/5`'s candidate choice must go to the
    # LOWER Shopify position (moduledoc), not whichever option happened
    # to be listed first in the payload's own "options" array — those
    # can differ. `field` is always `"option<position>"`, so sorting by
    # the parsed suffix gives exactly that order; `Enum.min_by/3` then
    # keeps the first (= lowest-position) candidate on a genuine tie.
    # `sets`/`modifiers` (Shopify's own array order) are untouched.
    fields =
      fields
      |> Enum.reverse()
      |> Enum.sort_by(fn {_slug, "option" <> pos} -> String.to_integer(pos) end)

    priced = Enum.reject(variants, &is_nil(variant_price(&1)))
    {modifiers, applied_rule} = fit_modifiers(rule, modifiers, fields, priced, min_all_price)
    anchor = anchor(Keyword.get(opts, :base_price), min_all_price, fields)
    fit = fit_summary(applied_rule, modifiers, fields, priced, {min_all_price, anchor})

    %{
      sets: Enum.reverse(sets),
      modifiers: modifiers,
      fit: fit,
      warnings: fit_warnings(shopify_product, fit)
    }
  end

  defp fit_modifiers(:cheapest, modifiers, _fields, _priced, _min_all), do: {modifiers, :cheapest}

  defp fit_modifiers(:never_cheaper, modifiers, [], _priced, _min_all),
    do: {modifiers, :never_cheaper}

  defp fit_modifiers(:never_cheaper, modifiers, _fields, _priced, nil),
    do: {modifiers, :never_cheaper}

  defp fit_modifiers(:never_cheaper, modifiers, fields, priced, min_all) do
    if Enum.all?(deviations(modifiers, fields, priced, min_all), &Decimal.eq?(&1, 0)) do
      {modifiers, :never_cheaper}
    else
      candidates =
        for {_slug, field} = absorber <- fields, eligible_absorber?(priced, field) do
          absorb(modifiers, fields, absorber, priced, min_all)
        end

      case candidates do
        [] ->
          {modifiers, :cheapest}

        _ ->
          {Enum.min_by(candidates, &total_overcharge(&1, fields, priced, min_all), Decimal),
           :never_cheaper}
      end
    end
  end

  defp eligible_absorber?(priced, field),
    do: Enum.all?(priced, &(Map.get(&1, field) not in [nil, ""]))

  defp absorb(modifiers, fields, {slug, field} = absorber, priced, min_all) do
    others = List.delete(fields, absorber)

    absorbed =
      priced
      |> Enum.group_by(&Map.get(&1, field))
      |> Map.new(fn {value, group} ->
        residual =
          group
          |> Enum.map(fn variant ->
            variant
            |> variant_price()
            |> Decimal.sub(predicted_price(variant, modifiers, others, min_all))
          end)
          |> Enum.reduce(&Decimal.max/2)

        {value, Decimal.max(residual, @zero)}
      end)

    Map.update(modifiers, slug, absorbed, &Map.merge(&1, absorbed))
  end

  # predicted − actual for every priced variant.
  defp deviations(modifiers, fields, priced, min_all) do
    Enum.map(
      priced,
      &Decimal.sub(predicted_price(&1, modifiers, fields, min_all), variant_price(&1))
    )
  end

  defp total_overcharge(modifiers, fields, priced, min_all) do
    modifiers
    |> deviations(fields, priced, min_all)
    |> Enum.filter(&Decimal.gt?(&1, 0))
    |> Enum.reduce(@zero, &Decimal.add/2)
  end

  # The price the storefront starts from: the item's stored base when the
  # caller passed one, else Shopify's own cheapest variant (the modifiers'
  # anchor). `nil` when there is nothing priced at all.
  # A product with no real options has no modifiers for this sync to
  # re-anchor — a base that differs from its one Shopify price is a plain
  # pending price change, which the Changes tab already reports.
  defp anchor(_base_price, min_all, []), do: min_all
  defp anchor(%Decimal{} = base_price, _min_all, _fields), do: base_price
  defp anchor(_base_price, min_all, _fields), do: min_all

  defp fit_summary(rule, modifiers, fields, priced, {min_all, anchor}) do
    devs =
      if is_nil(anchor),
        do: [],
        else: deviations(modifiers, fields, priced, anchor)

    # Whether the MODIFIERS reproduce Shopify (against its own cheapest
    # variant) — as opposed to the base having drifted, which is reported
    # separately (`:base_offset`) and is not an approximation.
    approximated? =
      fields != [] and not is_nil(min_all) and
        Enum.any?(deviations(modifiers, fields, priced, min_all), &(not Decimal.eq?(&1, 0)))

    overs = Enum.filter(devs, &Decimal.gt?(&1, 0))
    unders = devs |> Enum.filter(&Decimal.lt?(&1, 0)) |> Enum.map(&Decimal.abs/1)

    %{
      exact?: overs == [] and unders == [],
      approximated?: approximated?,
      rule: rule,
      variants: length(priced),
      over: length(overs),
      under: length(unders),
      max_over: decimal_max(overs),
      max_under: decimal_max(unders),
      base_offset: base_offset(anchor, min_all)
    }
  end

  defp base_offset(%Decimal{} = anchor, %Decimal{} = min_all), do: Decimal.sub(anchor, min_all)
  defp base_offset(_anchor, _min_all), do: @zero

  defp decimal_max([]), do: @zero
  defp decimal_max(decimals), do: Enum.reduce(decimals, &Decimal.max/2)

  defp fit_warnings(_product, %{exact?: true}), do: []

  defp fit_warnings(product, fit) do
    label = product["handle"] || product["id"] || product["title"] || "unknown"
    message = fit_message(fit)
    Logger.warning("Shopify variant sync: product #{label}, #{message}")
    [message]
  end

  defp fit_message(%{approximated?: true} = fit) do
    "prices approximated (#{fit.rule}): #{fit.over + fit.under} of #{fit.variants} variants " <>
      "differ from Shopify, up to +#{fit.max_over} / -#{fit.max_under}" <>
      base_offset_note(fit.base_offset, "; ")
  end

  defp fit_message(fit), do: base_offset_note(fit.base_offset, "")

  defp base_offset_note(offset, prefix) do
    if Decimal.eq?(offset, 0),
      do: "",
      else:
        prefix <>
          "the base price is #{offset} off Shopify's cheapest variant — " <>
          "apply the price change under Shopify sync, Changes"
  end

  defp predicted_price(variant, modifiers, fields, min_all_price) do
    Enum.reduce(fields, min_all_price, fn {slug, field}, sum ->
      Decimal.add(sum, get_in(modifiers, [slug, variant[field]]) || Decimal.new(0))
    end)
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
