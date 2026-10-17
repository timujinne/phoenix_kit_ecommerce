defmodule PhoenixKitEcommerce.API.Loader do
  @moduledoc """
  Loads products for the public API from whichever product source is active
  and wraps each in a `PhoenixKitEcommerce.API.Record`: the storefront
  view-struct, its category chain, the visibility facts and the resulting
  state. One code path serves the search indexer and every public tool, for
  both sources.

  On the Catalogue source the raw item is read too, because the view-struct
  collapses the catalogue's `inactive`, `discontinued` and `deleted` states
  into `"archived"` and the visibility rule tells them apart. The stored shop
  status of an item and of a category is read from the raw record as well: the
  views turn a value they do not know into `"active"`, and the rule must see
  it as it is so that it can hide the product.

  A product that names a category the loader cannot find (outside the shop's
  catalogue, or missing from a stale `:categories` snapshot) is hidden, not
  listed: facts carry the category status `"missing"`.
  """

  import Ecto.Query, warn: false

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}
  @compile {:no_warn_undefined, PhoenixKitCatalogue.Schemas.Item}

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Utils.UUID, as: UUIDUtils
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Schemas.Item, as: CatItem
  alias PhoenixKitEcommerce.API.Facts
  alias PhoenixKitEcommerce.API.Record
  alias PhoenixKitEcommerce.API.Visibility
  alias PhoenixKitEcommerce.Product
  alias PhoenixKitEcommerce.ProductSource
  alias PhoenixKitEcommerce.ProductSource.Catalogue, as: CatalogueSource
  alias PhoenixKitEcommerce.ProductSource.Catalogue.Query, as: CatalogueQuery
  alias PhoenixKitEcommerce.ProductSource.Catalogue.View, as: CatalogueView
  alias PhoenixKitEcommerce.ProductSource.Legacy

  @max_chain_depth 20

  @doc """
  Records for `ids`, keyed by the canonical lowercase product uuid. Unknown,
  malformed and out-of-catalogue ids are absent from the map. An id in another
  spelling (upper case) loads, but under the canonical key: callers normalise
  an id before they look it up in the result.

  Options: `:language` (the language option labels are written in; Catalogue
  source only) and `:categories` (a map from `categories/0`, so a caller that
  loads many chunks reads the category table once).
  """
  @spec load([term()], keyword()) :: %{String.t() => Record.t()}
  def load(ids, opts \\ []) when is_list(ids) do
    ids = ids |> Enum.map(&canonical_uuid/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if ids == [] do
      %{}
    else
      load_valid(ids, opts)
    end
  end

  defp load_valid(ids, opts) do
    case ProductSource.current() do
      ProductSource.Catalogue -> load_catalogue(ids, opts)
      _legacy -> load_legacy(ids, Keyword.get_lazy(opts, :categories, &categories/0))
    end
  end

  @doc """
  Every category of the active source by uuid; hidden and deleted ones
  included. On the Catalogue source a category carries its stored status
  (its catalogue status when that is not `active`, otherwise its stored shop
  status, `active` when none is stored) and comes without a parent view or a resolved image,
  which the API never reads.
  """
  @spec categories() :: %{String.t() => PhoenixKitEcommerce.Category.t()}
  def categories do
    case ProductSource.current() do
      ProductSource.Catalogue -> catalogue_categories(CatalogueQuery.catalogue_uuid())
      source -> source.list_categories([]) |> Map.new(&{&1.uuid, &1})
    end
  end

  @doc """
  The ids of every product the source holds, listed or not (the rebuild decides
  which are listed). `{:error, :no_catalogue}` when the Catalogue source is on
  but the shop's catalogue cannot be resolved: a caller must then change nothing
  rather than treat the shop as empty.
  """
  @spec all_ids() :: {:ok, [String.t()]} | {:error, :no_catalogue}
  def all_ids do
    case ProductSource.current() do
      ProductSource.Catalogue ->
        case CatalogueQuery.catalogue_uuid() do
          nil ->
            {:error, :no_catalogue}

          uuid ->
            {:ok,
             RepoHelper.repo().all(
               from(i in CatItem, where: i.catalogue_uuid == ^uuid, select: i.uuid)
             )}
        end

      _legacy ->
        {:ok, RepoHelper.repo().all(from(p in Product, select: p.uuid))}
    end
  end

  @doc "The uuid of the shop's one catalogue; `nil` on the Legacy source or when it cannot be resolved."
  @spec shop_catalogue_uuid() :: String.t() | nil
  def shop_catalogue_uuid do
    case ProductSource.current() do
      ProductSource.Catalogue -> CatalogueQuery.catalogue_uuid()
      _legacy -> nil
    end
  end

  @doc """
  False only when the Catalogue source is on and the shop's catalogue cannot be
  resolved (renamed, deleted). A writer must then change nothing: an empty answer
  is "I cannot tell", not "the shop is empty". Always true on the Legacy source.
  """
  @spec source_resolvable?() :: boolean()
  def source_resolvable? do
    ProductSource.current() != ProductSource.Catalogue or CatalogueQuery.catalogue_uuid() != nil
  end

  @doc """
  True when the shop's catalogue exists and its status is `active`. Always true
  on the Legacy source, where no catalogue is involved.
  """
  @spec catalogue_listed?() :: boolean()
  def catalogue_listed? do
    ProductSource.current() != ProductSource.Catalogue or
      listed?(CatalogueQuery.catalogue_uuid())
  end

  defp listed?(nil), do: false
  defp listed?(uuid), do: match?(%{status: "active"}, Catalogue.get_catalogue(uuid))

  @doc "The ids of the products that sit directly in any of `category_uuids`."
  @spec item_ids_in_categories([String.t()]) :: [String.t()]
  def item_ids_in_categories(category_uuids) when is_list(category_uuids) do
    case category_uuids |> Enum.map(&canonical_uuid/1) |> Enum.reject(&is_nil/1) do
      [] -> []
      uuids -> products_in_categories(uuids)
    end
  end

  defp products_in_categories(uuids) do
    case ProductSource.current() do
      ProductSource.Catalogue ->
        case CatalogueQuery.catalogue_uuid() do
          nil ->
            []

          catalogue ->
            RepoHelper.repo().all(
              from(i in CatItem,
                where: i.catalogue_uuid == ^catalogue and i.category_uuid in ^uuids,
                select: i.uuid
              )
            )
        end

      _legacy ->
        RepoHelper.repo().all(
          from(p in Product, where: p.category_uuid in ^uuids, select: p.uuid)
        )
    end
  end

  @doc """
  The category and its ancestors, root first. Stops at the first category it
  has already seen (a cycle, a self-parent) and after #{@max_chain_depth} levels.
  The chain is unfiltered: it may contain hidden or deleted ancestors.
  """
  @spec chain(map() | nil, %{String.t() => map()}) :: [map()]
  def chain(nil, _categories), do: []
  def chain(category, categories), do: build_chain(category, categories, [], [])

  defp build_chain(nil, _categories, acc, _seen), do: acc

  defp build_chain(category, categories, acc, seen) do
    if category.uuid in seen or length(seen) >= @max_chain_depth do
      acc
    else
      parent = category.parent_uuid && Map.get(categories, category.parent_uuid)
      build_chain(parent, categories, [category | acc], [category.uuid | seen])
    end
  end

  @doc "`root` and the uuids of every descendant, each once (a cycle cannot repeat a uuid)."
  @spec subtree_uuids(String.t(), %{String.t() => map()}) :: [String.t()]
  def subtree_uuids(root, categories) do
    children = categories |> Map.values() |> Enum.group_by(& &1.parent_uuid, & &1.uuid)
    walk([root], children, MapSet.new([root]))
  end

  defp walk([], _children, seen), do: MapSet.to_list(seen)

  defp walk([uuid | rest], children, seen) do
    new = children |> Map.get(uuid, []) |> Enum.reject(&MapSet.member?(seen, &1))
    walk(rest ++ new, children, Enum.reduce(new, seen, &MapSet.put(&2, &1)))
  end

  # --- the two sources -------------------------------------------------------

  defp load_catalogue(ids, opts) do
    catalogue = CatalogueQuery.catalogue_uuid()
    categories = Keyword.get_lazy(opts, :categories, fn -> catalogue_categories(catalogue) end)
    items = CatalogueQuery.list_items_by_uuids(ids, catalogue)
    products = CatalogueSource.products_for_items(items, Keyword.take(opts, [:language]))
    listed? = listed?(catalogue)

    items
    |> Enum.zip(products)
    |> Map.new(fn {item, product} ->
      facts = %Facts{
        item_status: item.status,
        shop_status: stored_shop_status(item.data),
        category_status: category_status(item.category_uuid, categories),
        catalogue_listed?: listed?,
        position: item.position || 0
      }

      {item.uuid, record(item.uuid, product, item.category_uuid, categories, facts)}
    end)
  end

  defp catalogue_categories(catalogue) do
    [catalogue_uuid: catalogue]
    |> CatalogueQuery.list_categories()
    |> Map.new(fn raw ->
      {raw.uuid, %{CatalogueView.category_view(raw) | status: stored_category_status(raw)}}
    end)
  end

  # The status as written, never the views' normalised one (they turn a value
  # they do not know into "active"; the rule must see it to hide the product).
  defp stored_category_status(%{status: "active"} = raw), do: stored_shop_status(raw.data)
  defp stored_category_status(raw), do: raw.status

  defp stored_shop_status(%{"ecommerce" => %{"shop_status" => status}}) when status != nil,
    do: status

  defp stored_shop_status(_data), do: "active"

  defp category_status(nil, _categories), do: nil

  defp category_status(category_uuid, categories) do
    case Map.get(categories, category_uuid) do
      nil -> "missing"
      category -> category.status
    end
  end

  defp load_legacy(ids, categories) do
    ids
    |> Legacy.list_products_by_ids()
    |> Map.new(fn product ->
      facts = %Facts{
        item_status: "active",
        shop_status: product.status,
        category_status: category_status(product.category_uuid, categories),
        catalogue_listed?: true,
        position: 0
      }

      {product.uuid, record(product.uuid, product, product.category_uuid, categories, facts)}
    end)
  end

  defp record(id, product, category_uuid, categories, facts) do
    category = category_uuid && Map.get(categories, category_uuid)

    %Record{
      id: id,
      product: product,
      category: category,
      chain: chain(category, categories),
      facts: facts,
      state: Visibility.classify(facts)
    }
  end

  @doc """
  The canonical (lower-case) form of a 36-character UUID string; `nil` for
  anything else. `Ecto.UUID.cast/1` also takes any 16-byte string for raw UUID
  bytes, which is not an id a caller can send, so the length is checked first.
  """
  @spec canonical_uuid(term()) :: String.t() | nil
  def canonical_uuid(value) when is_binary(value) and byte_size(value) == 36 do
    if UUIDUtils.valid?(value), do: String.downcase(value)
  end

  def canonical_uuid(_other), do: nil
end
