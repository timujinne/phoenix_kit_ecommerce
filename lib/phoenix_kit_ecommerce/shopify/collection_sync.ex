defmodule PhoenixKitEcommerce.Shopify.CollectionSync do
  @moduledoc """
  Maps Shopify collections onto catalogue categories, preserving both
  orders — Block 7 Task 4 (`docs/superpowers/plans/2026-09-06-block7-
  shopify-media-collections.md`, §5 Блок 7 in the design spec), with the
  live-store allowlist and most-specific assignment added by Block 7b
  Task 2 (`docs/superpowers/plans/2026-09-06-block7b-shopify-live-fixes.md`)
  — the real store has 143 collections, of which only ~12
  `3d-printed-*` ones are our categories; the rest (an "all products",
  a curated cross-category "featured" mix, per-tag collections, ...)
  must never become categories or move an item at all.

  `run/1` fetches every collection via `opts[:client]` (a module
  exposing `fetch_collections/1`/`fetch_collection_product_ids/2`,
  defaulting to `PhoenixKitEcommerce.Shopify.AdminClient` — both
  `opts` keyword lists are forwarded to it as-is, so `:integration_uuid`/
  `:req_options` reach the real client the same way they reach
  `AdminClient.fetch_products/2`), then drops every collection that
  fails `opts[:filter]` (default: `PhoenixKitEcommerce.get_config/1`'s
  `"shopify_collections_filter"`, itself defaulting to `%{}` —
  everything passes) — `%{"prefix" => handle_prefix | nil, "exclude" =>
  [handle]}`; a collection is allowed when its handle starts with
  `prefix` (or `prefix` is `nil`/`""`) AND isn't in `exclude`. A
  filtered-out collection is skipped ENTIRELY: no category is
  matched/created/repositioned for it, its products are never fetched,
  and it can never be "the" category an item is assigned to — it is
  simply invisible to every phase below, counted only in
  `:collections_skipped_by_filter`. The surviving collections are
  RE-INDEXED 0.. in their own (filtered) API order before anything else
  runs, so a category's `position` never carries gaps left by the
  collections the filter removed.

  Each surviving collection resolves to a catalogue category (match by
  `slug[primary] == handle`, then by `name` case-insensitive, else
  create — Shopify collections are flat, so a created category's
  `parent_uuid` is always `nil`; the existing tree is never touched),
  and writes `category.position` = the collection's (re-indexed)
  position plus `category.data["ecommerce"]["shopify"]["collection_id"]`.

  Then every resolved collection's product ids
  (`fetch_collection_product_ids/2` — already in the collection's own
  sort order) are fetched, and each distinct product id is matched to a
  catalogue item by `data["ecommerce"]["shopify"]["product_id"]` and
  assigned to the MOST SPECIFIC of its own (allowed) collections — the
  one with the fewest products, ties broken by (filtered) API order — at
  that collection's list position for the item. An item listed in only
  one allowed collection trivially gets that one. This replaces Block
  7's original "keep the item's current category when Shopify still
  lists it there" rule outright: on the live store, several allowed
  categories can legitimately list the same item (e.g. a general
  "3d-printed-decor" alongside a narrower "3d-printed-wall-frames"), and
  always preferring whichever one happened to be assigned first —
  rather than the narrowest match — is the bug this task fixes. A
  product id with no matching item is collected into
  `:unmatched_products` instead (deduplicated — the same missing id is
  never reported twice even if more than one collection lists it).

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
    * `:filter` — `%{"prefix" => handle_prefix | nil, "exclude" =>
      [handle]}`; defaults to `PhoenixKitEcommerce.get_config/1`'s
      `"shopify_collections_filter"` (itself `%{}` — everything passes
      — when never configured).
    * anything else (`:integration_uuid`, `:req_options`, ...) is
      forwarded to the client calls unchanged.
  """
  @spec run(keyword()) ::
          {:ok,
           %{
             categories_created: non_neg_integer(),
             categories_matched: non_neg_integer(),
             collections_skipped_by_filter: non_neg_integer(),
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
    filter = resolve_filter(opts)

    with {:ok, catalogue_uuid} <- resolve_catalogue_uuid(Keyword.get(opts, :catalogue_uuid)),
         {:ok, collections} <- client.fetch_collections(opts),
         {allowed, skipped_by_filter} <- apply_collections_filter(collections, filter),
         {:ok, resolved, created, matched} <- resolve_categories(allowed, catalogue_uuid),
         {:ok, per_collection} <- fetch_collection_products(resolved, client, opts),
         {:ok, assigned, repositioned, unmatched} <-
           assign_products(per_collection, items_by_product_id(catalogue_uuid)) do
      {:ok,
       %{
         categories_created: created,
         categories_matched: matched,
         collections_skipped_by_filter: skipped_by_filter,
         items_assigned: assigned,
         items_repositioned: repositioned,
         unmatched_products: unmatched
       }}
    end
  end

  defp resolve_catalogue_uuid(uuid) when is_binary(uuid) and uuid != "", do: {:ok, uuid}
  defp resolve_catalogue_uuid(_), do: {:error, :missing_catalogue_uuid}

  # `Keyword.fetch/2`, not `Keyword.get/3` with the config lookup as the
  # default argument — Elixir evaluates a default argument eagerly, so
  # `Keyword.get/3` would hit `phoenix_kit_shop_config` on every call
  # EVEN when the caller passed `:filter` explicitly (every test in this
  # module, and any future caller that wants a one-off filter).
  defp resolve_filter(opts) do
    case Keyword.fetch(opts, :filter) do
      {:ok, filter} -> filter
      :error -> PhoenixKitEcommerce.get_config("shopify_collections_filter")
    end
  end

  # ============================================================
  # Phase 0: the live-store allowlist (Block 7b Task 2)
  # ============================================================

  # Drops every collection `collection_allowed?/2` rejects, then
  # RE-INDEXES the survivors' `"position"` 0.. in their own (already
  # filtered) order — a filtered-out collection must not leave a gap in
  # the category positions the survivors get in `resolve_one_category/4`
  # below.
  defp apply_collections_filter(collections, filter) do
    filter = filter || %{}
    {allowed, skipped} = Enum.split_with(collections, &collection_allowed?(&1, filter))

    reindexed =
      allowed
      |> Enum.with_index()
      |> Enum.map(fn {collection, position} -> Map.put(collection, "position", position) end)

    {reindexed, length(skipped)}
  end

  defp collection_allowed?(collection, filter) do
    handle = collection["handle"] || ""
    exclude = filter["exclude"] || []
    prefix = filter["prefix"]

    handle not in exclude and matches_prefix?(handle, prefix)
  end

  defp matches_prefix?(_handle, prefix) when prefix in [nil, ""], do: true
  defp matches_prefix?(handle, prefix), do: String.starts_with?(handle, prefix)

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

  # `product_id_string => [{category_uuid, position, collection_size}, ...]`
  # — one entry per (allowed) collection that lists this product, in the
  # SAME order `per_collection` itself is in (i.e. the filtered API
  # order); `position` = the product's own index within THAT
  # collection's list, `collection_size` = that collection's own total
  # product count — the specificity `target_category_and_position/1`
  # picks the smallest of.
  defp build_product_categories(per_collection) do
    Enum.reduce(per_collection, %{}, fn {category_uuid, product_ids}, acc ->
      size = length(product_ids)

      product_ids
      |> Enum.with_index()
      |> Enum.reduce(acc, fn {product_id, position}, acc ->
        key = to_string(product_id)
        entry = {category_uuid, position, size}
        Map.update(acc, key, [entry], &(&1 ++ [entry]))
      end)
    end)
  end

  defp reconcile_item(item, categories, index, assigned, repositioned, unmatched) do
    {target_category, target_position} = target_category_and_position(categories)

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

  # The most specific of the item's own (allowed) collections — the one
  # with the fewest products; ties broken by (filtered) API order, which
  # `categories` is already in (`build_product_categories/1` appends in
  # `per_collection` order), so `Enum.min_by/2` keeping the FIRST minimal
  # element already IS that tie-break. Deliberately ignores the item's
  # current category — see the moduledoc for why Block 7's "keep it when
  # Shopify still lists it there" rule doesn't hold up once several
  # allowed categories can legitimately list the same product.
  defp target_category_and_position(categories) do
    {category_uuid, position, _size} =
      Enum.min_by(categories, fn {_category_uuid, _position, size} -> size end)

    {category_uuid, position}
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
