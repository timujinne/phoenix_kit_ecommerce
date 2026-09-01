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
  """

  @page_limit 250
  @default_page_delay_ms 500

  @doc """
  Fetches every priced product from `shop_domain`'s public storefront,
  paging until an empty page is returned.

  Each returned map has exactly two keys: `"handle"` and `"variants"`
  (variants trimmed to `"price"` only). Products with no priced variants
  are omitted.

  ## Options

    * `:req_options` — keyword list merged into `Req.new/1` (e.g. `plug:`
      to stub the transport in tests).
    * `:page_delay_ms` — pause between page requests, to stay gentle with
      the storefront's rate limit. Defaults to 500ms; tests pass `0`.
  """
  @spec fetch_products(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def fetch_products(shop_domain, opts \\ []) do
    # `retry: false` — Req's own `:transient` retry would otherwise swallow
    # a 429/5xx behind several real-time exponential-backoff sleeps before
    # this function ever saw it, which both makes a permanent failure take
    # tens of seconds to surface and makes it unrelated to `page_delay_ms`
    # in tests. `AdminClient` (the sibling module) makes the same call.
    req =
      [base_url: "https://#{shop_domain}", retry: false]
      |> Keyword.merge(Keyword.get(opts, :req_options, []))
      |> Req.new()

    page_delay_ms = Keyword.get(opts, :page_delay_ms, @default_page_delay_ms)
    fetch_pages(req, 1, [], page_delay_ms)
  end

  defp fetch_pages(req, page, acc, page_delay_ms) do
    case Req.get(req, url: "/products.json", params: [limit: @page_limit, page: page]) do
      {:ok, %{status: 200, body: %{"products" => []}}} ->
        {:ok, Enum.reverse(acc)}

      {:ok, %{status: 200, body: %{"products" => products}}} ->
        acc = Enum.reduce(products, acc, &prepend_priced/2)
        if page_delay_ms > 0, do: Process.sleep(page_delay_ms)
        fetch_pages(req, page + 1, acc, page_delay_ms)

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp prepend_priced(product, acc) do
    case {product["handle"], priced_variants(product["variants"])} do
      {handle, [_ | _] = variants} when is_binary(handle) ->
        [%{"handle" => handle, "variants" => variants} | acc]

      _ ->
        acc
    end
  end

  defp priced_variants(variants) do
    variants
    |> List.wrap()
    |> Enum.filter(&is_binary(&1["price"]))
    |> Enum.map(&%{"price" => &1["price"]})
  end
end
