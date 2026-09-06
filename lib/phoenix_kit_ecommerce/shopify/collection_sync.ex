defmodule PhoenixKitEcommerce.Shopify.CollectionSync do
  @moduledoc """
  Maps Shopify collections onto catalogue categories, preserving both
  orders — Block 7 Task 4 (`docs/superpowers/plans/2026-09-06-block7-
  shopify-media-collections.md`, §5 Блок 7 in the design spec).

  `run/1` fetches every collection via `opts[:client]` (a module
  exposing `fetch_collections/1`/`fetch_collection_product_ids/2`,
  defaulting to `PhoenixKitEcommerce.Shopify.AdminClient` — both
  `opts` keyword lists are forwarded to it as-is, so `:integration_uuid`/
  `:req_options` reach the real client the same way they reach
  `AdminClient.fetch_products/2`), resolves each to a catalogue category
  (match by `slug[primary] == handle`, then by `name` case-insensitive,
  else create — Shopify collections are flat, so a created category's
  `parent_uuid` is always `nil`; the existing tree is never touched),
  and writes `category.position` = the collection's own `position`
  (`AdminClient.fetch_collections/1`'s running index across
  `custom_collections` then `smart_collections`, in API order) plus
  `category.data["ecommerce"]["shopify"]["collection_id"]`.

  Then every resolved collection's product ids
  (`fetch_collection_product_ids/2` — already in the collection's own
  sort order) are fetched, and each distinct product id is matched to a
  catalogue item by `data["ecommerce"]["shopify"]["product_id"]` and
  reconciled against the FULL set of collections that list IT (not
  every collection-derived category in the catalogue): if the item's
  CURRENT category is one of ITS OWN collections, it keeps that one
  (updating `item.position` when the list position changed since a
  previous run); otherwise it is assigned to the first of its own
  collections in API order, at that collection's list position. A
  product moved in Shopify from one collection to another therefore
  does get repositioned — an item's current category only survives when
  Shopify itself still lists it there. A product id with no matching
  item is collected into `:unmatched_products` instead (deduplicated —
  the same missing id is never reported twice even if more than one
  collection lists it).

  A no-op — `{:error, :catalogue_source_inactive}` — when
  `ProductSource.current/0` isn't `Catalogue` (Global Constraints: every
  new Block 7 writer is legacy-source-safe on its own).

  `opts[:catalogue_uuid]` is required — unlike `Writer`'s functions,
  which resolve the shop's one catalogue internally, this module takes
  it explicitly so a caller (the Task 5 worker, or a test) controls
  exactly which catalogue is touched.

  Categories with no matching Shopify collection at all (e.g. a
  manually-curated category the store never modeled as a collection)
  are never looked at here, let alone modified.
  """

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce.ProductSource
  alias PhoenixKitEcommerce.Shopify.AdminClient
  alias PhoenixKitEcommerce.Translations

  @doc """
  See the moduledoc. `opts`:

    * `:client` — module implementing `fetch_collections/1` and
      `fetch_collection_product_ids/2`; defaults to `AdminClient`.
    * `:catalogue_uuid` — required.
    * anything else (`:integration_uuid`, `:req_options`, ...) is
      forwarded to the client calls unchanged.
  """
  @spec run(keyword()) ::
          {:ok,
           %{
             categories_created: non_neg_integer(),
             categories_matched: non_neg_integer(),
             items_assigned: non_neg_integer(),
             items_repositioned: non_neg_integer(),
             unmatched_products: [term()]
           }}
          | {:error, :catalogue_source_inactive | :missing_catalogue_uuid | term()}
  def run(opts \\ []) when is_list(opts) do
    if ProductSource.current() == ProductSource.Catalogue do
      do_run(opts)
    else
      {:error, :catalogue_source_inactive}
    end
  end

  defp do_run(opts) do
    client = Keyword.get(opts, :client, AdminClient)

    with {:ok, catalogue_uuid} <- resolve_catalogue_uuid(Keyword.get(opts, :catalogue_uuid)),
         {:ok, collections} <- client.fetch_collections(opts),
         {:ok, resolved, created, matched} <- resolve_categories(collections, catalogue_uuid),
         {:ok, per_collection} <- fetch_collection_products(resolved, client, opts),
         {:ok, assigned, repositioned, unmatched} <-
           assign_products(per_collection, items_by_product_id(catalogue_uuid)) do
      {:ok,
       %{
         categories_created: created,
         categories_matched: matched,
         items_assigned: assigned,
         items_repositioned: repositioned,
         unmatched_products: unmatched
       }}
    end
  end

  defp resolve_catalogue_uuid(uuid) when is_binary(uuid) and uuid != "", do: {:ok, uuid}
  defp resolve_catalogue_uuid(_), do: {:error, :missing_catalogue_uuid}

  # ============================================================
  # Phase 1: collections -> categories, with order
  # ============================================================

  defp resolve_categories(collections, catalogue_uuid) do
    primary = Translations.default_language()
    existing = Catalogue.list_categories_metadata_for_catalogue(catalogue_uuid)

    collections
    |> Enum.reduce_while({:ok, [], existing, 0, 0}, fn collection,
                                                       {:ok, resolved, categories, created,
                                                        matched} ->
      case resolve_one_category(collection, categories, catalogue_uuid, primary) do
        {:ok, {:matched, category}} ->
          entry = %{id: collection["id"], category_uuid: category.uuid}

          {:cont,
           {:ok, [entry | resolved], replace_category(categories, category), created, matched + 1}}

        {:ok, {:created, category}} ->
          entry = %{id: collection["id"], category_uuid: category.uuid}
          {:cont, {:ok, [entry | resolved], [category | categories], created + 1, matched}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, resolved, _categories, created, matched} ->
        {:ok, Enum.reverse(resolved), created, matched}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_one_category(collection, categories, catalogue_uuid, primary) do
    handle = collection["handle"]
    title = collection["title"] || handle
    position = collection["position"] || 0
    collection_id = to_string(collection["id"])

    case find_category(categories, handle, title, primary) do
      {:ok, category} ->
        case update_matched_category(category, position, collection_id) do
          {:ok, updated} -> {:ok, {:matched, updated}}
          {:error, reason} -> {:error, reason}
        end

      :not_found ->
        case create_matched_category(
               catalogue_uuid,
               title,
               handle,
               position,
               collection_id,
               primary
             ) do
          {:ok, category} -> {:ok, {:created, category}}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp find_category(categories, handle, title, primary) do
    case Enum.find(categories, &(primary_slug(&1, primary) == handle)) do
      nil -> find_category_by_name(categories, title)
      category -> {:ok, category}
    end
  end

  defp find_category_by_name(categories, title) do
    downcased_title = String.downcase(title || "")

    case Enum.find(categories, &(String.downcase(&1.name || "") == downcased_title)) do
      nil -> :not_found
      category -> {:ok, category}
    end
  end

  defp primary_slug(%{slug: slug}, primary) when is_map(slug), do: slug[primary]
  defp primary_slug(_category, _primary), do: nil

  defp update_matched_category(category, position, collection_id) do
    Catalogue.update_category(category, %{
      position: position,
      data: put_collection_id(category.data, collection_id)
    })
  end

  defp create_matched_category(catalogue_uuid, title, handle, position, collection_id, primary) do
    Catalogue.create_category(%{
      name: title,
      catalogue_uuid: catalogue_uuid,
      parent_uuid: nil,
      position: position,
      slug: %{primary => handle},
      data: put_collection_id(%{}, collection_id)
    })
  end

  defp put_collection_id(data, collection_id) do
    ecommerce = (data || %{})["ecommerce"] || %{}
    shopify = Map.put(ecommerce["shopify"] || %{}, "collection_id", collection_id)
    Map.put(data || %{}, "ecommerce", Map.put(ecommerce, "shopify", shopify))
  end

  defp replace_category(categories, updated) do
    Enum.map(categories, fn category ->
      if category.uuid == updated.uuid, do: updated, else: category
    end)
  end

  # ============================================================
  # Phase 2: collection product lists -> item category/position
  # ============================================================

  defp items_by_product_id(catalogue_uuid) do
    catalogue_uuid
    |> Catalogue.list_items_for_catalogue()
    |> Map.new(&{shopify_product_id(&1), &1})
    |> Map.delete(nil)
  end

  defp shopify_product_id(item) do
    get_in(item.data || %{}, ["ecommerce", "shopify", "product_id"])
  end

  # One `fetch_collection_product_ids/2` call per resolved collection —
  # same calls the old, per-collection walk already made, just gathered
  # up front so `assign_products/2` can reconcile each product against
  # the FULL set of collections that list it, not only the one being
  # walked when it happens to be seen first.
  defp fetch_collection_products(resolved, client, opts) do
    resolved
    |> Enum.reduce_while({:ok, []}, fn collection, {:ok, acc} ->
      case client.fetch_collection_product_ids(collection.id, opts) do
        {:ok, product_ids} -> {:cont, {:ok, [{collection.category_uuid, product_ids} | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp assign_products(per_collection, item_index) do
    product_categories = build_product_categories(per_collection)

    per_collection
    |> Enum.flat_map(fn {_category_uuid, product_ids} -> product_ids end)
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, item_index, 0, 0, []}, fn product_id,
                                                         {:ok, index, assigned, repositioned,
                                                          unmatched} ->
      case Map.fetch(index, to_string(product_id)) do
        :error ->
          {:cont, {:ok, index, assigned, repositioned, [product_id | unmatched]}}

        {:ok, item} ->
          categories = Map.fetch!(product_categories, to_string(product_id))
          reconcile_item(item, categories, index, assigned, repositioned, unmatched)
      end
    end)
    |> case do
      {:ok, _index, assigned, repositioned, unmatched} ->
        {:ok, assigned, repositioned, Enum.reverse(unmatched)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `product_id_string => [{category_uuid, position}, ...]` — one entry
  # per collection that lists this product, in the SAME order
  # `per_collection` itself is in (i.e. API/collection order), position
  # = the product's own index within THAT collection's list.
  defp build_product_categories(per_collection) do
    Enum.reduce(per_collection, %{}, fn {category_uuid, product_ids}, acc ->
      product_ids
      |> Enum.with_index()
      |> Enum.reduce(acc, fn {product_id, position}, acc ->
        key = to_string(product_id)
        Map.update(acc, key, [{category_uuid, position}], &(&1 ++ [{category_uuid, position}]))
      end)
    end)
  end

  defp reconcile_item(item, categories, index, assigned, repositioned, unmatched) do
    {target_category, target_position} = target_category_and_position(item, categories)

    cond do
      item.category_uuid == target_category and item.position == target_position ->
        {:cont, {:ok, index, assigned, repositioned, unmatched}}

      item.category_uuid == target_category ->
        with_reposition(item, target_position, index, assigned, repositioned, unmatched)

      true ->
        with_assignment(
          item,
          target_category,
          target_position,
          index,
          assigned,
          repositioned,
          unmatched
        )
    end
  end

  # Keep the item's current category when Shopify itself still lists the
  # product there (one of `categories`'s own entries); otherwise fall
  # back to the first collection in API order.
  defp target_category_and_position(item, categories) do
    case Enum.find(categories, fn {category_uuid, _position} ->
           category_uuid == item.category_uuid
         end) do
      nil -> List.first(categories)
      match -> match
    end
  end

  defp with_reposition(item, position, index, assigned, repositioned, unmatched) do
    case Catalogue.update_item(item, %{position: position}) do
      {:ok, updated} ->
        index = Map.put(index, shopify_product_id(updated), updated)
        {:cont, {:ok, index, assigned, repositioned + 1, unmatched}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp with_assignment(item, category_uuid, position, index, assigned, repositioned, unmatched) do
    case Catalogue.update_item(item, %{category_uuid: category_uuid, position: position}) do
      {:ok, updated} ->
        index = Map.put(index, shopify_product_id(updated), updated)
        {:cont, {:ok, index, assigned + 1, repositioned, unmatched}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end
end
