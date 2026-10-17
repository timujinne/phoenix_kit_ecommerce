defmodule PhoenixKitEcommerce.API.CartMoneyTest do
  @moduledoc "Money objects of the API: a string amount rounded to the currency's decimal places."

  use PhoenixKitEcommerce.DataCase, async: false

  import PhoenixKitEcommerce.CartApiFixtures

  alias PhoenixKitEcommerce.API.CartMoney

  setup do
    ensure_currencies!()
    :ok
  end

  test "renders two decimals and the currency code" do
    assert CartMoney.new(Decimal.new("12.5"), "USD") == %{amount: "12.50", currency: "USD"}
    assert CartMoney.new(Decimal.new("7"), "EUR") == %{amount: "7.00", currency: "EUR"}
  end

  test "rounds half up to the currency's decimal places" do
    assert CartMoney.new(Decimal.new("1.005"), "USD") == %{amount: "1.01", currency: "USD"}
  end

  test "a currency without decimals renders a whole number" do
    {:ok, _} =
      PhoenixKitBilling.create_currency(%{
        code: "JPY",
        name: "Yen",
        symbol: "¥",
        exchange_rate: "150",
        decimal_places: 0
      })

    PhoenixKit.Cache.clear(:billing_currencies)
    # The row is rolled back with the sandbox; the cached list must not outlive it.
    on_exit(fn -> PhoenixKit.Cache.clear(:billing_currencies) end)

    assert CartMoney.new(Decimal.new("1234.5"), "JPY") == %{amount: "1235", currency: "JPY"}
  end

  test "nil stays nil, an unknown code keeps two decimals" do
    assert CartMoney.new(nil, "USD") == nil
    assert CartMoney.new(Decimal.new("3"), "XYZ") == %{amount: "3.00", currency: "XYZ"}
    assert CartMoney.new(Decimal.new("3"), nil) == %{amount: "3.00", currency: nil}
  end
end
