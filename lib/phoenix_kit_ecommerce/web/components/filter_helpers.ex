defmodule PhoenixKitEcommerce.Web.Components.FilterHelpers do
  @moduledoc """
  Shared helpers for storefront filter state management.

  Used by both ShopCatalog and CatalogCategory LiveViews to:
  - Load enabled filters and aggregate values
  - Parse filter params from URL query string
  - Build query opts for product listing
  - Build URLs with filter params
  """

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.ProductSource
  alias PhoenixKitEcommerce.StorefrontCache

  @doc """
  Loads enabled filters and their aggregated values.

  Returns `{filters, filter_values}` tuple.

  Options:
  - `:category_uuid` - Scope aggregation to a category by UUID
  - `:category` - The `%Category{}` being viewed (its `storefront_filters`
    overrides the global filter config for `:filters` - see
    `Shop.merge_storefront_filters/2`); `nil` for the global catalog page
  - `:language` - Translates an `attribute_set`/`metadata_option`
    filter's label to that language's attribute-set display name (see
    `Shop.get_enabled_storefront_filters/2`), and picks the same
    language's facet-value labels in `:filter_values` (forwarded to
    `Shop.aggregate_filter_values/1` as part of `opts`)
  """
  def load_filter_data(opts \\ []) do
    category = Keyword.get(opts, :category)
    language = Keyword.get(opts, :language)
    filters = Shop.get_enabled_storefront_filters(category, language)
    # The adapter would otherwise resolve this same list a second time.
    filter_values = Shop.aggregate_filter_values(Keyword.put(opts, :filters, filters))
    {filters, filter_values}
  end

  @doc """
  `load_filter_data/1` through `PhoenixKitEcommerce.StorefrontCache`: the
  result is shared by every visitor for up to a minute instead of
  recomputing the facet aggregates (a sequential scan each) on every mount.

  Takes the same options. The cached value is viewer-independent: the price
  range is the raw catalogue amount (the sidebar shows it as a placeholder,
  never converted), and filter labels are translated at render time, so
  neither the display currency nor the Gettext locale belongs in the key.
  A `:language` the shop has not enabled (it comes from the URL) is computed
  directly, never cached - see `StorefrontCache.fetch_in_language/3`.
  """
  def load_filter_data_cached(opts \\ []) do
    StorefrontCache.fetch_in_language(
      Keyword.get(opts, :language),
      filter_data_key(opts),
      fn -> load_filter_data(opts) end
    )
  end

  # Everything `load_filter_data/1` depends on: the product source (it can be
  # switched at runtime), and the options - `:language`, `:category_uuid`,
  # `:exclude_hidden_categories`. `:category` is reduced to its
  # `storefront_filters` overrides, the only thing read from it: the whole
  # struct would put a new key into the cache on every unrelated edit of the
  # category, and an edit of the overrides themselves changes the key.
  defp filter_data_key(opts) do
    overrides =
      case Keyword.get(opts, :category) do
        %{storefront_filters: overrides} -> overrides
        _ -> nil
      end

    {:filter_data, ProductSource.current(), overrides,
     opts |> Keyword.delete(:category) |> Enum.sort()}
  end

  @doc """
  Parses URL query params into active filter state.

  Returns a map: `%{"price" => %{min: Decimal, max: Decimal}, "vendor" => ["V1", "V2"], ...}`
  """
  def parse_filter_params(params, filters) do
    Enum.reduce(filters, %{}, fn filter, acc ->
      case parse_single_filter(filter, params) do
        nil -> acc
        value -> Map.put(acc, filter["key"], value)
      end
    end)
  end

  defp parse_single_filter(%{"type" => "price_range", "key" => key}, params) do
    min_val = parse_decimal(params["#{key}_min"])
    max_val = parse_decimal(params["#{key}_max"])

    if min_val || max_val do
      %{min: min_val, max: max_val}
    else
      nil
    end
  end

  defp parse_single_filter(%{"type" => type, "key" => key}, params)
       when type in ["vendor", "metadata_option", "attribute_set"] do
    # Raw URL params: Plug parses `?vendor[x]=y` into a map and
    # `?vendor[]=a` into a list that may hold nested maps. Anything that
    # isn't a comma list or a flat list of binaries is ignored rather than
    # raised on — a crafted URL must never 500 a storefront page.
    case params[key] do
      nil -> nil
      "" -> nil
      value when is_binary(value) -> String.split(value, ",", trim: true)
      values when is_list(values) -> presence_list(Enum.filter(values, &is_binary/1))
      _ -> nil
    end
  end

  defp parse_single_filter(%{"type" => "search", "key" => key}, params) do
    case params[key] do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp parse_single_filter(_filter, _params), do: nil

  @doc """
  Converts active filter state into keyword opts for `Shop.list_products_with_count/1`.
  """
  def build_query_opts(active_filters, filters) do
    Enum.reduce(filters, [], fn filter, opts ->
      active_filters
      |> Map.get(filter["key"])
      |> apply_filter_to_opts(filter, opts)
    end)
  end

  defp apply_filter_to_opts(nil, _filter, opts), do: opts

  defp apply_filter_to_opts(%{min: min_val, max: max_val}, _filter, opts) do
    opts
    |> maybe_add_opt(:price_min, min_val)
    |> maybe_add_opt(:price_max, max_val)
  end

  defp apply_filter_to_opts(values, filter, opts) when is_list(values) and values != [] do
    apply_list_filter(filter["type"], filter, values, opts)
  end

  defp apply_filter_to_opts(value, %{"type" => "search"}, opts)
       when is_binary(value) and value != "" do
    Keyword.put(opts, :search, value)
  end

  defp apply_filter_to_opts(_, _filter, opts), do: opts

  defp apply_list_filter("vendor", _filter, values, opts) do
    Keyword.put(opts, :vendors, values)
  end

  defp apply_list_filter("metadata_option", filter, values, opts) do
    existing = Keyword.get(opts, :metadata_filters, [])
    meta = %{key: filter["option_key"] || filter["key"], values: values}
    Keyword.put(opts, :metadata_filters, existing ++ [meta])
  end

  # Same shape as `metadata_option` (values are the attribute set's value
  # SLUGS, not labels — see `Query.filter_by_metadata/2`), keyed by
  # `set_slug` instead of `option_key`.
  defp apply_list_filter("attribute_set", filter, values, opts) do
    existing = Keyword.get(opts, :metadata_filters, [])
    meta = %{key: filter["set_slug"] || filter["key"], values: values}
    Keyword.put(opts, :metadata_filters, existing ++ [meta])
  end

  defp apply_list_filter(_, _filter, _values, opts), do: opts

  @doc """
  Builds a query string from active filter state (e.g. `"?price_min=10&price_max=100"` or `""`).

  Used to append filter params to navigation links so filter state persists
  across page transitions.
  """
  def build_query_string(active_filters, filters) do
    params = build_params_map(active_filters, filters)
    if params == %{}, do: "", else: "?" <> URI.encode_query(params)
  end

  @doc """
  Builds a URL path with filter query params.

  Merges filter state into a clean query string, preserving page param only
  when `keep_page` is true.
  """
  def build_filter_url(base_path, active_filters, filters, opts \\ []) do
    page = Keyword.get(opts, :page)
    params = build_params_map(active_filters, filters)
    params = if page && page > 1, do: Map.put(params, "page", page), else: params

    if params == %{} do
      base_path
    else
      query = URI.encode_query(params)
      "#{base_path}?#{query}"
    end
  end

  defp build_params_map(active_filters, filters) do
    Enum.reduce(filters, %{}, fn filter, acc ->
      case Map.get(active_filters, filter["key"]) do
        nil ->
          acc

        %{min: min_val, max: max_val} ->
          acc
          |> maybe_put_param("#{filter["key"]}_min", min_val)
          |> maybe_put_param("#{filter["key"]}_max", max_val)

        values when is_list(values) and values != [] ->
          Map.put(acc, filter["key"], Enum.join(values, ","))

        value when is_binary(value) and value != "" ->
          Map.put(acc, filter["key"], value)

        _ ->
          acc
      end
    end)
  end

  @doc """
  Returns true if any filters are currently active.
  """
  def has_active_filters?(active_filters) do
    active_filters != %{} and
      Enum.any?(active_filters, fn
        {_key, %{min: nil, max: nil}} -> false
        {_key, []} -> false
        {_key, nil} -> false
        _ -> true
      end)
  end

  @doc """
  Counts the number of active filter values (for mobile badge).
  """
  def active_filter_count(active_filters) do
    Enum.reduce(active_filters, 0, fn
      {_key, %{min: min_val, max: max_val}}, count ->
        count + if(min_val, do: 1, else: 0) + if max_val, do: 1, else: 0

      {_key, values}, count when is_list(values) ->
        count + length(values)

      {_key, value}, count when is_binary(value) and value != "" ->
        count + 1

      _, count ->
        count
    end)
  end

  @doc """
  Toggles a value in a checkbox-type filter.
  Returns updated active_filters map.
  """
  def toggle_filter_value(active_filters, filter_key, value) do
    current = Map.get(active_filters, filter_key, [])

    updated =
      if value in current do
        List.delete(current, value)
      else
        current ++ [value]
      end

    if updated == [] do
      Map.delete(active_filters, filter_key)
    else
      Map.put(active_filters, filter_key, updated)
    end
  end

  @doc """
  Drops one filter entirely, leaving every other selection in place.

  The sidebar's "Clear filters" button empties everything; this is the
  per-filter counterpart, so narrowing by size and then starting the size
  over does not also lose the colour the shopper picked.
  """
  def clear_filter(active_filters, filter_key) do
    Map.delete(active_filters, filter_key)
  end

  @doc """
  Updates a text search filter.
  Returns updated active_filters map; a blank term removes the filter.
  """
  def update_search_filter(active_filters, filter_key, value) do
    case value do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> Map.delete(active_filters, filter_key)
          trimmed -> Map.put(active_filters, filter_key, trimmed)
        end

      _ ->
        Map.delete(active_filters, filter_key)
    end
  end

  @doc """
  Updates price range filter.
  Returns updated active_filters map.
  """
  def update_price_filter(active_filters, filter_key, min_val, max_val) do
    min_dec = parse_decimal(min_val)
    max_dec = parse_decimal(max_val)

    if min_dec || max_dec do
      Map.put(active_filters, filter_key, %{min: min_dec, max: max_dec})
    else
      Map.delete(active_filters, filter_key)
    end
  end

  defp parse_decimal(nil), do: nil
  defp parse_decimal(""), do: nil

  defp parse_decimal(val) when is_binary(val) do
    case Decimal.parse(val) do
      {decimal, ""} -> decimal
      {decimal, _} -> decimal
      :error -> nil
    end
  end

  defp parse_decimal(val) when is_integer(val), do: Decimal.new(val)
  defp parse_decimal(val) when is_float(val), do: Decimal.from_float(val)
  defp parse_decimal(%Decimal{} = val), do: val
  # `?price_min[]=1` arrives as a list, `?price_min[x]=1` as a map.
  defp parse_decimal(_), do: nil

  defp presence_list([]), do: nil
  defp presence_list(values), do: values

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, val), do: Keyword.put(opts, key, val)

  defp maybe_put_param(params, _key, nil), do: params

  defp maybe_put_param(params, key, %Decimal{} = val) do
    Map.put(params, key, Decimal.to_string(val))
  end

  defp maybe_put_param(params, key, val), do: Map.put(params, key, to_string(val))
end
