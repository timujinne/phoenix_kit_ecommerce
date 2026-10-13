defmodule PhoenixKitEcommerce.Web.CheckoutDefaultCountryTest do
  @moduledoc """
  The country a checkout starts with when the cart has none: it comes from the
  shop's settings (`Shop.default_checkout_country/0`), and falls back to "EE"
  only when they say nothing — a hardcoded "EE" once left a UA-only shop with
  no shipping method to offer on every new cart.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce, as: Shop

  describe "default_checkout_country/0" do
    test "is EE when nothing is configured" do
      assert Shop.default_checkout_country() == "EE"
    end

    test "uses the company country first" do
      Settings.update_json_setting("company_info", %{"country" => "lv"})
      Settings.update_setting_with_module("shop_default_tax_country", "FI", "shop")
      shipping_method(countries: ["UA"])
      Settings.update_setting("country_select_priority", "PL")

      assert Shop.default_checkout_country() == "LV"
    end

    test "then the shop's default country" do
      Settings.update_setting_with_module("shop_default_tax_country", "fi", "shop")
      shipping_method(countries: ["UA"])

      assert Shop.default_checkout_country() == "FI"
    end

    test "then the single country all active shipping methods share" do
      shipping_method(countries: ["UA"])
      shipping_method(countries: ["UA"])
      Settings.update_setting("country_select_priority", "PL")

      assert Shop.default_checkout_country() == "UA"
    end

    test "methods with different or open country lists say nothing" do
      shipping_method(countries: ["UA"])
      shipping_method(countries: ["PL"])
      assert Shop.default_checkout_country() == "EE"

      shipping_method(countries: [])
      Settings.update_setting("country_select_priority", "UA, PL")
      assert Shop.default_checkout_country() == "UA"
    end

    test "inactive methods don't count" do
      shipping_method(countries: ["UA"])
      shipping_method(countries: ["PL"], active: false)

      assert Shop.default_checkout_country() == "UA"
    end

    test "compares the shipping methods' countries case-insensitively" do
      shipping_method(countries: ["UA"])
      shipping_method(countries: ["ua"])

      assert Shop.default_checkout_country() == "UA"
    end

    test "a method listing its country twice still counts as that one country" do
      shipping_method(countries: ["UA", "ua"])
      shipping_method(countries: ["UA"])

      assert Shop.default_checkout_country() == "UA"
    end

    test "skips a code that names no country" do
      Settings.update_json_setting("company_info", %{"country" => "XX"})
      Settings.update_setting("country_select_priority", "PL")

      assert Shop.default_checkout_country() == "PL"
    end

    test "ignores values that are not a country code" do
      Settings.update_json_setting("company_info", %{"country" => "Ukraine"})
      Settings.update_setting("country_select_priority", "UA")

      assert Shop.default_checkout_country() == "UA"
    end
  end

  test "a new cart without a country is offered the shop's shipping methods", %{conn: conn} do
    Settings.update_setting_with_module("shop_shipping_selection_position", "checkout", "shop")

    method = shipping_method(countries: ["UA"])
    conn = setup_shippable_cart_session(conn)

    {:ok, view, _html} = live(conn, "/checkout")

    # The form starts on the shop's country, not on a hardcoded one.
    assert has_element?(view, "#checkout-billing-form select option[value='UA'][selected]")
    refute has_element?(view, "#checkout-billing-form select option[value='EE'][selected]")

    # The buyer fills in the rest and keeps the country the form started on.
    billing = Map.delete(complete_billing("UA", "default-country"), "country")
    view |> form("#checkout-billing-form", billing: billing) |> render_change()
    view |> element("button[phx-click='proceed_to_review']") |> render_click()

    assert has_element?(view, "#checkout-shipping-method-#{method.uuid}")
    refute has_element?(view, "#checkout-shipping-blocked")
  end

  defp shipping_method(attrs) do
    unique = System.unique_integer([:positive])

    {:ok, method} =
      Shop.create_shipping_method(%{
        "name" => "Default country #{unique}",
        "price" => Decimal.new("5.00"),
        "active" => Keyword.get(attrs, :active, true),
        "countries" => Keyword.fetch!(attrs, :countries)
      })

    method
  end

  defp setup_shippable_cart_session(conn) do
    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Default Country Widget"},
        "price" => Decimal.new("25.00"),
        "status" => "active",
        "currency" => "USD",
        "product_type" => "physical",
        "requires_shipping" => true,
        "weight_grams" => 500
      })

    session_id = "checkout-default-country-#{System.unique_integer([:positive])}"

    {:ok, cart} = Shop.create_cart(session_id: session_id)
    {:ok, _cart} = Shop.add_to_cart(cart, product, 1)

    Plug.Test.init_test_session(conn, %{"shop_session_id" => session_id})
  end
end
