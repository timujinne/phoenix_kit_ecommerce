defmodule PhoenixKitEcommerce.Search.Document do
  @moduledoc """
  Turns a loaded product (`PhoenixKitEcommerce.API.Record`) into the row of
  the search index for one language. Pure: the settings reads inside
  `Translations` are its only outside contact.

  Text is language-resolved the way the storefront resolves it
  (`Translations.get/3`: the exact language, then the shop's default language,
  then any value), so a product with no German title is still found by the
  German search, under its default-language title. A blank value counts as
  missing, so an empty German title falls back as well.

  The index holds the names as stored: the storefront-only `shop_name_prefixes`
  setting (`Translations.get_display/4`) does not decide what can be found, and
  nothing reindexes when it changes.

  Only `active` categories of the chain are indexed (their names, their uuids
  and the leaf `category_uuid`): a hidden, deleted or unlisted ancestor, or an
  unlisted category of the product itself, is never named or searchable
  through the product, although the product itself stays listed.

  The weights of the `tsvector` the indexer builds from these parts:
  title A; vendor, tags and category names B (`:text_b`); option set names and
  value labels C (`:text_c`); the description D (`:text_d`).
  """

  alias PhoenixKitEcommerce.API.Money
  alias PhoenixKitEcommerce.API.PlainText
  alias PhoenixKitEcommerce.API.Record
  alias PhoenixKitEcommerce.PriceDisplay
  alias PhoenixKitEcommerce.Search.Dictionary
  alias PhoenixKitEcommerce.Search.OptionKeys
  alias PhoenixKitEcommerce.Translations

  @description_limit 5_000

  @doc "The index row for `record` in `language`, or `nil` when the product has no title at all."
  @spec build(Record.t(), String.t()) :: map() | nil
  def build(%Record{} = record, language) when is_binary(language) do
    case title(record.product, language) do
      nil -> nil
      title -> row(record, language, title)
    end
  end

  defp row(%Record{product: product, chain: chain, facts: facts}, language, title) do
    chain = Enum.filter(chain, &(&1.status == "active"))
    options = OptionKeys.extract(product)
    labels = OptionKeys.labels(options)
    category_names = Enum.map(chain, &category_name(&1, language))
    category = List.last(chain)
    vendor = blank_to_nil(product.vendor)
    tags = product.tags |> List.wrap() |> Enum.filter(&is_binary/1)
    # A product on "price on request" shows no price anywhere (the cards hide
    # it), so the index must not hold one either: otherwise `price_max`,
    # `price_min`, the price sorts and the price facet leak it (a price oracle
    # by bisection). NULL prices drop out of every price filter and facet and
    # sort last.
    on_request? = PriceDisplay.on_request?(product)
    price = if on_request?, do: nil, else: decimal(product.price)
    compare_at = if on_request?, do: nil, else: decimal(product.compare_at_price)
    on_sale? = on_sale?(price, compare_at)

    %{
      item_uuid: product.uuid,
      language: language,
      regconfig: Dictionary.regconfig(language),
      title: title,
      text_b: join_words([vendor | tags ++ category_names]),
      text_c: labels |> Map.values() |> Enum.sort() |> join_words(),
      text_d: description(product, language),
      category_uuid: category && category.uuid,
      category_path: category_names,
      category_path_uuids: Enum.map(chain, & &1.uuid),
      vendor: vendor,
      tags: tags,
      option_pairs: OptionKeys.pairs(options),
      option_labels: labels,
      made_to_order: product.made_to_order == true,
      on_sale: on_sale?,
      price: price,
      compare_at_price: compare_at,
      discount_pct: if(on_sale?, do: discount_pct(price, compare_at)),
      sort_position: facts.position || 0,
      item_inserted_at: to_datetime(product.inserted_at)
    }
  end

  defp title(product, language) do
    product |> localized(:title, language) |> blank_to_nil()
  end

  defp category_name(category, language) do
    case localized(category, :name, language) do
      name when is_binary(name) -> name
      _other -> ""
    end
  end

  # The body when it has text, else the short description.
  defp description(product, language) do
    text =
      Enum.find_value([:body_html, :description], fn field ->
        product |> localized(field, language) |> PlainText.convert(@description_limit)
      end)

    text || ""
  end

  # `Translations.get/3` with blank values left out, so an empty string in the
  # requested language does not defeat the fallback.
  defp localized(entity, field, language) do
    entity
    |> Map.update(field, %{}, &drop_blank/1)
    |> Translations.get(field, language)
  end

  defp drop_blank(%{} = values) do
    values |> Enum.reject(fn {_language, value} -> blank_to_nil(value) == nil end) |> Map.new()
  end

  defp drop_blank(_other), do: %{}

  defp on_sale?(%Decimal{} = price, %Decimal{} = compare_at) do
    Decimal.compare(price, 0) == :gt and Decimal.compare(compare_at, price) == :gt
  end

  defp on_sale?(_price, _compare_at), do: false

  defp discount_pct(price, compare_at) do
    compare_at
    |> Decimal.sub(price)
    |> Decimal.div(compare_at)
    |> Decimal.mult(100)
    |> Decimal.round(2)
  end

  defp join_words(words) do
    words |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" ")
  end

  defp decimal(%Decimal{} = value), do: Money.to_decimal(value)
  defp decimal(_other), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_other), do: nil

  defp to_datetime(%DateTime{} = value), do: value
  defp to_datetime(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")
  defp to_datetime(_other), do: nil
end
