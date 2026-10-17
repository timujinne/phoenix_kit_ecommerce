defmodule PhoenixKitEcommerce.API.Record do
  @moduledoc """
  A product as the public API sees it: the storefront view-struct, its
  category chain (root first), the visibility facts and the resulting state.
  Built by `PhoenixKitEcommerce.API.Loader`.

  Only the product's own category gates its visibility. `chain` is unfiltered
  and may contain hidden or deleted ancestors; a caller that exposes category
  names must filter it.
  """

  alias PhoenixKitEcommerce.API.Facts
  alias PhoenixKitEcommerce.API.Visibility

  @type t :: %__MODULE__{
          id: String.t(),
          product: PhoenixKitEcommerce.Product.t(),
          facts: Facts.t(),
          state: Visibility.state(),
          category: PhoenixKitEcommerce.Category.t() | nil,
          chain: [PhoenixKitEcommerce.Category.t()]
        }

  @enforce_keys [:id, :product, :facts, :state]
  defstruct [:id, :product, :facts, :state, category: nil, chain: []]
end
