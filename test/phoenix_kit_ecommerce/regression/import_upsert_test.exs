defmodule PhoenixKitEcommerce.Regression.ImportUpsertTest do
  @moduledoc """
  A re-import must not delete what the feed says nothing about.

  `upsert_product/1` merges localized fields but replaced every other field
  wholesale, and the importers always supply the full attr set — blank cells
  included. So a routine second import of a minimal CSV wiped translations in
  languages the file never mentioned, plus the admin's option pricing, image
  mappings and custom metadata.
  """
  use PhoenixKitEcommerce.DataCase, async: true

  alias PhoenixKitEcommerce, as: Shop

  defp lang, do: PhoenixKitEcommerce.Translations.default_language()

  defp existing_product(extra \\ %{}) do
    suffix = System.unique_integer([:positive])

    {:ok, product} =
      Shop.create_product(
        Map.merge(
          %{
            "title" => %{lang() => "Planter", "de" => "Blumentopf"},
            "slug" => %{lang() => "planter-#{suffix}"},
            "body_html" => %{lang() => "<p>Handmade</p>", "de" => "<p>Handgemacht</p>"},
            "seo_title" => %{lang() => "Planter", "de" => "Blumentopf"},
            "price" => Decimal.new("10.00"),
            "status" => "active",
            "vendor" => "Studio Ceramica",
            "images" => [%{"src" => "https://cdn.example/legacy.jpg"}],
            "featured_image" => "https://cdn.example/legacy.jpg"
          },
          extra
        )
      )

    product
  end

  # What a feed WITHOUT those columns transforms into: the transformer drops
  # an attribute whose source column the file does not have, so the upsert is
  # never asked to change it.
  defp minimal_reimport(product, overrides \\ %{}) do
    Map.merge(
      %{
        "slug" => %{lang() => product.slug[lang()]},
        "title" => %{lang() => "Planter"},
        "price" => Decimal.new("12.00")
      },
      overrides
    )
  end

  test "a feed without a column leaves that field alone in every language" do
    product = existing_product()

    {:ok, updated, :updated} = Shop.upsert_product(minimal_reimport(product))

    assert updated.body_html["de"] == "<p>Handgemacht</p>"
    assert updated.body_html[lang()] == "<p>Handmade</p>"
    assert updated.seo_title["de"] == "Blumentopf"
    assert updated.title["de"] == "Blumentopf", "an untouched language must survive"
  end

  test "a blank cell clears the imported language only" do
    product = existing_product()

    {:ok, updated, :updated} =
      Shop.upsert_product(minimal_reimport(product, %{"body_html" => %{}}))

    refute Map.has_key?(updated.body_html, lang()), "the file said this cell is empty"

    assert updated.body_html["de"] == "<p>Handgemacht</p>",
           "a blank cell erased every language, not just the imported one"
  end

  test "a supplied translation still wins over the stored one" do
    product = existing_product()

    {:ok, updated, :updated} =
      Shop.upsert_product(minimal_reimport(product, %{"body_html" => %{lang() => "<p>New</p>"}}))

    assert updated.body_html[lang()] == "<p>New</p>"
    assert updated.body_html["de"] == "<p>Handgemacht</p>"
  end

  test "a re-import keeps metadata the feed knows nothing about" do
    product =
      existing_product(%{
        "metadata" => %{
          "custom" => %{"care" => "wipe clean"},
          "_price_modifiers" => %{"size" => %{"large" => "5.00"}},
          "_image_mappings" => %{"red" => "img-1"}
        }
      })

    {:ok, updated, :updated} =
      Shop.upsert_product(
        minimal_reimport(product, %{"metadata" => %{"_option_values" => %{"size" => ["large"]}}})
      )

    assert updated.metadata["custom"] == %{"care" => "wipe clean"}
    assert updated.metadata["_price_modifiers"] == %{"size" => %{"large" => "5.00"}}
    assert updated.metadata["_image_mappings"] == %{"red" => "img-1"}
    assert updated.metadata["_option_values"] == %{"size" => ["large"]}, "incoming keys still win"
  end

  test "a feed's option data does not delete an option it says nothing about" do
    product =
      existing_product(%{
        "metadata" => %{
          "_price_modifiers" => %{
            "size" => %{"XL" => "10.00"},
            "engraving" => %{"yes" => "2.00"}
          }
        }
      })

    {:ok, updated, :updated} =
      Shop.upsert_product(
        minimal_reimport(product, %{
          "metadata" => %{"_price_modifiers" => %{"size" => %{"M" => "5.00"}}}
        })
      )

    assert updated.metadata["_price_modifiers"]["engraving"] == %{"yes" => "2.00"},
           "an admin-created option was deleted by a feed that never mentioned it"

    assert updated.metadata["_price_modifiers"]["size"]["M"] == "5.00"
  end

  test "a feed with no image columns does not clear the product's images" do
    product = existing_product()

    {:ok, updated, :updated} = Shop.upsert_product(minimal_reimport(product))

    assert updated.images == [%{"src" => "https://cdn.example/legacy.jpg"}]
    assert updated.featured_image == "https://cdn.example/legacy.jpg"
    assert updated.vendor == "Studio Ceramica"
  end

  test "a feed that DOES carry an empty column still clears it" do
    product = existing_product()

    {:ok, updated, :updated} =
      Shop.upsert_product(minimal_reimport(product, %{"vendor" => nil, "images" => []}))

    assert updated.vendor == nil, "an exported-but-empty column must still be able to clear"
    assert updated.images == []
  end

  test "a feed that does carry images replaces them" do
    product = existing_product()

    {:ok, updated, :updated} =
      Shop.upsert_product(
        minimal_reimport(product, %{
          "images" => [%{"src" => "https://cdn.example/new.jpg"}],
          "featured_image" => "https://cdn.example/new.jpg",
          "vendor" => "Other Studio"
        })
      )

    assert updated.images == [%{"src" => "https://cdn.example/new.jpg"}]
    assert updated.featured_image == "https://cdn.example/new.jpg"
    assert updated.vendor == "Other Studio"
  end

  test "fields the feed does own are still updated" do
    product = existing_product()

    {:ok, updated, :updated} =
      Shop.upsert_product(minimal_reimport(product, %{"status" => "draft"}))

    assert Decimal.equal?(updated.price, Decimal.new("12.00"))
    assert updated.status == "draft"
  end

  test "an attrs map with no metadata key stays string-keyed" do
    product = existing_product()

    # Ecto refuses a params map that mixes atom and string keys.
    assert {:ok, _updated, :updated} =
             Shop.upsert_product(%{
               "slug" => %{lang() => product.slug[lang()]},
               "title" => %{lang() => "Planter"},
               "price" => Decimal.new("12.00")
             })
  end

  @tag :requires_core_transliteration
  test "a Cyrillic title yields a stable slug, so a re-import matches it" do
    suffix = System.unique_integer([:positive])

    {:ok, product} =
      Shop.create_product(%{
        "title" => %{lang() => "Кашпо #{suffix}"},
        "price" => Decimal.new("10.00"),
        "status" => "active"
      })

    slug = product.slug[lang()]
    assert slug =~ "kashpo", "a Cyrillic title used to slugify to an empty string"

    {:ok, _same, :updated} =
      Shop.upsert_product(%{
        "slug" => %{lang() => slug},
        "title" => %{lang() => "Кашпо #{suffix}"},
        "price" => Decimal.new("11.00")
      })
  end

  describe "language spellings" do
    test "spelling twins are refused outright, so a lookup has nothing to prefer" do
      # This test used to pin `slug_preference/2`: two products holding one
      # slug string under different SPELLINGS of a language ("en" / "en-US"),
      # where an OR with limit 1 returned an arbitrary row and the preference
      # ranking made it deterministic. V171 removed the ambiguity at the
      # source — spellings fold into one (base language, value) bucket, and
      # the projection's primary key refuses the twin at insert, as a
      # changeset error rather than an arbitrary winner at read time.
      suffix = System.unique_integer([:positive])
      slug = "twin-slug-#{suffix}"

      {:ok, exact} =
        Shop.create_product(%{
          "title" => %{lang() => "Exact"},
          "slug" => %{lang() => slug},
          "price" => Decimal.new("10.00"),
          "status" => "active"
        })

      other = if lang() == "en", do: "en-US", else: "en"

      {:error, changeset} =
        Shop.create_product(%{
          "title" => %{lang() => "Other spelling", other => "Other spelling"},
          "slug" => %{lang() => "#{slug}-x", other => slug},
          "price" => Decimal.new("20.00"),
          "status" => "active"
        })

      assert {"has already been taken", _} = changeset.errors[:slug]

      # And the lookup is unambiguous by construction.
      assert {:ok, found} = Shop.get_product_by_slug_localized(slug, lang())
      assert found.uuid == exact.uuid
    end

    test "the other spelling is still found when nothing matches exactly" do
      suffix = System.unique_integer([:positive])
      slug = "other-only-#{suffix}"
      other = if lang() == "en", do: "en-US", else: "en"

      {:ok, product} =
        Shop.create_product(%{
          "title" => %{lang() => "Other only", other => "Other only"},
          "slug" => %{other => slug},
          "price" => Decimal.new("10.00"),
          "status" => "active"
        })

      assert {:ok, found} = Shop.get_product_by_slug_localized(slug, lang())
      assert found.uuid == product.uuid
    end
  end

  describe "colliding slugs" do
    test "a second product with the same generated slug fails cleanly" do
      suffix = System.unique_integer([:positive])

      {:ok, _first} =
        Shop.create_product(%{
          "title" => %{lang() => "Collide #{suffix}"},
          "price" => Decimal.new("10.00"),
          "status" => "active"
        })

      # Transliteration widens this: "Ель" and "Эль" both slugify to "el".
      assert {:error, changeset} =
               Shop.create_product(%{
                 "title" => %{lang() => "Collide #{suffix}"},
                 "price" => Decimal.new("20.00"),
                 "status" => "active"
               })

      assert changeset.errors[:slug],
             "a duplicate primary slug raised out of the caller instead of erroring on the field"
    end
  end
end
