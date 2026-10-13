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

  The `Retry-After` header this reads to decide how long to sleep on a
  429 comes from the *unauthenticated public endpoint itself* — the one
  input in this whole module that isn't just "a store operator's own
  data read back." `retry_after_seconds/1` clamps it to
  `0..60` seconds before it ever reaches
  `Process.sleep/1`: unclamped, a negative value crashes `Process.sleep/1`
  (which only accepts a non-negative integer or `:infinity`) instead of
  returning the promised error tuple, and a huge one sleeps for real.

  That per-sleep clamp bounds any ONE sleep, but not the fetch as a
  whole: `@max_pages` pages, each retried up to `@max_retries` times at
  up to `@max_retry_after_seconds`, is `200 * 5 * 60` seconds — over 16
  hours — of a `start_async` task sleeping with the spinner up, with no
  escape but a page reload. `fetch_products/2`'s `:deadline_ms` option
  (see its own doc) bounds the aggregate: a wall-clock deadline computed
  once via `System.monotonic_time/1` and threaded through every
  recursive `fetch_pages/6` call, checked before each page request (and
  therefore before whatever sleep that iteration might otherwise start).
  """

  alias PhoenixKitEcommerce.Services.ImageDownloader
  alias PhoenixKitEcommerce.Shopify.ShopDomain

  @page_limit 250
  @default_page_delay_ms 500
  @max_retries 5
  @default_retry_after_seconds 5
  @max_retry_after_seconds 60
  @max_pages 200
  @max_redirects 3
  @redirect_statuses [301, 302, 303, 307, 308]
  @default_deadline_ms :timer.minutes(2)

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

  The whole fetch also carries a wall-clock deadline, independent of the
  per-page/per-retry budgets above (see the moduledoc): once it passes,
  the NEXT page request (or retry) is skipped and `{:error,
  :deadline_exceeded}` is returned instead — an in-flight sleep is not
  interrupted, but no new one is started, so the fetch can never run
  past `deadline_ms` by more than a single already-clamped sleep.

  ## Options

    * `:req_options` — keyword list merged into `Req.new/1` (e.g. `plug:`
      to stub the transport in tests).
    * `:address_check` — `(host -> {:ok, pin} | :error)`, asked for every
      redirect hop that leaves the shop host. Defaults to
      `ImageDownloader.public_address/1`; tests pass a stub so no DNS is
      queried.
    * `:page_delay_ms` — pause between page requests, to stay gentle with
      the storefront's rate limit. Defaults to 500ms; tests pass `0`.
    * `:deadline_ms` — the wall-clock budget for the whole fetch (paging
      and retries together), starting from the moment this function is
      called. Defaults to #{@default_deadline_ms}ms (2 minutes).
  """
  @spec fetch_products(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def fetch_products(shop_domain, opts \\ []) do
    with {:ok, host} <- ShopDomain.validate(shop_domain) do
      do_fetch_products(host, opts)
    end
  end

  # Redirects are followed here, unlike `AdminClient`: this request carries
  # no credential, and a `*.myshopify.com` storefront answers with a redirect
  # to the store's primary domain whenever it has one. They are followed by
  # `get/3`, not by Req, because a `Location` header is the remote side's
  # word: every hop must be https on the default port and, off the validated
  # shop host, resolve only to public addresses — and the connection is
  # pinned to the address that was checked. A response that is not a product
  # list is reported by shape only.
  defp do_fetch_products(shop_domain, opts) do
    # `retry: false` — this module owns 429 handling itself (the 429
    # clauses in `fetch_pages/6` below), because that requires resuming
    # the *same* page with the accumulator intact and respecting
    # `Retry-After`. Req's own `:transient` retry can't do either: it
    # knows nothing about pages or accumulators, and it sleeps in real
    # wall-clock time on its own schedule, which made a permanent error
    # take 30+ real seconds to surface in tests before this module had
    # its own 429 handling.
    req =
      [base_url: "https://#{shop_domain}", retry: false, redirect: false]
      |> Keyword.merge(Keyword.get(opts, :req_options, []))
      |> Req.new()
      |> Req.Request.put_private(:shop_host, shop_domain)
      |> Req.Request.put_private(
        :address_check,
        Keyword.get(opts, :address_check, &ImageDownloader.public_address/1)
      )

    page_delay_ms = Keyword.get(opts, :page_delay_ms, @default_page_delay_ms)
    deadline_ms = Keyword.get(opts, :deadline_ms, @default_deadline_ms)
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    fetch_pages(req, 1, [], page_delay_ms, @max_retries, deadline)
  end

  defp fetch_pages(_req, page, _acc, _page_delay_ms, _retries_left, _deadline)
       when page > @max_pages do
    {:error, :too_many_pages}
  end

  defp fetch_pages(req, page, acc, page_delay_ms, retries_left, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :deadline_exceeded}
    else
      do_fetch_page(req, page, acc, page_delay_ms, retries_left, deadline)
    end
  end

  defp do_fetch_page(req, page, acc, page_delay_ms, retries_left, deadline) do
    case get(req, "/products.json", limit: @page_limit, page: page) do
      {:ok, %{status: 200, body: %{"products" => products}}} when is_list(products) ->
        handle_page(req, page, acc, page_delay_ms, products, deadline)

      {:ok, %{status: 429} = response} when retries_left > 0 ->
        Process.sleep(:timer.seconds(retry_after_seconds(response)))
        fetch_pages(req, page, acc, page_delay_ms, retries_left - 1, deadline)

      {:ok, %{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %{status: 200, body: body}} ->
        {:error, {:unexpected_body, body_summary(body)}}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # One GET, with the redirect chain walked here (see `do_fetch_products/2`).
  defp get(req, path, params) do
    current = "https://" <> Req.Request.get_private(req, :shop_host) <> path
    result = Req.get(req, url: path, params: params)
    follow_redirects(result, req, current, @max_redirects)
  end

  defp follow_redirects({:ok, %{status: status} = response}, req, current, hops_left)
       when status in @redirect_statuses do
    with :ok <- redirect_budget(hops_left),
         {:ok, url, pin_opts} <- redirect_target(req, response, current) do
      req
      |> Req.get([url: url] ++ pin_opts)
      |> follow_redirects(req, url, hops_left - 1)
    end
  end

  defp follow_redirects(result, _req, _current, _hops_left), do: result

  defp redirect_budget(hops_left) when hops_left > 0, do: :ok
  defp redirect_budget(_hops_left), do: {:error, :too_many_redirects}

  defp redirect_target(req, response, current) do
    with [location | _] <- Req.Response.get_header(response, "location"),
         %URI{scheme: "https", host: host, port: port, userinfo: nil} = uri
         when is_binary(host) and host != "" and port in [nil, 443] <-
           safe_merge(current, location),
         {:ok, pin} <- redirect_pin(req, host) do
      {url, pin_opts} = ImageDownloader.pinned_request(URI.to_string(uri), pin)
      {:ok, url, pin_opts}
    else
      {:error, _reason} = error -> error
      _other -> {:error, {:redirect_refused, :unsafe_target}}
    end
  end

  # The validated shop host needs no check or pin (`ShopDomain` bounded it to
  # `*.myshopify.com`); any other host is a destination the remote side chose.
  defp redirect_pin(req, host) do
    if host == Req.Request.get_private(req, :shop_host) do
      {:ok, nil}
    else
      case Req.Request.get_private(req, :address_check).(host) do
        {:ok, pin} -> {:ok, pin}
        :error -> {:error, {:redirect_refused, :private_address}}
      end
    end
  end

  defp safe_merge(current, location) do
    URI.merge(URI.parse(current), location)
  rescue
    _ -> :error
  end

  # What the error carries is shown to the operator, so it names the shape of
  # the answer and never its content: a redirect to another host can make the
  # body anything at all.
  defp body_summary(body) when is_binary(body), do: {:text, byte_size(body)}
  defp body_summary(body) when is_map(body), do: {:object, map_size(body)}
  defp body_summary(body) when is_list(body), do: {:list, length(body)}
  defp body_summary(_body), do: :other

  defp handle_page(_req, _page, acc, _page_delay_ms, [], _deadline), do: {:ok, Enum.reverse(acc)}

  defp handle_page(req, page, acc, page_delay_ms, products, deadline) do
    acc = Enum.reduce(products, acc, &prepend_priced/2)
    if page_delay_ms > 0, do: Process.sleep(page_delay_ms)
    # Retry budget resets to @max_retries: it protects each page's own
    # request, not the fetch as a whole (the deadline does that).
    fetch_pages(req, page + 1, acc, page_delay_ms, @max_retries, deadline)
  end

  @doc false
  # Public (not documented as API) so the clamp itself can be pinned
  # directly with a synthetic response — the two failure modes it guards
  # (`Process.sleep(-1)` raising `FunctionClauseError` out of a function
  # whose own spec promises `{:ok, _} | {:error, _}`; an unbounded real
  # sleep on a huge header, times up to `@max_retries` per page, with no
  # timeout on the caller's `start_async` task) both come from the ONE
  # input in this module that's genuinely adversarial — an unauthenticated
  # public endpoint's response header — so this is worth being certain
  # about independent of any one fetch scenario reaching it.
  @spec retry_after_seconds(map()) :: non_neg_integer()
  def retry_after_seconds(response) do
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
