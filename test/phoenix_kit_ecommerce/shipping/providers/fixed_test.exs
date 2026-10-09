defmodule PhoenixKitEcommerce.Shipping.Providers.FixedTest do
  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.Shipping.{Context, Field, Quote, RateRequest, Service}
  alias PhoenixKitEcommerce.Shipping.Providers.Fixed
  alias PhoenixKitEcommerce.ShippingMethod

  defp ctx(attrs \\ []), do: struct(%Context{}, attrs)

  test "identifies itself" do
    assert Fixed.key() == "fixed"
    assert is_binary(Fixed.label())
    refute function_exported?(Fixed, :integration, 0)
  end

  describe "services/1" do
    test "defaults to no destination" do
      assert [%Service{key: "default", destination: :none, lookup: :manual}] =
               Fixed.services(ctx())
    end

    test "address destination" do
      assert [%Service{destination: :address}] =
               Fixed.services(ctx(settings: %{"destination" => "address"}))
    end

    test "anything else means no destination" do
      assert [%Service{destination: :none}] =
               Fixed.services(ctx(settings: %{"destination" => "warp"}))
    end
  end

  test "settings_fields/0 describes the destination select" do
    assert [%Field{key: "destination", type: :select, options: options}] = Fixed.settings_fields()
    assert Enum.map(options, &elem(&1, 1)) == ["none", "address"]
  end

  describe "quote/2" do
    test "returns the method price" do
      method = %ShippingMethod{price: Decimal.new("49.00"), currency: "UAH"}

      assert {:ok, %Quote{} = quote} = Fixed.quote(%RateRequest{}, ctx(method: method))
      assert Decimal.equal?(quote.amount, "49")
      assert quote.currency == "UAH"
      assert quote.source == :fixed
      assert quote.eta == nil
    end

    test "the context currency wins over the method currency" do
      method = %ShippingMethod{price: Decimal.new("5"), currency: "UAH"}

      assert {:ok, %Quote{currency: "USD"}} =
               Fixed.quote(%RateRequest{}, ctx(method: method, currency: "USD"))
    end

    test "carries the estimated days of the method" do
      method = %ShippingMethod{
        price: Decimal.new("5"),
        estimated_days_min: 2,
        estimated_days_max: 4
      }

      assert {:ok, %Quote{eta: %{min_days: 2, max_days: 4, date: nil}}} =
               Fixed.quote(%RateRequest{}, ctx(method: method))
    end

    test "fails without a method" do
      assert {:error, :no_method} = Fixed.quote(%RateRequest{}, ctx())
    end
  end
end
