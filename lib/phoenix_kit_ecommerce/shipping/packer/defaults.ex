defmodule PhoenixKitEcommerce.Shipping.Packer.Defaults do
  @moduledoc """
  Shop-level packing defaults.

    * `weight_g` - weight assumed for a position that has none
    * `box_mm` - `[l, w, h]` of the shop's standard box, millimetres; every
      parcel is at least this big
  """

  defstruct weight_g: nil, box_mm: nil

  @type t :: %__MODULE__{
          weight_g: non_neg_integer() | nil,
          box_mm: [pos_integer()] | nil
        }
end
