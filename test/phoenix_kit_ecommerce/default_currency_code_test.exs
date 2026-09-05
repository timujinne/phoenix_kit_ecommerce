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
end
