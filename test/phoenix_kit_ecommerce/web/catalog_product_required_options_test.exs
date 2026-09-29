defmodule PhoenixKitEcommerce.Web.CatalogProductRequiredOptionsTest do
  @moduledoc """
  The product page of a product whose options are DISCOVERED from its
  metadata (the catalogue source's attribute sets, an imported
  product's own options) — none of which carries an admin's
  `"required"` flag.

  Live defect (2026-09-24, "Coffee Splash Illusion Sculpture"): base
  35.52, every liquid colour +32.00, every cup colour +0.00, so every
  real combination costs 67.52. Nothing was pre-selected, the headline
  and the quantity line read 35.52, and Add to Cart put a 35.52 line
  with no colour at all into the cart.

  A discovered option is now required, and a required select starts on
  its first value — the rule `build_default_specs/2` already applied to
  an admin's required options — so the headline is always the price of a
  combination that can actually be bought, and the line records it.

  A legacy product carrying the same metadata goes through the same
  discovery, so this runs without the catalogue bridge; the real
  attribute-set path is `catalog_product_catalogue_options_test.exs`.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Options

  defp lang do
    PhoenixKitEcommerce.SlugResolver.normalize_language_public(
      PhoenixKitEcommerce.Translations.default_language()
    )
  end

  setup %{conn: conn} do
    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Coffee Splash", lang() => "Coffee Splash"},
        "slug" => %{lang() => "coffee-splash-#{System.unique_integer([:positive])}"},
        "price" => Decimal.new("35.52"),
        "status" => "active",
        "currency" => "USD",
        "requires_shipping" => false,
        "metadata" => %{
          "_option_values" => %{
            "liquid_color" => ["Black", "Blue"],
            "cup_color" => ["White", "Gold"]
          },
          "_price_modifiers" => %{
            "liquid_color" => %{"Black" => "32.00", "Blue" => "32.00"},
            "cup_color" => %{"White" => "0.00", "Gold" => "0.00"}
          }
        }
      })

    session_id = "required-options-#{System.unique_integer([:positive])}"
    conn = Plug.Test.init_test_session(conn, %{"shop_session_id" => session_id})

    %{conn: conn, product: product, session_id: session_id}
  end

  defp open(conn, product) do
    {:ok, view, _html} = live(conn, "/shop/product/#{product.slug[lang()]}")
    view
  end

  defp headline(view), do: view |> element("span.text-3xl.text-primary") |> render()

  defp option(key, value), do: ~s(button[phx-value-key="#{key}"][phx-value-opt="#{value}"])

  defp cart_lines(session_id) do
    case Shop.find_active_cart(session_id: session_id) do
      %{items: items} -> items
      nil -> []
    end
  end

  test "the headline is the price of a real combination, never the bare base price", %{
    conn: conn,
    product: product
  } do
    view = open(conn, product)

    assert headline(view) =~ "67.52"
    refute render(view) =~ "35.52"
  end

  test "every option starts on a chosen value, shown as selected", %{
    conn: conn,
    product: product
  } do
    view = open(conn, product)

    assert has_element?(view, option("liquid_color", "Black") <> ".btn-primary")
    assert has_element?(view, option("cup_color", "White") <> ".btn-primary")
  end

  test "Add to Cart straight away records every option and charges the full combination", %{
    conn: conn,
    product: product,
    session_id: session_id
  } do
    view = open(conn, product)

    view |> element("button[phx-click=add_to_cart]") |> render_click()

    assert [line] = cart_lines(session_id)
    assert line.selected_specs == %{"liquid_color" => "Black", "cup_color" => "White"}
    assert Decimal.equal?(line.base_unit_price, Decimal.new("67.52"))
  end

  test "the combination the shopper picks is the one the line records", %{
    conn: conn,
    product: product,
    session_id: session_id
  } do
    view = open(conn, product)

    view |> element(option("liquid_color", "Blue")) |> render_click()
    view |> element(option("cup_color", "Gold")) |> render_click()
    view |> element("button[phx-click=add_to_cart]") |> render_click()

    assert [line] = cart_lines(session_id)
    assert line.selected_specs == %{"liquid_color" => "Blue", "cup_color" => "Gold"}
    assert Decimal.equal?(line.base_unit_price, Decimal.new("67.52"))
  end

  test "an option left unchosen is named and the add is refused", %{
    conn: conn,
    product: product,
    session_id: session_id
  } do
    view = open(conn, product)

    # No button sends an empty value; a stale or crafted client can.
    render_click(view, "select_spec", %{"key" => "liquid_color", "opt" => ""})
    view |> element("button[phx-click=add_to_cart]") |> render_click()

    assert has_element?(view, "legend.text-error", "Liquid Color")
    assert cart_lines(session_id) == []
  end

  test "an admin's price-neutral option on the priced key still starts selected", %{
    conn: conn,
    product: product
  } do
    # The picker shows the admin's spec for `liquid_color`; the price list
    # still prices it from the discovered +32.00.
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

    view = open(conn, product)

    assert has_element?(view, option("liquid_color", "Black") <> ".btn-primary")
    assert headline(view) =~ "67.52"
  end

  test "a required option the context adds after the page opened is refused by its label", %{
    conn: conn,
    product: product,
    session_id: session_id
  } do
    view = open(conn, product)

    # Made required after mount: the page's own check cannot see it, the
    # context's does, and names it by its key.
    {:ok, _} =
      Options.update_global_options([
        %{
          "key" => "surface_finish",
          "label" => "Finish",
          "type" => "select",
          "options" => ["Matte", "Gloss"],
          "required" => true,
          "position" => 0
        }
      ])

    html = view |> element("button[phx-click=add_to_cart]") |> render_click()

    assert html =~ "Missing required option: Finish."
    refute html =~ "surface_finish"
    assert cart_lines(session_id) == []
  end
end
