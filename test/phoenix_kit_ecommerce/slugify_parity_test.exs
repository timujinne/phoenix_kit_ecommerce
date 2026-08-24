defmodule PhoenixKitEcommerce.SlugifyParityTest do
  @moduledoc """
  Product and Category must derive the same slug from the same text.

  This is the test that would have caught both drifts. It is DB-backed
  (both changesets read a language setting), which is why it is split out
  from `PhoenixKitEcommerce.SlugifyTest` — the pure-function cases there
  must keep running on a checkout with no PostgreSQL.

  Both sides go through the CHANGESET, not through `Product.slugify/2`.
  Comparing the raw function on one side to a changeset on the other only
  proves the two functions agree; the drift that actually shipped twice was
  about what each *schema* does when deriving a slug, so that is what this
  compares.

  Since both schemas now pass the map key as the language, this also pins that
  each schema slugs a German entry AS German and an Estonian entry AS Estonian —
  the reduce in both had the language bound and was discarding it.
  """
  use PhoenixKitEcommerce.DataCase, async: true

  alias PhoenixKitEcommerce.Category
  alias PhoenixKitEcommerce.Product

  @drifted [
    # every case the two implementations have disagreed on
    "Größe Fußball",
    "Видеопродакшн",
    "Corporate Video",
    "Öl",
    "Müük",
    # unromanizable: both must apply the same hash fallback, not omit the key
    "日本語"
  ]

  test "both schemas slug identically for every case that has drifted" do
    for text <- @drifted do
      assert derived_slug(Product, :title, text) == derived_slug(Category, :name, text),
             """
             #{text}: \
             product=#{inspect(derived_slug(Product, :title, text))} \
             category=#{inspect(derived_slug(Category, :name, text))}\
             """
    end
  end

  test "a non-empty title always yields a non-empty slug" do
    # The Cyrillic drift's real symptom: a category with no URL at all.
    for text <- @drifted do
      refute derived_slug(Product, :title, text) in [nil, ""]
      refute derived_slug(Category, :name, text) in [nil, ""]
    end
  end

  test "each schema slugs an entry in the language of its own map key" do
    # Both reduces had `lang` bound and were throwing it away, so every language
    # got the neutral rule. German wants oe, Estonian wants o, from the same text.
    assert derived_slug(Product, :title, "Größe", "de") == "groesse"
    assert derived_slug(Category, :name, "Größe", "de") == "groesse"
    assert derived_slug(Product, :title, "Größe", "et") == "grosse"
    assert derived_slug(Category, :name, "Größe", "et") == "grosse"
  end

  # The slug each schema's changeset derives for the "en" entry of its own
  # title field. Both schemas key the generated slug map by language, so a
  # single-language input yields a single-key map.
  defp derived_slug(schema, title_field, text, lang \\ "en") do
    struct(schema)
    |> schema.changeset(%{to_string(title_field) => %{lang => text}})
    |> Ecto.Changeset.get_change(:slug)
    |> case do
      %{^lang => slug} -> slug
      other -> other
    end
  end
end
