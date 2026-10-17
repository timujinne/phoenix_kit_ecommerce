defmodule PhoenixKitEcommerce.API.PublicTools do
  @moduledoc """
  The tools of the shop's public API that only read: search, product cards,
  categories and similar products. Declared to core through
  `PhoenixKitEcommerce.api_tools/0`; core's executor validates the input
  against the schemas below, rate-limits, calls the handler and shapes the
  answer.

  No tool here needs a key, a scope or a permission (`audience: :public`); the
  API switch (`api_public_enabled`) and the website password gate are core's.

  This module, `API.CartTools` and `API.CartStore` are the lib modules that
  name core's `PhoenixKit.API.*` modules, each behind `Code.ensure_loaded?/1`
  or `@compile {:no_warn_undefined, ...}`. This one checks that core has
  `PhoenixKit.API.Tool`, so the package still compiles with
  `--warnings-as-errors` against a released core that has no shop API: there
  `tools/0` answers `[]` and `api_tools/0` is never called.

  A tool that core refuses is left out and logged once; it never takes the
  other tools (or the module's other API tools) down with it. Core asks for the
  tools on every request, so the log line must not depend on request traffic.
  """

  require Logger

  alias PhoenixKit.API.Tool
  alias PhoenixKitEcommerce.API.Public.Catalog
  alias PhoenixKitEcommerce.API.Public.Search

  @compile {:no_warn_undefined, PhoenixKit.API.Tool}

  @read_only %{read_only: true, destructive: false, idempotent: true, open_world: false}

  @spec tools() :: [struct()]
  def tools do
    if Code.ensure_loaded?(Tool), do: build_all(specs()), else: []
  end

  @doc false
  # Public for the test: builds the given specs, dropping (and logging once) the refused.
  @spec build_all([keyword()]) :: [struct()]
  def build_all(specs), do: Enum.flat_map(specs, &build/1)

  defp build(attrs) do
    case Tool.new(attrs) do
      {:ok, tool} ->
        [tool]

      {:error, messages} ->
        log_once(attrs[:name], messages)
        []
    end
  end

  defp log_once(name, messages) do
    key = {__MODULE__, :refused, name}

    unless :persistent_term.get(key, false) do
      :persistent_term.put(key, true)

      Logger.warning(
        "[PhoenixKitEcommerce] public tool #{name} is invalid: " <> Enum.join(messages, "; ")
      )
    end
  end

  defp specs do
    [
      [
        name: "shop.search_products",
        audience: :public,
        title: "Search products",
        description:
          "Search the shop's products by words, category, price, options, vendor and sale status. " <>
            "Returns a page of products with prices, the exact number of matches and facets " <>
            "(categories, vendors, options, price range) to refine the search. Leave out q to browse. " <>
            "Use the product ids with shop.get_products for full details.",
        input_schema: Search.search_input_schema(),
        output_schema: Search.search_output_schema(),
        handler: {Search, :search_products},
        annotations: @read_only
      ],
      [
        name: "shop.search_products_batch",
        audience: :public,
        title: "Search products, several queries at once",
        description:
          "Run up to 20 product searches in one call, for example one per item on a shopping list. " <>
            "Each query takes the same fields as shop.search_products and gets its own result block, " <>
            "in order. A query the search rejects (for example a category id that is not a UUID) gets an error block and the others still run; a query that breaks the input rules (a limit of 0, an unknown sort) fails the whole call. A batch returns about 200 products in total (every query returns at least one); a query without limit gets 10. " <>
            "Each query counts as one request against the rate limit.",
        input_schema: Search.batch_input_schema(),
        output_schema: Search.batch_output_schema(),
        handler: {Search, :search_products_batch},
        annotations: @read_only,
        max_items: 20,
        # One rate-limit unit per query, charged by the executor before validation.
        cost: {Search, :batch_cost}
      ],
      [
        name: "shop.get_products",
        audience: :public,
        title: "Get product details",
        description:
          "Get the full card of up to 50 products by id: title, description, price and sale price, " <>
            "options with their keys, tags, images and category path. A product that is no longer " <>
            "sold returns only its id, title and status \"discontinued\"; an id that does not exist " <>
            "or is not for sale returns not_found. Every ten ids count as one request against the rate limit.",
        input_schema: Catalog.get_products_input_schema(),
        output_schema: Catalog.get_products_output_schema(),
        handler: {Catalog, :get_products},
        annotations: @read_only,
        max_items: 50,
        # One rate-limit unit per ten ids, charged by the executor before validation.
        cost: {Catalog, :get_products_cost}
      ],
      [
        name: "shop.list_categories",
        audience: :public,
        title: "List product categories",
        description:
          "List the shop's categories as a tree, with the number of products in each category " <>
            "and in all of its sub-categories. Use a category id as category_id in shop.search_products.",
        input_schema: Catalog.list_categories_input_schema(),
        output_schema: Catalog.list_categories_output_schema(),
        handler: {Catalog, :list_categories},
        annotations: @read_only
      ],
      [
        name: "shop.similar_products",
        audience: :public,
        title: "Find similar products",
        description:
          "Find products similar to one product: in the same category, or sharing an option value or " <>
            "a tag, ranked by how much they share. Returns up to 20 products as in shop.search_products.",
        input_schema: Catalog.similar_products_input_schema(),
        output_schema: Catalog.similar_products_output_schema(),
        handler: {Catalog, :similar_products},
        annotations: @read_only
      ]
    ]
  end
end
