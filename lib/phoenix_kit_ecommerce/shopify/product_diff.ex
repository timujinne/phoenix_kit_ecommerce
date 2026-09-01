defmodule PhoenixKitEcommerce.Shopify.ProductDiff do
  @moduledoc """
  Compares local products against Shopify Admin API product data.

  Matching is by `product.slug[base_locale] == shopify_product["handle"]`.
  A Shopify product with no local match is skipped — this module never
  creates products, only flags differences on ones that already exist
  (product creation stays the CSV importer's job).

  Compared fields: `title`, `body_html`, `description`, `vendor`, `tags`,
  `status`, `price`. `title`/`body_html`/`description` are localized fields;
  only the base locale is read/compared here (writing them back is
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
  @comparable_fields [:title, :body_html, :description, :vendor, :tags, :status, :price]

  defmodule Change do
    @moduledoc """
    One local product's field-by-field diff against its matched Shopify
    product. `changes` only contains fields that actually differ, keyed by
    field atom, each holding `%{current:, incoming:}`. `price_extreme?` is
    true only when `:price` is in `changes` and the current/incoming ratio
    exceeds 3x.
    """
    @enforce_keys [:product_uuid, :handle, :title]
    defstruct [:product_uuid, :handle, :title, changes: %{}, price_extreme?: false]

    @type t :: %__MODULE__{
            product_uuid: String.t(),
            handle: String.t(),
            title: String.t() | nil,
            changes: %{atom() => %{current: term(), incoming: term()}},
            price_extreme?: boolean()
          }
  end

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
  """
  @spec diff([Product.t()], [map()], String.t(), keyword()) :: [Change.t()]
  def diff(
        local_products,
        shopify_products,
        base_locale \\ Translations.default_language(),
        opts \\ []
      ) do
    only = Keyword.get(opts, :only, @comparable_fields)
    index = index_by_handle(local_products, base_locale)

    shopify_products
    |> Enum.map(&{Map.get(index, &1["handle"]), &1})
    |> Enum.reject(fn {product, _shopify_product} -> is_nil(product) end)
    |> Enum.map(fn {product, shopify_product} ->
      build_change(product, shopify_product, base_locale, only)
    end)
    |> Enum.reject(fn change -> change.changes == %{} end)
  end

  defp index_by_handle(products, base_locale) do
    Enum.reduce(products, %{}, fn product, acc ->
      case get_in(product.slug || %{}, [base_locale]) do
        handle when is_binary(handle) and handle != "" -> Map.put(acc, handle, product)
        _ -> acc
      end
    end)
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

    %Change{
      product_uuid: product.uuid,
      handle: shopify_product["handle"],
      title: current_title || shopify_product["handle"],
      changes: changes,
      price_extreme?: extreme_price?(changes)
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
