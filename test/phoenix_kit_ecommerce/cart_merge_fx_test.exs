defmodule PhoenixKitEcommerce.CartMergeFxTest do
  @moduledoc """
  Guest and user carts freeze independently. Merging a guest EUR cart
  into a leftover USD user cart must restamp line money through base
  rather than copy display amounts across frames.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitBilling.Currency
  alias PhoenixKitEcommerce, as: Shop

  defp lang do
    PhoenixKitEcommerce.SlugResolver.normalize_language_public(
      PhoenixKitEcommerce.Translations.default_language()
    )
  end

  defp product_attrs do
    n = System.unique_integer([:positive])

    %{
      "title" => %{"en" => "Consulting #{n}", lang() => "Consulting #{n}"},
      "slug" => %{lang() => "consulting-#{n}"},
      "price" => Decimal.new("138.00"),
      "status" => "active",
      "currency" => "USD"
    }
  end

  setup do
    PhoenixKit.Cache.clear(:billing_currencies)
    Currency.put_request_currency(nil)
    on_exit(fn -> Currency.put_request_currency(nil) end)

    Repo.delete_all(PhoenixKitBilling.Currency)

    {:ok, _usd} =
      PhoenixKitBilling.create_currency(%{
        code: "USD",
        name: "Dollar",
        symbol: "$",
        is_default: true,
        exchange_rate: "1.0"
      })

    {:ok, _eur} =
      PhoenixKitBilling.create_currency(%{
        code: "EUR",
        name: "Euro",
        symbol: "€",
        exchange_rate: "0.909091"
      })

    :ok
  end

  test "a EUR guest line is restamped into a USD user cart at the user cart's frozen rate" do
    {:ok, user} =
      Auth.register_user(%{
        email: "merge-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    {:ok, _user_cart} = Shop.create_cart(user_uuid: user.uuid)

    Currency.put_request_currency("EUR")
    session_id = "guest-#{System.unique_integer([:positive])}"
    {:ok, guest} = Shop.create_cart(session_id: session_id)
    {:ok, product} = Shop.create_product(product_attrs())
    {:ok, guest} = Shop.add_to_cart(guest, product, 1)
    assert guest.currency == "EUR"
    assert Decimal.equal?(hd(guest.items).unit_price, Decimal.new("125.45"))

    assert {:ok, merged} = Shop.merge_guest_cart(session_id, user.uuid)
    assert merged.currency == "USD"
    [item] = merged.items
    assert item.currency == "USD"
    assert Decimal.equal?(item.unit_price, Decimal.new("138.00"))
    assert Decimal.equal?(item.base_unit_price, Decimal.new("138.00"))
  end
end
