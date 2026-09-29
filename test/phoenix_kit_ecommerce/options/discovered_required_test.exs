defmodule PhoenixKitEcommerce.Options.DiscoveredRequiredTest do
  @moduledoc """
  A DISCOVERED option — a key of `metadata["_option_values"]` with no
  admin-configured schema entry: the catalogue source's attribute sets,
  or an imported product's own options — is required.

  Nothing ever marked them so. `build_default_specs/2`
  (`catalog_product.ex`) pre-selects only a spec with a default or
  `"required" => true`, and the add-to-cart checks enforce only
  `"required" => true`, so a product whose every combination costs more
  than its base price (live: base 35.52, every liquid colour +32.00) was
  headlined at 35.52 and went into the cart at 35.52 with no colour
  chosen at all.

  A schema option keeps the admin's own `"required"` flag, narrowed or
  not — unless the option's PRICE still comes from the discovered spec:
  a schema option that does not itself affect price leaves the price
  list to the discovered one, and the picker must then require what the
  price list requires, or the +32.00 is charged only when the shopper
  happens to pick a colour.

  `DataCase` because the spec builders read the global option schema
  through `Repo` even when it is empty (see `option_labels_test.exs`).
  """

  use PhoenixKitEcommerce.DataCase, async: true

  alias PhoenixKitEcommerce.Options
  alias PhoenixKitEcommerce.Product

  # The live sculpture's shape: one set with a non-zero modifier on every
  # value, one whose modifiers are all zero.
  @metadata %{
    "_option_values" => %{
      "liquid_color" => ["Black", "Blue"],
      "cup_color" => ["White", "Gold"]
    },
    "_price_modifiers" => %{
      "liquid_color" => %{"Black" => "32.00", "Blue" => "32.00"},
      "cup_color" => %{"White" => "0.00", "Gold" => "0.00"}
    }
  }

  defp product(metadata), do: %Product{metadata: metadata, category_uuid: nil}

  defp by_key(specs), do: Map.new(specs, &{&1["key"], &1})

  test "a discovered price-affecting option is required" do
    assert [%{"key" => "liquid_color", "_discovered" => true} = spec] =
             Options.get_price_affecting_specs_for_product(product(@metadata))

    assert spec["required"] == true
  end

  test "every discovered option is required, whether it moves the price or not" do
    specs = @metadata |> product() |> Options.get_selectable_specs_for_product() |> by_key()

    assert specs["liquid_color"]["required"] == true
    assert specs["cup_color"]["required"] == true
    refute specs["cup_color"]["affects_price"]
  end

  defp configure_liquid_color(attrs) do
    {:ok, _} =
      Options.update_global_options([
        Map.merge(
          %{
            "key" => "liquid_color",
            "label" => "Liquid",
            "type" => "select",
            "options" => ["Black", "Blue"],
            "required" => false,
            "position" => 0
          },
          attrs
        )
      ])
  end

  test "a schema option that leaves its key's price to a discovered option is required" do
    configure_liquid_color(%{})
    product = product(@metadata)

    assert [%{"key" => "liquid_color", "_discovered" => true}] =
             Options.get_price_affecting_specs_for_product(product)

    specs = product |> Options.get_selectable_specs_for_product() |> by_key()

    # Still the admin's spec (its label), but required like the price list's.
    assert specs["liquid_color"]["label"] == "Liquid"
    refute Map.has_key?(specs["liquid_color"], "_discovered")
    assert specs["liquid_color"]["required"] == true
  end

  test "a price-affecting schema option keeps the admin's required flag over discovered modifiers" do
    configure_liquid_color(%{
      "affects_price" => true,
      "modifier_type" => "fixed",
      "allow_override" => true,
      "price_modifiers" => %{"Black" => "0", "Blue" => "5.00"}
    })

    product = product(@metadata)

    assert [%{"key" => "liquid_color"} = price_spec] =
             Options.get_price_affecting_specs_for_product(product)

    refute Map.has_key?(price_spec, "_discovered")

    specs = product |> Options.get_selectable_specs_for_product() |> by_key()
    assert specs["liquid_color"]["required"] == false
  end

  test "a schema option narrowed to the product's values keeps the admin's required flag" do
    {:ok, _} =
      Options.update_global_options([
        %{
          "key" => "cup_color",
          "label" => "Cup Color",
          "type" => "select",
          "options" => ["White", "Gold", "Silver"],
          "required" => false,
          "position" => 0
        }
      ])

    specs = @metadata |> product() |> Options.get_selectable_specs_for_product() |> by_key()

    assert specs["cup_color"]["options"] == ["White", "Gold"]
    refute Map.has_key?(specs["cup_color"], "_discovered")
    assert specs["cup_color"]["required"] == false
    assert specs["liquid_color"]["required"] == true
  end
end
