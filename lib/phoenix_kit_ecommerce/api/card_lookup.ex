defmodule PhoenixKitEcommerce.API.CardLookup do
  @moduledoc """
  What the cards of one answer share, read once for the answer instead of once
  per card:

    * the option schema each product's price range is read against (the global
      options once, the stored categories in one query),
    * the signed URL of each stored picture (one query for the pictures'
      variants).

  The number of queries is therefore the same for one card and for a hundred.
  `PhoenixKitEcommerce.API.Cards.lookup/2` decides what a set of cards needs.
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Modules.Storage.FileInstance
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Utils.UUID, as: UUIDUtils
  alias PhoenixKitEcommerce.Category
  alias PhoenixKitEcommerce.Options

  defstruct schemas: %{}, urls: %{}

  @type t :: %__MODULE__{
          schemas: %{String.t() => [map()]},
          urls: %{{String.t(), String.t()} => String.t() | nil}
        }

  @doc """
  Options: `:schemas` (read the option schemas of `products`, default
  `false`) and `:pictures` (`{file_uuid, variant}` pairs to sign, default none).
  """
  @spec build([map()], keyword()) :: t()
  def build(products, opts \\ []) when is_list(products) do
    %__MODULE__{
      schemas: if(Keyword.get(opts, :schemas, false), do: schemas(products), else: %{}),
      urls: urls(Keyword.get(opts, :pictures, []))
    }
  end

  @doc "The option schema of `product` (global options merged with its category's); `nil` when not read."
  @spec schema(t(), map()) :: [map()] | nil
  def schema(%__MODULE__{schemas: schemas}, %{uuid: uuid}), do: Map.get(schemas, uuid)

  @doc """
  The signed URL of the stored picture `file_uuid` in `variant`, the original
  when the file has no such variant, `nil` when it has neither (or is gone),
  as `PhoenixKitEcommerce.Web.Helpers.get_storage_image_url/2` answers.
  """
  @spec url(t(), String.t(), String.t()) :: String.t() | nil
  def url(%__MODULE__{urls: urls}, file_uuid, variant), do: Map.get(urls, {file_uuid, variant})

  # --- option schemas --------------------------------------------------------

  defp schemas(products) do
    global = Options.get_enabled_global_options()
    stored = stored_categories(products)

    Map.new(products, fn product ->
      {product.uuid, Options.merge_schemas(global, category_options(product, stored))}
    end)
  end

  # The same three cases as `Options.get_option_schema_for_product/1`: a
  # loaded category, no category, a category named by uuid.
  defp category_options(%{category: %Category{} = category}, _stored),
    do: Options.get_category_options(category)

  defp category_options(%{category_uuid: uuid}, stored) when is_binary(uuid) do
    case Map.get(stored, uuid) do
      nil -> []
      category -> Options.get_category_options(category)
    end
  end

  defp category_options(_product, _stored), do: []

  defp stored_categories(products) do
    uuids =
      for %{category: category, category_uuid: uuid} <- products,
          not match?(%Category{}, category),
          is_binary(uuid),
          UUIDUtils.valid?(uuid),
          uniq: true,
          do: uuid

    if uuids == [] do
      %{}
    else
      RepoHelper.repo().all(from(c in Category, where: c.uuid in ^uuids))
      |> Map.new(&{&1.uuid, &1})
    end
  end

  # --- pictures --------------------------------------------------------------

  defp urls(pairs) do
    pairs = pairs |> Enum.filter(fn {uuid, _variant} -> UUIDUtils.valid?(uuid) end) |> Enum.uniq()

    if pairs == [] do
      %{}
    else
      instances = instances(pairs)

      Map.new(pairs, fn {uuid, variant} -> {{uuid, variant}, signed(instances, uuid, variant)} end)
    end
  end

  # A file instance cannot exist without its file (foreign key), so the
  # instances alone say which pictures exist and in which variants.
  defp instances(pairs) do
    uuids = pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    variants = pairs |> Enum.map(&elem(&1, 1)) |> Enum.concat(["original"]) |> Enum.uniq()

    from(i in FileInstance,
      where: i.file_uuid in ^uuids and i.variant_name in ^variants,
      select: {i.file_uuid, i.variant_name}
    )
    |> RepoHelper.repo().all()
    |> MapSet.new()
  end

  defp signed(instances, uuid, variant) do
    cond do
      MapSet.member?(instances, {uuid, variant}) -> URLSigner.signed_url(uuid, variant)
      MapSet.member?(instances, {uuid, "original"}) -> URLSigner.signed_url(uuid, "original")
      true -> nil
    end
  end
end
