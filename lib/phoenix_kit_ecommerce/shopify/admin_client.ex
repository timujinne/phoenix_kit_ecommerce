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

  # Shopify's REST product payloads (`products.json`, `products/{id}.json`)
  # embed at most 100 variants whatever `limit` says — measured 2026-09-23:
  # a 256-variant product came back with its first 100. The variants
  # sub-resource pages normally (250 per page, `Link: rel="next"`), so any
  # product AT the cap is re-read from there. "Exactly 100" and "cut at
  # 100" look the same in the payload; the extra request is harmless.
  @embedded_variant_cap 100
  @variants_incomplete_key "_variants_incomplete"
  # Backfills run a few at a time: a full store fetch hit 68 capped
  # products (62 s one by one); Shopify's REST bucket absorbs a burst of
  # four, and a 429 is retried by `fetch_all/5` anyway.
  @backfill_concurrency 4

  @doc """
  Fetches every product from the Shopify store connected via
  `integration_uuid`, following `Link: rel="next"` pagination.

  Shopify's REST product payload embeds at most `#{@embedded_variant_cap}`
  variants per product regardless of the request's `limit` — any product
  whose embedded `"variants"` reaches that count is re-read in full from
  the `variants.json` sub-resource (see `complete_variants/3`). A product
  whose backfill fails is NOT dropped or failed as a whole call: it comes
  back with its truncated list and `"_variants_incomplete" => <reason>`
  (`variants_incomplete?/1`), so one bad product never stops the rest of
  the catalog from syncing.

  ## Options

    * `:req_options` — keyword list merged into `Req.new/1` (e.g. `plug:`
      to stub the transport in tests).
    * `:complete_variants` — which capped products to re-read: `true`
      (default, every one), `false` (none) or a one-argument function
      called with the product payload. A capped product that is NOT
      re-read comes back flagged `"_variants_incomplete" =>
      ":not_requested"`, so a caller that asked for less than everything
      can never mistake a truncated list for a complete one. Callers that
      only need some products' prices (the media sync, `Sync.check/2`)
      pass a predicate — a whole store holds far more capped products
      than the ones a sync compares or writes.
  """
  @spec fetch_products(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def fetch_products(integration_uuid, opts \\ []) do
    wanted = Keyword.get(opts, :complete_variants, true)

    with {:ok, {shop_domain, req}} <-
           resolve_client(integration_uuid, Keyword.get(opts, :req_options, [])),
         {:ok, products} <-
           fetch_all(req, initial_url(shop_domain), [], @max_retries, "products") do
      {:ok, complete_all(req, shop_domain, products, wanted)}
    end
  end

  @doc """
  Fetches a single product from the Shopify store connected via
  `integration_uuid`, given its Shopify `product_id` — a single,
  unpaginated `GET /admin/api/<version>/products/{id}.json` request. This
  is the point lookup a per-product panel needs instead of pulling the
  whole catalog through `fetch_products/2` to check one item.

  Reuses `resolve_client/2` (credential resolution/auth), the same
  `@product_fields` field set, and the same 429/401/403 handling as
  `fetch_products/2` — but is NOT built on top of `fetch_all/5`: that
  helper is shaped around a paginated LIST response (`Link: rel="next"`,
  an accumulator), while this endpoint returns exactly one `"product"`
  map and never paginates. The two diverge on the 404 case too — see
  below — so a shared status-handling core was not worth the added
  indirection for what is otherwise a short, linear match.

  A 404 here means the given `product_id` doesn't exist in this store
  and maps to `:not_found` — deliberately NOT `:shop_not_found`
  (`fetch_products/2`'s 404, meaning the *shop* domain itself doesn't
  resolve): the shop answered fine, it just has no such product.

  ## Options

    * `:req_options` — as `fetch_products/2`.
  """
  @spec fetch_product(String.t(), String.t() | integer(), keyword()) ::
          {:ok, map()} | {:error, :invalid_product_id | term()}
  def fetch_product(integration_uuid, product_id, opts \\ []) do
    with {:ok, product_id} <- numeric_id(product_id, :invalid_product_id),
         {:ok, {shop_domain, req}} <-
           resolve_client(integration_uuid, Keyword.get(opts, :req_options, [])),
         {:ok, product} <- fetch_one(req, product_url(shop_domain, product_id), @max_retries) do
      {:ok, complete_variants(req, shop_domain, product)}
    end
  end

  @doc """
  True when `fetch_products/2`/`fetch_product/3` could not read this
  product's full variant list (its `"variants"` is the capped first 100).
  Price-writing and price-comparing callers must skip such a product.
  """
  @spec variants_incomplete?(map()) :: boolean()
  def variants_incomplete?(product) when is_map(product),
    do: Map.has_key?(product, @variants_incomplete_key)

  def variants_incomplete?(_product), do: false

  # Shopify ids are numeric. An id is interpolated straight into the URL
  # path, so anything else — `"555/../shop"`, `"555?x=1"`, `""` — would
  # rewrite the request rather than name a product. A stored id is
  # trusted no more than a typed one; both go through this.
  defp numeric_id(id, _error) when is_integer(id) and id >= 0, do: {:ok, id}

  defp numeric_id(id, error) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, error}
    end
  end

  defp numeric_id(_id, error), do: {:error, error}

  @doc """
  Fetches the connected store's own `shop.json` — its name, domain, and
  crucially its `currency`. Per the per-domain-currency design (§7.5), a
  Shopify sync must be able to check the store's own currency against
  the base currency and refuse price updates on a mismatch rather than
  silently reimporting numbers that no longer mean what they used to.

  A single, unpaginated request — unlike `fetch_products/2` and its
  siblings, there is only ever one shop.

  ## Options

    * `:req_options` — as `fetch_products/2`.
  """
  @spec fetch_shop(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch_shop(integration_uuid, opts \\ []) do
    with {:ok, {shop_domain, req}} <-
           resolve_client(integration_uuid, Keyword.get(opts, :req_options, [])) do
      req
      |> Req.get(url: shop_url(shop_domain))
      |> parse_shop_response()
    end
  end

  @doc false
  # Split out of `fetch_shop/2` so the response-shape handling can be
  # covered directly (`AdminClientTest`) without a network call — the
  # error atoms mirror `fetch_all/5`'s own status-code handling above,
  # so the two clients agree on what a given Shopify status means.
  @spec parse_shop_response({:ok, Req.Response.t()} | {:error, term()}) ::
          {:ok, map()} | {:error, term()}
  def parse_shop_response({:ok, %{status: 200, body: %{"shop" => shop}}}), do: {:ok, shop}
  def parse_shop_response({:ok, %{status: 401}}), do: {:error, :unauthorized}
  def parse_shop_response({:ok, %{status: 403}}), do: {:error, :forbidden}
  def parse_shop_response({:ok, %{status: 404}}), do: {:error, :shop_not_found}
  def parse_shop_response({:ok, %{status: status}}), do: {:error, {:unexpected_status, status}}
  def parse_shop_response({:error, reason}), do: {:error, reason}

  defp shop_url(shop_domain), do: "https://#{shop_domain}/admin/api/#{@api_version}/shop.json"

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
          {:ok, [term()]} | {:error, :invalid_collection_id | term()}
  def fetch_collection_product_ids(collection_id, opts \\ []) do
    with {:ok, collection_id} <- numeric_id(collection_id, :invalid_collection_id),
         {:ok, integration_uuid} <- fetch_integration_uuid(opts),
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

  defp product_url(shop_domain, product_id) do
    query = URI.encode_query(%{"fields" => Enum.join(@product_fields, ",")})

    "https://#{shop_domain}/admin/api/#{@api_version}/products/#{product_id}.json?" <> query
  end

  # Which capped products to re-read is decided HERE, in the calling
  # process: `wanted` is the caller's (a predicate may close over something
  # big, like the media sync's whole item index), and a closure evaluated
  # inside a task has its environment copied into that task. Only the
  # products that need a request become tasks, each capturing just `req`
  # and `shop_domain`; the rest keep their place in the list untouched.
  defp complete_all(req, shop_domain, products, wanted) do
    planned = products |> Enum.map(&{plan(&1, wanted), &1}) |> Enum.with_index()

    fetched =
      planned
      |> Enum.flat_map(fn
        {{:fetch, product}, index} -> [{index, product}]
        _other -> []
      end)
      |> Task.async_stream(
        fn {index, product} -> {index, complete_variants(req, shop_domain, product)} end,
        max_concurrency: @backfill_concurrency,
        timeout: :infinity
      )
      |> Map.new(fn {:ok, indexed} -> indexed end)

    Enum.map(planned, fn
      {{:fetch, _product}, index} ->
        Map.fetch!(fetched, index)

      {{:mark, product}, _index} ->
        Map.put(product, @variants_incomplete_key, inspect(:not_requested))

      {{:keep, product}, _index} ->
        product
    end)
  end

  defp plan(product, wanted) do
    cond do
      not at_cap?(product) -> :keep
      wanted?(wanted, product) -> :fetch
      true -> :mark
    end
  end

  defp at_cap?(%{"variants" => variants}) when is_list(variants),
    do: length(variants) >= @embedded_variant_cap

  defp at_cap?(_product), do: false

  defp wanted?(true, _product), do: true
  defp wanted?(false, _product), do: false
  defp wanted?(fun, product) when is_function(fun, 1), do: fun.(product) == true

  # Re-reads a product's variants past the REST payload's cap (see
  # `@embedded_variant_cap` above). "Exactly at the cap" and "truncated at
  # the cap" are indistinguishable from the embedded list alone, so this
  # always re-reads at the cap — the extra request returns the same list
  # for a product that genuinely has exactly that many variants. A failed
  # backfill flags only this product (`@variants_incomplete_key`) and
  # keeps its truncated list rather than failing the whole
  # `fetch_products/2`/`fetch_product/3` call.
  #
  # `id` comes straight from Shopify's own JSON, same as a caller-supplied
  # `product_id` — `numeric_id/2` (the same guard `fetch_product/3` runs
  # on ITS id before it ever reaches a URL) must pass before it is
  # interpolated into `variants_url/2`; a payload whose "id" is not a
  # plain non-negative integer never should happen, but a stray id built
  # from unchecked Shopify JSON is exactly what that check exists to
  # catch. This IS treated as a failed backfill — flagged the same way a
  # failed `variants.json` request would be — even though no request is
  # ever made: a product still sitting at the embedded cap with an id
  # that can't be trusted must not read as complete to `ProductDiff`/the
  # variants writer, which only ever check the flag, never the id. A
  # payload with no "id" at all takes the same path (`numeric_id(nil, _)`
  # is an error), so no product at the cap ever passes through unflagged.
  defp complete_variants(req, shop_domain, %{"variants" => variants} = product)
       when is_list(variants) and length(variants) >= @embedded_variant_cap do
    case numeric_id(product["id"], :invalid_product_id) do
      {:ok, product_id} ->
        backfill_variants(req, shop_domain, product_id, product)

      {:error, reason} ->
        Logger.warning(
          "Shopify: could not read all variants of product #{inspect(product["id"])} " <>
            "(#{inspect(reason)}); its prices are left as they are until a later sync " <>
            "reads it in full"
        )

        Map.put(product, @variants_incomplete_key, inspect(reason))
    end
  end

  defp complete_variants(_req, _shop_domain, product), do: product

  defp backfill_variants(req, shop_domain, product_id, product) do
    case fetch_all(req, variants_url(shop_domain, product_id), [], @max_retries, "variants") do
      {:ok, all_variants} ->
        Map.put(product, "variants", all_variants)

      {:error, reason} ->
        # `fetch_all/5` reads a 404 as "the shop is gone"; on this
        # sub-resource the shop answered — the product is what vanished.
        reason = if reason == :shop_not_found, do: :product_not_found, else: reason

        Logger.warning(
          "Shopify: could not read all variants of product #{product_id} (#{inspect(reason)}); " <>
            "its prices are left as they are until a later sync reads it in full"
        )

        Map.put(product, @variants_incomplete_key, inspect(reason))
    end
  end

  defp variants_url(shop_domain, product_id) do
    query = URI.encode_query(%{"limit" => @page_limit})

    "https://#{shop_domain}/admin/api/#{@api_version}/products/#{product_id}/variants.json?" <>
      query
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

  # `fetch_product/3`'s own request loop — not built on `fetch_all/5`
  # (see that function's doc for why: no accumulator, no pagination, a
  # singular `"product"` map instead of a list, and a 404 that means
  # something different here). Shares `retry_after_seconds/1` and the
  # 429/401/403/unexpected-status handling verbatim.
  defp fetch_one(req, url, retries_left) do
    case Req.get(req, url: url) do
      {:ok, %{status: 200, body: %{"product" => product}}} ->
        {:ok, product}

      {:ok, %{status: 429} = response} when retries_left > 0 ->
        retry_after = retry_after_seconds(response)
        Process.sleep(:timer.seconds(retry_after))
        fetch_one(req, url, retries_left - 1)

      {:ok, %{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %{status: 403}} ->
        {:error, :forbidden}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

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
