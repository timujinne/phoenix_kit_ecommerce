defmodule PhoenixKitEcommerce.Search.Entry do
  @moduledoc """
  One row of the public search index: a listed product in one language.

  Rows are written only by `PhoenixKitEcommerce.Search.Indexer` (raw SQL,
  because the `document` column is a `tsvector` built by Postgres) and read
  by `PhoenixKitEcommerce.Search.Query`. The `document` field is never loaded
  into a struct (`load_in_query: false`); queries reach it through fragments.

  The index is derived data. Nothing outside the indexer writes it, and a
  full rebuild reproduces it from the catalogue.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix

  @table "phoenix_kit_shop_search_index"

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema @table do
    field :item_uuid, Ecto.UUID
    field :language, :string
    field :title, :string
    field :title_trgm, :string
    field :document, :string, load_in_query: false
    field :category_uuid, Ecto.UUID
    field :category_path, {:array, :string}, default: []
    field :category_path_uuids, {:array, Ecto.UUID}, default: []
    field :vendor, :string
    field :tags, {:array, :string}, default: []
    field :option_pairs, {:array, :string}, default: []
    field :option_labels, :map, default: %{}
    field :made_to_order, :boolean, default: false
    field :on_sale, :boolean, default: false
    field :price, :decimal
    field :compare_at_price, :decimal
    field :discount_pct, :decimal
    field :sort_position, :integer, default: 0
    field :item_inserted_at, :utc_datetime_usec
    field :indexed_at, :utc_datetime_usec
  end

  @doc """
  The schema-qualified table name for raw SQL: bare on an unprefixed install,
  `<prefix>.phoenix_kit_shop_search_index` under `config :phoenix_kit, prefix:`.
  """
  @spec table() :: String.t()
  def table do
    # Not `case __schema__(:prefix) do nil -> ...; prefix -> prefix <> "." <> ...`:
    # `@schema_prefix` compiles to a literal `nil`, and Elixir 1.19's type
    # checker then warns "incompatible types in binary construction" on the
    # second branch, which `mix compile --warnings-as-errors` turns into a
    # failed build.
    [__schema__(:prefix), @table]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(".")
  end
end
