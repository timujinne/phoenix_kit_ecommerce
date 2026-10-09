defmodule PhoenixKitEcommerce.Shipping.MetadataFields do
  @moduledoc false
  # Virtual integer fields of a schema that live in one map inside its
  # `metadata` (a product's `dimensions_mm`, a category's `parcel_defaults`):
  # no columns, no migration. `fields` is a keyword list of
  # `schema field => key (atom) in the stored map`.

  import Ecto.Changeset

  alias PhoenixKitEcommerce.Shipping.Codec

  @doc "Casts the virtual fields and checks they are not negative."
  @spec cast_fields(Ecto.Changeset.t(), map(), keyword()) :: Ecto.Changeset.t()
  def cast_fields(changeset, attrs, fields) do
    names = Keyword.keys(fields)

    names
    |> Enum.reduce(cast(changeset, attrs, names), fn name, acc ->
      validate_number(acc, name, greater_than_or_equal_to: 0)
    end)
  end

  @doc """
  The stored values in the order of `fields`, `nil` for a missing or
  unreadable one.
  """
  @spec stored(map(), atom(), keyword()) :: [integer() | nil]
  def stored(%{metadata: metadata}, metadata_key, fields) do
    map = Codec.get(metadata, metadata_key)
    Enum.map(fields, fn {_name, key} -> Codec.integer(Codec.get(map, key)) end)
  end

  @doc """
  Writes the virtual fields into `metadata[metadata_key]`, but only when
  `attrs` mentions one of them, so every other save leaves the metadata (and
  its other keys) alone. A field that is blank or 0 is not stored; one that
  is not in `attrs` keeps the value of the struct, else the stored one. An
  invalid changeset is returned as is.
  """
  @spec put(Ecto.Changeset.t(), map(), atom(), keyword()) :: Ecto.Changeset.t()
  def put(changeset, attrs, metadata_key, fields) do
    if changeset.valid? and mentioned?(attrs, fields),
      do: do_put(changeset, attrs, metadata_key, fields),
      else: changeset
  end

  defp mentioned?(attrs, fields) when is_map(attrs),
    do: Enum.any?(fields, fn {name, _key} -> in_attrs?(attrs, name) end)

  defp mentioned?(_attrs, _fields), do: false

  defp in_attrs?(attrs, name),
    do: Map.has_key?(attrs, name) or Map.has_key?(attrs, Atom.to_string(name))

  defp do_put(changeset, attrs, metadata_key, fields) do
    metadata = get_field(changeset, :metadata) || %{}
    current = Codec.get(metadata, metadata_key)
    stored_key = Atom.to_string(metadata_key)

    values =
      for {name, key} <- fields,
          value = value(changeset, attrs, name, current, key),
          value != 0,
          into: %{},
          do: {Atom.to_string(key), value}

    updated =
      if values == %{},
        do: Map.delete(metadata, stored_key),
        else: Map.put(metadata, stored_key, values)

    if updated == metadata, do: changeset, else: put_change(changeset, :metadata, updated)
  end

  defp value(changeset, attrs, name, current, key) do
    if in_attrs?(attrs, name) do
      get_field(changeset, name)
    else
      get_field(changeset, name) || Codec.integer(Codec.get(current, key))
    end
  end
end
