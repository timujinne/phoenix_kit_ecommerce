defmodule PhoenixKitEcommerce.Search.IndexerTest do
  @moduledoc """
  The indexer on the legacy product source (no catalogue needed). The
  catalogue-specific cases are in `indexer_catalogue_test.exs`.
  """
  use PhoenixKitEcommerce.DataCase, async: true

  import PhoenixKitEcommerce.SearchFixtures

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Search.Entry
  alias PhoenixKitEcommerce.Search.Indexer
  alias PhoenixKitEcommerce.Test.Repo

  defp rows(uuid) do
    Repo.all(
      from(e in Entry,
        where: e.item_uuid == ^uuid,
        order_by: e.language,
        select: {e.language, e.title}
      )
    )
  end

  # The whole row as a map (the tsvector as text, the stamp left out), read by SQL
  # so that no column escapes the comparison.
  defp row_snapshot(uuid) do
    %{rows: [[row]]} =
      Repo.query!(
        """
        SELECT to_jsonb(e) - 'indexed_at' - 'document' || jsonb_build_object('document', e.document::text)
        FROM phoenix_kit_shop_search_index e
        WHERE e.item_uuid = $1
        """,
        [Ecto.UUID.dump!(uuid)]
      )

    row
  end

  defp matches?(uuid, config, words) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(*) FROM phoenix_kit_shop_search_index
        WHERE item_uuid = $1 AND document @@ websearch_to_tsquery($2::text::regconfig, $3)
        """,
        [Ecto.UUID.dump!(uuid), config, words]
      )

    count == 1
  end

  defp index_count do
    Repo.one(from(e in Entry, select: count(e.uuid)))
  end

  test "indexes a listed product once per enabled language, with the default title as fallback" do
    enable_languages!(["en", "de"])
    product = legacy_product!(%{"en" => "Red Vase"})

    assert {:ok, %{indexed: 2, removed: 0}} = Indexer.reindex_items([product.uuid])

    assert rows(product.uuid) == [{"de", "Red Vase"}, {"en", "Red Vase"}]
  end

  test "a translated title is indexed in its own language" do
    enable_languages!(["en", "de"])
    product = legacy_product!(%{"en" => "Red Vase", "de" => "Rote Vasen"})

    {:ok, _} = Indexer.reindex_items([product.uuid])

    assert rows(product.uuid) == [{"de", "Rote Vasen"}, {"en", "Red Vase"}]

    # The german document is stemmed with the german configuration: "Vase" finds "Vasen".
    %{rows: [[count]]} =
      Repo.query!("""
      SELECT count(*) FROM phoenix_kit_shop_search_index
      WHERE language = 'de' AND document @@ websearch_to_tsquery('german', 'Vase')
      """)

    assert count == 1
  end

  test "dialect language codes are kept in the row and still pick the language configuration" do
    enable_languages!(["en-US", "de-DE", "fr-FR"])
    product = legacy_product!(%{"en-US" => "Red Vase", "de-DE" => "Rote Vasen"})

    assert {:ok, %{indexed: 3, removed: 0}} = Indexer.reindex_items([product.uuid])

    assert rows(product.uuid) == [
             {"de-DE", "Rote Vasen"},
             {"en-US", "Red Vase"},
             {"fr-FR", "Red Vase"}
           ]

    # Only the german configuration stems "Rote" to "rot"; the simple one would not match "Rot".
    %{rows: [[language]]} =
      Repo.query!(
        """
        SELECT language FROM phoenix_kit_shop_search_index
        WHERE item_uuid = $1 AND document @@ websearch_to_tsquery('german', 'Rot')
        """,
        [Ecto.UUID.dump!(product.uuid)]
      )

    assert language == "de-DE"
  end

  test "a draft, an archived and a hidden-category product get no rows" do
    hidden = legacy_category!(%{"en" => "Hidden"}, %{status: "hidden"})
    draft = legacy_product!(%{"en" => "Draft"}, %{status: "draft"})
    archived = legacy_product!(%{"en" => "Archived"}, %{status: "archived"})
    in_hidden = legacy_product!(%{"en" => "In hidden"}, %{category_uuid: hidden.uuid})
    listed = legacy_product!(%{"en" => "Listed"})

    ids = [draft.uuid, archived.uuid, in_hidden.uuid, listed.uuid]
    assert {:ok, %{indexed: 1, removed: 0}} = Indexer.reindex_items(ids)

    assert rows(draft.uuid) == []
    assert rows(archived.uuid) == []
    assert rows(in_hidden.uuid) == []
    assert [{"en", "Listed"}] = rows(listed.uuid)
  end

  test "the row carries the category chain, options, price and sale flags" do
    root = legacy_category!(%{"en" => "Home"})
    leaf = legacy_category!(%{"en" => "Vases"}, %{parent_uuid: root.uuid})

    product =
      legacy_product!(%{"en" => "Red Vase"}, %{
        category_uuid: leaf.uuid,
        vendor: "Acme",
        tags: ["gift"],
        price: "20.00",
        compare_at_price: "25.00",
        made_to_order: true,
        metadata: %{"_option_values" => %{"size" => ["Large"]}}
      })

    {:ok, _} = Indexer.reindex_items([product.uuid])

    entry = Repo.one!(from(e in Entry, where: e.item_uuid == ^product.uuid))

    assert entry.category_uuid == leaf.uuid
    assert entry.category_path == ["Home", "Vases"]
    assert entry.category_path_uuids == [root.uuid, leaf.uuid]
    assert entry.vendor == "Acme"
    assert entry.tags == ["gift"]
    assert entry.option_pairs == ["size:large"]
    assert entry.option_labels == %{"size" => "Size", "size:large" => "Large"}
    assert entry.made_to_order
    assert entry.on_sale
    assert Decimal.equal?(entry.price, Decimal.new("20.00"))
    assert Decimal.equal?(entry.discount_pct, Decimal.new("20.00"))
    assert entry.title_trgm == "red vase"
  end

  test "a product that stops being listed loses its rows on the next reindex" do
    product = legacy_product!(%{"en" => "Red Vase"})
    {:ok, _} = Indexer.reindex_items([product.uuid])
    assert [{"en", "Red Vase"}] = rows(product.uuid)

    {:ok, _} = Shop.update_product(product, %{status: "draft"})

    assert {:ok, %{indexed: 0, removed: 1}} = Indexer.reindex_items([product.uuid])
    assert rows(product.uuid) == []
  end

  test "an upper-case id is the same product: its rows are kept" do
    product = legacy_product!(%{"en" => "Red Vase"})
    {:ok, _} = Indexer.reindex_items([product.uuid])
    before = rows(product.uuid)
    assert before != []

    assert {:ok, %{removed: 0}} = Indexer.reindex_items([String.upcase(product.uuid)])
    assert rows(product.uuid) == before
  end

  test "a deleted product loses its rows" do
    product = legacy_product!(%{"en" => "Red Vase"})
    {:ok, _} = Indexer.reindex_items([product.uuid])

    {:ok, _} = Shop.delete_product(product)

    assert {:ok, %{indexed: 0, removed: 1}} = Indexer.reindex_items([product.uuid])
    assert rows(product.uuid) == []
  end

  test "reindex_items/1 touches only the ids it is given" do
    a = legacy_product!(%{"en" => "Alpha Vase"})
    b = legacy_product!(%{"en" => "Beta Vase"})
    {:ok, _} = Indexer.reindex_items([a.uuid, b.uuid])

    {:ok, _} = Shop.update_product(a, %{title: %{"en" => "Alpha Bowl"}})
    {:ok, _} = Shop.update_product(b, %{title: %{"en" => "Beta Bowl"}})

    {:ok, _} = Indexer.reindex_items([a.uuid])

    assert [{"en", "Alpha Bowl"}] = rows(a.uuid)
    assert [{"en", "Beta Vase"}] = rows(b.uuid)
  end

  test "rows of a language that is no longer enabled are removed" do
    enable_languages!(["en", "de"])
    product = legacy_product!(%{"en" => "Red Vase"})
    {:ok, _} = Indexer.reindex_items([product.uuid])
    assert length(rows(product.uuid)) == 2

    enable_languages!(["en"])

    assert {:ok, %{indexed: 1, removed: 1}} = Indexer.reindex_items([product.uuid])
    assert rows(product.uuid) == [{"en", "Red Vase"}]
  end

  test "malformed ids and an empty list are harmless" do
    assert {:ok, %{indexed: 0, removed: 0}} = Indexer.reindex_items([])
    assert {:ok, %{indexed: 0, removed: 0}} = Indexer.reindex_items(["nope", nil, 3])
  end

  describe "refreshing an existing row" do
    test "a reindex rewrites every column of a row that holds other values" do
      root = legacy_category!(%{"en" => "Home"})
      leaf = legacy_category!(%{"en" => "Vases"}, %{parent_uuid: root.uuid})

      product =
        legacy_product!(%{"en" => "Red Vase"}, %{
          category_uuid: leaf.uuid,
          vendor: "Acme",
          tags: ["gift"],
          price: "20.00",
          compare_at_price: "25.00",
          made_to_order: true,
          description: %{"en" => "Handmade ceramic"},
          metadata: %{"_option_values" => %{"size" => ["Large"]}}
        })

      {:ok, _} = Indexer.reindex_items([product.uuid])
      fresh = row_snapshot(product.uuid)

      # No column may be empty here, or an overwrite of it could not be told from a skipped one.
      assert Enum.all?(fresh, fn {_column, value} -> value not in [nil, [], %{}, ""] end)

      Repo.query!(
        """
        UPDATE phoenix_kit_shop_search_index SET
          title = 'stale', title_trgm = 'stale', document = to_tsvector('simple', 'stale'),
          category_uuid = NULL, category_path = '{}', category_path_uuids = '{}', vendor = NULL,
          tags = '{}', option_pairs = '{}', option_labels = '{}'::jsonb, made_to_order = false,
          on_sale = false, price = NULL, compare_at_price = NULL, discount_pct = NULL,
          sort_position = 99, item_inserted_at = '2000-01-01', indexed_at = '2000-01-01'
        WHERE item_uuid = $1
        """,
        [Ecto.UUID.dump!(product.uuid)]
      )

      refute row_snapshot(product.uuid) == fresh

      assert {:ok, %{indexed: 1, removed: 0}} = Indexer.reindex_items([product.uuid])

      assert row_snapshot(product.uuid) == fresh
    end

    test "an edit of everything the row derives from reaches the row and the tsvector" do
      root = legacy_category!(%{"en" => "Home"})
      leaf = legacy_category!(%{"en" => "Vases"}, %{parent_uuid: root.uuid})
      kitchen = legacy_category!(%{"en" => "Kitchen"})

      product =
        legacy_product!(%{"en" => "Red Vase"}, %{
          category_uuid: leaf.uuid,
          vendor: "Acme",
          tags: ["gift"],
          price: "20.00",
          compare_at_price: "25.00",
          made_to_order: true,
          description: %{"en" => "Handmade ceramic"},
          metadata: %{"_option_values" => %{"size" => ["Large"]}}
        })

      {:ok, _} = Indexer.reindex_items([product.uuid])
      before = Repo.one!(from(e in Entry, where: e.item_uuid == ^product.uuid, select: e.uuid))

      for word <- ["Vase", "Acme", "gift", "ceramic", "Large", "Home"],
          do: assert(matches?(product.uuid, "english", word), word)

      {:ok, _} =
        Shop.update_product(product, %{
          title: %{"en" => "Blue Bowl"},
          category_uuid: kitchen.uuid,
          vendor: "Zeta",
          tags: ["sale"],
          price: Decimal.new("15.00"),
          compare_at_price: nil,
          made_to_order: false,
          description: %{"en" => "Hand blown glass"},
          metadata: %{"_option_values" => %{"color" => ["Teal"]}}
        })

      assert {:ok, %{indexed: 1, removed: 0}} = Indexer.reindex_items([product.uuid])

      entry = Repo.one!(from(e in Entry, where: e.item_uuid == ^product.uuid))

      assert entry.uuid == before
      assert entry.title == "Blue Bowl"
      assert entry.title_trgm == "blue bowl"
      assert entry.category_uuid == kitchen.uuid
      assert entry.category_path == ["Kitchen"]
      assert entry.category_path_uuids == [kitchen.uuid]
      assert entry.vendor == "Zeta"
      assert entry.tags == ["sale"]
      assert entry.option_pairs == ["color:teal"]
      assert entry.option_labels == %{"color" => "Color", "color:teal" => "Teal"}
      refute entry.made_to_order
      refute entry.on_sale
      assert Decimal.equal?(entry.price, Decimal.new("15.00"))
      assert entry.compare_at_price == nil
      assert entry.discount_pct == nil

      for word <- ["Bowl", "Zeta", "sale", "glass", "Teal", "Kitchen"],
          do: assert(matches?(product.uuid, "english", word), word)

      for word <- ["Vase", "Acme", "gift", "ceramic", "Large", "Home"],
          do: refute(matches?(product.uuid, "english", word), word)
    end
  end

  describe "a 16-byte string is no id" do
    test "reindex_items/2 neither writes a row for it nor removes the row of that product" do
      {product, raw} = raw_uuid_product!(%{"en" => "Red Vase"})

      assert {:ok, %{indexed: 0, removed: 0}} = Indexer.reindex_items([raw])
      assert index_count() == 0

      assert {:ok, %{indexed: 1}} = Indexer.reindex_items([product.uuid])
      before = row_snapshot(product.uuid)

      assert {:ok, %{indexed: 0, removed: 0}} = Indexer.reindex_items([raw])
      assert index_count() == 1
      assert row_snapshot(product.uuid) == before
    end
  end

  describe "overlapping runs" do
    test "an older run does not overwrite a newer row, its content or its stamp" do
      product = legacy_product!(%{"en" => "Red Bowl"})
      newer = DateTime.utc_now()
      older = DateTime.add(newer, -60, :second)

      assert {:ok, %{indexed: 1}} = Indexer.reindex_items([product.uuid], started_at: newer)

      # What the older run read before the edit: it comes back with the old title.
      {:ok, _} = Shop.update_product(product, %{title: %{"en" => "Red Vase"}})

      assert {:ok, %{indexed: 0, removed: 0}} =
               Indexer.reindex_items([product.uuid], started_at: older)

      assert {:ok, %{products: 1, indexed: 0, removed: 0}} = Indexer.rebuild(started_at: older)

      assert %{title: "Red Bowl", indexed_at: stamp} =
               Repo.one!(
                 from(e in Entry,
                   where: e.item_uuid == ^product.uuid,
                   select: %{title: e.title, indexed_at: e.indexed_at}
                 )
               )

      assert DateTime.compare(stamp, newer) == :eq
    end

    test "a newer run overwrites an older row" do
      product = legacy_product!(%{"en" => "Red Vase"})
      older = DateTime.add(DateTime.utc_now(), -60, :second)
      {:ok, _} = Indexer.reindex_items([product.uuid], started_at: older)

      {:ok, _} = Shop.update_product(product, %{title: %{"en" => "Red Bowl"}})

      assert {:ok, %{indexed: 1, removed: 0}} = Indexer.reindex_items([product.uuid])
      assert rows(product.uuid) == [{"en", "Red Bowl"}]
    end

    test "a run with the same stamp is written again (ties are not skipped)" do
      product = legacy_product!(%{"en" => "Red Vase"})
      stamp = DateTime.utc_now()
      {:ok, _} = Indexer.reindex_items([product.uuid], started_at: stamp)

      {:ok, _} = Shop.update_product(product, %{title: %{"en" => "Red Bowl"}})

      assert {:ok, %{indexed: 1, removed: 0}} =
               Indexer.reindex_items([product.uuid], started_at: stamp)

      assert rows(product.uuid) == [{"en", "Red Bowl"}]
    end
  end

  describe "more products than one chunk" do
    test "reindex_items/2 writes and removes across all chunks" do
      products = for n <- 1..5, do: legacy_product!(%{"en" => "Vase #{n}"})
      ids = Enum.map(products, & &1.uuid)

      assert {:ok, %{indexed: 5, removed: 0}} = Indexer.reindex_items(ids, chunk_size: 2)
      assert index_count() == 5

      for product <- products, do: {:ok, _} = Shop.update_product(product, %{status: "draft"})

      assert {:ok, %{indexed: 0, removed: 5}} = Indexer.reindex_items(ids, chunk_size: 2)
      assert index_count() == 0
    end

    test "rebuild/1 writes and removes across all chunks" do
      products = for n <- 1..5, do: legacy_product!(%{"en" => "Vase #{n}"})

      assert {:ok, %{products: 5, indexed: 5, removed: 0}} = Indexer.rebuild(chunk_size: 2)
      assert index_count() == 5

      for product <- products, do: {:ok, _} = Shop.update_product(product, %{status: "draft"})

      assert {:ok, %{products: 5, indexed: 0, removed: 5}} = Indexer.rebuild(chunk_size: 2)
      assert index_count() == 0
    end
  end

  describe "no enabled language" do
    test "a rebuild falls back to the default language and does not wipe the index" do
      product = legacy_product!(%{"en" => "Red Vase"})
      {:ok, _} = Indexer.reindex_items([product.uuid])
      enable_languages!([])
      assert PhoenixKitEcommerce.Translations.enabled_languages() == []

      assert {:ok, %{products: 1, indexed: 1, removed: 0}} = Indexer.rebuild()
      assert [{_language, "Red Vase"}] = rows(product.uuid)

      assert {:ok, %{indexed: 1, removed: 0}} = Indexer.reindex_items([product.uuid])
      assert [{_language, "Red Vase"}] = rows(product.uuid)
    end
  end

  describe "rebuild/0" do
    test "indexes every listed product and removes rows nobody owns any more" do
      listed = legacy_product!(%{"en" => "Listed"})
      _draft = legacy_product!(%{"en" => "Draft"}, %{status: "draft"})

      Repo.query!(
        """
        INSERT INTO phoenix_kit_shop_search_index
          (item_uuid, language, title, title_trgm, document, indexed_at)
        VALUES ($1, 'en', 'Ghost', 'ghost', to_tsvector('simple', 'ghost'), now() - interval '1 day')
        """,
        [Ecto.UUID.bingenerate()]
      )

      assert {:ok, %{products: 2, indexed: 1, removed: 1}} = Indexer.rebuild()

      titles = Repo.all(from(e in Entry, select: e.title))
      assert titles == ["Listed"]
      assert [{"en", "Listed"}] = rows(listed.uuid)
    end

    test "upserts in place: the row of a product that stays listed keeps its primary key" do
      product = legacy_product!(%{"en" => "Red Vase"})
      {:ok, _} = Indexer.reindex_items([product.uuid])
      before = Repo.one!(from(e in Entry, where: e.item_uuid == ^product.uuid, select: e.uuid))

      {:ok, _} = Shop.update_product(product, %{title: %{"en" => "Red Bowl"}})
      assert {:ok, %{indexed: 1, removed: 0}} = Indexer.rebuild()

      after_rebuild =
        Repo.one!(
          from(e in Entry, where: e.item_uuid == ^product.uuid, select: {e.uuid, e.title})
        )

      assert after_rebuild == {before, "Red Bowl"}
    end

    test "on an empty shop it empties the index (the shop really is empty)" do
      Repo.query!(
        """
        INSERT INTO phoenix_kit_shop_search_index
          (item_uuid, language, title, title_trgm, document, indexed_at)
        VALUES ($1, 'en', 'Ghost', 'ghost', to_tsvector('simple', 'ghost'), now() - interval '1 day')
        """,
        [Ecto.UUID.bingenerate()]
      )

      assert {:ok, %{products: 0, indexed: 0, removed: 1}} = Indexer.rebuild()
    end
  end

  describe "empty?/0" do
    test "is true until a row is written, which every enabled language gets" do
      enable_languages!(["en", "de"])
      assert Indexer.empty?()

      product = legacy_product!(%{"en" => "Red Vase"})
      {:ok, _} = Indexer.reindex_items([product.uuid])

      refute Indexer.empty?()

      languages =
        Repo.all(from(e in Entry, group_by: e.language, select: {e.language, count(e.uuid)}))

      assert Map.new(languages) == %{"en" => 1, "de" => 1}
    end
  end
end
