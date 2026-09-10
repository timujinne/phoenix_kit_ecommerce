defmodule PhoenixKitEcommerce.Catalogue.CategoryCommerce do
  @moduledoc """
  Embedded schema for the shop fields a catalogue category stores under
  `category.data["ecommerce"]`. See `PhoenixKitEcommerce.Catalogue.ItemCommerce`
  moduledoc for the discovery contract this namespace is reached through.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias PhoenixKitEcommerce.OptionTypes

  @type t :: %__MODULE__{}

  @statuses ~w(active unlisted hidden)

  @primary_key false
  embedded_schema do
    # active | unlisted | hidden
    field :shop_status, :string, default: "active"
    field :option_schema, {:array, :map}, default: []
    field :featured_item_uuid, Ecto.UUID
    # per-category override read by the storefront filters (Block 4)
    field :storefront_filters, :map, default: %{}
  end

  @fields ~w(shop_status option_schema featured_item_uuid storefront_filters)a

  @doc "Changeset — `option_schema` reuses `PhoenixKitEcommerce.OptionTypes.validate_options/1`."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(struct, attrs) do
    struct
    |> cast(attrs, @fields)
    |> validate_inclusion(:shop_status, @statuses)
    |> validate_change(:option_schema, fn :option_schema, value ->
      case OptionTypes.validate_options(value) do
        {:ok, _} -> []
        {:error, reason} -> [option_schema: reason]
      end
    end)
  end

  @doc """
  Merges `params` (submitted form/API values, or `nil`) over `current`
  (the existing `data["ecommerce"]` map, or `nil`) and validates the
  result.

  Returns `{:ok, map}` with the full resulting namespace (defaults
  included) or `{:error, [{field, message}]}`.
  """
  @spec cast(map() | nil, map() | nil) :: {:ok, map()} | {:error, [{atom(), String.t()}]}
  def cast(params, current) do
    merged =
      (current || %{})
      |> Map.merge(normalize_option_schema(params || %{}))

    %__MODULE__{}
    |> changeset(merged)
    |> case do
      %Ecto.Changeset{valid?: true} = changeset ->
        storage = changeset |> apply_changes() |> to_storage_map()
        {:ok, Map.merge(current || %{}, storage)}

      %Ecto.Changeset{valid?: false} = changeset ->
        {:error, error_list(changeset)}
    end
  end

  # `option_schema` has no input in `ShopSections.category/1` (Block 1
  # ships it written programmatically only — e.g. by a future admin tool
  # or a data migration) so a submitted value always already has the
  # list shape the `{:array, :map}` field expects; nothing to normalize.
  defp normalize_option_schema(params), do: params

  defp to_storage_map(%__MODULE__{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
  end

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
