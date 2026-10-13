defmodule PhoenixKitEcommerce.Shipping.PackItem do
  @moduledoc """
  One cart position as seen by a packer.

    * `weight_g` - weight of a single unit, grams, `nil` when unknown
    * `dims_mm` - `[l, w, h]` of a single unit, millimetres, `nil` when unknown
    * `default_weight_g` - weight to assume when `weight_g` is unknown (taken
      from the category)
    * `quantity` - number of units
  """

  defstruct weight_g: nil, dims_mm: nil, default_weight_g: nil, quantity: 1

  @type t :: %__MODULE__{
          weight_g: non_neg_integer() | nil,
          dims_mm: [pos_integer()] | nil,
          default_weight_g: non_neg_integer() | nil,
          quantity: non_neg_integer()
        }
end
