defmodule PhoenixKitEcommerce.Shopify.StorefrontClient do
  @moduledoc """
  Reads live product/price data from a store's public storefront JSON
  endpoint (`/products.json`) — no Admin API token required, because
  nothing is authenticated. This is the fallback price source: when the
  Admin API token configured for a store is missing or rejected, price
  sync keeps working through this keyless path instead of stalling until
  someone notices and rotates the token.

  Only sees products published to the Online Store sales channel, which is
  a narrower view than the Admin API gives (e.g. draft products are
  invisible here). That is an accepted trade-off for a fallback.

  The returned payload is deliberately trimmed to `"handle"` and
  `"variants"` alone, even though the endpoint also returns `"title"` and
  `"body_html"`. Two reasons:

    1. Published storefront text is not the same view of a product that
       the Admin API gives — it should never be treated as if it were.
    2. `PhoenixKitEcommerce.Shopify.ProductDiff.diff/4`'s `opts[:only]`
       exists precisely to stop an unfiltered comparison from reporting a
       source's *absent* fields as deletions. A fallback that quietly
       widened its authority to text fields would defeat that guard —
       silently overwriting real product copy with nothing, the moment
       this path activates.

  Being narrow is the feature. Do not widen the returned fields.

  Unlike the Admin API, storefront pagination has no natural terminator
  (no `Link: rel="next"` header to follow) — it is just `?page=N` until a
  page comes back empty. That makes two failure modes possible that
  `AdminClient` cannot have: a malformed page whose `"products"` value is
  not a list (rejected without touching the accumulator), and a server
  that never returns an empty page (bounded by `@max_pages`). Both return
  an error tuple instead of raising or looping.

  A real store fetched during development turned out to have thousands of
  published products across a dozen pages, and burst requests against it
  reliably trigger a 429 that (per the endpoint's own behavior) can take
  minutes to clear — so 429 handling here is not a hypothetical.
  """

  @page_limit 250
  @default_page_delay_ms 500
  @max_retries 5
  @default_retry_after_seconds 5
  @max_pages 200

  @doc """
  Fetches every priced product from `shop_domain`'s public storefront,
  paging until an empty page is returned.

  Each returned map has exactly two keys: `"handle"` and `"variants"`
  (each variant trimmed to `"price"` only). Products with no priced
  variants are omitted.

  A 429 response is retried up to 5 times, honoring the `Retry-After`
  header (defaulting to #{@default_retry_after_seconds}s when the header
  is absent), resuming the *same* page with the accumulator intact. The
  retry budget resets after each page that succeeds. Exhausting it
  returns `{:error, :rate_limited}`.

  Paging stops with `{:error, :too_many_pages}` after #{@max_pages} pages
  without an empty page — a store would need over #{@max_pages * @page_limit}
  products to hit this legitimately; in practice it means the endpoint
  is not honoring `?page=` at all.

  ## Options

    * `:req_options` — keyword list merged into `Req.new/1` (e.g. `plug:`
      to stub the transport in tests).
    * `:page_delay_ms` — pause between page requests, to stay gentle with
      the storefront's rate limit. Defaults to 500ms; tests pass `0`.
  """
  @spec fetch_products(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def fetch_products(shop_domain, opts \\ []) do
    # `retry: false` — this module owns 429 handling itself (the 429
    # clauses in `fetch_pages/5` below), because that requires resuming
    # the *same* page with the accumulator intact and respecting
    # `Retry-After`. Req's own `:transient` retry can't do either: it
    # knows nothing about pages or accumulators, and it sleeps in real
    # wall-clock time on its own schedule, which made a permanent error
    # take 30+ real seconds to surface in tests before this module had
    # its own 429 handling.
    req =
      [base_url: "https://#{shop_domain}", retry: false]
      |> Keyword.merge(Keyword.get(opts, :req_options, []))
      |> Req.new()

    page_delay_ms = Keyword.get(opts, :page_delay_ms, @default_page_delay_ms)
    fetch_pages(req, 1, [], page_delay_ms, @max_retries)
  end

  defp fetch_pages(_req, page, _acc, _page_delay_ms, _retries_left) when page > @max_pages do
    {:error, :too_many_pages}
  end

  defp fetch_pages(req, page, acc, page_delay_ms, retries_left) do
    case Req.get(req, url: "/products.json", params: [limit: @page_limit, page: page]) do
      {:ok, %{status: 200, body: %{"products" => products}}} when is_list(products) ->
        handle_page(req, page, acc, page_delay_ms, products)

      {:ok, %{status: 429} = response} when retries_left > 0 ->
        Process.sleep(:timer.seconds(retry_after_seconds(response)))
        fetch_pages(req, page, acc, page_delay_ms, retries_left - 1)

      {:ok, %{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %{status: 200, body: body}} ->
        {:error, {:unexpected_body, body}}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_page(_req, _page, acc, _page_delay_ms, []), do: {:ok, Enum.reverse(acc)}

  defp handle_page(req, page, acc, page_delay_ms, products) do
    acc = Enum.reduce(products, acc, &prepend_priced/2)
    if page_delay_ms > 0, do: Process.sleep(page_delay_ms)
    # Retry budget resets to @max_retries: it protects each page's own
    # request, not the fetch as a whole.
    fetch_pages(req, page + 1, acc, page_delay_ms, @max_retries)
  end

  defp retry_after_seconds(response) do
    with value when is_binary(value) <- response_header(response, "retry-after"),
         {seconds, _} <- Integer.parse(value) do
      seconds
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

  defp prepend_priced(product, acc) do
    case {product["handle"], priced_variants(product["variants"])} do
      {handle, [_ | _] = variants} when is_binary(handle) ->
        [%{"handle" => handle, "variants" => variants} | acc]

      _ ->
        acc
    end
  end

  # `is_binary/1` rather than the original host module's `reject(&is_nil/1)`
  # — deliberately stricter: a variant with a non-string price (a stray
  # number, `false`, anything else a malformed response might carry) is
  # dropped rather than passed through for a caller to mis-parse.
  defp priced_variants(variants) do
    variants
    |> List.wrap()
    |> Enum.filter(&is_binary(&1["price"]))
    |> Enum.map(&%{"price" => &1["price"]})
  end
end
