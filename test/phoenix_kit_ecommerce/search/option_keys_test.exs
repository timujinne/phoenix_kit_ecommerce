defmodule PhoenixKitEcommerce.Search.OptionKeysTest do
  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.Product
  alias PhoenixKitEcommerce.Search.OptionKeys

  defp product(metadata), do: struct(Product, metadata: metadata)

  test "reads keys, labels, value keys and the price flag from the metadata" do
    options =
      OptionKeys.extract(
        product(%{
          "_option_values" => %{"size" => ["Large", "Small"], "colour" => ["Red"]},
          "_value_slugs" => %{"size" => %{"Large" => "l-size"}},
          "_option_labels" => %{"size" => "Size"},
          "_price_modifiers" => %{"size" => %{"Large" => "5.00"}}
        })
      )

    assert options == [
             %{
               key: "colour",
               label: "Colour",
               affects_price: false,
               values: [%{key: "red", label: "Red"}]
             },
             %{
               key: "size",
               label: "Size",
               affects_price: true,
               values: [%{key: "l-size", label: "Large"}, %{key: "small", label: "Small"}]
             }
           ]
  end

  test "a value without a slug entry is slugified; an unromanizable one keeps its lower-cased words" do
    options =
      OptionKeys.extract(product(%{"_option_values" => %{"mood" => ["Very Nice", "★ ★"]}}))

    [%{values: values}] = options

    assert Enum.map(values, & &1.key) == ["very-nice", "★-★"]
  end

  test "a colon in an option key cannot break the pair format" do
    [option] = OptionKeys.extract(product(%{"_option_values" => %{"a:b" => ["x"]}}))

    assert option.key == "a_b"
    assert OptionKeys.pairs([option]) == ["a_b:x"]
  end

  test "pairs/1 and labels/1" do
    options =
      OptionKeys.extract(
        product(%{
          "_option_values" => %{"size" => ["Large"]},
          "_option_labels" => %{"size" => "Size"}
        })
      )

    assert OptionKeys.pairs(options) == ["size:large"]
    assert OptionKeys.labels(options) == %{"size" => "Size", "size:large" => "Large"}
  end

  test "missing, empty or malformed metadata yields no options" do
    assert OptionKeys.extract(product(nil)) == []
    assert OptionKeys.extract(product(%{})) == []
    assert OptionKeys.extract(product(%{"_option_values" => "oops"})) == []
    assert OptionKeys.extract(product(%{"_option_values" => %{"size" => []}})) == []
    assert OptionKeys.extract(product(%{"_option_values" => %{"size" => [1, nil, " "]}})) == []
  end

  test "two labels with one value key collapse into one value" do
    [option] =
      OptionKeys.extract(
        product(%{
          "_option_values" => %{"size" => ["Large", "large"]}
        })
      )

    assert [%{key: "large"}] = option.values
  end

  describe "affects_price" do
    defp price_flag(modifiers) do
      [option] =
        OptionKeys.extract(
          product(%{
            "_option_values" => %{"size" => ["Large", "Small"]},
            "_price_modifiers" => modifiers
          })
        )

      option.affects_price
    end

    test "is true when some amount is not zero" do
      assert price_flag(%{"size" => %{"Large" => "5.00", "Small" => "0.00"}}) == true

      assert price_flag(%{"size" => %{"Large" => %{"type" => "fixed", "value" => "-2.50"}}}) ==
               true
    end

    test "is false when the set has no modifiers or every amount is zero, blank or not a number" do
      assert price_flag(%{}) == false
      assert price_flag(%{"size" => %{}}) == false
      assert price_flag(%{"size" => %{"Large" => "0.00", "Small" => "0"}}) == false
      assert price_flag(%{"size" => %{"Large" => "", "Small" => "abc"}}) == false
      assert price_flag(%{"size" => %{"Large" => %{"value" => "0.00"}, "Small" => nil}}) == false
      assert price_flag(%{"size" => "oops"}) == false
    end

    test "belongs to the set it is stored under" do
      options =
        OptionKeys.extract(
          product(%{
            "_option_values" => %{"size" => ["Large"], "colour" => ["Red"]},
            "_price_modifiers" => %{"colour" => %{"Red" => "3.00"}, "size" => %{"Large" => "0"}}
          })
        )

      assert Enum.map(options, &{&1.key, &1.affects_price}) == [{"colour", true}, {"size", false}]
    end
  end

  test "a set without a stored name is labelled with its humanised key" do
    [option] = OptionKeys.extract(product(%{"_option_values" => %{"color_variant" => ["Red"]}}))

    assert option.label == "Color Variant"
    assert OptionKeys.labels([option])["color_variant"] == "Color Variant"
  end

  test "a colon in a value key cannot break the pair format either" do
    [option] =
      OptionKeys.extract(
        product(%{
          "_option_values" => %{"size" => ["Odd", "★:★"]},
          "_value_slugs" => %{"size" => %{"Odd" => "a:b"}}
        })
      )

    assert Enum.map(option.values, & &1.key) == ["a_b", "★_★"]
    assert OptionKeys.pairs([option]) == ["size:a_b", "size:★_★"]
  end

  test "keys are trimmed, and a blank key or an empty slug does not make an option or a key" do
    options =
      OptionKeys.extract(
        product(%{
          "_option_values" => %{"" => ["x"], " " => ["y"], " size " => ["Large"]},
          "_value_slugs" => %{" size " => %{"Large" => ""}}
        })
      )

    assert [%{key: "size", values: [%{key: "large", label: "Large"}]}] = options
  end

  test "value labels are trimmed in the label and in the fallback key" do
    options =
      OptionKeys.extract(product(%{"_option_values" => %{"size" => ["  Large ", " ★ "]}}))

    assert [%{values: [%{key: "large", label: "Large"}, %{key: "★", label: "★"}]}] = options
    assert OptionKeys.pairs(options) == ["size:large", "size:★"]
  end

  test "sets whose keys collapse to one key are merged into one option" do
    options =
      OptionKeys.extract(
        product(%{
          "_option_values" => %{"a:b" => ["One", "Two"], "a_b" => ["Two", "Three"]},
          "_price_modifiers" => %{"a_b" => %{"Two" => "1.00"}}
        })
      )

    assert [%{key: "a_b", affects_price: true, values: values}] = options
    assert Enum.map(values, & &1.key) == ["one", "two", "three"]
  end

  test "options come out sorted by key whatever the size of the map" do
    keys = for n <- 1..40, do: "set#{String.pad_leading(Integer.to_string(n), 2, "0")}"

    options =
      OptionKeys.extract(product(%{"_option_values" => Map.new(keys, &{&1, ["Value"]})}))

    assert Enum.map(options, & &1.key) == keys
  end

  describe "the key rules a caller can reuse" do
    test "neutral_key/1 trims the key and turns a colon into an underscore" do
      assert OptionKeys.neutral_key(" size:eu ") == "size_eu"
      assert OptionKeys.neutral_key("colour") == "colour"
    end

    test "neutral_key/1 gives the key extract/1 announces" do
      metadata = %{"_option_values" => %{" colour name:x " => ["Light Red"]}}
      [option] = OptionKeys.extract(product(metadata))

      assert option.key == OptionKeys.neutral_key(" colour name:x ")
    end

    test "product_value_key/3 is the value key extract/1 announces, slug or slugified label" do
      metadata = %{
        "_option_values" => %{"size" => ["Large", "Light Red", "A:B"]},
        "_value_slugs" => %{"size" => %{"Large" => "l-size"}}
      }

      product = product(metadata)
      [option] = OptionKeys.extract(product)

      for value <- option.values do
        assert OptionKeys.product_value_key(product, "size", value.label) == value.key
      end

      assert OptionKeys.product_value_key(product, "size", "Large") == "l-size"
      assert OptionKeys.product_value_key(product, "size", "Light Red") == "light-red"
    end

    test "product_value_key/3 works for a product without metadata" do
      assert OptionKeys.product_value_key(%{metadata: nil}, "size", "Large") == "large"
    end
  end

  describe "catalogue value keys" do
    defp keyed_product do
      product(%{
        "_option_values" => %{"colour" => ["red-2", "red"], "size" => ["Large"]},
        "_value_labels" => %{"colour" => %{"red" => "Red", "red-2" => "Red", "blue" => "Blue"}},
        "_value_slugs" => %{"colour" => %{"Red" => "red", "Blue" => "blue"}}
      })
    end

    test "a value of _option_values is the value key and _value_labels is what it is shown as" do
      assert [colour, size] = OptionKeys.extract(keyed_product())

      assert colour.values == [%{key: "red-2", label: "Red"}, %{key: "red", label: "Red"}]
      assert size.values == [%{key: "large", label: "Large"}]
    end

    test "two values that share a label stay two pairs" do
      assert OptionKeys.pairs(OptionKeys.extract(keyed_product())) ==
               ["colour:red", "colour:red-2", "size:large"]
    end

    test "product_value_key/3 keeps a value key and still maps a label to its key" do
      product = keyed_product()

      assert OptionKeys.product_value_key(product, "colour", "red-2") == "red-2"
      assert OptionKeys.product_value_key(product, "colour", "Blue") == "blue"
      assert OptionKeys.product_value_key(product, "size", "Large") == "large"
    end
  end

  test "pairs/1 are unique and sorted" do
    options = [
      %{key: "size", values: [%{key: "small"}, %{key: "large"}, %{key: "small"}]},
      %{key: "colour", values: [%{key: "red"}]},
      %{key: "colour", values: [%{key: "red"}]}
    ]

    assert OptionKeys.pairs(options) == ["colour:red", "size:large", "size:small"]
  end
end
