defmodule PhoenixKitEcommerce.Regression.RequiredOptionsCartTest do
  @moduledoc """
  `add_to_cart/4` must refuse a line that leaves a required option
  unchosen — enforced in the context, not only by the product page.

  Live defect (2026-09-24): a catalogue product whose options come from
  its attribute sets (base 35.52, every liquid colour +32.00, every cup
  colour +0.00) went into the cart at 35.52 with no colour at all. Two
  gaps let it through: a discovered option was never required, and an
  EMPTY `selected_specs` skipped validation entirely, so even an admin's
  `"required" => true` was not enforced for a caller that sent nothing.

  A legacy product carrying the same `_option_values`/`_price_modifiers`
  metadata goes through the very same discovery and pricing code as the
  catalogue view-struct, so this runs without the catalogue bridge; the
  real attribute-set path is `web/catalog_product_catalogue_options_test.exs`.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Options

  @sculpture_metadata %{
    "_option_values" => %{
      "liquid_color" => ["Black", "Blue"],
      "cup_color" => ["White", "Gold"]
    },
    "_price_modifiers" => %{
      "liquid_color" => %{"Black" => "32.00", "Blue" => "32.00"},
      "cup_color" => %{"White" => "0.00", "Gold" => "0.00"}
    }
  }

  defp product(attrs \\ %{}) do
    {:ok, product} =
      Map.merge(
        %{
          "title" => %{"en" => "Required #{System.unique_integer([:positive])}"},
          "price" => Decimal.new("35.52"),
          "status" => "active",
          "currency" => "USD",
          "requires_shipping" => false
        },
        attrs
      )
      |> Shop.create_product()

    product
  end

  defp cart do
    {:ok, cart} = Shop.create_cart(session_id: "req-#{System.unique_integer([:positive])}")
    cart
  end

  defp lines(cart), do: Shop.get_cart(cart.uuid).items

  defp configure_material(required?) do
    {:ok, _} =
      Options.update_global_options([
        %{
          "key" => "material",
          "label" => "Material",
          "type" => "select",
          "options" => ["PLA", "PETG"],
          "required" => required?,
          "affects_price" => true,
          "modifier_type" => "fixed",
          "price_modifiers" => %{"PLA" => "0", "PETG" => "10.00"},
          "position" => 0
        }
      ])
  end

  describe "a product with discovered options" do
    setup do
      %{product: product(%{"metadata" => @sculpture_metadata})}
    end

    test "is refused with no option chosen", %{product: product} do
      cart = cart()

      assert {:error, :missing_required_option, key} = Shop.add_to_cart(cart, product, 1)
      assert key in ["liquid_color", "cup_color"]
      assert lines(cart) == []
    end

    test "is refused with only the price-neutral option chosen", %{product: product} do
      cart = cart()

      assert {:error, :missing_required_option, "liquid_color"} =
               Shop.add_to_cart(cart, product, 1, selected_specs: %{"cup_color" => "Gold"})

      assert lines(cart) == []
    end

    test "is refused with only the priced option chosen", %{product: product} do
      cart = cart()

      assert {:error, :missing_required_option, "cup_color"} =
               Shop.add_to_cart(cart, product, 1, selected_specs: %{"liquid_color" => "Blue"})

      assert lines(cart) == []
    end

    test "is refused through the clause that takes no keyword opts", %{product: product} do
      cart = cart()

      assert {:error, :missing_required_option, _key} = Shop.add_to_cart(cart, product, 1, %{})
      assert lines(cart) == []
    end

    test "is refused when an admin's non-price option of the same key shadows the priced one",
         %{product: product} do
      # Global `liquid_color`, optional and price-neutral: the picker gets
      # the admin's spec, the price list still gets the discovered +32.00.
      {:ok, _} =
        Options.update_global_options([
          %{
            "key" => "liquid_color",
            "label" => "Liquid",
            "type" => "select",
            "options" => ["Black", "Blue"],
            "required" => false,
            "position" => 0
          }
        ])

      cart = cart()

      assert {:error, :missing_required_option, "liquid_color"} =
               Shop.add_to_cart(cart, product, 1, selected_specs: %{"cup_color" => "White"})

      assert lines(cart) == []
    end

    test "is carted with nothing chosen only when the caller opts out of validation",
         %{product: product} do
      assert {:ok, cart} = Shop.add_to_cart(cart(), product, 1, skip_spec_validation: true)

      assert [line] = cart.items
      assert line.selected_specs == %{}
    end

    test "is priced from the full selection once every option is chosen", %{product: product} do
      specs = %{"liquid_color" => "Blue", "cup_color" => "Gold"}

      assert {:ok, cart} = Shop.add_to_cart(cart(), product, 1, selected_specs: specs)

      assert [line] = cart.items
      assert line.selected_specs == specs
      assert Decimal.equal?(line.base_unit_price, Decimal.new("67.52"))
    end
  end

  describe "a product with only admin-configured (schema) options" do
    test "an option the admin left optional stays optional" do
      configure_material(false)

      assert {:ok, cart} = Shop.add_to_cart(cart(), product(), 1)
      assert [line] = cart.items
      assert Decimal.equal?(line.base_unit_price, Decimal.new("35.52"))
    end

    test "an option the admin made required is enforced even when nothing is sent" do
      configure_material(true)
      cart = cart()

      assert {:error, :missing_required_option, "material"} = Shop.add_to_cart(cart, product(), 1)
      assert lines(cart) == []
    end
  end

  test "a product with no options at all is added as before" do
    assert {:ok, cart} = Shop.add_to_cart(cart(), product(), 2)
    assert [%{quantity: 2}] = cart.items
  end
end
