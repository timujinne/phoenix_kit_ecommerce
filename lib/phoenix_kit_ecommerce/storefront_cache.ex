defmodule PhoenixKitEcommerce.StorefrontCache do
  @moduledoc """
  A node-wide, 60-second cache for the viewer-independent parts of the
  storefront pages: the active category list and the filter sidebar's
  data (enabled filters plus facet aggregates).

  Both depend only on the product source, the language and the page scope,
  never on who is looking, yet every `/shop` mount (two per real visitor:
  the HTTP render and the WebSocket mount) recomputed them. The facet
  aggregates are the expensive part - each one is a sequential scan of the
  catalogue items table.

  Backed by `PhoenixKit.Cache`; the process is contributed to the host's
  supervision tree by `PhoenixKitEcommerce.children/0`.

  ## Fail open

  `fetch/2` and `clear/0` never raise because of the cache. A host that
  did not start module children, a test, or a crashed cache process all
  degrade to "compute directly": the storefront is slower, never wrong.

  ## Bounded keys

  A key may carry the page language, and the language comes from the URL
  (`?locale=`, `/xx/shop`). `fetch_in_language/3` therefore caches only
  languages the shop actually has enabled; any other value is computed
  directly and never stored, so a client cannot mint cache entries by
  inventing locales. `max_size` is the backstop for the legitimate key
  space (categories x languages x options).

  ## Freshness

  The TTL is the safety net. On top of it this package clears the cache
  itself when it writes something the cached values depend on: the
  storefront filter settings (`PhoenixKitEcommerce.update_storefront_filters/1`)
  and the legacy-source product and category writes that announce
  themselves through `PhoenixKitEcommerce.Events` (the single and bulk
  status writes; see the note there for what does not). The clear is
  node-local: another node of a cluster serves its entries until they
  expire.

  Everything else is visible within the TTL only:

    * edits made on the catalogue side (`phoenix_kit_catalogue`), and this
      package's own catalogue-mode writers (`Catalogue.Writer`, the Shopify
      sync) - none of them pass through `Events`;
    * the legacy bulk category change and bulk product delete;
    * the catalogue the shop reads (`shop_catalogue`), which is not part of
      any key: it is written out-of-band, not through a supported runtime
      flow, so switching it needs a `clear/0` (or a minute);
    * a transient database error: the facet queries turn errors into empty
      results, and the cache cannot tell those from a legitimately empty
      shop, so the sidebar can show no facets for up to the TTL after one
      failed query (the page itself stays up).
  """

  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKitEcommerce.Translations

  @cache_name :ecommerce_storefront
  @ttl :timer.seconds(60)

  # Backstop only - the languages are already clamped (`fetch_in_language/3`).
  # Legitimate keys: the category list in a few option shapes, plus filter
  # data per (language x category scope), i.e. a few hundred on a large
  # multilingual shop.
  @max_size 2_000

  @doc """
  Child specs for `PhoenixKitEcommerce.children/0`.
  """
  def children do
    [
      Supervisor.child_spec(
        {PhoenixKit.Cache, name: @cache_name, ttl: @ttl, max_size: @max_size},
        id: :ecommerce_storefront_cache
      )
    ]
  end

  @doc """
  Returns the cached value for `key`, or runs `fun`, caches its result and
  returns it.

  `key` must carry everything the result depends on (see the callers for
  the shape); nothing viewer-specific may be cached. Runs `fun` directly
  when the cache is not running.
  """
  def fetch(key, fun) when is_function(fun, 0) do
    if running?() do
      PhoenixKit.Cache.remember(@cache_name, key, fun)
    else
      fun.()
    end
  end

  @doc """
  `fetch/2` for a key that carries `language`.

  The language is client-supplied, so it is cached only when it is `nil` or
  one the shop has enabled (the codes, or the default dialect of their base
  - `"en"` resolves to `"en-US"` whichever of the two is configured). Any
  other value is computed directly, as it was before the cache existed, and
  nothing is stored under it.
  """
  def fetch_in_language(language, key, fun) when is_function(fun, 0) do
    if cacheable_language?(language) do
      fetch(key, fun)
    else
      fun.()
    end
  end

  @doc """
  Drops every cached entry. A no-op when the cache is not running.
  """
  def clear do
    if running?(), do: PhoenixKit.Cache.clear(@cache_name)
    :ok
  end

  defp cacheable_language?(nil), do: true

  defp cacheable_language?(language) when is_binary(language) do
    enabled = Translations.enabled_languages()
    language in enabled or language in Enum.map(enabled, &default_dialect/1)
  end

  defp cacheable_language?(_language), do: false

  defp default_dialect(code) do
    code |> DialectMapper.extract_base() |> DialectMapper.resolve_dialect()
  end

  # Checked up front rather than left to `PhoenixKit.Cache`'s own
  # "unavailable" handling, which logs a warning per call - on a host
  # without the cache that would be two log lines per /shop mount.
  # `Registry.lookup/2` raises when the registry itself is not running.
  defp running? do
    PhoenixKit.Cache.Registry.cache_exists?(@cache_name)
  rescue
    ArgumentError -> false
  end
end
