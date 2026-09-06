defmodule PhoenixKitEcommerce.Catalogue.Writer do
  @moduledoc """
  Writes Shopify sync changes into `phoenix_kit_catalogue` items — the
  write side of Block 3's "sync 6a" (`docs/superpowers/specs/2026-09-05-
  catalogue-as-shop-product-list-design.md` §5 Блок 3) and Block 7's 6b
  (same doc, same §, "Блок 7"), active only when `ProductSource.
  current/0` is `Catalogue`. `update_from_shopify/3`/`create_from_shopify/2`
  are called by `PhoenixKitEcommerce.Shopify.Sync`; `sync_variants/2` (and
  the images/collections writers Block 7 adds alongside it) is called
  directly by the sync worker instead — nothing here touches
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

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Attachments}
  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}
  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue.Slugs}
  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue.AttributeSets}
  @compile {:no_warn_undefined, PhoenixKitEntities}

  alias PhoenixKit.Utils.Multilang
  alias PhoenixKitCatalogue.Attachments
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.AttributeSets
  alias PhoenixKitCatalogue.Schemas.Item
  alias PhoenixKitEcommerce.Catalogue.ItemCommerce
  alias PhoenixKitEcommerce.Catalogue.ValueResolver
  alias PhoenixKitEcommerce.ProductSource
  alias PhoenixKitEcommerce.ProductSource.Catalogue.Query
  alias PhoenixKitEcommerce.Services.ImageDownloader
  alias PhoenixKitEcommerce.Shopify.VariantMapper
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

  `:handle` and `:product_id` are the exception: not part of
  `ProductDiff.comparable_fields/0`, they are merged into
  `data["ecommerce"]["shopify"]` (`product_id` stringified) whenever
  present, alongside whatever `Writer` or a later Shopify sync already
  wrote there (`image_ids`, `set_slugs`, `collection_id`) — never
  replacing that sub-map wholesale. `Shopify.Sync.apply_change/2` sets
  both on every applied `Change`, backfilling identity even when the
  caller only asked for a subset of the diffed fields.
  """
  @spec update_from_shopify(Item.t(), map(), String.t()) ::
          {:ok, Item.t()} | {:error, Ecto.Changeset.t() | [{atom(), String.t()}]}
  def update_from_shopify(item, change_fields, base_locale)
      when is_map(item) and is_map(change_fields) and is_binary(base_locale) do
    current_ecommerce = get_in(item.data || %{}, ["ecommerce"])

    with {:ok, cast_ecommerce} <-
           ItemCommerce.cast(
             ecommerce_params(change_fields, current_ecommerce),
             current_ecommerce
           ) do
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
  `shopify: %{"handle" => ..., "product_id" => ...}` (`product_id`
  stringified, same as `update_from_shopify/3`'s own backfill — every
  reader, `CollectionSync` and the Task 5 worker's item index included,
  matches it as a string) and `shop_status` derived from the Shopify
  product's own `status`.
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

  @doc """
  Turns `shopify_product`'s options/variants
  (`PhoenixKitEcommerce.Shopify.VariantMapper.build/1`) into catalogue
  attribute-set attachments on `item`: one set per real Shopify option
  (found by blueprint name `"catalogue_set_" <> slug`, created `kind:
  "fixed"` when missing), values resolved to slugs via `ValueResolver.
  resolve_many/3` (unknown labels become `draft` values), attached in
  Shopify's option order and selected in label order, with a
  slug-keyed price-modifier map written to `data["ecommerce"]
  ["price_modifiers"][set_slug]`.

  A no-op — `{:error, :catalogue_source_inactive}` — when
  `ProductSource.current/0` isn't `Catalogue` (Global Constraints: every
  new Block 7 writer is legacy-source-safe on its own, not only via
  whatever caller happens to gate it).

  Idempotent: a second call against the same `shopify_product` resolves
  every label to its already-created slug (`values_created: 0`), leaves
  already-selected/attached sets untouched (no write, no activity row —
  `AttributeSets.attach_set/3` and `set_attachment_selection/4` are both
  no-ops on an unchanged state), and rewrites the same `price_modifiers`/
  `set_slugs`. Any set previously written by a Shopify sync (tracked in
  `data["ecommerce"]["shopify"]["set_slugs"]`) that this product no
  longer has options for is detached and dropped from both that list and
  `price_modifiers`.
  """
  @spec sync_variants(Item.t(), map()) ::
          {:ok, %{sets: non_neg_integer(), values_created: non_neg_integer()}}
          | {:error, :catalogue_source_inactive | term()}
  def sync_variants(item, shopify_product) when is_map(item) and is_map(shopify_product) do
    if ProductSource.current() == ProductSource.Catalogue do
      do_sync_variants(item, shopify_product)
    else
      {:error, :catalogue_source_inactive}
    end
  end

  defp do_sync_variants(item, shopify_product) do
    %{sets: mapped_sets, modifiers: modifiers} = VariantMapper.build(shopify_product)

    mapped_sets
    |> Enum.reduce_while({:ok, [], 0}, fn set, {:ok, acc, created_total} ->
      case sync_one_set(item, set, Map.get(modifiers, set.slug, %{})) do
        {:ok, result} -> {:cont, {:ok, [result | acc], created_total + result.created}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results, values_created} ->
        finalize_variant_sync(item, Enum.reverse(results), values_created)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sync_one_set(item, %{name: name, slug: slug, values: values}, modifiers_by_label) do
    with {:ok, set} <- find_or_create_set(name, slug),
         {:ok, value_slugs, created} <- resolve_values(slug, values),
         {:ok, _attachment} <- AttributeSets.attach_set(item.uuid, set.uuid),
         :ok <- AttributeSets.set_attachment_selection(item.uuid, set.uuid, value_slugs) do
      {:ok,
       %{
         slug: slug,
         created: created,
         value_amounts: amounts_by_slug(values, value_slugs, modifiers_by_label)
       }}
    end
  end

  defp find_or_create_set(name, slug) do
    case PhoenixKitEntities.get_entity_by_name("catalogue_set_" <> slug) do
      nil -> AttributeSets.create_set(%{name: name, slug: slug, kind: "fixed"})
      entity -> {:ok, entity}
    end
  end

  defp resolve_values(slug, values) do
    resolved = ValueResolver.resolve_many(slug, values)

    Enum.reduce_while(values, {:ok, [], 0}, fn label, {:ok, slugs, created} ->
      case Map.fetch!(resolved, label) do
        {:ok, value_slug} -> {:cont, {:ok, [value_slug | slugs], created}}
        {:created, value_slug} -> {:cont, {:ok, [value_slug | slugs], created + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, slugs, created} -> {:ok, Enum.reverse(slugs), created}
      {:error, reason} -> {:error, reason}
    end
  end

  defp amounts_by_slug(values, value_slugs, modifiers_by_label) do
    values
    |> Enum.zip(value_slugs)
    |> Map.new(fn {label, value_slug} ->
      amount = Map.get(modifiers_by_label, label, Decimal.new("0.00"))
      {value_slug, Decimal.to_string(amount)}
    end)
  end

  defp finalize_variant_sync(item, results, values_created) do
    new_slugs = Enum.map(results, & &1.slug)
    new_modifiers = Map.new(results, &{&1.slug, &1.value_amounts})

    ecommerce = get_in(item.data || %{}, ["ecommerce"]) || %{}
    previous_slugs = get_in(ecommerce, ["shopify", "set_slugs"]) || []
    stale_slugs = previous_slugs -- new_slugs

    detach_stale_sets(item.uuid, stale_slugs)

    shopify = Map.put(ecommerce["shopify"] || %{}, "set_slugs", new_slugs)

    # Write per set, never replace the whole map: `price_modifiers` can
    # also carry a set THIS sync never drove (a set never listed in
    # `set_slugs` — an operator-authored modifier, or a legacy-migration
    # key whose Shopify option name normalises to a different slug) —
    # only the stale, previously-Shopify-owned slugs (already detached
    # above) are dropped; every set in `new_modifiers` is (re)written.
    price_modifiers =
      (ecommerce["price_modifiers"] || %{})
      |> Map.drop(stale_slugs)
      |> Map.merge(new_modifiers)

    ecommerce =
      ecommerce
      |> Map.put("shopify", shopify)
      |> Map.put("price_modifiers", price_modifiers)

    data = Map.put(item.data || %{}, "ecommerce", ecommerce)

    case Catalogue.update_item(item, %{data: data}) do
      {:ok, _updated} -> {:ok, %{sets: length(results), values_created: values_created}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp detach_stale_sets(item_uuid, stale_slugs) do
    Enum.each(stale_slugs, fn slug ->
      case PhoenixKitEntities.get_entity_by_name("catalogue_set_" <> slug) do
        nil -> :ok
        entity -> AttributeSets.detach_set(item_uuid, entity.uuid)
      end
    end)
  end

  # ============================================================
  # Images
  # ============================================================

  @doc """
  Downloads `shopify_product`'s `"images"` into Storage and attaches
  them to `item` in Shopify's own `position` order (ascending; the
  payload's own array order is NOT trusted), featured = the position-1
  image.

  Dedup is keyed by Shopify's own image id, recorded in `data
  ["ecommerce"]["shopify"]["image_ids"]` (`%{"<shopify image id>" =>
  file_uuid}`) — an id already in that map reuses its file uuid instead
  of downloading again. `opts[:downloader]` (default `&ImageDownloader.
  download_and_store/3`, `(url, user_uuid, opts) -> {:ok, file_uuid} |
  {:error, reason}`) and `opts[:user_uuid]` (the file owner passed
  straight through — no local system-actor fallback here; deciding the
  right actor for an unattended sync run is the worker's job) let tests
  swap in a stub that never makes an HTTP call.

  A download failure skips that image (it is not attached and its id is
  not recorded, so a later run retries it) and is reported back in the
  `:errors` list rather than aborting the whole product's images.

  A no-op — `{:error, :catalogue_source_inactive}` — when
  `ProductSource.current/0` isn't `Catalogue` (Global Constraints: every
  new Block 7 writer is legacy-source-safe on its own).

  Idempotent: a second run against the same payload resolves every
  image id to its already-known file uuid (`downloaded: 0`) and
  re-attaches the same order. `image_ids` is rewritten fresh from the
  current sync each run (same "derived fresh" idiom `sync_variants/2`
  uses for `price_modifiers`/`set_slugs`) — an id Shopify no longer
  lists is dropped from it, though the file itself is left attached (no
  deletions in this block).
  """
  @spec sync_images(Item.t(), map(), keyword()) ::
          {:ok,
           %{
             downloaded: non_neg_integer(),
             reused: non_neg_integer(),
             attached: non_neg_integer(),
             errors: [{String.t(), term()}]
           }}
          | {:error, :catalogue_source_inactive | term()}
  def sync_images(item, shopify_product, opts \\ [])
      when is_map(item) and is_map(shopify_product) and is_list(opts) do
    if ProductSource.current() == ProductSource.Catalogue do
      do_sync_images(item, shopify_product, opts)
    else
      {:error, :catalogue_source_inactive}
    end
  end

  defp do_sync_images(item, shopify_product, opts) do
    downloader = Keyword.get(opts, :downloader, &ImageDownloader.download_and_store/3)
    user_uuid = Keyword.get(opts, :user_uuid)

    known_image_ids =
      get_in(item.data || %{}, ["ecommerce", "shopify", "image_ids"]) || %{}

    images =
      (shopify_product["images"] || [])
      |> Enum.sort_by(&(&1["position"] || 0))

    {image_ids, file_uuids, downloaded, reused, errors} =
      Enum.reduce(images, {%{}, [], 0, 0, []}, fn image, acc ->
        resolve_image(image, known_image_ids, downloader, user_uuid, acc)
      end)

    file_uuids = Enum.reverse(file_uuids)
    errors = Enum.reverse(errors)

    with {:ok, item_with_ids} <- put_image_ids(item, image_ids),
         {:ok, _final_item} <- attach_images(item_with_ids, file_uuids) do
      {:ok,
       %{downloaded: downloaded, reused: reused, attached: length(file_uuids), errors: errors}}
    end
  end

  defp resolve_image(image, known_image_ids, downloader, user_uuid, acc) do
    id = to_string(image["id"])

    case Map.fetch(known_image_ids, id) do
      {:ok, uuid} ->
        put_resolved(acc, id, uuid, :reused)

      :error ->
        case downloader.(image["src"], user_uuid, []) do
          {:ok, uuid} -> put_resolved(acc, id, uuid, :downloaded)
          {:error, reason} -> put_error(acc, id, reason)
        end
    end
  end

  defp put_resolved({image_ids, file_uuids, downloaded, reused, errors}, id, uuid, :downloaded) do
    {Map.put(image_ids, id, uuid), [uuid | file_uuids], downloaded + 1, reused, errors}
  end

  defp put_resolved({image_ids, file_uuids, downloaded, reused, errors}, id, uuid, :reused) do
    {Map.put(image_ids, id, uuid), [uuid | file_uuids], downloaded, reused + 1, errors}
  end

  defp put_error({image_ids, file_uuids, downloaded, reused, errors}, id, reason) do
    {image_ids, file_uuids, downloaded, reused, [{id, reason} | errors]}
  end

  defp put_image_ids(item, image_ids) do
    ecommerce = get_in(item.data || %{}, ["ecommerce"]) || %{}
    shopify = Map.put(ecommerce["shopify"] || %{}, "image_ids", image_ids)
    ecommerce = Map.put(ecommerce, "shopify", shopify)
    data = Map.put(item.data || %{}, "ecommerce", ecommerce)

    Catalogue.update_item(item, %{data: data})
  end

  defp attach_images(item, []), do: {:ok, item}

  defp attach_images(item, file_uuids) do
    Attachments.attach_files(item, file_uuids,
      featured: List.first(file_uuids),
      order: file_uuids
    )
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

  defp ecommerce_params(change_fields, current_ecommerce) do
    %{}
    |> maybe_put_param("vendor", Map.get(change_fields, :vendor))
    |> maybe_put_param("tags", Map.get(change_fields, :tags))
    |> maybe_put_param("shop_status", shopify_shop_status(Map.get(change_fields, :status)))
    |> maybe_put_param(
      "compare_at_price",
      decimal_param(Map.get(change_fields, :compare_at_price))
    )
    |> maybe_put_shopify_identity(change_fields, current_ecommerce)
  end

  # Merges `:handle`/`:product_id` into the EXISTING `data["ecommerce"]
  # ["shopify"]` sub-map rather than replacing it outright — that sub-map
  # is also where `sync_images/3`, `sync_variants/2`, and `CollectionSync`
  # record `image_ids`, `set_slugs`, and `collection_id`; a plain
  # `%{"handle" => ..., "product_id" => ...}` here would wipe those out
  # on the next ordinary field sync.
  defp maybe_put_shopify_identity(params, change_fields, current_ecommerce) do
    handle = Map.get(change_fields, :handle)
    product_id = Map.get(change_fields, :product_id)

    if is_nil(handle) and is_nil(product_id) do
      params
    else
      current_shopify = get_in(current_ecommerce || %{}, ["shopify"]) || %{}

      shopify =
        current_shopify
        |> maybe_put_param("handle", handle)
        |> maybe_put_param("product_id", product_id && to_string(product_id))

      Map.put(params, "shopify", shopify)
    end
  end

  defp create_ecommerce_params(shopify_product) do
    %{
      "shop_status" => shopify_shop_status(shopify_product["status"]),
      "shopify" => %{
        "handle" => shopify_product["handle"],
        "product_id" => shopify_product["id"] && to_string(shopify_product["id"])
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
