defmodule PhoenixKitEcommerce.LocalizedSlug do
  @moduledoc """
  Shared per-language slug generation for Product and Category.

  Both schemas used to carry a private copy of this reduce. They drifted
  twice — Cyrillic, then German — and PR #21's empty-result guard would
  have been the third copy of the same function. There is one rule:

    * an existing non-blank slug is left alone (write-once; renaming
      must not move a live URL)
    * a blank or missing slug is derived from that language's title/name
    * `Slug.slugify/2` returning `""` (CJK, Arabic, emoji — scripts with
      no romanizer) must not write `""`. An empty value used to squat on
      the old primary-slug index and lock the shop out; after V171 it
      is simply not a URL. Either way the product is unreachable.
    * the fallback is a stable `item-<sha256>` of the source text, so two
      different unromanizable titles never collide and the same title
      always produces the same slug
    * leftover `""` values already in the map are scrubbed, so a legacy
      row self-heals on its next save
  """

  import Ecto.Changeset
  import Ecto.Query

  alias PhoenixKit.Utils.Slug

  @hash_len 10

  @doc """
  Fill missing per-language slugs on `changeset` from `source_field`.

  `source_field` is `:title` on products and `:name` on categories.
  """
  @spec maybe_generate(Ecto.Changeset.t(), atom()) :: Ecto.Changeset.t()
  def maybe_generate(%Ecto.Changeset{} = changeset, source_field) when is_atom(source_field) do
    source_map = get_field(changeset, source_field) || %{}
    slug_map = get_field(changeset, :slug) || %{}

    updated =
      source_map
      |> Enum.reduce(slug_map, fn {lang, text}, acc -> put_generated(acc, lang, text) end)
      |> drop_blanks()

    if updated == slug_map do
      changeset
    else
      put_change(changeset, :slug, updated)
    end
  end

  @doc """
  Stable ASCII slug for text `Slug.slugify/2` cannot romanize.

  The hash is of the source text alone, so the same title under two
  languages shares one value (allowed: uniqueness is per language) and
  two different titles almost never collide.
  """
  @spec fallback(String.t()) :: String.t()
  def fallback(text) when is_binary(text) do
    hash =
      :crypto.hash(:sha256, text)
      |> Base.encode16(case: :lower)
      |> binary_part(0, @hash_len)

    "item-#{hash}"
  end

  @doc """
  Fill a blank *string* slug (shipping methods) when `put_slug/3` left it
  empty because the source did not romanize.

  The column is `NOT NULL`. Leaving it blank is a failed insert, not a
  missing URL — the same empty-slugify case as products, via a plain
  unique column instead of the jsonb projection.
  """
  @spec put_plain_fallback(Ecto.Changeset.t(), atom(), keyword()) :: Ecto.Changeset.t()
  def put_plain_fallback(%Ecto.Changeset{} = changeset, source_field, opts \\ [])
      when is_atom(source_field) do
    to = Keyword.get(opts, :to, :slug)
    max_length = Keyword.get(opts, :max_length, 100)

    if get_field(changeset, to) in [nil, ""] do
      case get_field(changeset, source_field) do
        value when is_binary(value) and value != "" ->
          put_change(changeset, to, unique_plain(changeset, fallback(value), to, max_length))

        _ ->
          changeset
      end
    else
      changeset
    end
  end

  defp put_generated(acc, lang, text) do
    cond do
      Map.get(acc, lang) not in [nil, ""] ->
        acc

      text in [nil, ""] ->
        acc

      true ->
        slug =
          case Slug.slugify(text, locale: lang, transliterate: true) do
            "" -> fallback(text)
            generated -> generated
          end

        Map.put(acc, lang, slug)
    end
  end

  defp drop_blanks(map) do
    map
    |> Enum.reject(fn {_lang, slug} -> slug in [nil, ""] end)
    |> Map.new()
  end

  defp unique_plain(changeset, base, to, max_length) do
    case PhoenixKit.Config.get(:repo, nil) do
      nil ->
        base

      repo ->
        Slug.ensure_unique(
          base,
          &plain_taken?(changeset, to, repo, &1),
          max_length: max_length
        )
    end
  end

  defp plain_taken?(changeset, to, repo, candidate) do
    schema = changeset.data.__struct__
    prefix = changeset.data.__meta__.prefix

    query =
      changeset.data
      |> Map.get(:uuid)
      |> exclude_own(from(r in schema, where: field(r, ^to) == ^candidate))

    repo.exists?(query, prefix: prefix)
  end

  defp exclude_own(nil, query), do: query
  defp exclude_own(uuid, query), do: from(r in query, where: r.uuid != ^uuid)
end
