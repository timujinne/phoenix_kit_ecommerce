defmodule PhoenixKitEcommerce.API.ViaAssistantTest do
  @moduledoc """
  `add_to_cart/4` option `via: :assistant`: the per-line "item added" signal is
  not sent for a write made through the public cart API; the storefront path is
  unchanged.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  import PhoenixKitEcommerce.CartApiFixtures

  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Notifications

  setup do
    ensure_currencies!()
    # The first registered user of a sandboxed run is promoted to Owner, so
    # there is somebody for the signals to reach (see notifications_test.exs).
    owner = fixture_user()
    {:ok, _} = Settings.update_setting_with_module("shop_notify_cart_first_item", "true", "shop")
    {:ok, _} = Settings.update_setting_with_module("shop_notify_cart_item", "true", "shop")
    {:ok, cart} = Shop.create_cart(user_uuid: owner.uuid)
    %{cart: cart, product: product!()}
  end

  test "a storefront add still sends the first-item signal", %{cart: cart, product: product} do
    {:ok, _cart} = Shop.add_to_cart(cart, product, 1)

    assert count_notifications("shop.cart_first_item_added") == 1
  end

  test "an assistant add sends no per-line signal and still fills the cart", %{
    cart: cart,
    product: product
  } do
    assert {:ok, cart} = Shop.add_to_cart(cart, product, 2, via: :assistant)

    assert [%{quantity: 2}] = cart.items
    assert count_notifications("shop.cart_first_item_added") == 0
    assert count_notifications("shop.cart_item_added") == 0
  end

  test "an assistant add with options sends none either", %{cart: cart} do
    product = product_with_options!(%{"color" => ["Red", "Blue"]})

    assert {:ok, _cart} =
             Shop.add_to_cart(cart, product, 1,
               selected_specs: %{"color" => "Red"},
               via: :assistant
             )

    assert count_notifications("shop.cart_first_item_added") == 0
    assert count_notifications("shop.cart_item_added") == 0
  end

  test "Notifications.cart_item_added/4 with via: :assistant is a no-op", %{
    cart: cart,
    product: product
  } do
    {:ok, cart} = Shop.add_to_cart(cart, product, 1, via: :assistant)
    [item] = cart.items

    assert :ok = Notifications.cart_item_added(cart, item, product, via: :assistant)
    assert count_notifications("shop.cart_first_item_added") == 0

    assert :ok = Notifications.cart_item_added(cart, item, product, [])
    assert count_notifications("shop.cart_first_item_added") == 1
  end
end
