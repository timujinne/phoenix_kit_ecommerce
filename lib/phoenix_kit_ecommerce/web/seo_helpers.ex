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
  map (`Map.has_key?(entity.slug, lang)`) — `SlugResolver` silently falls
  back to the default-language slug, which must never produce an hreflang
  entry mislabelling the fallback URL as a translation.
  """

  require Logger

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitEcommerce.Translations

  @doc "SEO assigns for a product page."
  @spec product_seo(struct(), String.t()) :: map()
  def product_seo(product, language) do
    title =
      Translations.get(product, :seo_title, language) |> presence() ||
        Translations.get_display(product, :title, language)

    description =
      Translations.get(product, :seo_description, language) |> presence() ||
        Translations.get(product, :description, language) |> presence()

    canonical =
      canonical_absolute_url(language, PhoenixKitEcommerce.product_url(product, language))

    %{
      page_title: title,
      canonical_url: canonical,
      hreflang_links:
        slug_translated_hreflang(product, fn lang ->
          PhoenixKitEcommerce.product_url(product, lang)
        end),
      og: %{
        type: "product",
        title: title,
        description: description,
        url: canonical,
        locale: language
      }
    }
  end

  @doc "SEO assigns for a category page."
  @spec category_seo(struct(), String.t()) :: map()
  def category_seo(category, language) do
    canonical =
      canonical_absolute_url(language, PhoenixKitEcommerce.category_url(category, language))

    %{
      canonical_url: canonical,
      hreflang_links:
        slug_translated_hreflang(category, fn lang ->
          PhoenixKitEcommerce.category_url(category, lang)
        end),
      og: %{
        type: "website",
        title: Translations.get_display(category, :name, language),
        url: canonical,
        locale: language
      }
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

  defp slug_translated_hreflang(entity, url_fun) do
    slug_map = Map.get(entity, :slug) || %{}

    enabled_languages()
    |> Enum.filter(fn %{code: code} -> translated?(slug_map, code) end)
    |> Enum.map(fn %{code: code} ->
      %{code: DialectMapper.extract_base(code), url: canonical_absolute_url(code, url_fun.(code))}
    end)
    |> dedup_or_empty()
  end

  # A language counts as translated only when the raw slug map has a key
  # for it (exact or base form) — never via SlugResolver's silent fallback.
  defp translated?(slug_map, code) do
    base = DialectMapper.extract_base(code)
    Map.has_key?(slug_map, code) or Map.has_key?(slug_map, base)
  end

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
