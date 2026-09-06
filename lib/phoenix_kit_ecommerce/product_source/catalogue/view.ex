defmodule PhoenixKitEcommerce.ProductSource.Catalogue.View do
  @moduledoc """
  Builds hand-built `%PhoenixKitEcommerce.Product{}` / `%PhoenixKitEcommerce.Category{}`
  view-structs from a `phoenix_kit_catalogue` item/category, so the facade,
  `Options`, `PriceDisplay`, `CartItem` and the storefront templates read
  exactly the field names they read today from `phoenix_kit_shop_products`/
  `phoenix_kit_shop_categories` — no behavior change on their side.

  Every function here is pure: no `Repo` call, no write. `product_view/2`
  and `category_view/2` build the struct with `struct(Product|Category,
  fields)` — `__meta__` stays `:built`, which is exactly what
  `PhoenixKitEcommerce.update_product/2`/`delete_product/2` refuse.

  Accepts duck-typed records (a real `%PhoenixKitCatalogue.Schemas.Item{}`/
  `%PhoenixKitCatalogue.Schemas.Category{}`, or a plain map with the same
  keys) — nothing here pattern-matches on the catalogue structs, so tests
  can feed plain maps without the optional `phoenix_kit_catalogue`
  dependency loaded.
  """

  # `Catalogue.translated_name/2` etc. read `data["ecommerce"]` at line
  # granularity but never touch the namespace directly — this module (not
  # catalogue) owns interpreting `data["ecommerce"]`. The calls below are
  # only ever reached once `ProductSource.current/0` has already picked
  # this adapter, which requires `phoenix_kit_catalogue` to be loaded; the
  # tag only quietens the compiler's static xref check for hosts that
  # don't declare the optional dependency.
  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}

  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce.Category
  alias PhoenixKitEcommerce.PriceDisplay
  alias PhoenixKitEcommerce.Product
  alias PhoenixKitEcommerce.Translations

  @doc """
  Builds a `%Product{}` view-struct from a catalogue item.

  `opts[:sets]` is a `PhoenixKitCatalogue.Catalogue.AttributeSets.resolve_for_item/2`
  result (`%{schema_version: _, sets: [...]}`) — or, for tests and other
  callers that already have the per-item list, the bare `sets` list
  itself. `opts[:category]` is a `category_view/2` result, attached as
  `:category` when the caller preloaded one.

  `opts[:language]` (a language code, or `nil` for the untranslated
  labels `sets` already carries) picks the language `metadata`'s
  `_option_values`/`_price_modifiers`/`_value_slugs` use for each
  attribute-set VALUE's label — see `legacy_metadata/3`. It does NOT
  translate a set's own `:name` (`_option_labels`, below) — a value's
  translation lives right on it (`values[].extras`, whatever
  `resolve_set/2` read off the value's `EntityData.data`), so this
  pure module can pick it with a plain map lookup, but a set's
  `settings["translations"]` isn't part of the resolved shape at all;
  translating `:name` needs an actual read
  (`ProductSource.Catalogue.Query.set_display_names/2`) that only the
  caller building `sets` (`ProductSource.Catalogue`) can do before
  handing them to this pure function.
  """
  @spec product_view(map(), keyword()) :: Product.t()
  def product_view(item, opts \\ []) do
    sets = Keyword.get(opts, :sets, [])
    category = Keyword.get(opts, :category)
    language = Keyword.get(opts, :language)

    data = item.data || %{}
    ecommerce = Map.get(data, "ecommerce", %{})
    langs = language_keys(data)

    fields = %{
      uuid: item.uuid,
      title: localized_map(item, langs, &Catalogue.translated_name/2),
      body_html: localized_map(item, langs, &Catalogue.translated_description/2),
      description: summary_map(item, langs),
      seo_title: localized_map(item, langs, &Catalogue.translated_seo_title/2),
      seo_description: localized_map(item, langs, &Catalogue.translated_seo_description/2),
      slug: item.slug || %{},
      price: item.base_price,
      compare_at_price: to_decimal(Map.get(ecommerce, "compare_at_price")),
      cost_per_item: to_decimal(Map.get(ecommerce, "cost_per_item")),
      currency: Map.get(ecommerce, "currency") || base_currency_code(),
      taxable: Map.get(ecommerce, "taxable", true),
      weight_grams: Map.get(ecommerce, "weight_grams") || 0,
      requires_shipping: Map.get(ecommerce, "requires_shipping", true),
      made_to_order: Map.get(ecommerce, "made_to_order", false),
      product_type: Map.get(ecommerce, "product_type") || "physical",
      vendor: Map.get(ecommerce, "vendor"),
      tags: Map.get(ecommerce, "tags") || [],
      file_uuid: Map.get(ecommerce, "file_uuid"),
      download_limit: Map.get(ecommerce, "download_limit"),
      download_expiry_days: Map.get(ecommerce, "download_expiry_days"),
      status: product_status(item, ecommerce),
      featured_image_uuid: Map.get(data, "featured_image_uuid"),
      image_uuids: Map.get(data, "media_order") || [],
      images: [],
      featured_image: nil,
      metadata: metadata(item, ecommerce, sets, language),
      category_uuid: item.category_uuid,
      category: category,
      inserted_at: Map.get(item, :inserted_at),
      updated_at: Map.get(item, :updated_at)
    }

    struct(Product, fields)
  end

  @doc """
  Builds a `%Category{}` view-struct from a catalogue category.

  `opts[:parent]` sets the `:parent` association field (a `%Category{}`
  view-struct, or `nil` for a root category / when the caller didn't ask
  for it) — a view-struct can never be `Repo.preload/2`'d, so leaving the
  default `Ecto.Association.NotLoaded` in place (as every OTHER unset
  `belongs_to`/`has_many` field on this struct still does) would crash
  the first template that does a plain `if category.parent do` truthy
  check, same as `PhoenixKitEcommerce.ProductSource.Catalogue`'s
  `single_category/2` already resolves `:category` for products.

  `:storefront_filters` is read straight off
  `data["ecommerce"]["storefront_filters"]` (`%{}` when absent) — see
  `PhoenixKitEcommerce.merge_storefront_filters/2` for how it overrides
  the global filter config.
  """
  @spec category_view(map(), keyword()) :: Category.t()
  def category_view(category, opts \\ []) do
    data = category.data || %{}
    ecommerce = Map.get(data, "ecommerce", %{})
    langs = language_keys(data)

    fields = %{
      uuid: category.uuid,
      name: localized_map(category, langs, &Catalogue.translated_name/2),
      description: localized_map(category, langs, &Catalogue.translated_description/2),
      slug: category.slug || %{},
      status: Map.get(ecommerce, "shop_status") || "active",
      position: category.position,
      parent_uuid: category.parent_uuid,
      parent: Keyword.get(opts, :parent),
      option_schema: Map.get(ecommerce, "option_schema") || [],
      image_uuid: Map.get(ecommerce, "image_uuid"),
      featured_product_uuid: Map.get(ecommerce, "featured_item_uuid"),
      storefront_filters: Map.get(ecommerce, "storefront_filters") || %{},
      metadata: %{},
      inserted_at: Map.get(category, :inserted_at),
      updated_at: Map.get(category, :updated_at)
    }

    struct(Category, fields)
  end

  @doc """
  Synthesizes the legacy `metadata` sub-map every option/price-display
  reader (`Options`, variant picker, `CartItem.from_product/3`) expects:
  `_option_values` (labels in the item's stored selection order),
  `_price_modifiers` (slug-keyed `ecommerce.price_modifiers` swapped to
  the label keys those readers match on), `_option_labels` (`%{set_slug
  => set display name}`, read straight off `sets` — see the moduledoc
  note on `product_view/2`'s `:language`, since a set's OWN translated
  name has to already be sitting on it by the time it gets here) and
  `_value_slugs` (`%{set_slug => %{label => value slug}}`, every value in
  the set, not only the ones selected — Block 6/7's future slug-based
  `selected_specs` reads this; nothing in THIS block writes it back).
  All four computed fresh from `sets` on every call, merged over whatever
  else `data["ecommerce"]["legacy_metadata"]` snapshotted (`_option_slots`,
  `_image_mappings`, `_price_display`, …) — minus those same four keys,
  so a stale snapshot never shadows the live attachment state.

  `sets` accepts the same shapes `product_view/2`'s `:sets` option does.
  `language` (default `nil`) picks which translation of each VALUE's
  label `_option_values`/`_price_modifiers`/`_value_slugs` key on —
  `nil` keeps every one of them exactly as `product_view/2` built it
  before this option existed. `_option_labels` doesn't take `language`
  at all: it reads whatever `:name` already sits on each set in `sets`.
  """
  @spec legacy_metadata(map(), list() | map(), String.t() | nil) :: map()
  def legacy_metadata(item, sets, language \\ nil) do
    snapshot =
      get_in(item.data || %{}, ["ecommerce", "legacy_metadata"]) || %{}

    base =
      Map.drop(snapshot, [
        "_option_values",
        "_price_modifiers",
        "_option_labels",
        "_value_slugs"
      ])

    base
    |> maybe_put("_option_values", option_values_from_sets(sets, language))
    |> maybe_put("_price_modifiers", price_modifiers_from_sets(sets, item, language))
    |> maybe_put("_option_labels", option_labels_from_sets(sets))
    |> maybe_put("_value_slugs", value_slugs_from_sets(sets, language))
  end

  # ============================================================
  # Status
  # ============================================================

  defp product_status(item, ecommerce) do
    case Map.get(ecommerce, "shop_status") do
      status when status in ["draft", "active", "archived"] ->
        status

      _ ->
        if Map.get(item, :status) == "active", do: "active", else: "archived"
    end
  end

  # ============================================================
  # Metadata
  # ============================================================

  defp metadata(item, ecommerce, sets, language) do
    legacy_metadata(item, sets, language)
    |> maybe_put_price_display(ecommerce)
    |> maybe_put("_shopify", Map.get(ecommerce, "shopify"))
  end

  defp maybe_put_price_display(metadata, ecommerce) do
    price_display =
      PriceDisplay.build(
        Map.get(ecommerce, "price_unit") || %{},
        Map.get(ecommerce, "price_from", false) == true,
        Map.get(ecommerce, "price_on_request", false) == true
      )

    maybe_put(metadata, PriceDisplay.metadata_key(), price_display)
  end

  defp maybe_put(map, _key, value) when value in [%{}, nil], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # `sets` is `resolve_for_item/2`'s `%{schema_version: _, sets: [...]}`
  # result, or (tests, and any caller that already has the per-item list)
  # the bare `[...]` itself.
  defp sets_list(%{sets: sets}) when is_list(sets), do: sets
  defp sets_list(sets) when is_list(sets), do: sets
  defp sets_list(_), do: []

  defp option_values_from_sets(sets, language) do
    sets
    |> sets_list()
    |> Enum.reduce(%{}, fn set, acc ->
      key = set |> Map.get(:key) |> strip_set_prefix()
      selected = Map.get(set, :selected) || []
      labels_by_value = value_labels(set, language)

      labels =
        selected
        |> Enum.map(&Map.get(labels_by_value, &1))
        |> Enum.reject(&is_nil/1)

      if labels == [] or is_nil(key), do: acc, else: Map.put(acc, key, labels)
    end)
  end

  defp price_modifiers_from_sets(sets, item, language) do
    raw_modifiers = get_in(item.data || %{}, ["ecommerce", "price_modifiers"]) || %{}
    sets_by_key = sets_by_key_index(sets)

    Enum.reduce(raw_modifiers, %{}, fn {key, slug_amounts}, acc ->
      case Map.get(sets_by_key, key) do
        nil -> acc
        set -> put_labeled_modifiers(acc, key, slug_amounts, value_labels(set, language))
      end
    end)
  end

  # `%{set_slug (bare) => set display name}` — the picker's legend, and
  # the sidebar's would-be built-in label, read the SET's own name
  # rather than an admin-typed string. `:name` on `sets` (a
  # `resolve_for_item/2`-shaped value) is whatever the caller already
  # resolved it to (untranslated `display_name`, or a translated one —
  # `ProductSource.Catalogue` swaps it in via `Query.set_display_names/2`
  # before calling `product_view/2` when `:language` is given); this
  # function only ever reads it, never resolves a translation itself.
  # Skips a set with no name at all (a bare test fixture — see
  # `ViewTest`'s `@sets` — or a broken blueprint) rather than putting a
  # blank legend.
  defp option_labels_from_sets(sets) do
    sets
    |> sets_list()
    |> Enum.reduce(%{}, fn set, acc ->
      key = set |> Map.get(:key) |> strip_set_prefix()

      case {key, Map.get(set, :name)} do
        {nil, _} -> acc
        {_key, name} when not is_binary(name) or name == "" -> acc
        {key, name} -> Map.put(acc, key, name)
      end
    end)
  end

  # `%{set_slug (bare) => %{label => value slug}}`, every value in the
  # set (not only `:selected` — a future slug-based `selected_specs`
  # write needs to resolve whichever label the shopper just picked, not
  # only the ones the product started with). The label side matches
  # whatever `_option_values`/`_price_modifiers` used for the SAME
  # `language`, by construction (both come out of `translated_value_label/2`) —
  # the picker's displayed option and its price-modifier/slug lookups can
  # never disagree.
  defp value_slugs_from_sets(sets, language) do
    sets
    |> sets_list()
    |> Enum.reduce(%{}, &put_value_slugs(&2, &1, language))
  end

  defp put_value_slugs(acc, set, language) do
    key = set |> Map.get(:key) |> strip_set_prefix()
    mapping = value_slug_mapping(set, language)

    if is_nil(key) or mapping == %{}, do: acc, else: Map.put(acc, key, mapping)
  end

  defp value_slug_mapping(set, language) do
    set
    |> Map.get(:values, [])
    |> Map.new(&{translated_value_label(&1, language), Map.get(&1, :key)})
  end

  # A resolved set's `:key` is the entities blueprint NAME
  # (`AttributeSets.resolve_set/2` returns `key: set.name`), and
  # `AttributeSets.create_set/2` always stores that name prefixed —
  # `"catalogue_set_" <> slug` — while `data["ecommerce"]["price_modifiers"]`
  # and the legacy display keys (`_option_values`, `_option_slots`, …) use
  # the bare slug. Same "accept both forms" convention
  # `Query.set_uuid_for_key/1` already uses. Every set is indexed under
  # BOTH forms below so a lookup by either succeeds, and the bare slug is
  # always what ends up in the output map.
  @set_prefix "catalogue_set_"

  defp strip_set_prefix(@set_prefix <> rest), do: rest
  defp strip_set_prefix(key), do: key

  defp sets_by_key_index(sets) do
    sets
    |> sets_list()
    |> Enum.reduce(%{}, fn set, acc ->
      raw_key = Map.get(set, :key)

      acc
      |> Map.put(raw_key, set)
      |> Map.put(strip_set_prefix(raw_key), set)
    end)
  end

  defp put_labeled_modifiers(acc, key, slug_amounts, labels_by_value) do
    by_label = labels_for_amounts(slug_amounts, labels_by_value)
    if by_label == %{}, do: acc, else: Map.put(acc, key, by_label)
  end

  defp labels_for_amounts(slug_amounts, labels_by_value) do
    Enum.reduce(slug_amounts || %{}, %{}, fn {slug, amount}, acc ->
      case Map.get(labels_by_value, slug) do
        nil -> acc
        label -> Map.put(acc, label, amount)
      end
    end)
  end

  defp value_labels(set, language) do
    set
    |> Map.get(:values, [])
    |> Map.new(&{Map.get(&1, :key), translated_value_label(&1, language)})
  end

  # A value's `:label` is `AttributeSets.resolve_set/2`'s bare
  # `record.title` (the primary/default language); `:extras` is that
  # SAME `EntityData` row's raw `data` column, which — whenever a
  # translation was ever saved for the value (`set_title_translation/3`)
  # — also carries `data[lang]["_title"]` overrides for every OTHER
  # language, untouched by `resolve_set/2` (it reads `extras` straight
  # off the column, no `:lang` option involved). `language: nil` (every
  # call site before this option existed, and every caller that hasn't
  # opted in) skips the lookup entirely and returns the untranslated
  # `:label`, unchanged.
  #
  # Goes through `Multilang.get_language_data/2` (matching
  # `EntityData.get_title_translation/2`'s own path) rather than a naive
  # `data[language]["_title"]` key lookup, so a value translated under a
  # base code ("fr") is still found from a dialect-precision page
  # ("fr-FR") and vice versa, and `data[primary]["_title"]` (the
  # PRIMARY language's own override, distinct from `:label`'s
  # `record.title` whenever the two diverge) is consulted before falling
  # back to `:label`.
  defp translated_value_label(value, nil), do: Map.get(value, :label)

  defp translated_value_label(value, language) do
    extras = Map.get(value, :extras) || %{}

    case Map.get(Multilang.get_language_data(extras, language), "_title") do
      title when is_binary(title) and title != "" -> title
      _ -> Map.get(value, :label)
    end
  end

  # ============================================================
  # Localized fields
  # ============================================================

  # Every enabled language that has its own entry in `data`, plus the
  # record's primary language — matches `data["_primary_language"]`'s
  # convention (`PhoenixKit.Utils.Multilang`): a language with no entry
  # at all carries no override for ANY field, so every localized map on
  # this record omits it uniformly.
  #
  # Whitelisted against `Translations.enabled_languages/0` rather than
  # blacklisting known non-language namespaces: catalogue items carry
  # several top-level keys that are not per-language data at all
  # (`files_folder_uuid` — every item with media, written by
  # `Attachments.attach_files/3`; `meta` — `PhoenixKitCatalogue.Metadata`;
  # `original_unit` — the import mapper) and a hardcoded blacklist would
  # have to keep discovering catalogue's future top-level keys one probe
  # at a time.
  defp language_keys(data) do
    primary = Map.get(data, "_primary_language") || Translations.default_language()
    enabled = Translations.enabled_languages()
    langs = data |> Map.keys() |> Enum.filter(&(&1 in enabled))

    if primary in langs, do: Enum.uniq(langs), else: Enum.uniq([primary | langs])
  end

  defp localized_map(record, langs, translate_fn) do
    Enum.reduce(langs, %{}, fn lang, acc ->
      case translate_fn.(record, lang) do
        value when is_binary(value) and value != "" -> Map.put(acc, lang, value)
        _ -> acc
      end
    end)
  end

  # `_summary` per language, falling back to the first 300 characters of
  # the (HTML-stripped) translated description — never omitted for an
  # included language, unlike `localized_map/3`'s siblings: a product
  # page needs *some* description text once the language is in scope.
  defp summary_map(item, langs) do
    Enum.reduce(langs, %{}, fn lang, acc ->
      case summary_for(item, lang) do
        value when is_binary(value) and value != "" -> Map.put(acc, lang, value)
        _ -> acc
      end
    end)
  end

  defp summary_for(item, lang) do
    translation = Catalogue.get_translation(item, lang)

    case Map.get(translation, "_summary") do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        item
        |> Catalogue.translated_description(lang)
        |> strip_and_truncate(300)
    end
  end

  defp strip_and_truncate(nil, _limit), do: nil

  defp strip_and_truncate(html, limit) do
    text =
      html
      |> String.replace(~r/<[^>]*>/, "")
      |> String.trim()
      |> String.slice(0, limit)

    if text == "", do: nil, else: text
  end

  # ============================================================
  # Decimal
  # ============================================================

  defp to_decimal(nil), do: nil
  defp to_decimal(""), do: nil
  defp to_decimal(%Decimal{} = decimal), do: decimal

  defp to_decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, _rest} -> decimal
      :error -> nil
    end
  end

  defp to_decimal(value) when is_number(value), do: Decimal.new(to_string(value))
  defp to_decimal(_), do: nil

  # The shop's base currency code when the facade exposes it (currency
  # work, `get_base_currency/0`); "USD" only as the last resort so a
  # catalogue item without an explicit currency never disagrees with the
  # shop's configured base.
  defp base_currency_code do
    if function_exported?(PhoenixKitEcommerce, :get_base_currency, 0),
      do: currency_code(apply(PhoenixKitEcommerce, :get_base_currency, [])),
      else: "USD"
  end

  defp currency_code(%{code: code}) when is_binary(code), do: code
  defp currency_code(code) when is_binary(code), do: code
  defp currency_code(_), do: "USD"
end
