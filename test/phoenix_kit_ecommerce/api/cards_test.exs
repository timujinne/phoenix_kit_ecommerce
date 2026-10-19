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
  alias PhoenixKitEcommerce.API.Public.Schemas
  alias PhoenixKitEcommerce.Options

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

  describe "the price of an option value" do
    defp priced_vase(extra_metadata \\ %{}) do
      vase(%{
        metadata:
          Map.merge(
            %{
              "_option_values" => %{"size" => ["Large", "Small"], "colour" => ["Red"]},
              "_option_labels" => %{"size" => "Size", "colour" => "Colour"},
              "_price_modifiers" => %{"size" => %{"Large" => "10.00", "Small" => "0"}}
            },
            extra_metadata
          )
      })
    end

    defp finish_option do
      %{
        "key" => "finish",
        "label" => "Finish",
        "type" => "select",
        "options" => ["Matt", "Gloss"],
        "affects_price" => true,
        "modifier_type" => "percent",
        "price_modifiers" => %{"Matt" => "0", "Gloss" => "20"}
      }
    end

    defp global_finish!, do: {:ok, _} = Options.update_global_options([finish_option()])

    defp option(card, key), do: Enum.find(card["options"], &(&1["key"] == key))

    # A Legacy product: no value labels or slugs, so every key is a slugified label.
    defp many_sizes(count) do
      values = for n <- 1..count, do: "Size #{n}"

      {product, _root, _leaf} =
        priced_vase(%{
          "_option_values" => %{"size" => values},
          "_price_modifiers" => %{
            "size" => Map.new(Enum.with_index(values, 1), fn {v, n} -> {v, "#{n}.00"} end)
          }
        })

      {product, values}
    end

    test "an option that affects the price gives each value the product's price with it chosen",
         %{context: context} do
      {product, _root, _leaf} = priced_vase()

      card = Cards.card(record(product), context)

      assert %{"affects_price" => true, "values" => values} = option(card, "size")

      assert values == [
               %{
                 "key" => "large",
                 "label" => "Large",
                 "price" => %{"amount" => "30.00", "currency" => "USD"}
               },
               %{
                 "key" => "small",
                 "label" => "Small",
                 "price" => %{"amount" => "20.00", "currency" => "USD"}
               }
             ]

      assert card["price"] == %{"amount" => "20.00", "currency" => "USD"}
    end

    test "an option that does not affect the price has no price on its values",
         %{context: context} do
      {product, _root, _leaf} = priced_vase()

      assert %{"affects_price" => false, "values" => [value]} =
               option(Cards.card(record(product), context), "colour")

      assert value == %{"key" => "red", "label" => "Red"}
    end

    test "prices are in the response currency", %{} do
      {product, _root, _leaf} = priced_vase()

      card = Cards.card(record(product), context("en", %{"currency" => "EUR"}))

      assert [%{"price" => large}, %{"price" => small}] = option(card, "size")["values"]
      assert large == %{"amount" => "27.27", "currency" => "EUR"}
      assert small == %{"amount" => "18.18", "currency" => "EUR"}
    end

    test "a percent modifier is a price too, and each value is priced on its own",
         %{context: context} do
      {product, _root, _leaf} =
        priced_vase(%{
          "_option_values" => %{"size" => ["Large", "Small"], "finish" => ["Matt", "Gloss"]},
          "_price_modifiers" => %{
            "size" => %{"Large" => "10.00", "Small" => "0"},
            "finish" => %{"Gloss" => %{"type" => "percent", "value" => "20"}, "Matt" => "0"}
          }
        })

      card = Cards.card(record(product), context)

      prices = Map.new(option(card, "finish")["values"], &{&1["key"], &1["price"]})
      %{"gloss" => gloss, "matt" => matt} = prices

      assert gloss == %{"amount" => "24.00", "currency" => "USD"}
      assert matt == %{"amount" => "20.00", "currency" => "USD"}

      # Not the 36.00 of Large with Gloss: one value of one option at a time.
      assert [%{"price" => %{"amount" => "30.00"}} | _] = option(card, "size")["values"]
    end

    test "a global option with modifiers prices its values although the product carries none",
         %{context: context} do
      global_finish!()

      {product, _root, _leaf} =
        priced_vase(%{
          "_option_values" => %{"size" => ["Large", "Small"], "finish" => ["Matt", "Gloss"]}
        })

      card = Cards.card(record(product), context)

      assert %{"affects_price" => true, "values" => values} = option(card, "finish")

      assert Map.new(values, &{&1["key"], &1["price"]}) == %{
               "gloss" => %{"amount" => "24.00", "currency" => "USD"},
               "matt" => %{"amount" => "20.00", "currency" => "USD"}
             }

      # What the cart charges for the same choice.
      assert Shop.calculate_product_price(product, %{"finish" => "Gloss"}) == Decimal.new("24.00")
      assert Enum.all?(option(card, "size")["values"], &Map.has_key?(&1, "price"))
    end

    test "a category option with modifiers prices its values too", %{context: context} do
      {product, _root, leaf} =
        priced_vase(%{"_option_values" => %{"finish" => ["Matt", "Gloss"]}})

      {:ok, _} = Options.update_category_options(leaf, [finish_option()])

      card = Cards.card(record(product), context)

      assert %{"affects_price" => true, "values" => values} = option(card, "finish")

      assert Map.new(values, &{&1["key"], &1["price"]}) == %{
               "gloss" => %{"amount" => "24.00", "currency" => "USD"},
               "matt" => %{"amount" => "20.00", "currency" => "USD"}
             }
    end

    test "a global option whose modifiers are all zero is not price-affecting", %{
      context: context
    } do
      {:ok, _} =
        Options.update_global_options([
          %{finish_option() | "price_modifiers" => %{"Matt" => "0", "Gloss" => "0"}}
        ])

      {product, _root, _leaf} =
        priced_vase(%{"_option_values" => %{"finish" => ["Matt", "Gloss"]}})

      card = Cards.card(record(product), context)

      assert %{"affects_price" => false, "values" => values} = option(card, "finish")
      refute Enum.any?(values, &Map.has_key?(&1, "price"))
    end

    test "a global option the product has no values for is not announced or priced",
         %{context: context} do
      global_finish!()
      {product, _root, _leaf} = priced_vase()

      card = Cards.card(record(product), context)

      assert option(card, "finish") == nil
      assert option(card, "size")["affects_price"] == true
    end

    test "many values of a priced option are priced by the cart's own sum, one by one",
         %{context: context} do
      {product, values} = many_sizes(60)

      card = Cards.card(record(product), context)
      announced = option(card, "size")["values"]

      assert length(announced) == 60

      for {value, index} <- Enum.with_index(values, 1) do
        entry = Enum.find(announced, &(&1["label"] == value))
        expected = Shop.calculate_product_price(product, %{"size" => value})

        assert entry["price"]["amount"] == Decimal.to_string(expected, :normal)
        assert expected == Decimal.add(Decimal.new("20.00"), index)
      end
    end

    test "pricing the values of an option slugifies each value a bounded number of times",
         %{context: context} do
      {product, _values} = many_sizes(60)
      record = record(product)
      mfa = {PhoenixKit.Utils.Slug, :slugify, 2}

      :erlang.trace_pattern(mfa, true, [:call_count])

      try do
        Cards.card(record, context)
        {:call_count, calls} = :erlang.trace_info(mfa, :call_count)

        # About two a value (the announced key, the stored value's key). Working
        # a key back to its stored value one value at a time is 60 x 60.
        assert calls <= 5 * 60
      after
        :erlang.trace_pattern(mfa, false, [:call_count])
      end
    end

    test "values keyed by the catalogue's own keys are priced the same way", %{context: context} do
      keys = for n <- 1..60, do: "v#{n}"

      {product, _root, _leaf} =
        priced_vase(%{
          "_option_values" => %{"size" => keys},
          "_value_labels" => %{"size" => Map.new(keys, &{&1, "Size #{&1}"})},
          "_price_modifiers" => %{
            "size" => Map.new(Enum.with_index(keys, 1), fn {key, n} -> {key, "#{n}.00"} end)
          }
        })

      announced = option(Cards.card(record(product), context), "size")["values"]

      assert length(announced) == 60
      assert Enum.all?(announced, &Map.has_key?(&1, "price"))

      for %{"key" => key, "price" => %{"amount" => amount}} <- announced do
        expected = Shop.calculate_product_price(product, %{"size" => key})
        assert amount == Decimal.to_string(expected, :normal)
      end
    end

    test "two stored values that share a key are priced as the first, which is the one announced",
         %{context: context} do
      {product, _root, _leaf} =
        priced_vase(%{
          "_option_values" => %{"size" => ["A b", "a-b"]},
          "_price_modifiers" => %{"size" => %{"A b" => "5.00", "a-b" => "9.00"}}
        })

      assert %{"values" => [%{"label" => "A b", "price" => price}]} =
               option(Cards.card(record(product), context), "size")

      assert price == %{"amount" => "25.00", "currency" => "USD"}
    end

    test "a card built from a lookup that read no schemas prices the same",
         %{context: context} do
      global_finish!()

      {product, _root, _leaf} =
        priced_vase(%{"_option_values" => %{"finish" => ["Matt", "Gloss"]}})

      record = record(product)
      lookup = Cards.lookup([record], keys: ["id"])

      assert Cards.card(record, context, lookup: lookup) == Cards.card(record, context)

      assert %{"affects_price" => true} =
               option(Cards.card(record, context, lookup: lookup), "finish")
    end

    test "a product priced on request quotes no price per value", %{context: context} do
      {product, _root, _leaf} =
        priced_vase(%{"_price_display" => %{"on_request" => true}})

      for value <- option(Cards.card(record(product), context), "size")["values"] do
        refute Map.has_key?(value, "price")
      end
    end

    test "the card's schema describes the price as money" do
      value = Schemas.card()["properties"]["options"]["items"]["properties"]["values"]["items"]

      price = value["properties"]["price"]

      assert Map.delete(price, "description") == Schemas.money()
      assert price["description"] =~ "only this value chosen"

      assert Schemas.card()["properties"]["options"]["items"]["properties"]["affects_price"][
               "description"
             ] =~ "global or category"

      assert value["required"] == ["key", "label"]
    end
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
