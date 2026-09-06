defmodule PhoenixKitEcommerce.Shopify.AdminClient do
  @moduledoc """
  Thin REST client for the Shopify Admin API's `products.json` endpoint.

  Resolves the shop domain and access token from the `PhoenixKit.Integrations`
  connection identified by `integration_uuid` — never from application env
  (see `PhoenixKitEcommerce.Shopify.Provider` for why). Authenticates with
  the `X-Shopify-Access-Token` header, NOT `Authorization: Bearer` — that is
  what the REST Admin API expects for a Custom App's static token.
  """

  require Logger

  alias PhoenixKit.Integrations

  # Shopify deprecates REST Admin API versions roughly a year after release
  # (see https://shopify.dev/docs/api/usage/versioning) — this needs
  # periodic bumping to a currently-supported stable version.
  @api_version "2025-01"

  @page_limit 250
  @product_fields ~w(id handle title body_html vendor product_type tags status images variants options)
  @collection_fields ~w(id handle title sort_order)
  @max_retries 5
  @default_retry_after_seconds 1
  @max_retry_after_seconds 60

  @doc """
  Fetches every product from the Shopify store connected via
  `integration_uuid`, following `Link: rel="next"` pagination.

  ## Options

    * `:req_options` — keyword list merged into `Req.new/1` (e.g. `plug:`
      to stub the transport in tests).
  """
  @spec fetch_products(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def fetch_products(integration_uuid, opts \\ []) do
    with {:ok, {shop_domain, req}} <-
           resolve_client(integration_uuid, Keyword.get(opts, :req_options, [])) do
      fetch_all(req, initial_url(shop_domain), [], @max_retries, "products")
    end
  end

  @doc """
  Fetches every collection from the connected store — `custom_collections`
  and `smart_collections` concatenated, each paginated like
  `fetch_products/2`. Each returned collection carries `"kind"` (`"custom"`
  or `"smart"`, which endpoint it came from) and `"position"` — a running
  index across BOTH lists, in API order (custom first, then smart) — this
  is the order `CollectionSync` writes as `category.position`.

  ## Options

    * `:integration_uuid` — required; resolves the shop domain/access
      token the same way `fetch_products/2` does.
    * `:req_options` — as `fetch_products/2`.
  """
  @spec fetch_collections(keyword()) :: {:ok, [map()]} | {:error, term()}
  def fetch_collections(opts \\ []) do
    with {:ok, integration_uuid} <- fetch_integration_uuid(opts),
         {:ok, {shop_domain, req}} <-
           resolve_client(integration_uuid, Keyword.get(opts, :req_options, [])) do
      fetch_collections_by_kind(req, shop_domain)
    end
  end

  @doc """
  Fetches the product ids of `collection_id`, in the order Shopify
  returns them — Shopify applies the collection's own sort order to this
  endpoint, so no client-side sorting happens here; `CollectionSync` reads
  this order directly as `item.position` within the category. Paginated
  like `fetch_products/2`.

  ## Options

  Same as `fetch_collections/1`.
  """
  @spec fetch_collection_product_ids(String.t() | integer(), keyword()) ::
          {:ok, [term()]} | {:error, term()}
  def fetch_collection_product_ids(collection_id, opts \\ []) do
    with {:ok, integration_uuid} <- fetch_integration_uuid(opts),
         {:ok, {shop_domain, req}} <-
           resolve_client(integration_uuid, Keyword.get(opts, :req_options, [])) do
      url = collection_products_url(shop_domain, collection_id)

      case fetch_all(req, url, [], @max_retries, "products") do
        {:ok, products} -> {:ok, Enum.map(products, & &1["id"])}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp fetch_integration_uuid(opts) do
    case Keyword.get(opts, :integration_uuid) do
      uuid when is_binary(uuid) and uuid != "" -> {:ok, uuid}
      _ -> {:error, :missing_integration_uuid}
    end
  end

  defp resolve_client(integration_uuid, req_options) do
    case Integrations.get_credentials(integration_uuid) do
      {:ok, %{"shop_domain" => shop_domain, "access_token" => access_token}}
      when is_binary(shop_domain) and shop_domain != "" and
             is_binary(access_token) and access_token != "" ->
        {:ok, {shop_domain, build_req(access_token, req_options)}}

      {:ok, _incomplete} ->
        {:error, :missing_credentials}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_collections_by_kind(req, shop_domain) do
    with {:ok, custom} <-
           fetch_all(
             req,
             collections_url(shop_domain, "custom_collections"),
             [],
             @max_retries,
             "custom_collections"
           ),
         {:ok, smart} <-
           fetch_all(
             req,
             collections_url(shop_domain, "smart_collections"),
             [],
             @max_retries,
             "smart_collections"
           ) do
      collections =
        (tag_kind(custom, "custom") ++ tag_kind(smart, "smart"))
        |> Enum.with_index()
        |> Enum.map(fn {collection, index} -> Map.put(collection, "position", index) end)

      {:ok, collections}
    end
  end

  defp tag_kind(collections, kind), do: Enum.map(collections, &Map.put(&1, "kind", kind))

  defp initial_url(shop_domain) do
    query =
      URI.encode_query(%{"limit" => @page_limit, "fields" => Enum.join(@product_fields, ",")})

    "https://#{shop_domain}/admin/api/#{@api_version}/products.json?" <> query
  end

  defp collections_url(shop_domain, resource) do
    query =
      URI.encode_query(%{"limit" => @page_limit, "fields" => Enum.join(@collection_fields, ",")})

    "https://#{shop_domain}/admin/api/#{@api_version}/#{resource}.json?" <> query
  end

  defp collection_products_url(shop_domain, collection_id) do
    query = URI.encode_query(%{"limit" => @page_limit, "fields" => "id"})

    "https://#{shop_domain}/admin/api/#{@api_version}/collections/#{collection_id}/products.json?" <>
      query
  end

  defp build_req(access_token, req_options) do
    [headers: [{"x-shopify-access-token", access_token}], retry: false]
    |> Keyword.merge(req_options)
    |> Req.new()
  end

  defp fetch_all(_req, nil, acc, _retries_left, _response_key), do: {:ok, Enum.reverse(acc)}

  defp fetch_all(req, url, acc, retries_left, response_key) do
    case Req.get(req, url: url) do
      {:ok, %{status: 200, body: %{^response_key => entries}} = response} ->
        fetch_all(
          req,
          next_page_url(response),
          Enum.reverse(entries, acc),
          @max_retries,
          response_key
        )

      {:ok, %{status: 429} = response} when retries_left > 0 ->
        retry_after = retry_after_seconds(response)
        Process.sleep(:timer.seconds(retry_after))
        fetch_all(req, url, acc, retries_left - 1, response_key)

      {:ok, %{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %{status: 403}} ->
        {:error, :forbidden}

      {:ok, %{status: 404}} ->
        {:error, :shop_not_found}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp next_page_url(response) do
    case response_header(response, "link") do
      nil -> nil
      link -> parse_next_link(link)
    end
  end

  defp parse_next_link(link_header) do
    case Regex.run(~r/<([^>]+)>;\s*rel="next"/, link_header) do
      [_, url] -> url
      _ -> nil
    end
  end

  # Clamped to 0..60s, matching
  # `PhoenixKitEcommerce.Shopify.StorefrontClient.retry_after_seconds/1`
  # (whose moduledoc carries the full rationale). Shopify's own
  # `Retry-After` is well-behaved, so this is not a live bug — but the
  # header still crosses the network, an unclamped negative makes
  # `Process.sleep/1` raise `FunctionClauseError` out of a function whose
  # spec promises `{:ok, _} | {:error, _}`, and an unclamped large one
  # sleeps for real up to @max_retries times per page, with no deadline on
  # this path to bound it. The two clients had no reason to differ.
  defp retry_after_seconds(response) do
    with value when is_binary(value) <- response_header(response, "retry-after"),
         {seconds, _} <- Integer.parse(value) do
      seconds |> max(0) |> min(@max_retry_after_seconds)
    else
      _ -> @default_retry_after_seconds
    end
  end

  defp response_header(%{headers: headers}, name) do
    headers
    |> Enum.find_value(fn {key, value} ->
      if String.downcase(to_string(key)) == name, do: value
    end)
    |> List.wrap()
    |> List.first()
  end
end
