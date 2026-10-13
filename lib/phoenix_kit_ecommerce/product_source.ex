defmodule PhoenixKitEcommerce.ProductSource do
  @moduledoc """
  Behaviour for the storefront's product/category read path.

  Two adapters implement it: `PhoenixKitEcommerce.ProductSource.Legacy`
  (today's `phoenix_kit_shop_products`/`phoenix_kit_shop_categories`
  tables, unchanged) and, once `phoenix_kit_catalogue` is present,
  `PhoenixKitEcommerce.ProductSource.Catalogue` (reads catalogue items
  and returns hand-built `%Product{}`/`%Category{}` view-structs so the
  facade, guards, `CartItem`, `Options` and `SeoHelpers` need no changes).

  `current/0` picks the adapter at runtime; `PhoenixKitEcommerce`'s
  public read functions delegate to it so callers never choose an
  adapter themselves.
  """

  require Logger

  alias PhoenixKitEcommerce.Category
  alias PhoenixKitEcommerce.Product

  @callback list_products(keyword()) :: [Product.t()]
  @callback list_products_with_count(keyword()) :: {[Product.t()], non_neg_integer()}
  @callback list_products_by_ids([String.t()]) :: [Product.t()]
  @callback get_product(String.t(), keyword()) :: Product.t() | nil
  @callback get_product_by_slug_localized(String.t(), String.t(), keyword()) ::
              {:ok, Product.t()} | {:error, :not_found}
  @callback get_product_by_any_slug(String.t(), keyword()) ::
              {:ok, Product.t(), String.t()} | {:error, :not_found}
  @callback list_categories(keyword()) :: [Category.t()]
  @callback get_category(String.t(), keyword()) :: Category.t() | nil
  @callback get_category_by_slug_localized(String.t(), String.t(), keyword()) ::
              {:ok, Category.t()} | {:error, :not_found}
  @callback get_category_by_any_slug(String.t(), keyword()) ::
              {:ok, Category.t(), String.t()} | {:error, :not_found}
  @callback product_counts_by_category() :: %{String.t() => non_neg_integer()}
  @callback aggregate_filter_values(keyword()) :: map()
  @callback get_price_range_for(keyword()) :: {Decimal.t() | nil, Decimal.t() | nil}
  @doc "Number of products, optionally narrowed by `:status` and `:product_type`."
  @callback count_products(keyword()) :: non_neg_integer()
  @doc "Number of categories."
  @callback count_categories() :: non_neg_integer()
  @doc """
  Option keys found on the source's own products, most used first — what
  the settings page offers as `metadata_option` storefront filters.
  """
  @callback discover_filterable_options() :: [%{key: String.t(), count: non_neg_integer()}]

  @legacy_module PhoenixKitEcommerce.ProductSource.Legacy
  @catalogue_module PhoenixKitEcommerce.ProductSource.Catalogue
  @memo_key {__MODULE__, :source_key}
  @default_memo_ms 1_000

  @doc """
  Returns the adapter module for the currently active product source.

  `Catalogue` only when `phoenix_kit_catalogue` is loaded AND the
  `shop_product_source` config key (`phoenix_kit_shop_config`) is
  `"catalogue"`; `Legacy` otherwise — including when the key is absent
  or the catalogue module isn't loaded, so a host without the optional
  `phoenix_kit_catalogue` dependency always gets `Legacy` regardless of
  the stored key.

  The key is a row of `phoenix_kit_shop_config`, written out-of-band (no
  function of this package writes it), so there is nothing to invalidate a
  shared cache on. It is memoized per PROCESS instead, for
  `:product_source_memo_ms` (application env, default #{@default_memo_ms} ms): one
  storefront mount asks several times within a few milliseconds and pays
  for one read, a long-lived LiveView sees a switch within that interval,
  and no node can hold a value another node has moved on from.

  A failed read never raises into the storefront: the process's last known
  value is reused, and with none known the answer is `Legacy`. Either way
  the read is not retried before the next interval. The `Code.
  ensure_loaded?/1` guard runs FIRST so a host without the optional
  `phoenix_kit_catalogue` dependency never pays for the read at all.
  """
  def current do
    if Code.ensure_loaded?(PhoenixKitCatalogue) and source_key() == "catalogue" do
      @catalogue_module
    else
      @legacy_module
    end
  end

  defp source_key do
    now = System.monotonic_time(:millisecond)
    ttl = Application.get_env(:phoenix_kit_ecommerce, :product_source_memo_ms, @default_memo_ms)

    case Process.get(@memo_key) do
      {value, read_at} when now - read_at < ttl -> value
      previous -> read_source_key(previous, now)
    end
  end

  defp read_source_key(previous, now) do
    value = PhoenixKitEcommerce.get_config("shop_product_source")
    Process.put(@memo_key, {value, now})
    value
  rescue
    error ->
      Logger.error("[Shop] reading shop_product_source failed: #{Exception.message(error)}")

      value =
        case previous do
          {value, _read_at} -> value
          _ -> nil
        end

      # Back off for one memo interval: without this every call during a
      # database problem repeats the failing read and logs again.
      Process.put(@memo_key, {value, now})
      value
  end

  # Max length for a user-supplied search term. Anything longer is
  # truncated: ILIKE against unindexed JSONB expansions is linear in both
  # pattern and row count, so an unbounded public `?search=` param would be
  # a cheap seq-scan amplifier.
  @max_search_term_length 100

  @doc false
  # Builds a safe `%term%` ILIKE pattern from raw user input: caps the
  # length, strips NUL bytes (Postgres rejects them in text params), and
  # escapes LIKE metacharacters so `%`, `_`, and `\` match literally —
  # a search for "100%" must not match every "100", and SKUs routinely
  # contain underscores. Shared by both adapters so the two can never
  # drift on what a search term is allowed to mean.
  @spec search_like_pattern(String.t()) :: String.t()
  def search_like_pattern(search) when is_binary(search) do
    escaped =
      search
      |> String.replace(<<0>>, "")
      |> String.slice(0, @max_search_term_length)
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

    "%#{escaped}%"
  end
end
