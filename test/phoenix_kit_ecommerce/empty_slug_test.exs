defmodule PhoenixKitEcommerce.EmptySlugTest do
  @moduledoc """
  An unromanizable title must not write an empty slug.

  `Slug.slugify/2` returns `""` for scripts it cannot romanize (CJK,
  Arabic, emoji). Writing that `""` used to lock the shop out via the
  old `extract_primary_slug` index; after V171 empty values are simply
  not a URL. Either way a CJK-only product with no slug is unreachable
  from the catalog (`product_url/2` interpolates nil into
  `/shop/product/`).

  The generator now writes a stable `item-<hash>` fallback instead, and
  scrubs leftover `""` values so a legacy row self-heals on its next
  save — and gains a URL.
  """
  use PhoenixKitEcommerce.DataCase, async: true

  alias Ecto.Changeset
  alias PhoenixKitEcommerce.Category
  alias PhoenixKitEcommerce.LocalizedSlug
  alias PhoenixKitEcommerce.Product
  alias PhoenixKitEcommerce.SlugResolver

  defp product_slugs(title_map, base \\ %Product{}) do
    base
    |> Product.changeset(%{title: title_map, price: 100})
    |> Changeset.get_field(:slug)
  end

  defp cjk_slug(text), do: LocalizedSlug.fallback(text)

  describe "the generator" do
    test "writes a stable fallback for an unromanizable title, never an empty slug" do
      # The map key is the store's language, not the script of the text — an
      # English-keyed shop entering CJK text is the everyday route here.
      assert product_slugs(%{"en" => "日本語"}) == %{"en" => cjk_slug("日本語")}
    end

    test "the fallback is stable across saves and distinct per title" do
      assert cjk_slug("日本語") == cjk_slug("日本語")
      refute cjk_slug("日本語") == cjk_slug("別の話")
      assert cjk_slug("日本語") =~ ~r/^item-[0-9a-f]{10}$/
    end

    test "keeps the romanizable languages of a mixed title and falls back for the rest" do
      assert product_slugs(%{"en" => "Nihongo", "ja" => "日本語"}) == %{
               "en" => "nihongo",
               "ja" => cjk_slug("日本語")
             }
    end

    test "categories behave the same" do
      slugs =
        %Category{}
        |> Category.changeset(%{name: %{"en" => "日本語"}})
        |> Changeset.get_field(:slug)

      assert slugs == %{"en" => cjk_slug("日本語")}
    end
  end

  describe "against the real index" do
    test "a second CJK-only product inserts — the lockout this fixes" do
      for title <- ["日本語", "別の話"] do
        {:ok, product} =
          %Product{}
          |> Product.changeset(%{title: %{"en" => title}, price: 100})
          |> Repo.insert()

        assert product.slug == %{"en" => cjk_slug(title)}
      end
    end

    test "two products with the same unromanizable title collide as a changeset error" do
      {:ok, _} =
        %Product{}
        |> Product.changeset(%{title: %{"en" => "日本語"}, price: 100})
        |> Repo.insert()

      {:error, changeset} =
        %Product{}
        |> Product.changeset(%{title: %{"en" => "日本語"}, price: 100})
        |> Repo.insert()

      assert {"has already been taken", _} = changeset.errors[:slug]
    end

    test "a legacy row holding an empty slug self-heals on its next save" do
      # Written the way pre-fix code wrote it, bypassing the changeset.
      legacy =
        Repo.insert!(%Product{
          title: %{"en" => "日本語"},
          slug: %{"en" => ""},
          price: Decimal.new(100)
        })

      {:ok, healed} = legacy |> Product.changeset(%{}) |> Repo.update()

      assert healed.slug == %{"en" => cjk_slug("日本語")}

      # And with the "" key vacated, a different CJK-only product can insert.
      {:ok, _} =
        %Product{}
        |> Product.changeset(%{title: %{"en" => "別の話"}, price: 100})
        |> Repo.insert()
    end
  end

  describe "V171's projection bucket, from the changeset's side" do
    test "a same-language collision is a changeset error, not a raw Postgrex error" do
      {:ok, _} =
        %Product{}
        |> Product.changeset(%{title: %{"en" => "Same Hat"}, price: 100})
        |> Repo.insert()

      {:error, changeset} =
        %Product{}
        |> Product.changeset(%{
          title: %{"en" => "Other"},
          slug: %{"en" => "same-hat"},
          price: 100
        })
        |> Repo.insert()

      assert {"has already been taken", _} = changeset.errors[:slug]
    end

    test "the same value under a different language inserts fine" do
      # The old expression index rejected this pair; the projection does not —
      # a URL request always carries a language.
      {:ok, _} =
        %Product{}
        |> Product.changeset(%{title: %{"en" => "Hat"}, price: 100})
        |> Repo.insert()

      {:ok, _} =
        %Product{}
        |> Product.changeset(%{
          title: %{"en" => "Other Hat", "de" => "Hut"},
          slug: %{"en" => "other-hat", "de" => "hat"},
          price: 100
        })
        |> Repo.insert()
    end
  end

  describe "URL resolution of blank slugs" do
    test "product_slug skips a stored empty string rather than emitting it" do
      product = %Product{slug: %{"en" => ""}, title: %{"en" => "日本語"}}
      assert SlugResolver.product_slug(product, "en") == nil
    end

    test "product_slug falls through a blank to another language's value" do
      product = %Product{slug: %{"en" => "", "de" => "hut"}}
      assert SlugResolver.product_slug(product, "en") == "hut"
    end

    test "a generated CJK slug is what product_url interpolates" do
      product = %Product{
        title: %{"en" => "日本語"},
        slug: %{"en" => cjk_slug("日本語")}
      }

      url = PhoenixKitEcommerce.product_url(product, "en")
      assert url =~ cjk_slug("日本語")
      refute url =~ ~r{/shop/product/?$}
    end
  end
end
