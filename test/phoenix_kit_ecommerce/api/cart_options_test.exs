defmodule PhoenixKitEcommerce.API.CartOptionsTest do
  @moduledoc """
  `{attribute_key, value_key}` <-> `selected_specs`. The keys are the ones the
  product card announces (`Search.OptionKeys`): the Legacy source is exercised
  with real products (the value key is the slugified label), the catalogue
  source's slugs with hand-built view-structs (no catalogue needed: the mapping
  lives in `product.metadata["_value_slugs"]`).
  """

  use PhoenixKitEcommerce.DataCase, async: false

  import PhoenixKitEcommerce.CartApiFixtures

  alias PhoenixKitEcommerce.API.CartOptions
  alias PhoenixKitEcommerce.CartItem
  alias PhoenixKitEcommerce.Product
  alias PhoenixKitEcommerce.Search.OptionKeys

  defp opts(pairs), do: Enum.map(pairs, fn {k, v} -> %{attribute_key: k, value_key: v} end)

  defp slug_product(color_labels_to_slugs) do
    %Product{
      uuid: Ecto.UUID.generate(),
      status: "active",
      metadata: %{
        "_option_values" => %{"color" => Map.keys(color_labels_to_slugs) |> Enum.sort()},
        "_value_slugs" => %{"color" => color_labels_to_slugs}
      }
    }
  end

  describe "normalize/1" do
    test "accepts string-keyed and atom-keyed maps, sorted by attribute key" do
      assert CartOptions.normalize([
               %{"attribute_key" => "size", "value_key" => "M"},
               %{attribute_key: "color", value_key: "red"}
             ]) == {:ok, opts([{"color", "red"}, {"size", "M"}])}

      assert CartOptions.normalize(nil) == {:ok, []}
      assert CartOptions.normalize([]) == {:ok, []}
    end

    test "rejects anything that is not a list of complete pairs of non-empty strings" do
      for bad <- [
            "color",
            %{},
            [%{"attribute_key" => "color"}],
            [%{"attribute_key" => "", "value_key" => "red"}],
            [%{"attribute_key" => "color", "value_key" => 3}],
            [%{"attribute_key" => "color", "value_key" => "red"}, "size"],
            [nil]
          ] do
        assert CartOptions.normalize(bad) == :error, "accepted #{inspect(bad)}"
      end
    end
  end

  describe "to_specs/2 under the Legacy source (the value key is the slugified label)" do
    setup do
      %{product: product_with_options!(%{"color" => ["Red", "Blue"], "size" => ["S", "M", "L"]})}
    end

    # The seam with the product card: the keys `shop.get_products` announces
    # are the keys this module accepts, for a label with a capital, a space or a colon.
    test "accepts every key the product card announces" do
      product =
        product_with_options!(%{"colour name" => ["Light Red"], "size:eu" => ["Large", "Small"]})

      announced =
        for option <- OptionKeys.extract(product),
            do: %{attribute_key: option.key, value_key: hd(option.values).key}

      assert length(announced) == 2

      assert {:ok, %{"colour name" => "Light Red", "size:eu" => "Large"}} =
               CartOptions.to_specs(product, announced)

      assert CartOptions.to_options(product, %{"colour name" => "Light Red", "size:eu" => "Large"}) ==
               Enum.sort_by(announced, & &1.attribute_key)
    end

    test "maps every pair to its label", %{product: product} do
      assert {:ok, %{"color" => "Red", "size" => "M"}} =
               CartOptions.to_specs(product, opts([{"color", "red"}, {"size", "m"}]))
    end

    test "a missing required option names the attribute and the values on offer", %{
      product: product
    } do
      assert {:error, :option_required, %{attribute_key: "size", allowed: ["s", "m", "l"]}} =
               CartOptions.to_specs(product, opts([{"color", "blue"}]))
    end

    test "a value the product does not offer lists the ones it does", %{product: product} do
      assert {:error, :option_invalid,
              %{attribute_key: "color", value_key: "green", allowed: ["red", "blue"]}} =
               CartOptions.to_specs(product, opts([{"color", "green"}, {"size", "s"}]))
    end

    test "an attribute the product does not have lists the ones it has", %{product: product} do
      assert {:error, :option_invalid,
              %{attribute_key: "weight", allowed_attribute_keys: ["color", "size"]}} =
               CartOptions.to_specs(product, opts([{"weight", "heavy"}]))
    end

    test "the same attribute twice is refused", %{product: product} do
      assert {:error, :option_invalid,
              %{attribute_key: "color", reason: "duplicate_attribute_key"}} =
               CartOptions.to_specs(
                 product,
                 opts([{"color", "red"}, {"color", "blue"}, {"size", "s"}])
               )
    end
  end

  describe "to_specs/2 for a product without options" do
    test "accepts no options and refuses an invented one" do
      product = product!()

      assert {:ok, %{}} = CartOptions.to_specs(product, [])

      assert {:error, :option_invalid, %{attribute_key: "color"}} =
               CartOptions.to_specs(product, opts([{"color", "red"}]))
    end
  end

  describe "to_specs/2 and to_options/2 under the catalogue source (value keys are slugs)" do
    test "maps slugs to the labels of the product's language and back" do
      german = slug_product(%{"Rot" => "red", "Blau" => "blue"})

      assert {:ok, %{"color" => "Rot"}} = CartOptions.to_specs(german, opts([{"color", "red"}]))
      assert CartOptions.to_options(german, %{"color" => "Rot"}) == opts([{"color", "red"}])
    end

    test "a label is not a value key" do
      german = slug_product(%{"Rot" => "red", "Blau" => "blue"})

      assert {:error, :option_invalid,
              %{attribute_key: "color", value_key: "Rot", allowed: ["blue", "red"]}} =
               CartOptions.to_specs(german, opts([{"color", "Rot"}]))
    end

    test "the same neutral options read back identically in another language" do
      german = slug_product(%{"Rot" => "red", "Blau" => "blue"})
      french = slug_product(%{"Rouge" => "red", "Bleu" => "blue"})

      {:ok, specs_de} = CartOptions.to_specs(german, opts([{"color", "red"}]))
      {:ok, specs_fr} = CartOptions.to_specs(french, opts([{"color", "red"}]))

      assert specs_de == %{"color" => "Rot"}
      assert specs_fr == %{"color" => "Rouge"}
      assert CartOptions.to_options(german, specs_de) == CartOptions.to_options(french, specs_fr)
    end

    test "only the values the product itself offers are valid, though the set has more" do
      product = %Product{
        uuid: Ecto.UUID.generate(),
        status: "active",
        metadata: %{
          "_option_values" => %{"color" => ["Rot"]},
          "_value_slugs" => %{"color" => %{"Rot" => "red", "Blau" => "blue"}}
        }
      }

      assert {:error, :option_invalid, %{allowed: ["red"]}} =
               CartOptions.to_specs(product, opts([{"color", "blue"}]))
    end
  end

  describe "to_specs/2 and to_options/2 under the catalogue source with keyed values" do
    defp keyed_product(language_labels) do
      %Product{
        uuid: Ecto.UUID.generate(),
        status: "active",
        metadata: %{
          "_option_values" => %{"color" => ["red", "blue"]},
          "_value_labels" => %{"color" => language_labels},
          "_value_slugs" =>
            Map.new(%{"color" => Map.new(language_labels, fn {k, l} -> {l, k} end)})
        }
      }
    end

    test "the value key is stored as it is, in every language" do
      german = keyed_product(%{"red" => "Rot", "blue" => "Blau"})
      french = keyed_product(%{"red" => "Rouge", "blue" => "Bleu"})

      assert {:ok, %{"color" => "red"}} = CartOptions.to_specs(german, opts([{"color", "red"}]))
      assert {:ok, %{"color" => "red"}} = CartOptions.to_specs(french, opts([{"color", "red"}]))
      assert CartOptions.to_options(french, %{"color" => "red"}) == opts([{"color", "red"}])
    end

    test "a label is not a value key" do
      german = keyed_product(%{"red" => "Rot", "blue" => "Blau"})

      assert {:error, :option_invalid, %{value_key: "Rot", allowed: ["red", "blue"]}} =
               CartOptions.to_specs(german, opts([{"color", "Rot"}]))
    end

    test "a line stored with the label of its language reads back as the value key" do
      french = keyed_product(%{"red" => "Rouge", "blue" => "Bleu"})

      assert CartOptions.to_options(french, %{"color" => "Rouge"}) == opts([{"color", "red"}])
    end
  end

  describe "from_item/2" do
    test "prefers the neutral options stored on the line" do
      item = %CartItem{
        selected_specs: %{"color" => "Rot"},
        metadata: %{"api_options" => [%{"attribute_key" => "color", "value_key" => "red"}]}
      }

      assert CartOptions.from_item(item, nil) == opts([{"color", "red"}])
      assert CartOptions.stored(item) == opts([{"color", "red"}])
    end

    test "without stored options it maps the labels through the product, else through the key rule alone" do
      item = %CartItem{selected_specs: %{"color" => "Rot"}, metadata: %{}}
      german = slug_product(%{"Rot" => "red", "Blau" => "blue"})

      assert CartOptions.from_item(item, german) == opts([{"color", "red"}])
      assert CartOptions.from_item(item, nil) == opts([{"color", "rot"}])
      assert CartOptions.stored(item) == []
    end

    test "a line without options has none" do
      assert CartOptions.from_item(%CartItem{selected_specs: %{}, metadata: nil}, nil) == []
    end
  end

  describe "labelled/3" do
    defp labelled_product do
      %Product{
        uuid: Ecto.UUID.generate(),
        status: "active",
        metadata: %{
          "_option_values" => %{"size" => ["5-inches-13-cm", "10-inches-25-cm"]},
          "_option_labels" => %{"size" => "Größe"},
          "_value_labels" => %{
            "size" => %{"5-inches-13-cm" => "5 Zoll (13 cm)", "10-inches-25-cm" => "10 Zoll"}
          }
        }
      }
    end

    test "adds the option's name and the value's label from the product's own options" do
      assert CartOptions.labelled(opts([{"size", "5-inches-13-cm"}]), labelled_product()) == [
               %{
                 attribute_key: "size",
                 value_key: "5-inches-13-cm",
                 attribute_label: "Größe",
                 value_label: "5 Zoll (13 cm)"
               }
             ]
    end

    test "a legacy product's value is its own label" do
      product = %Product{
        uuid: Ecto.UUID.generate(),
        status: "active",
        metadata: %{"_option_values" => %{"cup_color" => ["Red Gold"]}}
      }

      assert [%{attribute_label: "Cup Color", value_label: "Red Gold"}] =
               CartOptions.labelled(opts([{"cup_color", "red-gold"}]), product)
    end

    test "a line whose product is gone keeps the name from its key and the value it stored" do
      options = opts([{"size", "5-inches-13-cm"}])

      assert [%{attribute_label: "Size", value_label: "5 inches"}] =
               CartOptions.labelled(options, nil, %{"size" => "5 inches"})

      assert [%{attribute_label: "Size", value_label: "5-inches-13-cm"}] =
               CartOptions.labelled(options, nil)
    end

    test "a value the product no longer offers falls back the same way" do
      options = opts([{"size", "20-inches"}])

      assert [%{attribute_label: "Größe", value_label: "20 Zoll"}] =
               CartOptions.labelled(options, labelled_product(), %{"size" => "20 Zoll"})
    end

    test "matches the stored value by the neutral key of its attribute" do
      options = opts([{"a_b", "x"}])

      assert [%{value_label: "X!"}] = CartOptions.labelled(options, nil, %{"a:b" => "X!"})
    end
  end

  describe "stored_form/1 and canonical/1" do
    test "store string keys, compare as sorted pairs" do
      options = opts([{"size", "M"}, {"color", "red"}])

      assert CartOptions.stored_form(options) == [
               %{"attribute_key" => "size", "value_key" => "M"},
               %{"attribute_key" => "color", "value_key" => "red"}
             ]

      assert CartOptions.canonical(options) == [["color", "red"], ["size", "M"]]
    end
  end
end
