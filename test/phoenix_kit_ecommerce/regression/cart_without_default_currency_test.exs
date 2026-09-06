defmodule PhoenixKitEcommerce.Regression.CartWithoutDefaultCurrencyTest do
  @moduledoc """
  `Cart.changeset/2` requires `:currency` (§4.2), so `create_cart/1` now
  FAILS when Billing has no default currency configured. Both storefront
  call sites hard-matched `{:ok, cart}`, so a shop in that state answered
  every cart-page request — and every add-to-cart — with a MatchError.
  They degrade to the same "shop is currently unavailable" exit the
  disabled-shop gate takes.
  """

  use PhoenixKitEcommerce.LiveCase

  alias PhoenixKitEcommerce.Test.Repo

  setup do
    Repo.delete_all(PhoenixKitBilling.Currency)
    :ok
  end

  test "the cart page redirects with a flash instead of crashing", %{conn: conn} do
    assert {:error, {kind, %{to: "/", flash: flash}}} = live(conn, "/cart")
    assert kind in [:redirect, :live_redirect]
    assert flash["error"] =~ "unavailable"
  end
end
