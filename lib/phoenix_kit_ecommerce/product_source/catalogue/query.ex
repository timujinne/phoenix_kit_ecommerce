defmodule PhoenixKitEcommerce.ProductSource.Catalogue.Query do
  @moduledoc """
  Ecto queries over `phoenix_kit_catalogue`'s `Item`/`Category` schemas,
  scoped to the one catalogue the shop reads (`get_config("shop_catalogue")`,
  default name `"decor3dprint"`, resolved through `Catalogue.list_catalogues/0`).

  Returns raw catalogue structs — `PhoenixKitEcommerce.ProductSource.Catalogue`
  turns them into view-structs via `Catalogue.View`. Nothing here is called
  unless `ProductSource.current/0` already picked this adapter, which
  requires `phoenix_kit_catalogue` to be loaded; `@compile
  {:no_warn_undefined, ...}` only quietens the compiler's static xref
  check for hosts that don't declare the optional dependency.
  """

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}
  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue.AttributeSets}
  @compile {:no_warn_undefined, PhoenixKitCatalogue.Schemas.Category}
  @compile {:no_warn_undefined, PhoenixKitCatalogue.Schemas.Item}
  @compile {:no_warn_undefined, PhoenixKitCatalogue.Schemas.ItemAttributeSet}
  @compile {:no_warn_undefined, PhoenixKitEntities.EntityData}

  import Ecto.Query, warn: false

  require Logger

  alias PhoenixKit.Utils.Multilang
  alias PhoenixKit.Utils.UUID, as: UUIDUtils
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Schemas.Category, as: CatCategory
  alias PhoenixKitCatalogue.Schemas.Item, as: CatItem
  alias PhoenixKitCatalogue.Schemas.ItemAttributeSet
  alias PhoenixKitEntities.EntityData

  @default_catalogue_name "decor3dprint"

  # ============================================================
  # Catalogue resolution
  # ============================================================

  @doc """
  The uuid of the one catalogue the shop reads, or `nil` when it can't
  be resolved (not yet bootstrapped, or the configured name matches
  none). Resolved by name on every call — the shop has one catalogue,
  so this is one small `SELECT` against a handful of rows, not a
  per-request bottleneck.
  """
  @spec catalogue_uuid() :: Ecto.UUID.t() | nil
  def catalogue_uuid do
    name = PhoenixKitEcommerce.get_config("shop_catalogue") || @default_catalogue_name

    Catalogue.list_catalogues()
    |> Enum.find(&(&1.name == name))
    |> case do
      %{uuid: uuid} -> uuid
      _ -> nil
    end
  end

  # ============================================================
  # Items
  # ============================================================

  @doc "Lists items matching `opts`, ordered by `position, name`."
  @spec list_items(keyword()) :: [CatItem.t()]
  def list_items(opts \\ []) do
    case catalogue_uuid() do
      nil ->
        []

      uuid ->
        CatItem
        |> where([i], i.catalogue_uuid == ^uuid)
        |> apply_item_filters(opts)
        |> order_by([i], asc: i.position, asc: i.name)
        |> maybe_paginate(opts)
        |> repo().all()
    end
  end

  @doc "`list_items/1` plus the total count before pagination is applied."
  @spec list_items_with_count(keyword()) :: {[CatItem.t()], non_neg_integer()}
  def list_items_with_count(opts \\ []) do
    case catalogue_uuid() do
      nil ->
        {[], 0}

      uuid ->
        base =
          CatItem
          |> where([i], i.catalogue_uuid == ^uuid)
          |> apply_item_filters(opts)

        total = repo().aggregate(base, :count)

        items =
          base
          |> order_by([i], asc: i.position, asc: i.name)
          |> maybe_paginate(opts)
          |> repo().all()

        {items, total}
    end
  end

  @doc "Count of items matching `opts` (no pagination applied)."
  @spec count_items(keyword()) :: non_neg_integer()
  def count_items(opts \\ []) do
    case catalogue_uuid() do
      nil ->
        0

      uuid ->
        CatItem
        |> where([i], i.catalogue_uuid == ^uuid)
        |> apply_item_filters(opts)
        |> repo().aggregate(:count)
    end
  end

  @doc "Fetches one item by uuid, scoped to the shop catalogue. `nil` on a miss."
  @spec get_item(String.t()) :: CatItem.t() | nil
  def get_item(uuid) when is_binary(uuid) do
    if UUIDUtils.valid?(uuid) do
      case catalogue_uuid() do
        nil -> nil
        catalogue_uuid -> repo().get_by(CatItem, uuid: uuid, catalogue_uuid: catalogue_uuid)
      end
    else
      nil
    end
  end

  def get_item(_), do: nil

  @doc """
  Fetches items by uuid, order preserved, missing uuids dropped, scoped
  to the shop catalogue (same "one catalogue only" contract every other
  read in this module enforces) — mirrors
  `PhoenixKitEcommerce.ProductSource.Legacy.list_products_by_ids/1`.
  """
  @spec list_items_by_uuids([Ecto.UUID.t()]) :: [CatItem.t()]
  def list_items_by_uuids([]), do: []

  def list_items_by_uuids(uuids) when is_list(uuids) do
    case catalogue_uuid() do
      nil ->
        []

      catalogue_uuid ->
        by_uuid =
          CatItem
          |> where([i], i.uuid in ^uuids and i.catalogue_uuid == ^catalogue_uuid)
          |> repo().all()
          |> Map.new(&{&1.uuid, &1})

        uuids |> Enum.uniq() |> Enum.flat_map(&List.wrap(Map.get(by_uuid, &1)))
    end
  end

  @doc """
  Active-item counts grouped by `category_uuid`, "active" meaning
  `item.status == "active" AND data.ecommerce.shop_status == "active"`
  (spec principle 7) — items with no category are excluded, same as
  `ProductSource.Legacy.product_counts_by_category/0`.
  """
  @spec product_counts_by_category() :: %{String.t() => non_neg_integer()}
  def product_counts_by_category do
    case catalogue_uuid() do
      nil ->
        %{}

      uuid ->
        CatItem
        |> where([i], i.catalogue_uuid == ^uuid)
        |> where([i], not is_nil(i.category_uuid))
        |> active_visibility()
        |> group_by([i], i.category_uuid)
        |> select([i], {i.category_uuid, count(i.uuid)})
        |> repo().all()
        |> Map.new()
    end
  rescue
    e ->
      Logger.warning("Failed to load catalogue product counts by category: #{inspect(e)}")
      %{}
  end

  @doc "Min/max `base_price` over active items, optionally scoped to a category."
  @spec price_range(keyword()) :: {Decimal.t() | nil, Decimal.t() | nil}
  def price_range(opts \\ []) do
    case catalogue_uuid() do
      nil ->
        {nil, nil}

      uuid ->
        query =
          CatItem
          |> where([i], i.catalogue_uuid == ^uuid)
          |> active_visibility()
          |> maybe_filter_category(Keyword.get(opts, :category_uuid))

        {repo().aggregate(query, :min, :base_price), repo().aggregate(query, :max, :base_price)}
    end
  rescue
    _ -> {nil, nil}
  end

  @doc """
  Distinct `vendor` values (from `data["ecommerce"]["vendor"]`) over
  active items, with counts, optionally scoped to a category.
  """
  @spec vendor_counts(keyword()) :: [%{value: String.t(), count: non_neg_integer()}]
  def vendor_counts(opts \\ []) do
    case catalogue_uuid() do
      nil ->
        []

      uuid ->
        CatItem
        |> where([i], i.catalogue_uuid == ^uuid)
        |> active_visibility()
        |> where([i], fragment("COALESCE(?->'ecommerce'->>'vendor', '') != ''", i.data))
        |> maybe_filter_category(Keyword.get(opts, :category_uuid))
        |> group_by([i], fragment("?->'ecommerce'->>'vendor'", i.data))
        |> select([i], %{
          value: fragment("?->'ecommerce'->>'vendor'", i.data),
          count: count(i.uuid)
        })
        |> order_by([i], desc: count(i.uuid))
        |> repo().all()
    end
  rescue
    _ -> []
  end

  @doc """
  Facet counts for one attribute SET's values (`set_slug` — the set's
  entities blueprint name, with or without the `"catalogue_set_"`
  prefix, same lookup `filter_by_metadata/2` uses), scoped to
  storefront-visible items (`active_visibility/1`) in the shop
  catalogue.

  Options: `:category_uuid` (scope to one category), `:exclude_hidden_categories`
  (drop items whose category's `shop_status` is `"hidden"`), `:language`
  (prefer `data[language]["_title"]` over the value's bare `title` —
  the picker/sidebar's fuller per-language resolution is Block 5's
  remaining work; this covers the plain value label).

  A value with no `published` `EntityData` row for the requested slug
  never appears — `draft`/`archived` values (Block 5's resolver creates
  unknown Shopify strings as `draft`) are excluded from storefront
  facets by construction, not by a separate filter.

  Ordered by the value's position, then its resolved label.
  """
  @spec attribute_set_counts(String.t(), keyword()) :: [
          %{slug: String.t(), label: String.t(), count: non_neg_integer()}
        ]
  def attribute_set_counts(set_slug, opts \\ []) when is_binary(set_slug) do
    with catalogue_uuid when not is_nil(catalogue_uuid) <- catalogue_uuid(),
         set_uuid when not is_nil(set_uuid) <- set_uuid_for_key(set_slug) do
      language = Keyword.get(opts, :language)

      CatItem
      |> where([i], i.catalogue_uuid == ^catalogue_uuid)
      |> active_visibility()
      |> maybe_filter_category(Keyword.get(opts, :category_uuid))
      |> exclude_hidden_categories(Keyword.get(opts, :exclude_hidden_categories, false))
      |> join(:inner, [i], a in ItemAttributeSet,
        on: a.item_uuid == i.uuid and a.set_uuid == ^set_uuid
      )
      |> join(
        :inner_lateral,
        [i, a],
        slug in fragment(
          "jsonb_array_elements_text(CASE WHEN jsonb_typeof(?->'selected_value_slugs') = 'array' THEN ?->'selected_value_slugs' ELSE '[]'::jsonb END)",
          a.data,
          a.data
        ),
        on: true
      )
      |> join(:inner, [i, a, slug], ev in EntityData,
        on: ev.entity_uuid == ^set_uuid and ev.slug == slug and ev.status == "published"
      )
      |> group_by([i, a, slug, ev], [slug, ev.title, ev.position, ev.data])
      |> select([i, a, slug, ev], %{
        slug: slug,
        title: ev.title,
        data: ev.data,
        position: ev.position,
        count: count(i.uuid, :distinct)
      })
      |> repo().all()
      |> Enum.map(
        &%{
          slug: &1.slug,
          label: value_label(&1, language),
          count: &1.count,
          position: &1.position
        }
      )
      |> Enum.sort_by(&{&1.position, &1.label})
      |> Enum.map(&Map.take(&1, [:slug, :label, :count]))
    else
      _ -> []
    end
  rescue
    e ->
      Logger.warning("Failed to load attribute_set_counts(#{inspect(set_slug)}): #{inspect(e)}")
      []
  end

  @doc """
  Translated display names for a batch of attribute-set BLUEPRINTS,
  keyed by set uuid (`AttributeSets.resolve_for_item/2`'s per-set `:uuid`
  field) — `ProductSource.Catalogue` swaps a resolved set's `:name` for
  this before handing `sets` to `View.product_view/2` (which is pure and
  has no way to read `settings["translations"]` itself). One
  `AttributeSets.get_set/2` call per DISTINCT set, never per item — a
  product page has a handful of attached sets, and a listing page's many
  items still share that same handful, so the count stays small; there
  is no batched-by-uuid-list entities read to reach for instead. A set
  that can't be resolved (deleted, or gated by `get_set/2`'s own owner
  check) is simply absent from the result — callers keep the
  untranslated `:name` already on the resolved set for it.
  """
  @spec set_display_names([Ecto.UUID.t()], String.t()) :: %{Ecto.UUID.t() => String.t()}
  def set_display_names([], _language), do: %{}

  def set_display_names(set_uuids, language) when is_list(set_uuids) and is_binary(language) do
    set_uuids
    |> Enum.uniq()
    |> Map.new(&{&1, set_display_name(&1, language)})
    |> Enum.reject(fn {_uuid, name} -> is_nil(name) end)
    |> Map.new()
  end

  @doc """
  Translated display name of one attribute set by its FILTER-CONFIG slug
  (`set_slug` — with or without the `catalogue_set_` prefix, same lookup
  `filter_by_metadata/2` uses), `nil` when the slug doesn't resolve to a
  set. The sidebar's `attribute_set`/`metadata_option` filter section
  reads this — a filter config only ever carries the slug, never the
  set's uuid.
  """
  @spec set_label(String.t(), String.t()) :: String.t() | nil
  def set_label(set_slug, language) when is_binary(set_slug) and is_binary(language) do
    case set_uuid_for_key(set_slug) do
      nil -> nil
      set_uuid -> set_display_name(set_uuid, language)
    end
  end

  # The one place this module reaches for `AttributeSets.get_set/2`
  # rather than a plain query of its own: `get_set/2`'s `:lang` option
  # already applies the exact translation-with-fallback
  # (`settings["translations"][language]["display_name"]`, else the bare
  # `display_name`) a hand-rolled fragment would have to duplicate —
  # base/dialect matching (`"es"` finding an `"es-ES"` translation)
  # included. Writing that logic a second time here would drift from
  # `PhoenixKitEntities.resolve_language/2`'s the moment either changes.
  defp set_display_name(set_uuid, language) do
    case Catalogue.AttributeSets.get_set(set_uuid, lang: language) do
      %{display_name: name} when is_binary(name) and name != "" -> name
      _ -> nil
    end
  rescue
    e ->
      Logger.warning("Failed to resolve set display name for #{inspect(set_uuid)}: #{inspect(e)}")
      nil
  end

  defp value_label(%{title: title}, nil), do: title

  # `Multilang.get_language_data/2` (matching
  # `EntityData.get_title_translation/2`'s own path) rather than a naive
  # `data[language]["_title"]` key lookup, so a value translated under a
  # base code ("fr") is still found from a dialect-precision page
  # ("fr-FR") and vice versa, and `data[primary]["_title"]` is consulted
  # before falling back to the untranslated `title` column.
  defp value_label(%{title: title, data: data}, language) do
    case Map.get(Multilang.get_language_data(data, language), "_title") do
      value when is_binary(value) and value != "" -> value
      _ -> title
    end
  end

  # Items with no category (`category_uuid: nil`) are never hidden by a
  # category's own `shop_status` — there is no category to check.
  defp exclude_hidden_categories(query, false), do: query

  defp exclude_hidden_categories(query, true) do
    hidden_category_uuids =
      from(c in CatCategory,
        where: fragment("COALESCE(?->'ecommerce'->>'shop_status', 'active')", c.data) == "hidden",
        select: c.uuid
      )

    where(
      query,
      [i],
      is_nil(i.category_uuid) or i.category_uuid not in subquery(hidden_category_uuids)
    )
  end

  # ============================================================
  # Categories
  # ============================================================

  @doc "Lists the shop catalogue's categories."
  @spec list_categories(keyword()) :: [CatCategory.t()]
  def list_categories(opts \\ []) do
    case catalogue_uuid() do
      nil ->
        []

      uuid ->
        CatCategory
        |> where([c], c.catalogue_uuid == ^uuid)
        |> apply_category_filters(opts)
        |> order_by([c], asc: c.position, asc: c.name)
        |> repo().all()
    end
  end

  @doc "Fetches one category by uuid, scoped to the shop catalogue."
  @spec get_category(String.t()) :: CatCategory.t() | nil
  def get_category(uuid) when is_binary(uuid) do
    if UUIDUtils.valid?(uuid) do
      case catalogue_uuid() do
        nil -> nil
        catalogue_uuid -> repo().get_by(CatCategory, uuid: uuid, catalogue_uuid: catalogue_uuid)
      end
    else
      nil
    end
  end

  def get_category(_), do: nil

  @doc "Fetches categories by uuid, scoped to the shop catalogue. Missing uuids dropped."
  @spec list_categories_by_uuids([String.t()]) :: [CatCategory.t()]
  def list_categories_by_uuids([]), do: []

  def list_categories_by_uuids(uuids) when is_list(uuids) do
    case catalogue_uuid() do
      nil ->
        []

      catalogue_uuid ->
        CatCategory
        |> where([c], c.uuid in ^uuids and c.catalogue_uuid == ^catalogue_uuid)
        |> repo().all()
    end
  end

  # ============================================================
  # Item filters
  # ============================================================

  defp apply_item_filters(query, opts) do
    query
    |> filter_by_status(Keyword.get(opts, :status))
    |> filter_by_category(Keyword.get(opts, :category_uuid))
    |> filter_by_visible_categories(Keyword.get(opts, :exclude_hidden_categories, false))
    |> filter_by_search(Keyword.get(opts, :search))
    |> filter_by_price_range(Keyword.get(opts, :price_min), Keyword.get(opts, :price_max))
    |> filter_by_vendors(Keyword.get(opts, :vendors))
    |> filter_by_metadata(Keyword.get(opts, :metadata_filters))
  end

  # Mirrors `View.product_status/2`'s fallback: with no `shop_status`
  # override, the derived status is "active" when `item.status ==
  # "active"`, else "archived".
  defp filter_by_status(query, nil), do: query

  defp filter_by_status(query, "active") do
    where(
      query,
      [i],
      i.status == "active" and
        fragment("COALESCE(?->'ecommerce'->>'shop_status', 'active') = 'active'", i.data)
    )
  end

  defp filter_by_status(query, status) do
    where(
      query,
      [i],
      fragment(
        "COALESCE(?->'ecommerce'->>'shop_status', CASE WHEN ? = 'active' THEN 'active' ELSE 'archived' END) = ?",
        i.data,
        i.status,
        ^status
      )
    )
  end

  # Item visibility per spec principle 7.
  defp active_visibility(query) do
    where(
      query,
      [i],
      i.status == "active" and
        fragment("(?->'ecommerce'->>'shop_status') = 'active'", i.data)
    )
  end

  defp filter_by_category(query, nil), do: query
  defp filter_by_category(query, uuid), do: where(query, [i], i.category_uuid == ^uuid)

  defp maybe_filter_category(query, nil), do: query
  defp maybe_filter_category(query, uuid), do: where(query, [i], i.category_uuid == ^uuid)

  defp filter_by_visible_categories(query, false), do: query

  defp filter_by_visible_categories(query, true) do
    from(i in query,
      left_join: c in CatCategory,
      on: c.uuid == i.category_uuid,
      where:
        is_nil(c.uuid) or
          fragment("COALESCE(?->'ecommerce'->>'shop_status', 'active')", c.data) != "hidden",
      distinct: i.uuid
    )
  end

  defp filter_by_price_range(query, nil, nil), do: query
  defp filter_by_price_range(query, min, nil), do: where(query, [i], i.base_price >= ^min)
  defp filter_by_price_range(query, nil, max), do: where(query, [i], i.base_price <= ^max)

  defp filter_by_price_range(query, min, max),
    do: where(query, [i], i.base_price >= ^min and i.base_price <= ^max)

  defp filter_by_vendors(query, nil), do: query
  defp filter_by_vendors(query, []), do: query

  defp filter_by_vendors(query, vendors) when is_list(vendors) do
    where(query, [i], fragment("?->'ecommerce'->>'vendor'", i.data) in ^vendors)
  end

  # `metadata_filters`: `[%{key: set_key, values: [value slugs]}]`. Takes
  # value SLUGS directly rather than resolving labels here — the storefront
  # filter UI that would collect labels from a shopper is Block 5 work
  # (self-review: "metadata_option filters disabled until block 5"); a
  # caller with labels resolves them through
  # `PhoenixKitCatalogue.Catalogue.AttributeSets.resolve_set/2`'s
  # `values` first. Matches on the item's attached-set row via `set_uuid`
  # (`sets_by_key/1` resolves `key` to a set uuid) and its
  # `data["selected_value_slugs"]` overlapping the requested slugs.
  defp filter_by_metadata(query, nil), do: query
  defp filter_by_metadata(query, []), do: query

  defp filter_by_metadata(query, filters) when is_list(filters) do
    Enum.reduce(filters, query, fn %{key: key, values: slugs}, q ->
      case set_uuid_for_key(key) do
        nil ->
          q

        set_uuid ->
          # `item_attribute_sets` is unique on `(item_uuid, set_uuid)`, so
          # this join adds at most one row per item — no de-dup needed.
          from(i in q,
            join: a in ItemAttributeSet,
            on: a.item_uuid == i.uuid and a.set_uuid == ^set_uuid,
            where:
              fragment(
                "?->'selected_value_slugs' \\?| ?",
                a.data,
                type(^slugs, {:array, :string})
              )
          )
      end
    end)
  end

  defp set_uuid_for_key(key) do
    Catalogue.AttributeSets.list_sets()
    |> Enum.find(&(&1.name == key or &1.name == "catalogue_set_" <> key))
    |> case do
      %{uuid: uuid} -> uuid
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @max_search_term_length 100

  defp search_like_pattern(search) do
    escaped =
      search
      |> String.replace(<<0>>, "")
      |> String.slice(0, @max_search_term_length)
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

    "%#{escaped}%"
  end

  defp filter_by_search(query, nil), do: query
  defp filter_by_search(query, ""), do: query

  defp filter_by_search(query, search) do
    term = search_like_pattern(search)

    where(
      query,
      [i],
      fragment(
        "(? ILIKE ? OR COALESCE(?, '') ILIKE ? OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(COALESCE(?->'ecommerce'->'tags', '[]'::jsonb)) AS tag WHERE tag ILIKE ?))",
        i.name,
        ^term,
        i.description,
        ^term,
        i.data,
        ^term
      )
    )
  end

  # ============================================================
  # Category filters
  # ============================================================

  defp apply_category_filters(query, opts) do
    query
    |> filter_by_category_status(Keyword.get(opts, :status, :skip))
    |> filter_by_parent_uuid(Keyword.get(opts, :parent_uuid, :skip))
  end

  defp filter_by_category_status(query, :skip), do: query
  defp filter_by_category_status(query, nil), do: query

  # `status`/`statuses` here are the SHOP status domain
  # (active|unlisted|hidden, `data["ecommerce"]["shop_status"]` —
  # what `View.category_view/2` maps `:status` from and what
  # `CategoryCommerce` validates), NOT the catalogue category's own
  # `c.status` column (active|deleted). `c.status != "deleted"` is kept
  # as a separate always-on guard alongside it so a soft-deleted
  # catalogue category can never be resurrected by a stray shop_status.
  defp filter_by_category_status(query, status) when is_binary(status) do
    query
    |> where([c], c.status != "deleted")
    |> where(
      [c],
      fragment("COALESCE(?->'ecommerce'->>'shop_status', 'active')", c.data) == ^status
    )
  end

  defp filter_by_category_status(query, statuses) when is_list(statuses) do
    query
    |> where([c], c.status != "deleted")
    |> where(
      [c],
      fragment("COALESCE(?->'ecommerce'->>'shop_status', 'active')", c.data) in ^statuses
    )
  end

  defp filter_by_parent_uuid(query, :skip), do: query
  defp filter_by_parent_uuid(query, nil), do: where(query, [c], is_nil(c.parent_uuid))
  defp filter_by_parent_uuid(query, uuid), do: where(query, [c], c.parent_uuid == ^uuid)

  # ============================================================
  # Pagination
  # ============================================================

  defp maybe_paginate(query, opts) do
    case {Keyword.get(opts, :page), Keyword.get(opts, :per_page)} do
      {nil, nil} ->
        query

      {page, per_page} ->
        page = page || 1
        per_page = per_page || 25
        offset = (page - 1) * per_page
        query |> limit(^per_page) |> offset(^offset)
    end
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
