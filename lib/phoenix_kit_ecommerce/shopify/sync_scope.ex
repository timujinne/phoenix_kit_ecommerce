defmodule PhoenixKitEcommerce.Shopify.SyncScope do
  @moduledoc """
  What "in scope" means for a Shopify → catalogue sync, when the connected
  store carries far more products than this shop wants in its catalogue
  (e.g. a store with 2750 Shopify products syncing only ~665 of them,
  selected by a `catalog-3d` tag).

  Persisted as one `phoenix_kit_shop_config` row under `"shopify_sync_scope"`
  (`PhoenixKitEcommerce.get_config/1`/`default_config_value/1`, mirroring
  `"shopify_collections_filter"`'s own key/default pattern), shape:

      %{"mode" => "all" | "filtered", "tags" => [String.t()],
        "product_types" => [String.t()]}

  `"all"` — the default, and what an operator who never configured this
  gets — means every Shopify product is in scope; `"filtered"` narrows to
  products carrying at least one of `"tags"` (when non-empty) AND whose
  `product_type` is in `"product_types"` (when non-empty). A `"filtered"`
  scope with both lists empty behaves exactly like `"all"` — see
  `in_scope?/2`.

  This module is deliberately generic (no hardcoded tag or product type):
  a different shop binds it to a different tag, a product type, or leaves
  it at `"all"` — see `PhoenixKitEcommerce.Workers.ShopifyMediaSyncWorker`
  and `PhoenixKitEcommerce.Shopify.Sync.check/2`, the two callers that
  consult it to decide what an UNMATCHED Shopify product means: in scope,
  it's missing from the catalogue and worth flagging; out of scope, its
  absence is by design and must never be reported as an error or offered
  for import. Neither caller ever scopes a product the catalogue ALREADY
  has — see each one's own moduledoc for why.
  """

  alias PhoenixKitEcommerce.ShopConfig
  alias PhoenixKitEcommerce.Shopify.ProductDiff

  @type mode :: :all | :filtered
  @type t :: %{mode: mode(), tags: [String.t()], product_types: [String.t()]}

  @config_key "shopify_sync_scope"

  @doc """
  Reads the current scope from `phoenix_kit_shop_config`, normalized.

  Never raises on a missing or malformed stored value — anything that
  isn't a recognizable `"filtered"` scope reads as `all()`, the same
  fail-open posture `CollectionSync`'s own filter default takes.
  """
  @spec get() :: t()
  def get do
    case PhoenixKitEcommerce.get_config(@config_key) |> normalize() do
      nil -> all()
      scope -> scope
    end
  end

  @doc """
  Validates and persists a scope, insert-or-update on the single
  `"shopify_sync_scope"` row (same pattern as
  `PhoenixKitEcommerce.update_storefront_filters/1`).

  Accepts the same shape `get/0` returns (string OR atom keys, string OR
  atom `mode`), normalizes it (trims tags/product types, drops blanks,
  dedupes, downcases nothing — Shopify tags/product types are compared
  case-insensitively at match time in `in_scope?/2`, not folded here so
  the stored value still reads back as the operator typed it), and
  refuses anything whose `mode` isn't `"all"`/`"filtered"` (or `:all`/
  `:filtered`) with `{:error, :invalid_mode}`.
  """
  @spec put(map()) :: {:ok, t()} | {:error, :invalid_mode | Ecto.Changeset.t()}
  def put(attrs) when is_map(attrs) do
    case normalize(attrs) do
      nil -> {:error, :invalid_mode}
      scope -> persist(scope)
    end
  end

  defp persist(scope) do
    value = %{"value" => stringify(scope)}

    result =
      case repo().get(ShopConfig, @config_key) do
        nil ->
          %ShopConfig{}
          |> ShopConfig.changeset(%{key: @config_key, value: value})
          |> repo().insert()

        config ->
          config
          |> ShopConfig.changeset(%{value: value})
          |> repo().update()
      end

    with {:ok, _config} <- result, do: {:ok, scope}
  end

  defp stringify(%{mode: mode, tags: tags, product_types: product_types}) do
    %{"mode" => Atom.to_string(mode), "tags" => tags, "product_types" => product_types}
  end

  @doc ~S{Whether `scope` is a `"filtered"` scope (as opposed to `"all"`).}
  @spec filtered?(t()) :: boolean()
  def filtered?(%{mode: :filtered}), do: true
  def filtered?(_scope), do: false

  @doc """
  Whether a Shopify product (raw Admin API map) falls within `scope`.

  `mode: :all` (or a `:filtered` scope with both lists empty — see the
  moduledoc) always returns `true`. Otherwise: `true` when (`tags` is
  empty OR the product carries at least one of them) AND
  (`product_types` is empty OR the product's `"product_type"` is one of
  them) — both sides must pass, so a scope configured with only tags
  ignores product type entirely, and vice versa.

  Shopify's `"tags"` field is a single comma-separated string on the
  Admin API (occasionally already a list, e.g. from a test fixture or a
  future API version); either shape is accepted. Comparison is
  case-insensitive and trims whitespace on both sides, matching how an
  operator is likely to have typed the scope's own tags.
  """
  @spec in_scope?(map(), t()) :: boolean()
  def in_scope?(_product, %{mode: :all}), do: true

  def in_scope?(_product, %{mode: :filtered, tags: [], product_types: []}), do: true

  def in_scope?(product, %{mode: :filtered, tags: tags, product_types: product_types}) do
    tags_match?(product, tags) and product_type_match?(product, product_types)
  end

  defp tags_match?(_product, []), do: true

  defp tags_match?(product, tags) do
    product_tags = product_tags(product) |> MapSet.new(&downcase_trim/1)
    wanted = MapSet.new(tags, &downcase_trim/1)
    not MapSet.disjoint?(product_tags, wanted)
  end

  defp product_type_match?(_product, []), do: true

  defp product_type_match?(product, product_types) do
    case product["product_type"] do
      type when is_binary(type) ->
        normalized = downcase_trim(type)
        Enum.any?(product_types, &(downcase_trim(&1) == normalized))

      _ ->
        false
    end
  end

  # Reuses `ProductDiff.parse_tags/1` — the exact same comma-split/trim/
  # reject-blank rule `ProductDiff.diff/4` already applies to this same
  # Shopify `"tags"` field, rather than a second, independent parser
  # that could silently drift out of sync with it.
  defp product_tags(%{"tags" => tags}), do: ProductDiff.parse_tags(tags)
  defp product_tags(_product), do: []

  defp downcase_trim(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp downcase_trim(nil), do: ""
  defp downcase_trim(value), do: value |> to_string() |> downcase_trim()

  @doc """
  Splits `products` into `{in_scope, out_of_scope}` per `in_scope?/2`,
  preserving each side's relative order.
  """
  @spec partition([map()], t()) :: {[map()], [map()]}
  def partition(products, scope), do: partition(products, scope, & &1)

  @doc """
  Same as `partition/2`, but for a list of ITEMS that each wrap a raw
  Shopify product rather than being one — `extract_fun` pulls the
  product map out of each item for the `in_scope?/2` check, while both
  output lists still carry the original items, not the extracted
  products. `Shopify.Sync.check/2`'s own `:new_products` uses this to
  partition `ProductDiff.Change` structs by their `.shopify_product`
  without a second, independent `Enum.split_with/2`.
  """
  @spec partition([term()], t(), (term() -> map())) :: {[term()], [term()]}
  def partition(items, scope, extract_fun)
      when is_list(items) and is_function(extract_fun, 1) do
    Enum.split_with(items, &in_scope?(extract_fun.(&1), scope))
  end

  @doc "The scope that means \"everything\" — `get/0`'s default."
  @spec all() :: t()
  def all, do: %{mode: :all, tags: [], product_types: []}

  # ============================================================
  # Normalization — tolerant of missing keys, atom/string keys,
  # atom/string mode, non-list tags/product_types, and garbage entirely.
  # ============================================================

  defp normalize(%{} = attrs) do
    case fetch(attrs, :mode) |> normalize_mode() do
      nil -> nil
      :all -> all()
      :filtered -> normalize_filtered(attrs)
    end
  end

  defp normalize(_attrs), do: all()

  defp normalize_filtered(attrs) do
    %{
      mode: :filtered,
      tags: fetch(attrs, :tags) |> normalize_list(),
      product_types: fetch(attrs, :product_types) |> normalize_list()
    }
  end

  defp fetch(attrs, key) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))
  end

  defp normalize_mode(nil), do: :all
  defp normalize_mode(:all), do: :all
  defp normalize_mode(:filtered), do: :filtered
  defp normalize_mode("all"), do: :all
  defp normalize_mode("filtered"), do: :filtered
  defp normalize_mode(_other), do: nil

  # A "filtered" scope's `tags`/`product_types` may arrive from a
  # `<.form>` submit as a single comma-separated string (this module's
  # own `SyncScope.put/1` caller on the sync page) or already as a list
  # (a programmatic caller, or `get/0`'s own stored shape) — both are
  # accepted here rather than requiring the LiveView to pre-split.
  defp normalize_list(nil), do: []

  defp normalize_list(value) when is_binary(value) do
    value |> String.split(",") |> normalize_list()
  end

  # Non-string entries are dropped rather than `to_string/1`-ed: a map or a
  # tuple (a tampered form submit, a hand-edited config row) raises
  # `Protocol.UndefinedError` there, and `get/0` runs on every sync-page
  # mount, `Sync.check/2` and media-sync run — one bad entry would take
  # all three down instead of reading as "not a tag".
  defp normalize_list(value) when is_list(value) do
    value
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_list(_other), do: []

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
