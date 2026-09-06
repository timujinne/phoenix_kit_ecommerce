defmodule PhoenixKitEcommerce.DefaultCurrencyCodeTest do
  @moduledoc """
  Pins §4.2 of the currency design spec: an empty currency table makes
  `get_default_currency_code/0` return `nil` (never a silent `"USD"`
  literal), and `create_cart/1` then fails loudly on its own changeset
  instead of persisting `currency = NULL`.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  test "an empty currency table yields nil, and create_cart/1 then fails on the changeset" do
    Repo.delete_all(PhoenixKitBilling.Currency)
    assert PhoenixKitEcommerce.get_default_currency_code() == nil

    assert {:error, %Ecto.Changeset{errors: errors}} =
             PhoenixKitEcommerce.create_cart(
               session_id: "s-#{System.unique_integer([:positive])}"
             )

    assert Keyword.has_key?(errors, :currency)
  end

  # Dropping `default: "USD"` from the SCHEMAS did not remove the literal:
  # core's baseline declares `DEFAULT 'USD'` on the four shop `currency`
  # columns too, and Ecto omits an unchanged field from the INSERT, so
  # Postgres substituted it. The struct said nil and the row said "USD".
  # `PhoenixKitEcommerce.Migrations` V2 drops those column defaults.
  test "with no default currency, create_product/1 stores no currency at all" do
    Repo.delete_all(PhoenixKitBilling.Currency)

    {:ok, product} =
      PhoenixKitEcommerce.create_product(%{
        "title" => %{"en" => "No-currency widget"},
        "slug" => %{"en" => "no-currency-widget-#{System.unique_integer([:positive])}"},
        "price" => "10.00"
      })

    assert product.currency == nil
    assert [[nil]] = persisted_currency("phoenix_kit_shop_products", product.uuid)
  end

  # The shipping-method form's hidden input submits "" when no currency is
  # configured, which Ecto treats as an empty value — same story as above.
  test "with no default currency, create_shipping_method/1 stores no currency at all" do
    Repo.delete_all(PhoenixKitBilling.Currency)

    {:ok, method} =
      PhoenixKitEcommerce.create_shipping_method(%{
        "name" => "No-currency shipping",
        "currency" => "",
        "price" => "5.00"
      })

    assert method.currency == nil
    assert [[nil]] = persisted_currency("phoenix_kit_shop_shipping_methods", method.uuid)
  end

  defp persisted_currency(table, uuid) do
    Repo.query!("SELECT currency FROM #{table} WHERE uuid = $1", [Ecto.UUID.dump!(uuid)]).rows
  end
end
