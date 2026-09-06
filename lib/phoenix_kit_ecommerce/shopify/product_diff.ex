defmodule PhoenixKitEcommerce.Shopify.ProductDiff do
  @moduledoc """
  Compares local products against Shopify Admin API product data.

  Matching is by handle: for a catalogue-backed view-struct
  (`metadata["_shopify"]["handle"]`, written by
  `ProductSource.Catalogue.View`) that handle is used directly; for a
  legacy product (no such metadata) matching falls back to
  `product.slug[base_locale] == shopify_product["handle"]`, unchanged.
  A Shopify product with no local match is skipped by `diff/4` — this
  module never creates products from there (product creation stays the
  CSV importer's job under the legacy source; under the catalogue
  source, `new_product_changes/3` below surfaces those same unmatched
  handles as create-`Change`s for `Shopify.Sync` instead).

  Compared fields: `title`, `body_html`, `description`, `vendor`, `tags`,
  `status`, `price`, `compare_at_price`. `title`/`body_html`/`description`
  are localized fields; only the base locale is read/compared here
  (writing them back is
  `Shopify.Sync.apply_change/2`'s job). `diff/4`'s `opts[:only]` narrows this
  set to a chosen list of fields — needed because some Shopify data sources
  (e.g. a public storefront fallback) only ever carry a subset of fields,
  such as price alone. Comparing an absent field against a present local
  value would otherwise be reported as a deletion, and applying such a
  change would erase real data.

  `diff/4` (and its `diff/2`/`diff/3` arities) is pure — no network or
  database access — so it can be tested directly with in-memory product
  structs and Shopify API response maps.
  """

  alias PhoenixKitEcommerce.HtmlText
  alias PhoenixKitEcommerce.Product
  alias PhoenixKitEcommerce.Translations

  @extreme_ratio Decimal.new("3")
  @comparable_fields [
    :title,
    :body_html,
    :description,
    :vendor,
    :tags,
    :status,
    :price,
    :compare_at_price
  ]

  defmodule Change do
    @moduledoc """
    One local product's field-by-field diff against its matched Shopify
    product. `changes` only contains fields that actually differ, keyed by
    field atom, each holding `%{current:, incoming:}`. `price_extreme?` is
    true only when `:price` is in `changes` and the current/incoming ratio
    exceeds 3x.

    `base_locale` is the locale `diff/4` matched/compared this product
    against — carried on the struct (not re-derived later) so
    `Shopify.Sync.apply_change/2` writes localized fields back into the
    SAME locale they were diffed against. Reading a fresh default at
    apply time would silently apply a change diffed in one locale into
    another.

    `create?`/`shopify_product` are only set on a create-`Change` (see
    `ProductDiff.new_product_changes/3`, catalogue source only):
    `product_uuid` is `nil` (there is no local product yet), `changes` is
    always `%{}`, and `shopify_product` carries the raw Shopify payload
    `Shopify.Sync.apply_change/2` hands to
    `PhoenixKitEcommerce.Catalogue.Writer.create_from_shopify/2`. A
    regular diff-`Change` never sets `shopify_product`.

    `product_id` is the Shopify product's own `"id"` — carried on every
    `Change` (regular or create), independent of `changes`/`opts[:only]`:
    it isn't diffed against a current value, just carried through, so
    `Shopify.Sync.apply_change/2` can backfill `data["ecommerce"]
    ["shopify"]["product_id"]` on a matched item even when the caller
    only asked to apply a subset of the comparable fields. This does NOT
    reach every local product on its own — `diff/4` still only returns a
    `Change` when some comparable field actually differs (see its own
    moduledoc); `product_id` just rides along on whichever `Change`s
    already exist.
    """
    @enforce_keys [:product_uuid, :handle, :title, :base_locale]
    defstruct [
      :product_uuid,
      :handle,
      :title,
      :base_locale,
      :shopify_product,
      :product_id,
      changes: %{},
      price_extreme?: false,
      create?: false
    ]

    @type t :: %__MODULE__{
            product_uuid: String.t() | nil,
            handle: String.t(),
            title: String.t() | nil,
            base_locale: String.t(),
            changes: %{atom() => %{current: term(), incoming: term()}},
            price_extreme?: boolean(),
            create?: boolean(),
            shopify_product: map() | nil,
            product_id: term() | nil
          }
  end

  @doc """
  The full set of fields `diff/4` can compare — its `opts[:only]` default,
  and what a caller (e.g. `PhoenixKitEcommerce.Shopify.Source`) should pass
  for a source that carries every field, such as the Admin API. There is no
  `:all` sentinel accepted by `opts[:only]` — passing this list explicitly
  is the correct way to ask for "everything".
  """
  @spec comparable_fields() :: [atom()]
  def comparable_fields, do: @comparable_fields

  @doc """
  Matches `shopify_products` to `local_products` by handle and returns one
  `Change` per match that has at least one real difference. Shopify
  products without a matching local product are skipped.

  `base_locale` defaults to `Translations.default_language/0`, which reads
  through `PhoenixKit.Settings` — pass it explicitly to keep a call free of
  database access (e.g. in tests).

  `opts[:only]` restricts the comparison to the given list of field atoms
  (a subset of #{inspect(@comparable_fields)}), defaulting to all of them.
  Pass it when the incoming Shopify data only ever carries some fields —
  e.g. a public-storefront fallback source that reads price alone — so the
  fields it doesn't carry aren't reported (and later applied) as deletions.
  An unknown key in `opts` raises, so a typo (e.g. `onlyy:`) can't silently
  fall back to comparing every field. Every element of `opts[:only]` itself
  is validated against #{inspect(@comparable_fields)} too — a typo'd field
  atom there (`only: [:titel]`) fails the *opposite* way a missing `:only`
  does: instead of comparing too much, it would compare nothing and report
  a catalog "in sync" that was never actually checked, which is the worse
  failure mode for a sync tool. `only: []` (compare nothing, deliberately)
  is not an error — every element of an empty list is vacuously valid.

  `base_locale` must be a string. This guards against the easy mistake of
  passing `opts` as the third argument and dropping `base_locale` entirely
  (`diff(local, shopify, only: [:price])`) — without the guard that silently
  matches nothing and returns `[]`, instead of raising.
  """
  @spec diff([Product.t()], [map()], String.t()) :: [Change.t()]
  @spec diff([Product.t()], [map()], String.t(), keyword()) :: [Change.t()]
  def diff(
        local_products,
        shopify_products,
        base_locale \\ Translations.default_language(),
        opts \\ []
      )
      when is_binary(base_locale) do
    opts = Keyword.validate!(opts, only: @comparable_fields)
    only = Keyword.fetch!(opts, :only)
    validate_only!(only)
    index = index_by_handle(local_products, base_locale)

    shopify_products
    |> Enum.map(&{Map.get(index, &1["handle"]), &1})
    |> Enum.reject(fn {product, _shopify_product} -> is_nil(product) end)
    |> Enum.map(fn {product, shopify_product} ->
      build_change(product, shopify_product, base_locale, only)
    end)
    |> Enum.reject(fn change -> change.changes == %{} end)
  end

  @doc """
  Counts distinct `local_products` matched by handle to a
  `shopify_products` entry — the same matching rule `diff/4` uses
  (`product.slug[base_locale] == shopify_product["handle"]`), but
  independent of whether the match has any actual field difference.

  This is "how much of the Shopify catalog a sync can even see": every
  local product with no matching Shopify handle is invisible to `diff/4`
  regardless of `:only` (see this module's moduledoc — a Shopify product
  with no local match is skipped, and the reverse is equally true: a
  local product with no Shopify-side handle never reaches `build_change/4`
  at all). Reuses `diff/4`'s own `index_by_handle/2`, so this can never
  drift from what `diff/4` actually matches.

  `base_locale` defaults to `Translations.default_language/0`, same as
  `diff/4` — pass it explicitly to keep a call free of that default's
  database access.
  """
  @spec matched_count([Product.t()], [map()]) :: non_neg_integer()
  @spec matched_count([Product.t()], [map()], String.t()) :: non_neg_integer()
  def matched_count(
        local_products,
        shopify_products,
        base_locale \\ Translations.default_language()
      )
      when is_binary(base_locale) do
    index = index_by_handle(local_products, base_locale)

    shopify_products
    |> Enum.map(&Map.get(index, &1["handle"]))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.uuid)
    |> length()
  end

  @doc """
  Shopify products with no matching local product, as create-`Change`s
  (`create?: true`, `product_uuid: nil`, `shopify_product: <raw payload>`,
  `changes: %{}`) — the mirror image of `diff/4`'s own skip rule (see this
  module's moduledoc). Meant for the catalogue source only, where a new
  Shopify handle becomes a new catalogue item via
  `PhoenixKitEcommerce.Catalogue.Writer.create_from_shopify/2`; the legacy
  source has no create path here at all (product creation stays the CSV
  importer's job there), so a caller must not call this under the legacy
  source.

  `base_locale` defaults to `Translations.default_language/0`, same as
  `diff/4` — pass it explicitly to keep a call free of that default's
  database access.
  """
  @spec new_product_changes([Product.t()], [map()]) :: [Change.t()]
  @spec new_product_changes([Product.t()], [map()], String.t()) :: [Change.t()]
  def new_product_changes(
        local_products,
        shopify_products,
        base_locale \\ Translations.default_language()
      )
      when is_binary(base_locale) do
    index = index_by_handle(local_products, base_locale)

    shopify_products
    |> Enum.filter(fn shopify_product ->
      handle = shopify_product["handle"]
      is_binary(handle) and handle != "" and not Map.has_key?(index, handle)
    end)
    |> Enum.map(&build_create_change(&1, base_locale))
  end

  defp build_create_change(shopify_product, base_locale) do
    %Change{
      product_uuid: nil,
      handle: shopify_product["handle"],
      title: shopify_product["title"] || shopify_product["handle"],
      base_locale: base_locale,
      shopify_product: shopify_product,
      product_id: shopify_product["id"],
      changes: %{},
      create?: true
    }
  end

  defp validate_only!(only) do
    case Enum.reject(only, &(&1 in @comparable_fields)) do
      [] ->
        :ok

      unrecognized ->
        raise ArgumentError,
              "opts[:only] must be a subset of #{inspect(@comparable_fields)}, " <>
                "got unrecognized field(s) #{inspect(unrecognized)}"
    end
  end

  defp index_by_handle(products, base_locale) do
    Enum.reduce(products, %{}, fn product, acc ->
      case shopify_handle(product, base_locale) do
        handle when is_binary(handle) and handle != "" -> Map.put(acc, handle, product)
        _ -> acc
      end
    end)
  end

  # A catalogue-backed view-struct carries its own Shopify handle in
  # `metadata["_shopify"]["handle"]` (written by `ProductSource.Catalogue.View`
  # from `data["ecommerce"]["shopify"]["handle"]`) — read that first, since a
  # catalogue item's `slug[base_locale]` is a URL, not necessarily the
  # original Shopify handle it was migrated from. A legacy product (or a
  # catalogue item never touched by Shopify) has no such metadata, so this
  # falls back to the slug, unchanged from before.
  defp shopify_handle(product, base_locale) do
    case get_in(product.metadata || %{}, ["_shopify", "handle"]) do
      handle when is_binary(handle) and handle != "" -> handle
      _ -> get_in(product.slug || %{}, [base_locale])
    end
  end

  defp build_change(product, shopify_product, base_locale, only) do
    current_title = local(product, :title, base_locale)

    changes =
      %{}
      |> maybe_put(:title, current_title, shopify_product["title"], only)
      |> maybe_put(
        :body_html,
        local(product, :body_html, base_locale),
        shopify_product["body_html"],
        only
      )
      |> maybe_put(
        :description,
        local(product, :description, base_locale),
        HtmlText.extract_description(shopify_product["body_html"]),
        only
      )
      |> maybe_put(:vendor, product.vendor, shopify_product["vendor"], only)
      |> maybe_put_tags(product.tags, shopify_product["tags"], only)
      |> maybe_put(:status, product.status, shopify_product["status"], only)
      |> maybe_put_price(product.price, shopify_product["variants"], only)
      |> maybe_put_compare_at(product.compare_at_price, shopify_product["variants"], only)

    %Change{
      product_uuid: product.uuid,
      handle: shopify_product["handle"],
      title: current_title || shopify_product["handle"],
      base_locale: base_locale,
      changes: changes,
      price_extreme?: extreme_price?(changes),
      product_id: shopify_product["id"]
    }
  end

  defp local(product, field, base_locale), do: (Map.get(product, field) || %{})[base_locale]

  defp maybe_put(changes, field, current, incoming, only) do
    cond do
      field not in only -> changes
      normalize(current) == normalize(incoming) -> changes
      true -> Map.put(changes, field, %{current: current, incoming: incoming})
    end
  end

  defp normalize(nil), do: ""
  defp normalize(value), do: value

  defp maybe_put_tags(changes, current_tags, incoming_raw, only) do
    if :tags in only do
      current = current_tags || []
      incoming = parse_tags(incoming_raw)

      if MapSet.new(current) == MapSet.new(incoming) do
        changes
      else
        Map.put(changes, :tags, %{current: current, incoming: incoming})
      end
    else
      changes
    end
  end

  defp parse_tags(nil), do: []

  defp parse_tags(tags) when is_binary(tags) do
    tags
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp maybe_put_price(changes, current_price, variants, only) do
    if :price in only do
      put_price_change(changes, current_price, min_variant_price(variants))
    else
      changes
    end
  end

  defp put_price_change(changes, _current_price, nil), do: changes

  defp put_price_change(changes, current_price, incoming_price) do
    if current_price && Decimal.eq?(current_price, incoming_price) do
      changes
    else
      Map.put(changes, :price, %{current: current_price, incoming: incoming_price})
    end
  end

  defp min_variant_price(variants) when is_list(variants) and variants != [] do
    variants
    |> Enum.map(& &1["price"])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Decimal.new/1)
    |> case do
      [] -> nil
      prices -> Enum.min(prices, Decimal)
    end
  end

  defp min_variant_price(_variants), do: nil

  # `compare_at_price` (Shopify's "old price", shown struck through next to
  # the current one) is optional per variant and legitimately absent when a
  # product has no sale — unlike `price`, absence on the Shopify side is NOT
  # "no data to compare" so much as "not on sale", but this mirrors
  # `maybe_put_price/4`'s conservative rule anyway: only report a change when
  # Shopify actually carries a compare_at value on at least one variant.
  # Clearing an existing compare_at_price (sale ended) is not a scenario this
  # diff surfaces — same limitation `price` already has for a fully-absent
  # `variants` list.
  defp maybe_put_compare_at(changes, current_compare_at, variants, only) do
    if :compare_at_price in only do
      put_compare_at_change(changes, current_compare_at, min_variant_compare_at_price(variants))
    else
      changes
    end
  end

  defp put_compare_at_change(changes, _current, nil), do: changes

  defp put_compare_at_change(changes, current, incoming) do
    if current && Decimal.eq?(current, incoming) do
      changes
    else
      Map.put(changes, :compare_at_price, %{current: current, incoming: incoming})
    end
  end

  defp min_variant_compare_at_price(variants) when is_list(variants) and variants != [] do
    variants
    |> Enum.map(& &1["compare_at_price"])
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.map(&Decimal.new/1)
    |> case do
      [] -> nil
      prices -> Enum.min(prices, Decimal)
    end
  end

  defp min_variant_compare_at_price(_variants), do: nil

  defp extreme_price?(%{price: %{current: current, incoming: incoming}}) do
    case price_ratio(current, incoming) do
      nil -> false
      ratio -> Decimal.gt?(ratio, @extreme_ratio)
    end
  end

  defp extreme_price?(_changes), do: false

  defp price_ratio(nil, _incoming), do: nil

  defp price_ratio(current, incoming) do
    if Decimal.eq?(current, 0) or Decimal.eq?(incoming, 0) do
      nil
    else
      a = Decimal.div(current, incoming)
      b = Decimal.div(incoming, current)
      Enum.max([a, b], Decimal)
    end
  end
end
