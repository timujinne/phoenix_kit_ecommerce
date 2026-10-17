defmodule PhoenixKitEcommerce.API.Cards do
  @moduledoc """
  The three shapes a product takes in a public answer:

    * `list_item/2` - a product in a list,
    * `card/3` - the full card of `shop.get_products` (a list item plus
      description, tags, options and images),
    * `stub/2` - a discontinued product: `id`, `title` and the status, nothing
      else, no price.

  They are built from live data (`PhoenixKitEcommerce.API.Record`), never from
  the search index, and contain plain JSON values only: strings, integers,
  booleans, lists and maps with string keys. A value that is `nil` is left out.
  Prices are base-currency amounts converted with `API.Context.money/2`; a
  product whose price is "on request" shows none.
  """

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.API.CardLookup
  alias PhoenixKitEcommerce.API.Context
  alias PhoenixKitEcommerce.API.PlainText
  alias PhoenixKitEcommerce.API.Record
  alias PhoenixKitEcommerce.HtmlToMarkdown
  alias PhoenixKitEcommerce.PriceDisplay
  alias PhoenixKitEcommerce.Search.OptionKeys
  alias PhoenixKitEcommerce.Translations
  alias PhoenixKitEcommerce.Web.Helpers

  @description_limit 4_000
  @images_limit 10

  @list_fields ~w(id title slug url price price_from compare_at discount_pct price_on_request
                  made_to_order vendor product_type category_path status image)

  @doc "The keys a list item can carry, in answer order (`fields` filters by these)."
  @spec list_fields() :: [String.t()]
  def list_fields, do: @list_fields

  @doc """
  What the cards of `records` share, read once for all of them (see
  `PhoenixKitEcommerce.API.CardLookup`), to be passed to `list_item/3` and
  `card/3` as `:lookup`. Options: `:keys` (the list fields asked for, default
  all) and `card?` (the full card's pictures too).
  """
  @spec lookup([Record.t()], keyword()) :: CardLookup.t()
  def lookup(records, opts \\ []) do
    keys = Keyword.get(opts, :keys) || @list_fields
    products = Enum.map(records, & &1.product)

    list_pictures =
      if "image" in keys,
        do:
          for(
            product <- products,
            uuid = Helpers.first_stored_image(product),
            do: {uuid, "small"}
          ),
        else: []

    card_pictures =
      if Keyword.get(opts, :card?, false),
        do: for(product <- products, uuid <- image_uuids(product), do: {uuid, "medium"}),
        else: []

    CardLookup.build(products,
      schemas: "price_from" in keys,
      pictures: list_pictures ++ card_pictures
    )
  end

  @doc """
  A product in a list. Options: `:keys` (build only these fields, default all)
  and `:lookup` (from `lookup/2`; built for this one record when absent).
  """
  @spec list_item(Record.t(), Context.t(), keyword()) :: map()
  def list_item(%Record{product: product} = record, %Context{} = context, opts \\ []) do
    keys = Keyword.get(opts, :keys) || @list_fields
    lookup = Keyword.get_lazy(opts, :lookup, fn -> lookup([record], keys: keys) end)
    language = context.language
    on_request? = PriceDisplay.on_request?(product)
    slug = link_slug(product, language)

    %{
      "id" => fn -> record.id end,
      "title" => fn -> Translations.get_display(product, :title, language) end,
      "slug" => fn -> slug end,
      "url" => fn -> slug && Context.absolute(context, Shop.product_url(product, language)) end,
      "price" => fn -> priced(on_request?, fn -> Context.money(context, product.price) end) end,
      "price_from" => fn ->
        priced(on_request?, fn -> lowest_price(context, product, lookup) end)
      end,
      "compare_at" => fn ->
        priced(on_request?, fn -> Context.money(context, compare_at(product)) end)
      end,
      "discount_pct" => fn -> priced(on_request?, fn -> discount_pct(product) end) end,
      "price_on_request" => fn -> on_request? end,
      "made_to_order" => fn -> product.made_to_order == true end,
      "vendor" => fn -> blank_to_nil(product.vendor) end,
      "product_type" => fn -> product.product_type end,
      "category_path" => fn -> category_path(record, language) end,
      "status" => fn -> "active" end,
      "image" => fn ->
        context
        |> Context.absolute(Helpers.first_image(product, &CardLookup.url(lookup, &1, &2)))
      end
    }
    |> Map.take(keys)
    |> Map.new(fn {key, build} -> {key, build.()} end)
    |> compact()
  end

  @doc """
  The slug of a product or a category in `language`, `nil` when it has none.
  Something with no slug in any language has no page to link to
  (`Shop.product_url/2` would answer `/en/shop/product/`, an empty slug), so
  `slug` and `url` are left out together.
  """
  @spec link_slug(map(), String.t()) :: String.t() | nil
  def link_slug(entity, language), do: blank_to_nil(Translations.get_slug(entity, language))

  @doc """
  The full card. Options: `format: "text"` (default; plain text: HTML tags and
  Markdown syntax removed) or `"markdown"` (stored Markdown, or stored HTML
  converted). Either way the description is cut to #{@description_limit}
  characters.
  """
  @spec card(Record.t(), Context.t(), keyword()) :: map()
  def card(%Record{product: product} = record, %Context{} = context, opts \\ []) do
    lookup = Keyword.get_lazy(opts, :lookup, fn -> lookup([record], card?: true) end)

    record
    |> list_item(context, lookup: lookup)
    |> Map.merge(%{
      "description" => description(product, context.language, Keyword.get(opts, :format, "text")),
      "tags" => product.tags |> List.wrap() |> Enum.filter(&is_binary/1),
      "options" => Enum.map(OptionKeys.extract(product), &option/1),
      "images" => images(product, context, lookup)
    })
    |> compact()
  end

  @spec stub(Record.t(), Context.t()) :: map()
  def stub(%Record{product: product, id: id}, %Context{} = context) do
    %{
      "id" => id,
      "title" => Translations.get_display(product, :title, context.language),
      "status" => "discontinued"
    }
  end

  @doc "The lowest price over the options, or `nil` when no option changes the price."
  @spec price_from(Context.t(), Decimal.t(), Decimal.t()) :: map() | nil
  def price_from(%Context{} = context, %Decimal{} = low, %Decimal{} = high) do
    if Decimal.compare(low, high) == :eq, do: nil, else: Context.money(context, low)
  end

  # --- pieces ----------------------------------------------------------------

  defp priced(true, _fun), do: nil
  defp priced(false, fun), do: fun.()

  defp lowest_price(context, product, lookup) do
    {low, high} = Shop.get_price_range(product, CardLookup.schema(lookup, product))
    price_from(context, low, high)
  end

  defp compare_at(%{price: %Decimal{} = price, compare_at_price: %Decimal{} = compare_at}) do
    if Decimal.compare(price, 0) == :gt and Decimal.compare(compare_at, price) == :gt,
      do: compare_at
  end

  defp compare_at(_product), do: nil

  defp discount_pct(product) do
    case compare_at(product) do
      nil ->
        nil

      compare_at ->
        compare_at
        |> Decimal.sub(product.price)
        |> Decimal.div(compare_at)
        |> Decimal.mult(100)
        |> Decimal.round(0)
        |> Decimal.to_integer()
    end
  end

  # Only categories `shop.list_categories` shows (status `active`) are named:
  # a hidden, deleted or unlisted ancestor stays out of the card.
  defp category_path(%Record{chain: chain}, language) do
    chain
    |> Enum.filter(&(&1.status == "active"))
    |> Enum.map(&category_ref(&1, language))
  end

  defp category_ref(category, language) do
    %{"id" => category.uuid, "name" => Translations.get_display(category, :name, language) || ""}
  end

  defp description(product, language, format) do
    raw = raw_description(product, language)

    case format do
      "markdown" ->
        raw
        |> PlainText.bound(@description_limit)
        |> HtmlToMarkdown.convert()
        |> cut(@description_limit)

      _text ->
        PlainText.convert(raw, @description_limit)
    end
  end

  defp cut(text, limit) when is_binary(text),
    do: text |> String.slice(0, limit) |> String.trim_trailing()

  defp cut(other, _limit), do: other

  defp raw_description(product, language) do
    body = Translations.get(product, :body_html, language)

    if is_binary(body) and String.trim(body) != "",
      do: body,
      else: Translations.get(product, :description, language)
  end

  defp option(option) do
    %{
      "key" => option.key,
      "label" => option.label,
      "affects_price" => option.affects_price,
      "values" => Enum.map(option.values, &%{"key" => &1.key, "label" => &1.label})
    }
  end

  defp images(product, context, lookup) do
    stored = Enum.map(image_uuids(product), &CardLookup.url(lookup, &1, "medium"))
    legacy = for %{"src" => src} <- List.wrap(product.images), is_binary(src), do: src

    (stored ++ legacy)
    |> Enum.reject(&is_nil/1)
    |> Enum.take(@images_limit)
    |> Enum.map(&Context.absolute(context, &1))
  end

  defp image_uuids(product) do
    [product.featured_image_uuid | List.wrap(product.image_uuids)]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_other), do: nil
end
