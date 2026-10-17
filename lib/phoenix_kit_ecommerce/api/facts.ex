defmodule PhoenixKitEcommerce.API.Facts do
  @moduledoc """
  The source-neutral facts the visibility rule reads
  (`PhoenixKitEcommerce.API.Visibility`).

    * `:item_status` - the catalogue item status (`active | inactive |
      discontinued | deleted`); `"active"` for a legacy product.
    * `:shop_status` - the merchant status as stored (`draft | active |
      archived`, `active` when none is stored); for a legacy product its
      `status`. A value the rule does not know hides the product.
    * `:category_status` - the category's status as stored (`active | unlisted |
      hidden`, a deleted catalogue category `deleted`), `nil` for a product
      without a category, `"missing"` for a category the loader could not find.
      A value the rule does not know hides the product.
    * `:catalogue_listed?` - the shop's catalogue exists and is `active`.
    * `:position` - the item's catalogue position (a sort key); 0 for legacy.
  """

  @type t :: %__MODULE__{
          item_status: String.t() | nil,
          shop_status: String.t() | nil,
          category_status: String.t() | nil,
          catalogue_listed?: boolean() | nil,
          position: integer()
        }

  defstruct item_status: nil,
            shop_status: nil,
            category_status: nil,
            catalogue_listed?: true,
            position: 0
end
