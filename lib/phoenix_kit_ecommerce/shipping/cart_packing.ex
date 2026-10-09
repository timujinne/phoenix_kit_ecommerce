defmodule PhoenixKitEcommerce.Shipping.CartPacking do
  @moduledoc """
  Between cart lines and the parcels sent to a carrier.

  Each line carries a snapshot of what is needed to pack it,
  `metadata["shipping_profile"]`, taken when the product is added to the cart
  (a later edit of the product must not repack a cart):

      %{"dims_mm" => [l, w, h] | nil, "default_weight_g" => 500 | nil}

  `profile/2` builds it: the size of one unit comes from the product, else
  from the box of the product's category; the default weight from the
  category. `pack_items/1` turns lines into `PhoenixKitEcommerce.Shipping.PackItem`s
  for a `PhoenixKitEcommerce.Shipping.Packer`.
  """

  alias PhoenixKitEcommerce.{Category, Product}
  alias PhoenixKitEcommerce.Shipping.{Codec, PackItem}

  @profile_key "shipping_profile"

  @doc "The metadata key the profile lives under."
  @spec profile_key() :: String.t()
  def profile_key, do: @profile_key

  @doc """
  The packing profile of one unit of `product`, whose category is `category`
  (a legacy `Category`, a catalogue category view or `nil`).
  """
  @spec profile(Product.t(), Category.t() | nil) :: %{String.t() => term()}
  def profile(product, category) do
    defaults = Category.parcel_defaults(category)

    %{
      "dims_mm" => Product.dimensions_mm(product) || defaults.dims_mm,
      "default_weight_g" => defaults.weight_g
    }
  end

  @doc """
  The cart lines that ship, as pack items. A line whose snapshot says
  `requires_shipping: false` is left out; one without the snapshot (added
  before it existed) counts as shipping, the conservative default used for
  weights as well.

  `weight_g` is the per-unit weight of the line (0 means unknown, `nil`
  here); size and default weight come from the line's `shipping_profile`.
  """
  @spec pack_items([struct()]) :: [PackItem.t()]
  def pack_items(items) when is_list(items) do
    for item <- items, ships?(item), do: pack_item(item)
  end

  defp ships?(%{metadata: metadata}), do: Codec.get(metadata, :requires_shipping) != false
  defp ships?(_item), do: true

  defp pack_item(item) do
    profile = Codec.get(item.metadata, :shipping_profile)

    %PackItem{
      weight_g: positive(item.weight_grams),
      dims_mm: dims(Codec.get(profile, :dims_mm)),
      default_weight_g: positive(Codec.get(profile, :default_weight_g)),
      quantity: item.quantity
    }
  end

  defp dims([_, _, _] = dims) do
    parsed = Enum.map(dims, &Codec.integer/1)
    if Enum.all?(parsed, &positive/1), do: parsed
  end

  defp dims(_other), do: nil

  defp positive(value) do
    case Codec.integer(value) do
      number when is_integer(number) and number > 0 -> number
      _ -> nil
    end
  end
end
