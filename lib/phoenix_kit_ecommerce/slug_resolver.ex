defmodule PhoenixKitEcommerce.SlugResolver do
  @moduledoc """
  Resolves URL slugs to Products and Categories with language awareness.

  This module provides language-aware slug resolution for the Shop module,
  supporting per-language URL slugs for SEO optimization.

  ## Features

  - Per-language SEO-friendly URL slugs
  - Fallback to canonical slug when translation not found
  - Base code matching (e.g., "en" matches "en-US")
  - Efficient queries using JSONB operators

  ## URL Architecture

  ```
  /shop/products/geometric-planter           # Default language
  /es/shop/products/maceta-geometrica        # Spanish (SEO slug)
  /ru/shop/products/geometricheskoe-kashpo   # Russian (SEO slug)
  ```

  ## Usage Examples

      # Find product by slug in specific language
      SlugResolver.find_product_by_slug("maceta-geometrica", "es-ES")
      # => {:ok, %Product{}}

      # Find product with base code (resolves to full dialect)
      SlugResolver.find_product_by_slug("geometric-planter", "en")
      # => {:ok, %Product{}} (matches en-US via base code)

      # Find category by slug
      SlugResolver.find_category_by_slug("jarrones-macetas", "es-ES")
      # => {:ok, %Category{}}

  ## Query Behavior

  The resolver checks both translated slugs and canonical slugs:

  1. First tries `translations->'language'->>'slug' = ?`
  2. Falls back to canonical `slug = ?`

  This ensures URLs work even for products without translations.
  """

  import Ecto.Query

  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKitEcommerce.Category
  alias PhoenixKitEcommerce.Product
  alias PhoenixKitEcommerce.Translations

  # ============================================================================
  # Product Slug Resolution
  # ============================================================================

  @doc """
  Finds a product by URL slug for a specific language.

  ## Parameters

    - `url_slug` - The URL slug to search for
    - `language` - Language code (supports both "es-ES" and base codes like "en")
    - `opts` - Optional keyword list:
      - `:preload` - Associations to preload (default: [])
      - `:status` - Filter by status (e.g., "active")

  ## Examples

      iex> SlugResolver.find_product_by_slug("maceta-geometrica", "es-ES")
      {:ok, %Product{title: "Maceta Geométrica", ...}}

      iex> SlugResolver.find_product_by_slug("geometric-planter", "en")
      {:ok, %Product{}}  # Matches en-US via base code resolution

      iex> SlugResolver.find_product_by_slug("nonexistent", "en-US")
      {:error, :not_found}

  ## Query Details

  The query checks both:
  1. Translated slug: `translations->'lang'->>'slug'`
  2. Canonical slug: `slug` column

  This ensures backward compatibility with products that have no translations.
  """
  @spec find_product_by_slug(String.t(), String.t(), keyword()) ::
          {:ok, Product.t()} | {:error, :not_found}
  def find_product_by_slug(url_slug, language, opts \\ []) do
    preload = Keyword.get(opts, :preload, [])
    status = Keyword.get(opts, :status)

    # Localized fields: slug is a JSONB map like %{"en" => "planter", "ru" => "kashpo"}
    query =
      from(p in Product,
        where: ^slug_matches(language, url_slug),
        order_by: ^slug_preference(language, url_slug),
        limit: 1
      )

    query = if status, do: from(p in query, where: p.status == ^status), else: query
    query = if preload != [], do: from(p in query, preload: ^preload), else: query

    case repo().one(query) do
      nil -> {:error, :not_found}
      product -> {:ok, product}
    end
  end

  @doc """
  Finds a product by slug, requiring exact language match.

  Unlike `find_product_by_slug/3`, this does not fall back to canonical slug.
  Useful when you need to ensure the translation exists.

  ## Examples

      iex> SlugResolver.find_product_by_translated_slug("maceta-geometrica", "es-ES")
      {:ok, %Product{}}

      iex> SlugResolver.find_product_by_translated_slug("maceta-geometrica", "en-US")
      {:error, :not_found}  # No fallback to canonical
  """
  @spec find_product_by_translated_slug(String.t(), String.t(), keyword()) ::
          {:ok, Product.t()} | {:error, :not_found}
  def find_product_by_translated_slug(url_slug, language, opts \\ []) do
    preload = Keyword.get(opts, :preload, [])

    # EXACT means exact: this asks whether the translation itself exists, so
    # it must not fall back to another spelling of the language the way the
    # URL-resolving finders do.
    query =
      from(p in Product,
        where: fragment("slug->>? = ?", ^normalize_language(language), ^url_slug),
        limit: 1
      )

    query = if preload != [], do: from(p in query, preload: ^preload), else: query

    case repo().one(query) do
      nil -> {:error, :not_found}
      product -> {:ok, product}
    end
  end

  # ============================================================================
  # Category Slug Resolution
  # ============================================================================

  @doc """
  Finds a category by URL slug for a specific language.

  ## Parameters

    - `url_slug` - The URL slug to search for
    - `language` - Language code (supports both full and base codes)
    - `opts` - Optional keyword list:
      - `:preload` - Associations to preload (default: [])
      - `:status` - Filter by status (e.g., "active")

  ## Examples

      iex> SlugResolver.find_category_by_slug("jarrones-macetas", "es-ES")
      {:ok, %Category{name: "Jarrones y Macetas", ...}}

      iex> SlugResolver.find_category_by_slug("vases-planters", "en")
      {:ok, %Category{}}

      iex> SlugResolver.find_category_by_slug("nonexistent", "en-US")
      {:error, :not_found}
  """
  @spec find_category_by_slug(String.t(), String.t(), keyword()) ::
          {:ok, Category.t()} | {:error, :not_found}
  def find_category_by_slug(url_slug, language, opts \\ []) do
    preload = Keyword.get(opts, :preload, [])
    status = Keyword.get(opts, :status)

    # Localized fields: slug is a JSONB map
    query =
      from(c in Category,
        where: ^slug_matches(language, url_slug),
        order_by: ^slug_preference(language, url_slug),
        limit: 1
      )

    query = if status, do: from(c in query, where: c.status == ^status), else: query
    query = if preload != [], do: from(c in query, preload: ^preload), else: query

    case repo().one(query) do
      nil -> {:error, :not_found}
      category -> {:ok, category}
    end
  end

  @doc """
  Finds a category by slug, requiring exact language match.

  Does not fall back to canonical slug.

  ## Examples

      iex> SlugResolver.find_category_by_translated_slug("jarrones-macetas", "es-ES")
      {:ok, %Category{}}
  """
  @spec find_category_by_translated_slug(String.t(), String.t(), keyword()) ::
          {:ok, Category.t()} | {:error, :not_found}
  def find_category_by_translated_slug(url_slug, language, opts \\ []) do
    preload = Keyword.get(opts, :preload, [])

    # Exact by contract — see `find_product_by_translated_slug/3`.
    query =
      from(c in Category,
        where: fragment("slug->>? = ?", ^normalize_language(language), ^url_slug),
        limit: 1
      )

    query = if preload != [], do: from(c in query, preload: ^preload), else: query

    case repo().one(query) do
      nil -> {:error, :not_found}
      category -> {:ok, category}
    end
  end

  # ============================================================================
  # Batch Resolution
  # ============================================================================

  @doc """
  Finds multiple products by their slugs for a specific language.

  Useful for preloading products in listing pages.

  ## Examples

      iex> SlugResolver.find_products_by_slugs(["planter-1", "planter-2"], "en-US")
      [%Product{}, %Product{}]
  """
  @spec find_products_by_slugs([String.t()], String.t(), keyword()) :: [Product.t()]
  def find_products_by_slugs(url_slugs, language, opts \\ []) when is_list(url_slugs) do
    preload = Keyword.get(opts, :preload, [])
    status = Keyword.get(opts, :status)

    # Localized fields: slug is a JSONB map
    query =
      from(p in Product,
        where: ^slug_matches_any(language, url_slugs)
      )

    query =
      if status do
        from(p in query, where: p.status == ^status)
      else
        query
      end

    query =
      if preload != [] do
        from(p in query, preload: ^preload)
      else
        query
      end

    # A row can satisfy more than one spelling of the requested language.
    query |> repo().all() |> Enum.uniq_by(& &1.uuid)
  end

  @doc """
  Finds multiple categories by their slugs for a specific language.

  ## Examples

      iex> SlugResolver.find_categories_by_slugs(["cat-1", "cat-2"], "en-US")
      [%Category{}, %Category{}]
  """
  @spec find_categories_by_slugs([String.t()], String.t(), keyword()) :: [Category.t()]
  def find_categories_by_slugs(url_slugs, language, opts \\ []) when is_list(url_slugs) do
    preload = Keyword.get(opts, :preload, [])
    status = Keyword.get(opts, :status)

    # Localized fields: slug is a JSONB map
    query =
      from(c in Category,
        where: ^slug_matches_any(language, url_slugs)
      )

    query =
      if status do
        from(c in query, where: c.status == ^status)
      else
        query
      end

    query =
      if preload != [] do
        from(c in query, preload: ^preload)
      else
        query
      end

    # A row can satisfy more than one spelling of the requested language.
    query |> repo().all() |> Enum.uniq_by(& &1.uuid)
  end

  # ============================================================================
  # Slug Existence Checks
  # ============================================================================

  @doc """
  Checks if a product slug exists for a specific language.

  Useful for slug validation during product creation/editing.

  ## Parameters

    - `slug` - The slug to check
    - `language` - Language code
    - `exclude_uuid` - Product UUID to exclude from check (for edits)

  ## Examples

      iex> SlugResolver.product_slug_exists?("geometric-planter", "en-US")
      true

      iex> SlugResolver.product_slug_exists?("geometric-planter", "en-US", exclude_uuid: "some-uuid")
      false  # Excludes product with given UUID from check
  """
  @spec product_slug_exists?(String.t(), String.t(), keyword()) :: boolean()
  def product_slug_exists?(slug, language, opts \\ []) do
    exclude_uuid = Keyword.get(opts, :exclude_uuid)

    # Localized fields: slug is a JSONB map
    query =
      from(p in Product,
        where: ^slug_matches(language, slug),
        select: count(p.uuid)
      )

    query =
      if is_binary(exclude_uuid) && match?({:ok, _}, Ecto.UUID.cast(exclude_uuid)) do
        from(p in query, where: p.uuid != ^exclude_uuid)
      else
        query
      end

    repo().one(query) > 0
  end

  @doc """
  Checks if a category slug exists for a specific language.

  ## Examples

      iex> SlugResolver.category_slug_exists?("vases-planters", "en-US")
      true
  """
  @spec category_slug_exists?(String.t(), String.t(), keyword()) :: boolean()
  def category_slug_exists?(slug, language, opts \\ []) do
    exclude_uuid = Keyword.get(opts, :exclude_uuid)

    # Localized fields: slug is a JSONB map
    query =
      from(c in Category,
        where: ^slug_matches(language, slug),
        select: count(c.uuid)
      )

    query =
      if is_binary(exclude_uuid) && match?({:ok, _}, Ecto.UUID.cast(exclude_uuid)) do
        from(c in query, where: c.uuid != ^exclude_uuid)
      else
        query
      end

    repo().one(query) > 0
  end

  # ============================================================================
  # URL Generation
  # ============================================================================

  @doc """
  Gets the best slug for a product in a specific language.

  Returns translated slug if available, otherwise canonical slug.

  ## Examples

      iex> SlugResolver.product_slug(product, "es-ES")
      "maceta-geometrica"

      iex> SlugResolver.product_slug(product, "fr-FR")
      "geometric-planter"  # Falls back to canonical
  """
  @spec product_slug(Product.t(), String.t()) :: String.t() | nil
  def product_slug(%Product{} = product, language) do
    localized_slug(product.slug || %{}, language)
  end

  @doc """
  Gets the best slug for a category in a specific language.

  Returns translated slug if available, otherwise canonical slug.

  ## Examples

      iex> SlugResolver.category_slug(category, "es-ES")
      "jarrones-macetas"
  """
  @spec category_slug(Category.t(), String.t()) :: String.t() | nil
  def category_slug(%Category{} = category, language) do
    localized_slug(category.slug || %{}, language)
  end

  # ============================================================================
  # Cross-Language Slug Resolution
  # ============================================================================

  @doc """
  Finds a product by slug in any language.

  Searches across all translated slugs to find the product.
  Useful for cross-language redirect when user visits with a slug
  from a different language.

  ## Parameters

    - `url_slug` - The URL slug to search for
    - `opts` - Optional keyword list:
      - `:preload` - Associations to preload (default: [])
      - `:status` - Filter by status (e.g., "active")

  ## Examples

      iex> SlugResolver.find_product_by_any_slug("maceta-geometrica")
      {:ok, %Product{}, "es"}  # Returns product with language that matched

      iex> SlugResolver.find_product_by_any_slug("geometric-planter")
      {:ok, %Product{}, "en"}

      iex> SlugResolver.find_product_by_any_slug("nonexistent")
      {:error, :not_found}
  """
  @spec find_product_by_any_slug(String.t(), keyword()) ::
          {:ok, Product.t(), String.t()} | {:error, :not_found}
  def find_product_by_any_slug(url_slug, opts \\ []) do
    preload = Keyword.get(opts, :preload, [])
    status = Keyword.get(opts, :status)

    # Search across all language slugs using JSONB query
    # slug is a JSONB map like %{"en" => "planter", "ru" => "kashpo", "es" => "maceta"}
    query =
      from(p in Product,
        where:
          fragment(
            "EXISTS (SELECT 1 FROM jsonb_each_text(slug) WHERE value = ?)",
            ^url_slug
          ),
        limit: 1
      )

    query =
      if status do
        from(p in query, where: p.status == ^status)
      else
        query
      end

    query =
      if preload != [] do
        from(p in query, preload: ^preload)
      else
        query
      end

    case repo().one(query) do
      nil ->
        {:error, :not_found}

      product ->
        # Find which language matched
        matched_lang = find_matching_language(product.slug || %{}, url_slug)
        {:ok, product, matched_lang}
    end
  end

  @doc """
  Finds a category by slug in any language.

  ## Examples

      iex> SlugResolver.find_category_by_any_slug("jarrones-macetas")
      {:ok, %Category{}, "es"}
  """
  @spec find_category_by_any_slug(String.t(), keyword()) ::
          {:ok, Category.t(), String.t()} | {:error, :not_found}
  def find_category_by_any_slug(url_slug, opts \\ []) do
    preload = Keyword.get(opts, :preload, [])
    status = Keyword.get(opts, :status)

    query =
      from(c in Category,
        where:
          fragment(
            "EXISTS (SELECT 1 FROM jsonb_each_text(slug) WHERE value = ?)",
            ^url_slug
          ),
        limit: 1
      )

    query =
      if status do
        from(c in query, where: c.status == ^status)
      else
        query
      end

    query =
      if preload != [] do
        from(c in query, preload: ^preload)
      else
        query
      end

    case repo().one(query) do
      nil ->
        {:error, :not_found}

      category ->
        matched_lang = find_matching_language(category.slug || %{}, url_slug)
        {:ok, category, matched_lang}
    end
  end

  # Find which language key contains the matching slug
  defp find_matching_language(slug_map, slug) do
    Enum.find_value(slug_map, default_language(), fn {lang, lang_slug} ->
      if lang_slug == slug, do: lang, else: nil
    end)
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  @doc """
  Normalizes a language code to dialect format.

  Converts base codes to full dialect (e.g., "en" -> "en-US").
  Used by import system to ensure consistent language keys in JSONB fields.
  """
  def normalize_language_public(lang) when is_binary(lang), do: normalize_language(lang)

  # Normalize language code (convert base code to full dialect)
  defp normalize_language(lang) when is_binary(lang) do
    cond do
      # Already a full dialect code (contains hyphen)
      String.contains?(lang, "-") ->
        lang

      # Base code only - convert to dialect
      String.length(lang) == 2 ->
        DialectMapper.base_to_dialect(lang)

      # Unknown format - use as-is
      true ->
        lang
    end
  end

  # Every spelling of the same language, most specific first.
  #
  # A localized map is keyed however its WRITER keyed it - the admin form and
  # both CSV importers store the shop's language code verbatim - while every
  # lookup here first normalized that code to a dialect ("en" -> "en-US").
  # On a shop whose language is the base code the two never met: product and
  # category pages 404'd, and a re-import could not find the product it had
  # just created (inserting a duplicate, or failing the unique index). The
  # moduledoc's promise of base-code matching only ever held in one direction.
  defp language_keys(language) when is_binary(language) do
    [language, normalize_language(language), DialectMapper.extract_base(language)]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
  end

  defp language_keys(_language), do: []

  # An OR of equalities over the candidate spellings.
  #
  # No index serves `slug->>? = ?` today (the JSONB GIN index cannot answer
  # it, and the functional unique index is on a different expression), so
  # this is a sequential scan either way — which is exactly why it is ONE
  # query with an OR rather than one query per spelling.
  defp slug_matches(language, url_slug) do
    Enum.reduce(language_keys(language), dynamic(false), fn key, acc ->
      dynamic(^acc or fragment("slug->>? = ?", ^key, ^url_slug))
    end)
  end

  # Two products CAN hold the same slug string under different spellings of
  # one language (a shop that changed its language config mid-life), and an
  # OR with `limit: 1` would then return an arbitrary one. Rank the spelling
  # the caller actually asked for first so the answer is deterministic.
  defp slug_preference(language, url_slug) do
    case language_keys(language) do
      [exact | _] ->
        dynamic(fragment("CASE WHEN slug->>? = ? THEN 0 ELSE 1 END", ^exact, ^url_slug))

      [] ->
        dynamic(0)
    end
  end

  defp slug_matches_any(language, url_slugs) do
    Enum.reduce(language_keys(language), dynamic(false), fn key, acc ->
      dynamic(^acc or fragment("slug->>? = ANY(?)", ^key, ^url_slugs))
    end)
  end

  defp localized_slug(slug_map, language) do
    Enum.find_value(language_keys(language), &present_slug(slug_map[&1])) ||
      Enum.find_value(language_keys(default_language()), &present_slug(slug_map[&1])) ||
      first_present_slug(slug_map)
  end

  defp default_language do
    Translations.default_language()
  end

  # `""` is truthy, so a bare Map.get would emit an empty slug into
  # `product_url/2` and produce `/shop/product/` for a legacy CJK row.
  defp present_slug(slug) when is_binary(slug) and slug != "", do: slug
  defp present_slug(_), do: nil

  defp first_present_slug(map) do
    Enum.find_value(map, fn {_lang, slug} -> present_slug(slug) end)
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
