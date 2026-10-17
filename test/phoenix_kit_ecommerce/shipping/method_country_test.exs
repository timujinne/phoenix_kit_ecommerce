defmodule PhoenixKitEcommerce.Shipping.MethodCountryTest do
  @moduledoc """
  `ShippingMethod.serves_country?/2` and `available_for?/2`: a method priced by
  a shipping provider is offered only where that provider delivers.
  """

  # Changes the application env (provider registry).
  use ExUnit.Case, async: false

  alias PhoenixKitEcommerce.ShippingMethod
  alias PhoenixKitEcommerce.Test.Shipping.CountryProvider

  setup do
    Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, [CountryProvider])
    Application.put_env(:phoenix_kit_ecommerce, :shipping_country_provider, ["UA", "PL"])

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_ecommerce, :shipping_providers)
      Application.delete_env(:phoenix_kit_ecommerce, :shipping_country_provider)
    end)
  end

  defp method(attrs \\ []) do
    struct(
      %ShippingMethod{
        active: true,
        metadata: %{"shipping_provider" => %{"provider" => CountryProvider.key()}}
      },
      attrs
    )
  end

  defp available?(method, country),
    do: ShippingMethod.available_for?(method, %{country: country})

  test "a method without its own countries serves the provider's countries only" do
    assert ShippingMethod.serves_country?(method(), "UA")
    refute ShippingMethod.serves_country?(method(), "DE")
    assert available?(method(), "PL")
    refute available?(method(), "DE")
  end

  test "the method's own lists narrow the provider's countries" do
    refute ShippingMethod.serves_country?(method(countries: ["UA", "DE"]), "DE")
    assert ShippingMethod.serves_country?(method(countries: ["UA", "DE"]), "UA")
    refute ShippingMethod.serves_country?(method(excluded_countries: ["UA"]), "UA")
  end

  test "an unknown country is never refused" do
    assert ShippingMethod.serves_country?(method(), nil)
  end

  test "a fixed-price method is not limited by any provider" do
    fixed = method(metadata: %{})
    assert ShippingMethod.serves_country?(fixed, "DE")
    refute ShippingMethod.serves_country?(%{fixed | excluded_countries: ["DE"]}, "DE")
  end

  test "NULL country lists read as empty ones" do
    fixed = method(metadata: %{}, countries: nil, excluded_countries: nil)
    assert ShippingMethod.serves_country?(fixed, "DE")
    refute ShippingMethod.serves_country?(%{fixed | excluded_countries: ["DE"]}, "DE")
    refute ShippingMethod.serves_country?(%{fixed | countries: ["UA"]}, "DE")
  end

  test "a method whose provider is not installed is not limited by it" do
    gone = method(metadata: %{"shipping_provider" => %{"provider" => "not_installed"}})
    assert ShippingMethod.serves_country?(gone, "DE")
  end
end
