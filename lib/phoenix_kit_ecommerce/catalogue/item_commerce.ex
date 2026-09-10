defmodule PhoenixKitEcommerce.Catalogue.ItemCommerce do
  @moduledoc """
  Embedded schema for the shop fields a catalogue item stores under
  `item.data["ecommerce"]`.

  Catalogue owns the item and never validates or renders this namespace —
  that is this module's job, reached only through
  `PhoenixKitEcommerce.Catalogue.Extension` (see its moduledoc for the
  discovery contract). Validations mirror `PhoenixKitEcommerce.Product`'s
  changeset for the fields the two share.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @statuses ~w(draft active archived)
  @product_types ~w(physical digital)

  @primary_key false
  embedded_schema do
    # draft | active | archived
    field :shop_status, :string, default: "draft"
    # physical | digital
    field :product_type, :string, default: "physical"
    field :vendor, :string
    field :tags, {:array, :string}, default: []
    field :compare_at_price, :decimal
    field :cost_per_item, :decimal
    # No `"USD"` default — that literal was removed from Product/Cart in
    # PR #31. Nil here lets the storefront fall back to the shop's base
    # currency (`View.product_view/2`); a schema default would stamp USD
    # onto every extension-saved item and make that fallback dead.
    field :currency, :string
    field :taxable, :boolean, default: true
    field :weight_grams, :integer, default: 0
    field :requires_shipping, :boolean, default: true
    field :made_to_order, :boolean, default: false
    field :file_uuid, Ecto.UUID
    field :download_limit, :integer
    field :download_expiry_days, :integer
    # lang -> label, e.g. %{"en-US" => "per hour"}
    field :price_unit, :map, default: %{}
    field :price_from, :boolean, default: false
    field :price_on_request, :boolean, default: false
    # option_key -> value_slug -> decimal string
    field :price_modifiers, :map, default: %{}
    # handle, product_id, variant_ids
    field :shopify, :map, default: %{}
    field :legacy_product_uuid, Ecto.UUID
    field :translation_fingerprints, :map, default: %{}
  end

  @fields ~w(
    shop_status product_type vendor tags compare_at_price cost_per_item
    currency taxable weight_grams requires_shipping made_to_order file_uuid
    download_limit download_expiry_days price_unit price_from
    price_on_request price_modifiers shopify legacy_product_uuid
    translation_fingerprints
  )a

  @doc """
  Changeset — same validations as `PhoenixKitEcommerce.Product.changeset/2`
  for the fields the two share.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(struct, attrs) do
    struct
    |> cast(attrs, @fields)
    |> validate_inclusion(:shop_status, @statuses)
    |> validate_inclusion(:product_type, @product_types)
    |> validate_number(:compare_at_price, greater_than_or_equal_to: 0)
    |> validate_number(:cost_per_item, greater_than_or_equal_to: 0)
    |> validate_number(:weight_grams, greater_than_or_equal_to: 0)
    |> validate_number(:download_limit, greater_than: 0)
    |> validate_number(:download_expiry_days, greater_than: 0)
    |> validate_length(:currency, is: 3)
  end

  @doc """
  Merges `params` (submitted form/API values, or `nil`) over `current`
  (the existing `data["ecommerce"]` map, or `nil`) and validates the
  result.

  Returns `{:ok, map}` with the full resulting namespace — defaults
  included, decimals rendered as strings so the map stays JSON-safe for
  JSONB storage — or `{:error, [{field, message}]}`.
  """
  @spec cast(map() | nil, map() | nil) :: {:ok, map()} | {:error, [{atom(), String.t()}]}
  def cast(params, current) do
    normalized =
      (params || %{})
      |> normalize_tags()
      |> normalize_price_unit()

    merged = Map.merge(current || %{}, normalized)

    %__MODULE__{}
    |> changeset(merged)
    |> case do
      %Ecto.Changeset{valid?: true} = changeset ->
        # Merge the validated schema-shaped map over `current` so a key
        # written under `data["ecommerce"]` by a newer version, a data
        # migration, or catalogue itself survives a form save. `cast/3`
        # drops unknown keys; without this merge they would be wiped.
        storage = changeset |> apply_changes() |> to_storage_map()
        {:ok, Map.merge(current || %{}, storage)}

      %Ecto.Changeset{valid?: false} = changeset ->
        {:error, error_list(changeset)}
    end
  end

  # The Shop section renders tags as a comma-separated text input (the
  # extension's own UI choice, not Product's), so a submitted string has
  # to become the list the `{:array, :string}` field expects before cast/2.
  # A caller passing an already-decoded list (e.g. a data migration) is
  # left untouched.
  defp normalize_tags(%{"tags" => tags} = params) when is_binary(tags) do
    list =
      tags
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    Map.put(params, "tags", list)
  end

  defp normalize_tags(params), do: params

  # A blank current-language price_unit input would otherwise store
  # `%{"<lang>" => ""}` and, because the map is merged in whole (the Shop
  # section carries every other language forward as a hidden input, so the
  # submitted map already covers the full set — see `ShopSections.item/1`),
  # blank strings would accumulate under every language a save ever
  # touched. Drop blank entries the same way `normalize_tags/1` does.
  defp normalize_price_unit(%{"price_unit" => price_unit} = params) when is_map(price_unit) do
    cleaned =
      price_unit
      |> Enum.reject(fn {_lang, value} -> value in [nil, ""] end)
      |> Map.new()

    Map.put(params, "price_unit", cleaned)
  end

  defp normalize_price_unit(params), do: params

  defp to_storage_map(%__MODULE__{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.new(fn {k, v} -> {Atom.to_string(k), stringify_decimal(v)} end)
  end

  defp stringify_decimal(%Decimal{} = d), do: Decimal.to_string(d)
  defp stringify_decimal(v), do: v

  defp error_list(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&translate_error/1)
    |> Enum.flat_map(fn {field, msgs} -> Enum.map(msgs, &{field, &1}) end)
  end

  defp translate_error({msg, opts}) do
    Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
      opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
    end)
  end
end
