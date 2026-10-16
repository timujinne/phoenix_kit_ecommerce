defmodule PhoenixKitEcommerce.SelectedSpecs do
  @moduledoc """
  The one place a cart line's option selection is written and read.

  A line's `selected_specs` is `%{option_key => value}`. What `value` is
  depends on where the product comes from:

    * **Catalogue source** — the option value's stable key (its slug), the
      same in every language. The label the buyer saw is snapshotted beside
      it, in `metadata["selection"]`:

          %{"format" => 2, "labels" => %{option_key => label}}

      Identity is the key; the label is display only. Two values that share
      a label in some language stay two selections with two prices.

    * **Legacy source** — the option value itself, an admin-typed string
      with no separate key. No `"selection"` entry: the value is both the
      identity and what is shown.

  A line written before keys existed is in the second shape whatever its
  product: its `selected_specs` holds the labels of the language it was
  added in and it has no `"selection"` entry. Such a line is displayed as
  stored (`labels/1`) and is never rewritten; `keys/2` is the single place
  it is matched back to keys, for callers that need to compare it with a
  keyed selection. Nothing prices a line from either function — a line's
  `unit_price` is the snapshot taken when it was added.

  An order line is a snapshot of `labels/1`, so orders read the same
  whichever shape the cart line had.
  """

  alias PhoenixKitEcommerce.CartItem
  alias PhoenixKitEcommerce.Product

  @format 2
  @metadata_key "selection"

  @doc "The cart line `metadata` key the label snapshot is stored under."
  @spec metadata_key() :: String.t()
  def metadata_key, do: @metadata_key

  @doc """
  The label an option value is shown under: the catalogue value's label in
  the language `product_metadata` was built for, or `value` itself where the
  option has no keyed values (a legacy option, or a schema option of the
  catalogue source).
  """
  @spec value_label(map() | nil, String.t(), term()) :: term()
  def value_label(product_metadata, option_key, value) when is_binary(value) do
    case product_metadata do
      %{"_value_labels" => %{^option_key => %{^value => label}}} when is_binary(label) -> label
      _ -> value
    end
  end

  def value_label(_product_metadata, _option_key, value), do: value

  @doc """
  The image mapped to an option value, `nil` when there is none.

  `_image_mappings` is `%{option_key => %{value => image}}`. On the
  catalogue source it is a snapshot written when values were identified by
  their label, so a value key that has no entry of its own is looked up by
  the label it is shown under.
  """
  @spec image_mapping(map() | nil, String.t(), term()) :: String.t() | nil
  def image_mapping(product_metadata, option_key, value) do
    mappings = get_in(product_metadata || %{}, ["_image_mappings", option_key])

    if is_map(mappings) do
      case Map.get(mappings, value) do
        image when image in [nil, ""] ->
          presence(Map.get(mappings, value_label(product_metadata, option_key, value)))

        image ->
          image
      end
    end
  end

  defp presence(""), do: nil
  defp presence(value), do: value

  @doc """
  `selected_specs` with every value replaced by its label for `product` —
  what a page shows for a selection it has not carted yet.
  """
  @spec labels_for(Product.t(), map()) :: map()
  def labels_for(%Product{metadata: metadata}, selected_specs) when is_map(selected_specs) do
    Map.new(selected_specs, fn {key, value} -> {key, value_label(metadata, key, value)} end)
  end

  @doc """
  The cart line `metadata` entry for a new line: the label snapshot for a
  catalogue-backed product, `nil` for a legacy one (whose line stays in the
  unkeyed shape).
  """
  @spec snapshot(Product.t(), map()) :: map() | nil
  def snapshot(%Product{origin: :catalogue} = product, selected_specs)
      when is_map(selected_specs) and map_size(selected_specs) > 0 do
    %{"format" => @format, "labels" => labels_for(product, selected_specs)}
  end

  def snapshot(_product, _selected_specs), do: nil

  @doc "Whether a cart line's `selected_specs` holds value keys (the catalogue shape)."
  @spec keyed?(CartItem.t() | map() | nil) :: boolean()
  def keyed?(%CartItem{metadata: metadata}), do: keyed?(metadata)
  def keyed?(%{@metadata_key => %{"format" => @format}}), do: true
  def keyed?(_metadata), do: false

  @doc """
  What a cart line's selection is shown as: `%{option_key => label}`, from
  the line's own snapshot. A line without one is shown as stored.
  """
  @spec labels(CartItem.t()) :: map()
  def labels(%CartItem{selected_specs: specs, metadata: metadata}) when is_map(specs) do
    case metadata do
      %{@metadata_key => %{"format" => @format, "labels" => %{} = labels}} ->
        Map.new(specs, fn {key, value} -> {key, Map.get(labels, key, value)} end)

      _ ->
        specs
    end
  end

  def labels(%CartItem{}), do: %{}

  @doc """
  A cart line's selection as value keys, for comparing it with a keyed
  selection of `product`.

  A keyed line answers its own `selected_specs`. A line in the unkeyed shape
  is resolved label by label through the product's `_value_slugs`; where two
  values share the label, the first in the set's own order is the answer,
  every time. A label the product no longer has stays as it is, so it
  matches nothing.
  """
  @spec keys(CartItem.t(), Product.t()) :: map()
  def keys(%CartItem{selected_specs: specs} = item, %Product{metadata: metadata})
      when is_map(specs) do
    if keyed?(item) do
      specs
    else
      Map.new(specs, fn {key, value} -> {key, key_for_label(metadata, key, value)} end)
    end
  end

  def keys(%CartItem{}, _product), do: %{}

  defp key_for_label(%{"_value_slugs" => %{} = slugs}, option_key, label) do
    case slugs do
      %{^option_key => %{^label => slug}} when is_binary(slug) -> slug
      _ -> label
    end
  end

  defp key_for_label(_metadata, _option_key, label), do: label
end
