defmodule PhoenixKitEcommerce.Web.SEOHelpers do
  @moduledoc """
  Catalog SEO assigns (canonical / hreflang / og) for the public shop
  LiveViews, multi-domain aware.

  The canonical host per language comes from the workspace-wide
  `config :phoenix_kit, :canonical_host_resolver, {mod, fun}` MFA (nil or
  absent ⇒ the site-wide `PhoenixKit.Utils.Routes.url/1` base, today's
  behavior). On a language's home host its own locale prefix is stripped —
  the language is that domain's default.

  hreflang inclusion for slug-translated pages is decided on the RAW slug
  map (a non-empty slug for the language, `Helpers.slug_translated?/2`) —
  `SlugResolver` silently falls back to the default-language slug, which
  must never produce an hreflang entry mislabelling the fallback URL as a
  translation.

  The share image (`og.image`, which core's root layout turns into
  `og:image`, `twitter:image` and a `summary_large_image` card) is the
  entity's main Storage image — `large`, else `original` — as the same
  signed `/file/…` URL the storefront renders, absolutized on the
  language's canonical host. For files in public libraries those tokens
  are permanent, so a crawler that fetches the image days after the page
  keeps getting it. No image, no `:image` key: the layout then renders a
  plain `summary` card.
  """

  require Logger

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitEcommerce.Translations
  alias PhoenixKitEcommerce.Web.Helpers

  @doc "SEO assigns for a product page."
  @spec product_seo(struct(), String.t()) :: map()
  def product_seo(product, language) do
    title =
      Translations.get(product, :seo_title, language) |> presence() ||
        Translations.get_display(product, :title, language)

    description =
      Translations.get(product, :seo_description, language) |> presence() ||
        Translations.get(product, :description, language) |> presence()

    canonical_lang = canonical_language(product, language)

    canonical =
      canonical_absolute_url(
        canonical_lang,
        PhoenixKitEcommerce.product_url(product, canonical_lang)
      )

    %{
      page_title: title,
      canonical_url: canonical,
      hreflang_links:
        slug_translated_hreflang(product, fn lang ->
          PhoenixKitEcommerce.product_url(product, lang)
        end),
      og:
        %{
          type: "product",
          title: title,
          description: description,
          url: canonical,
          locale: language
        }
        |> put_share_image(language, product_image_uuid(product), title)
    }
  end

  @doc "SEO assigns for a category page."
  @spec category_seo(struct(), String.t()) :: map()
  def category_seo(category, language) do
    name = Translations.get_display(category, :name, language)

    canonical_lang = canonical_language(category, language)

    canonical =
      canonical_absolute_url(
        canonical_lang,
        PhoenixKitEcommerce.category_url(category, canonical_lang)
      )

    %{
      canonical_url: canonical,
      hreflang_links:
        slug_translated_hreflang(category, fn lang ->
          PhoenixKitEcommerce.category_url(category, lang)
        end),
      og:
        %{
          type: "website",
          title: name,
          url: canonical,
          locale: language
        }
        |> put_share_image(language, category_image_uuid(category), name)
    }
  end

  @doc "SEO assigns for the catalog root (path-stable across languages)."
  @spec catalog_seo(String.t()) :: map()
  def catalog_seo(language) do
    canonical = canonical_absolute_url(language, PhoenixKitEcommerce.catalog_url(language))

    links =
      for %{code: code} <- enabled_languages() do
        %{
          code: DialectMapper.extract_base(code),
          url: canonical_absolute_url(code, PhoenixKitEcommerce.catalog_url(code))
        }
      end

    %{
      canonical_url: canonical,
      hreflang_links: dedup_or_empty(links),
      og: %{type: "website", url: canonical, locale: language}
    }
  end

  # -- internals --------------------------------------------------------

  # The page's main image: featured, else the first of the gallery. A
  # catalogue product arrives with the same two fields, mapped from
  # `data["featured_image_uuid"]` / `data["media_order"]` by its view.
  defp product_image_uuid(%{featured_image_uuid: id}) when is_binary(id) and id != "", do: id
  defp product_image_uuid(%{image_uuids: [id | _]}) when is_binary(id) and id != "", do: id
  defp product_image_uuid(_), do: nil

  # The same order `Category.get_image_url/2` uses: its own image, else the
  # featured product's (preloaded on the legacy source, a placeholder
  # carrying the resolved uuid on the catalogue one).
  defp category_image_uuid(%{image_uuid: id}) when is_binary(id) and id != "", do: id

  defp category_image_uuid(%{featured_product: %{featured_image_uuid: id}})
       when is_binary(id) and id != "",
       do: id

  defp category_image_uuid(_), do: nil

  defp put_share_image(og, _language, nil, _alt), do: og

  defp put_share_image(og, language, file_uuid, alt) do
    case share_image_path(file_uuid) do
      nil -> og
      path -> Map.merge(og, %{image: canonical_file_url(language, path), image_alt: alt})
    end
  end

  # A uuid that names no file costs the image, never the page; one that is
  # not a uuid at all (catalogue `data` is free-form JSON) never reaches the
  # query, which would raise on the cast.
  defp share_image_path(file_uuid) do
    case Ecto.UUID.cast(file_uuid) do
      {:ok, uuid} -> Helpers.get_storage_image_url(uuid, "large")
      :error -> nil
    end
  end

  # A file URL carries no locale segment, so — unlike a page URL — there is
  # nothing to strip on the language's home host.
  defp canonical_file_url(language, path) do
    case resolve_canonical_host(language) do
      nil -> Routes.base_url() <> path
      host -> "https://#{host}#{path}"
    end
  end

  # The language whose URL is the page's canonical.
  #
  # A page renders under the language the visitor asked for even when the
  # product has no slug in it (it shows the primary slug there). That URL is
  # a duplicate of the language the slug really belongs to, so its canonical
  # points there: the primary language when it has a slug, otherwise the first
  # enabled language that does. A page whose language has a slug of its own —
  # and every page of a single-language site, which has one URL per page — is
  # its own canonical.
  defp canonical_language(entity, language) do
    slug_map = Map.get(entity, :slug) || %{}

    cond do
      not Languages.enabled?() -> language
      translated?(slug_map, language) -> language
      true -> real_slug_language(slug_map, language)
    end
  end

  defp real_slug_language(slug_map, language) do
    primary = Translations.default_language()

    if translated?(slug_map, primary) do
      primary
    else
      case Enum.find(enabled_languages(), &translated?(slug_map, &1.code)) do
        %{code: code} -> code
        nil -> language
      end
    end
  end

  defp slug_translated_hreflang(entity, url_fun) do
    slug_map = Map.get(entity, :slug) || %{}

    enabled_languages()
    |> Enum.filter(fn %{code: code} -> translated?(slug_map, code) end)
    |> Enum.map(fn %{code: code} ->
      %{code: DialectMapper.extract_base(code), url: canonical_absolute_url(code, url_fun.(code))}
    end)
    |> dedup_or_empty()
  end

  # A language counts as translated only when the raw slug map has a
  # NON-EMPTY slug for it (exact or base form) — never via SlugResolver's
  # silent fallback, and never for a blank value.
  defp translated?(slug_map, code), do: Helpers.slug_translated?(slug_map, code)

  defp dedup_or_empty(links) do
    links = Enum.uniq_by(links, & &1.code)
    if length(links) < 2, do: [], else: links
  end

  defp enabled_languages do
    if Languages.enabled?(), do: Languages.get_enabled_languages(), else: []
  end

  @doc false
  def canonical_absolute_url(language, relative_url) do
    case resolve_canonical_host(language) do
      nil ->
        # relative_url is already locale-prefixed — Routes.url/1 would
        # re-apply path/1 and double the prefix; base_url/0 is the
        # documented absolutizer for pre-built paths.
        Routes.base_url() <> relative_url

      host ->
        "https://#{host}#{strip_language_prefix(relative_url, language)}"
    end
  end

  defp resolve_canonical_host(language) do
    case Application.get_env(:phoenix_kit, :canonical_host_resolver) do
      {mod, fun} -> apply(mod, fun, [language])
      _ -> nil
    end
  rescue
    error ->
      Logger.warning(
        "[Ecommerce] canonical_host_resolver raised, falling back to site base: " <>
          Exception.message(error)
      )

      nil
  end

  defp strip_language_prefix(url, language) when is_binary(url) and is_binary(language) do
    base = DialectMapper.extract_base(language)

    case String.split(url, "/", parts: 3) do
      ["", ^base] -> "/"
      ["", ^base, rest] -> "/" <> rest
      _ -> url
    end
  end

  defp strip_language_prefix(url, _), do: url

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value) when is_binary(value), do: value
  defp presence(_), do: nil
end
