defmodule PhoenixKitEcommerce.Search.DocumentTest do
  @moduledoc """
  `Search.Document.build/2` on hand-built records. Needs the database only for
  the settings reads inside `Translations` (default language, name prefixes).
  """
  use PhoenixKitEcommerce.DataCase, async: true

  import PhoenixKitEcommerce.SearchFixtures

  alias PhoenixKitEcommerce.API.Facts
  alias PhoenixKitEcommerce.API.Record
  alias PhoenixKitEcommerce.Category
  alias PhoenixKitEcommerce.Product
  alias PhoenixKitEcommerce.Search.Document

  # Languages off: the default language is "en", which the fallback test relies on.
  setup do
    disable_languages!()
    :ok
  end

  @root Ecto.UUID.generate()
  @mid Ecto.UUID.generate()
  @leaf Ecto.UUID.generate()

  defp category(uuid, names, parent),
    do: struct(Category, uuid: uuid, name: names, parent_uuid: parent, status: "active")

  defp chain do
    [
      category(@root, %{"en" => "Home", "de" => "Heim"}, nil),
      category(@leaf, %{"en" => "Vases", "de" => "Vasen"}, @root)
    ]
  end

  defp record(overrides \\ %{}, chain \\ chain()) do
    product =
      struct(
        Product,
        Map.merge(
          %{
            uuid: Ecto.UUID.generate(),
            title: %{"en" => "Red Vase", "de" => "Rote Vase"},
            description: %{"en" => "A <b>red</b> vase"},
            body_html: %{},
            vendor: "Acme",
            tags: ["ceramic", "gift"],
            price: Decimal.new("20.00"),
            compare_at_price: Decimal.new("25.00"),
            made_to_order: true,
            metadata: %{
              "_option_values" => %{"size" => ["Large", "Small"]},
              "_value_slugs" => %{"size" => %{"Large" => "large"}},
              "_option_labels" => %{"size" => "Size"}
            },
            inserted_at: ~U[2026-01-02 03:04:05Z]
          },
          overrides
        )
      )

    %Record{
      id: product.uuid,
      product: product,
      facts: %Facts{item_status: "active", shop_status: "active", position: 3},
      state: :listed,
      category: List.last(chain),
      chain: chain
    }
  end

  test "builds the row of a product in a language" do
    record = record()
    row = Document.build(record, "en")

    assert row.item_uuid == record.id
    assert row.language == "en"
    assert row.regconfig == "english"
    assert row.title == "Red Vase"
    assert row.vendor == "Acme"
    assert row.tags == ["ceramic", "gift"]
    assert row.made_to_order == true
    assert row.sort_position == 3
    assert row.item_inserted_at == ~U[2026-01-02 03:04:05Z]
    assert Decimal.equal?(row.price, Decimal.new("20.00"))
  end

  test "the text parts carry the weights: vendor, tags and categories in B; options in C; the description in D" do
    row = Document.build(record(), "en")

    assert row.text_b == "Acme ceramic gift Home Vases"
    assert row.text_c == "Large Size Small"
    assert row.text_d == "A red vase"
  end

  test "the description is plain text from HTML and from Markdown (the Catalogue source stores Markdown)" do
    html = Document.build(record(%{body_html: %{"en" => "<p>A <b>red</b> vase</p>"}}), "en")
    assert html.text_d == "A red vase"

    markdown =
      Document.build(record(%{body_html: %{"en" => "A **red** vase\n\n- one\n- two"}}), "en")

    assert markdown.text_d == "A red vase one two"
  end

  test "category path, uuids and the leaf category" do
    row = Document.build(record(), "de")

    assert row.category_path == ["Heim", "Vasen"]
    assert row.category_path_uuids == [@root, @leaf]
    assert row.category_uuid == @leaf
    assert row.regconfig == "german"
    assert row.title == "Rote Vase"
  end

  test "a product with no category has an empty path and no category uuid" do
    row = Document.build(record(%{}, []), "en")

    assert row.category_uuid == nil
    assert row.category_path == []
    assert row.category_path_uuids == []
  end

  test "a language the product has no translation for falls back like the storefront does" do
    row = Document.build(record(), "fr-FR")

    assert row.title == "Red Vase"
    assert row.language == "fr-FR"
    assert row.regconfig == "french"
  end

  test "option pairs and labels use the language-neutral value keys" do
    row = Document.build(record(), "en")

    assert row.option_pairs == ["size:large", "size:small"]

    assert row.option_labels == %{
             "size" => "Size",
             "size:large" => "Large",
             "size:small" => "Small"
           }
  end

  test "on_sale and discount_pct come from compare_at_price above the price" do
    row = Document.build(record(), "en")
    assert row.on_sale == true
    assert Decimal.equal?(row.discount_pct, Decimal.new("20.00"))
    assert Decimal.equal?(row.compare_at_price, Decimal.new("25.00"))

    third = Document.build(record(%{compare_at_price: Decimal.new("30.00")}), "en")
    assert Decimal.equal?(third.discount_pct, Decimal.new("33.33"))

    flat = Document.build(record(%{compare_at_price: Decimal.new("20.00")}), "en")
    assert flat.on_sale == false
    assert flat.discount_pct == nil

    cheaper = Document.build(record(%{compare_at_price: Decimal.new("10.00")}), "en")
    assert cheaper.on_sale == false

    free = Document.build(record(%{price: Decimal.new("0")}), "en")
    assert free.on_sale == false
    assert free.discount_pct == nil

    on_request =
      Document.build(
        record(%{metadata: %{"_price_display" => %{"on_request" => true}}}),
        "en"
      )

    assert on_request.price == nil
    assert on_request.compare_at_price == nil
    assert on_request.discount_pct == nil
    assert on_request.on_sale == false

    unpriced = Document.build(record(%{price: nil, compare_at_price: nil}), "en")
    assert unpriced.price == nil
    assert unpriced.on_sale == false
  end

  test "non-finite stored prices do not break an index rebuild" do
    for value <- ["NaN", "Infinity", "-Infinity"] do
      row = Document.build(record(%{compare_at_price: Decimal.new(value)}), "en")
      assert row.compare_at_price == nil
      assert row.on_sale == false
      assert row.discount_pct == nil

      row = Document.build(record(%{price: Decimal.new(value)}), "en")
      assert row.price == nil
      assert row.on_sale == false
      assert row.discount_pct == nil
    end
  end

  test "a product with no title in any language has no document" do
    assert Document.build(record(%{title: %{}}), "en") == nil
    assert Document.build(record(%{title: %{"en" => "   "}}), "en") == nil
  end

  test "missing optional fields become empty values, never nil lists" do
    row =
      Document.build(
        record(%{vendor: " ", tags: nil, description: %{}, body_html: %{}, metadata: nil}),
        "en"
      )

    assert row.vendor == nil
    assert row.tags == []
    assert row.option_pairs == []
    assert row.option_labels == %{}
    assert row.text_d == ""
    assert row.text_b == "Home Vases"
  end

  test "the description is the body when there is one, with tags stripped and length capped" do
    long = String.duplicate("word ", 3_000)
    row = Document.build(record(%{body_html: %{"en" => "<p>Full <i>body</i></p>"}}), "en")
    assert row.text_d == "Full body"

    capped = Document.build(record(%{body_html: %{"en" => long}}), "en")
    assert String.length(capped.text_d) in 4_990..5_000
  end

  test "an inserted_at that is a NaiveDateTime is read as UTC" do
    row = Document.build(record(%{inserted_at: ~N[2026-01-02 03:04:05]}), "en")
    assert row.item_inserted_at == ~U[2026-01-02 03:04:05Z]

    assert Document.build(record(%{inserted_at: nil}), "en").item_inserted_at == nil
  end

  test "the row holds exactly the keys the indexer writes" do
    row = Document.build(record(), "en")

    assert row |> Map.keys() |> Enum.sort() ==
             Enum.sort(~w(item_uuid language regconfig title text_b text_c text_d category_uuid
                          category_path category_path_uuids vendor tags option_pairs option_labels
                          made_to_order on_sale price compare_at_price discount_pct sort_position
                          item_inserted_at)a)
  end

  test "a missing position sorts as 0 and a nil made_to_order is false" do
    record = record(%{made_to_order: nil})
    row = Document.build(%{record | facts: %Facts{record.facts | position: nil}}, "en")

    assert row.sort_position == 0
    assert row.made_to_order == false
  end

  test "tags that are not strings are dropped" do
    assert Document.build(record(%{tags: ["a", 1, nil, "b"]}), "en").tags == ["a", "b"]
  end

  test "a blank value in the requested language falls back like a missing one" do
    row =
      Document.build(
        record(%{
          title: %{"en" => "Red Vase", "de" => ""},
          body_html: %{"en" => "English body", "de" => "  "}
        }),
        "de"
      )

    assert row.title == "Red Vase"
    assert row.text_d == "English body"

    names = [category(@root, %{"en" => "Home", "de" => ""}, nil)]
    assert Document.build(record(%{}, names), "de").category_path == ["Home"]
  end

  test "the description falls through to the short one when the body is blank or has no text" do
    short = %{description: %{"en" => "Short words"}}

    assert Document.build(record(Map.put(short, :body_html, %{"en" => "   "})), "en").text_d ==
             "Short words"

    assert Document.build(record(Map.put(short, :body_html, %{"en" => "<p></p>"})), "en").text_d ==
             "Short words"

    assert Document.build(record(Map.put(short, :body_html, %{"en" => "Body"})), "en").text_d ==
             "Body"
  end

  describe "categories that are not active" do
    defp hidden_chain(status) do
      [
        category(@root, %{"en" => "Home"}, nil),
        %{category(@mid, %{"en" => "Secret"}, @root) | status: status},
        category(@leaf, %{"en" => "Vases"}, @mid)
      ]
    end

    test "a hidden, deleted or unlisted ancestor is neither named, searchable nor listed" do
      for status <- ["hidden", "unlisted", "deleted", "weird"] do
        row = Document.build(record(%{}, hidden_chain(status)), "en")

        assert row.category_path == ["Home", "Vases"]
        assert row.category_path_uuids == [@root, @leaf]
        assert row.category_uuid == @leaf
        refute row.text_b =~ "Secret"
        assert row.text_b == "Acme ceramic gift Home Vases"
      end
    end

    test "the product's own unlisted category is not exposed either" do
      chain = [
        category(@root, %{"en" => "Home"}, nil),
        %{category(@leaf, %{"en" => "Vases"}, @root) | status: "unlisted"}
      ]

      row = Document.build(record(%{}, chain), "en")

      assert row.category_path == ["Home"]
      assert row.category_path_uuids == [@root]
      assert row.category_uuid == @root
    end
  end
end
