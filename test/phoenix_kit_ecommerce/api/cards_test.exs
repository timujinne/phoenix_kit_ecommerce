defmodule PhoenixKitEcommerce.API.CardsTest do
  @moduledoc """
  The three shapes a product takes in a public answer: list item, full card,
  stub. `async: false`: Billing's currency cache is node-global.
  """
  use PhoenixKitEcommerce.DataCase, async: false

  import PhoenixKitEcommerce.SearchFixtures

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.API.Cards
  alias PhoenixKitEcommerce.API.Context
  alias PhoenixKitEcommerce.API.Loader

  setup do
    disable_languages!()
    currencies!()
    %{context: context("en")}
  end

  defp context(language, input \\ %{}) do
    {:ok, context} =
      Context.build(input, %{
        language: language,
        currency: nil,
        hosts: ["shop.test"],
        base_url: "https://shop.test",
        actor: nil,
        request_id: nil
      })

    context
  end

  defp record(product), do: Loader.load([product.uuid])[product.uuid]

  defp vase(attrs \\ %{}) do
    root = legacy_category!(%{"en" => "Home"})
    leaf = legacy_category!(%{"en" => "Vases"}, %{parent_uuid: root.uuid})

    product =
      legacy_product!(
        %{"en" => "Red Vase"},
        Map.merge(
          %{
            category_uuid: leaf.uuid,
            vendor: "Acme",
            price: "20.00",
            compare_at_price: "25.00",
            made_to_order: true,
            images: [%{"src" => "https://cdn.example/red.jpg"}]
          },
          attrs
        )
      )

    {product, root, leaf}
  end

  test "list_item/2 carries the list item fields", %{context: context} do
    {product, root, leaf} = vase()
    item = Cards.list_item(record(product), context)

    assert item["id"] == product.uuid
    assert item["title"] == "Red Vase"
    assert is_binary(item["slug"])
    assert item["url"] == "https://shop.test" <> Shop.product_url(product, "en")
    assert item["price"] == %{"amount" => "20.00", "currency" => "USD"}
    assert item["compare_at"] == %{"amount" => "25.00", "currency" => "USD"}
    assert item["discount_pct"] == 20
    assert item["price_on_request"] == false
    assert item["made_to_order"] == true
    assert item["vendor"] == "Acme"
    assert item["product_type"] == "physical"
    assert item["status"] == "active"
    assert item["image"] == "https://cdn.example/red.jpg"

    assert item["category_path"] == [
             %{"id" => root.uuid, "name" => "Home"},
             %{"id" => leaf.uuid, "name" => "Vases"}
           ]

    # No option changes the price here, so there is no "from" price; nothing is nil.
    refute Map.has_key?(item, "price_from")
    assert Enum.all?(item, fn {_key, value} -> value != nil end)
    assert Map.keys(item) -- Cards.list_fields() == []
  end

  test "prices are converted into the response currency; the discount is not currency-dependent" do
    {product, _root, _leaf} = vase()
    item = Cards.list_item(record(product), context("en", %{"currency" => "EUR"}))

    assert item["price"] == %{"amount" => "18.18", "currency" => "EUR"}
    assert item["compare_at"] == %{"amount" => "22.73", "currency" => "EUR"}
    assert item["discount_pct"] == 20
  end

  test "a discount that is not a whole percent is rounded to one, up and down", %{
    context: context
  } do
    for {price, compare_at, expected} <- [
          {"5.00", "7.00", 29},
          {"6.00", "7.00", 14},
          {"2.00", "3.00", 33},
          {"1.00", "3.00", 67}
        ] do
      product =
        legacy_product!(%{"en" => "Vase #{price}"}, %{price: price, compare_at_price: compare_at})

      assert Cards.list_item(record(product), context)["discount_pct"] == expected,
             "#{price} against #{compare_at}"
    end
  end

  test "a product without a sale price has neither compare_at nor discount_pct", %{
    context: context
  } do
    {product, _root, _leaf} = vase(%{compare_at_price: "20.00"})
    item = Cards.list_item(record(product), context)

    refute Map.has_key?(item, "compare_at")
    refute Map.has_key?(item, "discount_pct")
  end

  test "price on request shows no price at all", %{context: context} do
    {product, _root, _leaf} = vase(%{metadata: %{"_price_display" => %{"on_request" => true}}})
    item = Cards.list_item(record(product), context)

    assert item["price_on_request"] == true

    for key <- ["price", "price_from", "compare_at", "discount_pct"] do
      refute Map.has_key?(item, key), "#{key} must be hidden"
    end
  end

  test "price_from/3 is the lowest price only when options change the price", %{context: context} do
    ten = Decimal.new("10")
    twenty = Decimal.new("20")

    assert Cards.price_from(context, ten, ten) == nil
    assert Cards.price_from(context, ten, twenty) == %{"amount" => "10.00", "currency" => "USD"}
  end

  test "card/3 adds the text description, tags, options and images", %{context: context} do
    {product, _root, _leaf} =
      vase(%{
        body_html: %{"en" => "<p>Hello <b>world</b></p>"},
        tags: ["gift", "ceramic"],
        metadata: %{
          "_option_values" => %{"size" => ["Large", "Small"]},
          "_option_labels" => %{"size" => "Size"}
        }
      })

    card = Cards.card(record(product), context)

    assert card["description"] == "Hello world"
    assert card["tags"] == ["gift", "ceramic"]
    assert card["images"] == ["https://cdn.example/red.jpg"]

    assert card["options"] == [
             %{
               "key" => "size",
               "label" => "Size",
               "affects_price" => false,
               "values" => [
                 %{"key" => "large", "label" => "Large"},
                 %{"key" => "small", "label" => "Small"}
               ]
             }
           ]

    assert card["title"] == "Red Vase"
  end

  test "card/3 can return the description as Markdown", %{context: context} do
    {product, _root, _leaf} = vase(%{body_html: %{"en" => "<p>Hello <b>world</b></p>"}})

    card = Cards.card(record(product), context, format: "markdown")

    assert card["description"] =~ "**world**"
    refute card["description"] =~ "<b>"
  end

  test "card/3 cuts the Markdown description to the same limit as the text one", %{
    context: context
  } do
    {product, _root, _leaf} =
      vase(%{body_html: %{"en" => "<p>" <> String.duplicate("word ", 5_000) <> "</p>"}})

    description = Cards.card(record(product), context, format: "markdown")["description"]

    assert String.length(description) <= 4_000
    assert String.length(description) > 3_900
  end

  test "card/3 text format is plain text also when the stored body is Markdown (Catalogue source)",
       %{
         context: context
       } do
    {product, _root, _leaf} =
      vase(%{body_html: %{"en" => "A **bold** vase\n\n- item one\n- item two"}})

    description = Cards.card(record(product), context)["description"]

    assert description == "A bold vase item one item two"
    refute description =~ "**"
  end

  test "category_path names active categories only: an unlisted ancestor is not exposed", %{
    context: context
  } do
    root = legacy_category!(%{"en" => "Secret Parent"}, %{status: "unlisted"})
    leaf = legacy_category!(%{"en" => "Visible Child"}, %{parent_uuid: root.uuid})
    product = legacy_product!(%{"en" => "Quiet Vase"}, %{category_uuid: leaf.uuid})

    item = Cards.list_item(record(product), context)

    assert Enum.map(item["category_path"], & &1["name"]) == ["Visible Child"]
  end

  @tag :requires_core_canonical_urls
  test "list_item/2 puts the url on the domain of the language of the answer" do
    enable_languages!(["en-US", "de-DE"])
    put_canonical_host_resolver!()
    product = legacy_product!(%{"en-US" => "Red Vase", "de-DE" => "Rote Vase"})
    record = record(product)

    german = context("de-DE")
    url = Context.with_request_currency(german, fn -> Cards.list_item(record, german)["url"] end)

    assert url == "https://shop.example.de/shop/product/#{Cards.link_slug(product, "de-DE")}"

    english = context("en-US")

    url =
      Context.with_request_currency(english, fn -> Cards.list_item(record, english)["url"] end)

    assert url == "https://shop.test" <> Shop.product_url(product, "en-US")
  end

  @tag :requires_core_canonical_urls
  test "list_item/2 takes the domain from the answer's language, not the request's default" do
    enable_languages!(["en-US", "de-DE"])
    put_canonical_host_resolver!()
    product = legacy_product!(%{"en-US" => "Red Vase", "de-DE" => "Rote Vase"})
    asked_in_german = context("en-US", %{"language" => "de-DE"})

    assert asked_in_german.language == "de-DE"
    assert asked_in_german.default_language == "en-US"

    url =
      Context.with_request_currency(asked_in_german, fn ->
        Cards.list_item(record(product), asked_in_german)["url"]
      end)

    assert url == "https://shop.example.de/shop/product/#{Cards.link_slug(product, "de-DE")}"
  end

  test "list_item/2 leaves out url and slug when the product has no slug", %{context: context} do
    {product, _root, _leaf} = vase()
    record = record(product)
    record = %{record | product: %{record.product | slug: %{}}}

    item = Cards.list_item(record, context)

    refute Map.has_key?(item, "slug")
    refute Map.has_key?(item, "url")
    assert item["id"] == product.uuid
    assert item["title"] == "Red Vase"
  end

  test "card/3 falls back to the short description when there is no body", %{context: context} do
    {product, _root, _leaf} = vase(%{description: %{"en" => "A short text"}})

    assert Cards.card(record(product), context)["description"] == "A short text"
  end

  test "stub/2 is exactly id, title and a discontinued status", %{context: context} do
    {product, _root, _leaf} = vase(%{status: "archived"})
    record = record(product)

    assert record.state == :discontinued

    assert Cards.stub(record, context) == %{
             "id" => product.uuid,
             "title" => "Red Vase",
             "status" => "discontinued"
           }
  end

  test "every shape is plain JSON: no Decimal, DateTime or struct inside", %{context: context} do
    {product, _root, _leaf} = vase(%{tags: ["gift"], body_html: %{"en" => "<p>x</p>"}})
    record = record(product)

    for shape <- [
          Cards.list_item(record, context),
          Cards.card(record, context),
          Cards.stub(record, context)
        ] do
      assert shape == shape |> JSON.encode!() |> JSON.decode!()
    end
  end

  test "a huge stored description is cut before it is converted to Markdown", %{context: context} do
    product =
      legacy_product!(%{"en" => "Big"}, %{
        body_html: %{"en" => String.duplicate("<p><b>", 100_000)}
      })

    {:reductions, before} = Process.info(self(), :reductions)
    card = Cards.card(record(product), context, format: "markdown")
    {:reductions, after_} = Process.info(self(), :reductions)

    assert is_map(card)
    # Converting all 600,000 characters costs about 120 million; the cut input, about 1.5 million.
    assert after_ - before < 15_000_000
  end

  test "script, style and inline pictures do not use up the Markdown cut", %{context: context} do
    body =
      "<p>Head</p><script>" <>
        String.duplicate("x", 50_000) <>
        "</script><p>Tail <img src=\"data:image/png;base64," <>
        String.duplicate("A", 50_000) <> "\"></p>"

    product = legacy_product!(%{"en" => "Heavy"}, %{body_html: %{"en" => body}})

    card = Cards.card(record(product), context, format: "markdown")

    assert card["description"] =~ "Head"
    assert card["description"] =~ "Tail"
  end
end
