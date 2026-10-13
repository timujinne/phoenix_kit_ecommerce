defmodule PhoenixKitEcommerce.Web.CheckoutAfterConversionTest do
  @moduledoc """
  What the checkout page does once the cart it holds has already become an
  order: a repeated "Confirm Order", and a remount after the conversion
  committed. Neither may tell the shopper something failed.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitBilling, as: Billing
  import Ecto.Query, only: [from: 2]

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Cart
  alias PhoenixKitEcommerce.DataCase
  alias PhoenixKitEcommerce.Test.Repo

  defp digital_product do
    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "After Conversion #{System.unique_integer([:positive])}"},
        "price" => Decimal.new("10.00"),
        "status" => "active",
        "currency" => "USD",
        "product_type" => "digital",
        "requires_shipping" => false,
        "weight_grams" => 0
      })

    product
  end

  defp logged_in(%{conn: conn}) do
    user = DataCase.fixture_user()
    {:ok, cart} = Shop.create_cart(user_uuid: user.uuid)
    {:ok, cart} = Shop.add_to_cart(cart, digital_product(), 1)
    conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid, email: user.email))

    {:ok, conn: conn, user: user, cart: cart}
  end

  defp guest(conn, trusted?) do
    session_id = "after-conversion-#{System.unique_integer([:positive])}"
    {:ok, cart} = Shop.create_cart(session_id: session_id)
    {:ok, cart} = Shop.add_to_cart(cart, digital_product(), 1)

    conn =
      Plug.Test.init_test_session(conn, %{
        "shop_session_id" => session_id,
        "shop_session_trusted" => trusted?
      })

    {conn, cart}
  end

  defp to_review(view) do
    billing = complete_billing("EE", "after-conversion")

    view |> form("#checkout-billing-form", billing: billing) |> render_change()
    view |> element("button[phx-click='proceed_to_review']") |> render_click()
    billing
  end

  describe "a second Confirm Order" do
    setup :logged_in

    test "goes to the order the first one made and records no failure", ctx do
      %{conn: conn, user: user, cart: cart} = ctx
      {:ok, view, _html} = live(conn, "/checkout")
      billing = to_review(view)

      # The first click, as far as the database is concerned.
      {:ok, order} =
        Shop.convert_cart_to_order(cart, billing_data: billing, user_uuid: user.uuid)

      view |> element("#checkout-confirm-order") |> render_click()

      {path, _flash} = assert_redirect(view)
      assert path =~ "/checkout/complete/#{order.uuid}"

      assert [_only] = Billing.list_user_orders(user.uuid)

      refute_activity_logged("shop.order_converted",
        metadata_has: %{"failure_reason" => "cart_not_active"}
      )
    end

    test "the button disables itself while the order is placed", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/checkout")
      to_review(view)

      assert has_element?(view, "#checkout-confirm-order[phx-disable-with]")
    end
  end

  describe "a cart that is not active for any other reason" do
    setup :logged_in

    test "still records the failed attempt", %{user: user, cart: cart} do
      cart
      |> Cart.status_changeset("abandoned", %{})
      |> Repo.update!()

      assert {:error, :cart_not_active} =
               Shop.convert_cart_to_order(cart,
                 billing_data: complete_billing("EE"),
                 user_uuid: user.uuid
               )

      assert_activity_logged("shop.order_converted",
        resource_uuid: cart.uuid,
        metadata_has: %{"failure_reason" => "cart_not_active"}
      )
    end
  end

  describe "opening checkout right after the order was placed" do
    test "a logged-in shopper is sent to that order", %{conn: conn} do
      {:ok, conn: conn, user: user, cart: cart} = logged_in(%{conn: conn})

      {:ok, order} =
        Shop.convert_cart_to_order(cart,
          billing_data: complete_billing("EE"),
          user_uuid: user.uuid
        )

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, "/checkout")
      assert to =~ "/checkout/complete/#{order.uuid}"
    end

    test "a guest is sent to it by the session that placed it", %{conn: conn} do
      {conn, cart} = guest(conn, true)
      {:ok, order} = Shop.convert_cart_to_order(cart, billing_data: complete_billing("EE"))

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, "/checkout")
      assert to =~ "/checkout/complete/#{order.uuid}"
    end

    test "a session of untrusted provenance is not", %{conn: conn} do
      {conn, cart} = guest(conn, false)
      {:ok, _order} = Shop.convert_cart_to_order(cart, billing_data: complete_billing("EE"))

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, "/checkout")
      assert to =~ "/cart"
    end

    test "another visitor is told their cart is empty", %{conn: conn} do
      {_conn, cart} = guest(conn, true)
      {:ok, _order} = Shop.convert_cart_to_order(cart, billing_data: complete_billing("EE"))

      other = Plug.Test.init_test_session(conn, %{"shop_session_id" => "someone-else"})

      assert {:error, {:live_redirect, %{to: to}}} = live(other, "/checkout")
      assert to =~ "/cart"
    end

    test "an order older than the window is not offered", %{conn: conn} do
      {conn, cart} = guest(conn, true)
      {:ok, order} = Shop.convert_cart_to_order(cart, billing_data: complete_billing("EE"))

      Repo.update_all(
        from(o in Billing.Order, where: o.uuid == ^order.uuid),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -3600, :second)]
      )

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, "/checkout")
      assert to =~ "/cart"
    end
  end
end
