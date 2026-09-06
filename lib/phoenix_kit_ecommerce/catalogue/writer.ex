defmodule PhoenixKitEcommerce.Catalogue.Writer do
  @moduledoc """
  Writes Shopify sync changes into `phoenix_kit_catalogue` items — the
  write side of Block 3's "sync 6a" (`docs/superpowers/specs/2026-09-05-
  catalogue-as-shop-product-list-design.md` §5 Блок 3), active only when
  `ProductSource.current/0` is `Catalogue`. `PhoenixKitEcommerce.Shopify.Sync`
  is the only intended caller; nothing here touches
  `phoenix_kit_shop_products` (the legacy writer, `Shop.update_product/2`,
  stays the write path for the legacy source).

  Every function is a thin translation from Shopify's field names to
  `PhoenixKitCatalogue.Schemas.Item` columns / `data["ecommerce"]`
  (`PhoenixKitEcommerce.Catalogue.ItemCommerce`) — no diffing (that's
  `ProductDiff`'s job) and no network access.

  `title`/`body_html` land on the item's own `:name`/`:description`
  columns when writing in the item's PRIMARY language, else as a
  multilang override (`data[lang]["_name"]`/`["_description"]`) — same
  primary-vs-override split `PhoenixKitCatalogue.Catalogue.Translations`
  reads. `description` (the ecommerce short summary,
  `PhoenixKitEcommerce.Product.description`) always writes
  `data[lang]["_summary"]`: unlike name/body_html it has no primary-column
  counterpart at all, in either language.
  """

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}
  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue.Slugs}

  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Schemas.Item
  alias PhoenixKitEcommerce.Catalogue.ItemCommerce
  alias PhoenixKitEcommerce.ProductSource.Catalogue.Query
  alias PhoenixKitEcommerce.Translations

  @max_slug_attempts 3

  @doc """
  Applies `change_fields` — a plain `%{field_atom => incoming_value}` map,
  built by `Shopify.Sync.apply_change/2` from a `ProductDiff.Change`'s
  `changes` (unwrapped of its `%{current:, incoming:}` shape) — to `item`,
  writing localized fields into `base_locale` (the SAME locale the change
  was diffed against — see `ProductDiff.Change`'s moduledoc for why that
  matters).

  Recognized keys: `:title`, `:body_html`, `:description`, `:vendor`,
  `:tags`, `:status` (mapped to `data["ecommerce"]["shop_status"]`),
  `:price` (→ `base_price`), `:compare_at_price`. Any other key is
  ignored — this mirrors `ProductDiff.comparable_fields/0`'s set, but
  doesn't hard-code it, so a caller that already filtered `change_fields`
  (e.g. to a single field an operator picked) never has to know that.
  """
  @spec update_from_shopify(Item.t(), map(), String.t()) ::
          {:ok, Item.t()} | {:error, Ecto.Changeset.t() | [{atom(), String.t()}]}
  def update_from_shopify(item, change_fields, base_locale)
      when is_map(item) and is_map(change_fields) and is_binary(base_locale) do
    current_ecommerce = get_in(item.data || %{}, ["ecommerce"])

    with {:ok, cast_ecommerce} <-
           ItemCommerce.cast(ecommerce_params(change_fields), current_ecommerce) do
      # `ItemCommerce.cast/2` returns ONLY its own embedded-schema fields —
      # `to_storage_map/1` builds the map from `Map.from_struct/1`, so a
      # non-schema key such as `legacy_metadata` (the migration snapshot
      # `View.legacy_metadata/2` reads `_option_slots`/`_image_mappings`
      # from) is silently dropped from the cast result even though it was
      # present in `current_ecommerce`. Re-merge it back in so every key
      # `data["ecommerce"]` carried survives a sync write.
      ecommerce = Map.merge(current_ecommerce || %{}, cast_ecommerce)

      data =
        (item.data || %{})
        |> apply_translation_fields(change_fields, base_locale, item)
        |> Map.put("ecommerce", ecommerce)

      attrs =
        %{data: data}
        |> maybe_put_primary_column(:name, :title, change_fields, base_locale, item)
        |> maybe_put_primary_column(:description, :body_html, change_fields, base_locale, item)
        |> maybe_put_base_price(change_fields)

      Catalogue.update_item(item, attrs)
    end
  end

  @doc """
  Creates a catalogue item from a Shopify Admin API product payload for a
  handle with no local match (`ProductDiff.new_product_changes/3`).

  `name`/`description` are written as the item's own columns (a brand new
  item has no other language yet, so `base_locale` — whatever locale the
  sync ran in — IS this item's primary language); `slug[base_locale]`
  comes from `Slugs.from_title/3`, retried with a `-2`/`-3` numeric
  suffix on a slug collision (`#{@max_slug_attempts}` attempts total,
  same shape the data migration's own slug retry uses); `base_price` from
  the cheapest variant; `markup_percentage` `0` (Shopify price is the
  single source of truth — see the design spec's pricing principle);
  `unit "piece"`; `status "active"`; `category_uuid nil` (uncategorized,
  same as a legacy-sync-created product used to be — sorting into a
  category is a manual follow-up either way); `data["ecommerce"]` carries
  `shopify: %{"handle" => ..., "product_id" => ...}` and `shop_status`
  derived from the Shopify product's own `status`.
  """
  @spec create_from_shopify(map(), String.t()) ::
          {:ok, Item.t()}
          | {:error, Ecto.Changeset.t() | [{atom(), String.t()}] | :catalogue_not_found}
  def create_from_shopify(shopify_product, base_locale)
      when is_map(shopify_product) and is_binary(base_locale) do
    title = shopify_product["title"] || shopify_product["handle"]

    with {:ok, catalogue_uuid} <- fetch_catalogue_uuid(),
         {:ok, ecommerce} <- ItemCommerce.cast(create_ecommerce_params(shopify_product), nil) do
      base_slug = Catalogue.Slugs.from_title(title, base_locale)

      attrs = %{
        catalogue_uuid: catalogue_uuid,
        name: title,
        description: shopify_product["body_html"],
        base_price: min_variant_price(shopify_product["variants"]),
        markup_percentage: Decimal.new(0),
        unit: "piece",
        status: "active",
        category_uuid: nil,
        data: %{"ecommerce" => ecommerce}
      }

      create_with_slug(attrs, base_slug, base_locale, 1)
    end
  end

  # ============================================================
  # Update: localized fields
  # ============================================================

  defp apply_translation_fields(data, change_fields, base_locale, item) do
    primary = item_primary_language(item)

    data
    |> maybe_override_field(:title, "_name", change_fields, base_locale, primary)
    |> maybe_override_field(:body_html, "_description", change_fields, base_locale, primary)
    |> maybe_summary_override(change_fields, base_locale)
  end

  # A primary-language change to :title/:body_html lands on the item's own
  # column instead (see `maybe_put_primary_column/5`) — writing BOTH would
  # make the column and the override disagree the moment the primary
  # language ever changes again.
  defp maybe_override_field(data, _field, _override_key, _change_fields, base_locale, primary)
       when base_locale == primary,
       do: data

  defp maybe_override_field(data, field, override_key, change_fields, base_locale, _primary) do
    case Map.fetch(change_fields, field) do
      :error -> data
      {:ok, value} -> put_language_field(data, base_locale, override_key, value)
    end
  end

  defp maybe_summary_override(data, change_fields, base_locale) do
    case Map.fetch(change_fields, :description) do
      :error -> data
      {:ok, value} -> put_language_field(data, base_locale, "_summary", value)
    end
  end

  defp put_language_field(data, lang, key, value) do
    existing = Map.get(data, lang, %{})
    Multilang.put_language_data(data, lang, Map.put(existing, key, value))
  end

  defp item_primary_language(item) do
    case item.data do
      %{"_primary_language" => primary} when is_binary(primary) -> primary
      _ -> Translations.default_language()
    end
  end

  defp maybe_put_primary_column(attrs, column, field, change_fields, base_locale, item) do
    primary = item_primary_language(item)

    case Map.fetch(change_fields, field) do
      {:ok, value} when base_locale == primary -> Map.put(attrs, column, value)
      _ -> attrs
    end
  end

  defp maybe_put_base_price(attrs, change_fields) do
    case Map.fetch(change_fields, :price) do
      {:ok, value} -> Map.put(attrs, :base_price, value)
      :error -> attrs
    end
  end

  # ============================================================
  # data["ecommerce"]
  # ============================================================

  defp ecommerce_params(change_fields) do
    %{}
    |> maybe_put_param("vendor", Map.get(change_fields, :vendor))
    |> maybe_put_param("tags", Map.get(change_fields, :tags))
    |> maybe_put_param("shop_status", shopify_shop_status(Map.get(change_fields, :status)))
    |> maybe_put_param(
      "compare_at_price",
      decimal_param(Map.get(change_fields, :compare_at_price))
    )
  end

  defp create_ecommerce_params(shopify_product) do
    %{
      "shop_status" => shopify_shop_status(shopify_product["status"]),
      "shopify" => %{
        "handle" => shopify_product["handle"],
        "product_id" => shopify_product["id"]
      }
    }
  end

  defp shopify_shop_status(status) when status in ["draft", "active", "archived"], do: status
  defp shopify_shop_status(_status), do: "draft"

  defp decimal_param(nil), do: nil
  defp decimal_param(%Decimal{} = decimal), do: Decimal.to_string(decimal)
  defp decimal_param(value), do: to_string(value)

  defp maybe_put_param(map, _key, nil), do: map
  defp maybe_put_param(map, key, value), do: Map.put(map, key, value)

  # ============================================================
  # Create: catalogue resolution, slug retry, price
  # ============================================================

  defp fetch_catalogue_uuid do
    case Query.catalogue_uuid() do
      nil -> {:error, :catalogue_not_found}
      uuid -> {:ok, uuid}
    end
  end

  defp create_with_slug(attrs, base_slug, base_locale, attempt)
       when attempt <= @max_slug_attempts do
    slug_value = if attempt == 1, do: base_slug, else: "#{base_slug}-#{attempt}"

    case Catalogue.create_item(Map.put(attrs, :slug, %{base_locale => slug_value})) do
      {:ok, item} ->
        {:ok, item}

      {:error, changeset} = error ->
        if attempt < @max_slug_attempts and slug_conflict?(changeset) do
          create_with_slug(attrs, base_slug, base_locale, attempt + 1)
        else
          error
        end
    end
  end

  defp slug_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:slug, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
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
end
