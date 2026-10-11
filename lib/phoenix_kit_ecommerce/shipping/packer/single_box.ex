defmodule PhoenixKitEcommerce.Shipping.Packer.SingleBox do
  @moduledoc """
  Packs the whole cart into one parcel.

  Weight is the sum of `quantity * weight`. A position without its own weight
  (or a non-positive one) uses `default_weight_g` of the item, then `weight_g`
  of the shop defaults; weights are rounded up to whole grams; one warning with the number of such positions is logged per call.

  Dimensions start from the shop's standard box (if any) and grow to the
  per-side maximum over every item, each triple sorted from the longest side.
  When the total volume of the items exceeds the volume of that box, the
  shortest side grows to `ceil(volume / (longest * middle))`. With neither a
  box nor item dimensions the parcel has no dimensions and the carrier prices
  by weight.
  """

  @behaviour PhoenixKitEcommerce.Shipping.Packer

  require Logger

  alias PhoenixKitEcommerce.Shipping.Packer.Defaults
  alias PhoenixKitEcommerce.Shipping.{PackItem, Parcel}

  @impl true
  def build(items, %Defaults{} = defaults) do
    case Enum.filter(items, &(quantity(&1) > 0)) do
      [] -> []
      items -> [parcel(items, defaults)]
    end
  end

  defp parcel(items, defaults) do
    weight = total_weight(items, defaults)

    case dimensions(items, defaults) do
      [l, w, h] -> %Parcel{weight_g: weight, length_mm: l, width_mm: w, height_mm: h}
      nil -> %Parcel{weight_g: weight}
    end
  end

  defp total_weight(items, defaults) do
    {total, defaulted} =
      Enum.reduce(items, {0, 0}, fn item, {total, defaulted} ->
        case positive_int(item.weight_g) do
          nil ->
            unit = positive_int(item.default_weight_g) || positive_int(defaults.weight_g) || 0
            {total + unit * quantity(item), defaulted + 1}

          unit ->
            {total + unit * quantity(item), defaulted}
        end
      end)

    if defaulted > 0 do
      Logger.warning(
        "Shipping packer: #{defaulted} cart position(s) without a weight; " <>
          "used the default weight"
      )
    end

    total
  end

  defp positive_int(value) when is_number(value) and value > 0, do: ceil(value)
  defp positive_int(_value), do: nil

  defp quantity(%PackItem{quantity: quantity}) when is_number(quantity) and quantity > 0,
    do: ceil(quantity)

  defp quantity(_item), do: 0

  defp dimensions(items, defaults) do
    sized = for item <- items, dims = normalize(item.dims_mm), do: {dims, quantity(item)}

    case Enum.reduce(sized, normalize(defaults.box_mm), &envelope/2) do
      nil -> nil
      box -> grow(box, volume(sized))
    end
  end

  defp envelope({dims, _quantity}, nil), do: dims

  defp envelope({dims, _quantity}, box) do
    box |> Enum.zip(dims) |> Enum.map(fn {a, b} -> max(a, b) end)
  end

  defp volume(sized) do
    Enum.reduce(sized, 0, fn {[l, w, h], quantity}, total -> total + l * w * h * quantity end)
  end

  defp grow([l, w, h], volume) when volume > l * w * h do
    Enum.sort([l, w, div(volume + l * w - 1, l * w)], :desc)
  end

  defp grow(box, _volume), do: box

  defp normalize([_, _, _] = dims) do
    if Enum.all?(dims, &(is_number(&1) and &1 > 0)) do
      dims |> Enum.map(&ceil/1) |> Enum.sort(:desc)
    end
  end

  defp normalize(_other), do: nil
end
