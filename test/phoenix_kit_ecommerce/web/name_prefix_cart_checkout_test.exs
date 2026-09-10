defmodule PhoenixKitEcommerce.Web.NamePrefixCartCheckoutTest do
  @moduledoc """
  `shop_name_prefixes` past the browse pages: the cart, checkout, and
  order-confirmation pages all render a cart/order line's SNAPSHOTTED
  title/name (`CartItem.product_title`, `Order.line_items[]["name"]`),
  never a live `Translations.get/3` read — so `Translations.get_display/3`
  never reaches them. Without a display-time strip at these three sites
  specifically, a shopper would see the prefix stripped everywhere they
  browse and then see it reappear the moment they add to cart — the part
  of the storefront closest to paying. Found on review of PR #51; see
  `PhoenixKitEcommerce.NamePrefix`'s moduledoc and
  `Translations.get_display/3`'s doc for why the STORED snapshot itself
  stays untouched while its on-page rendering does not.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.NamePrefix

  @prefixed_title "3D Printed Costume Masks"
  @stripped_title "Costume Masks"

  defp set_prefix(value), do: PhoenixKit.Settings.update_setting(NamePrefix.setting_key(), value)

  defp digital_cart_session(name) do
    session_id = "name-prefix-cart-#{System.unique_integer([:positive])}"

    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => name},
        "price" => Decimal.new("10.00"),
        "status" => "active",
        "currency" => "USD",
        "product_type" => "digital",
        "requires_shipping" => false,
        "weight_grams" => 0
      })

    {:ok, cart} = Shop.create_cart(session_id: session_id)
    {:ok, cart} = Shop.add_to_cart(cart, product, 1)

    %{session_id: session_id, cart: cart, product: product}
  end

  defp session_conn(conn, session_id, extra \\ %{}) do
    Plug.Test.init_test_session(
      conn,
      Map.merge(%{"shop_session_id" => session_id}, extra)
    )
  end

  describe "cart page" do
    test "renders the stripped title (image alt + line label) with the prefix configured", %{
      conn: conn
    } do
      set_prefix("3D Printed")
      %{session_id: session_id} = digital_cart_session(@prefixed_title)

      {:ok, _view, html} = live(session_conn(conn, session_id), "/cart")

      assert html =~ @stripped_title
      refute html =~ @prefixed_title
    end

    test "renders the RAW title with the default (empty) setting", %{conn: conn} do
      %{session_id: session_id} = digital_cart_session(@prefixed_title)

      {:ok, _view, html} = live(session_conn(conn, session_id), "/cart")

      assert html =~ @prefixed_title
    end
  end

  describe "checkout page" do
    test "renders the stripped title (Order Items, review step) with the prefix configured", %{
      conn: conn
    } do
      set_prefix("3D Printed")
      %{session_id: session_id} = digital_cart_session(@prefixed_title)

      {:ok, view, _html} = live(session_conn(conn, session_id), "/checkout")

      # The digital-only cart needs no shipping, so completing billing and
      # proceeding lands directly on :review, where "Order Items" renders.
      view |> fill_billing_form(country: "EE") |> render_change()
      html = view |> element("button[phx-click='proceed_to_review']") |> render_click()

      assert html =~ "id=\"checkout-review-change-billing\""
      assert html =~ @stripped_title
      refute html =~ @prefixed_title
    end
  end

  describe "order confirmation page" do
    test "renders the stripped line-item name with the prefix configured, while the STORED order keeps the raw name",
         %{conn: conn} do
      set_prefix("3D Printed")
      %{session_id: session_id, cart: cart} = digital_cart_session(@prefixed_title)

      {:ok, order} =
        Shop.convert_cart_to_order(cart,
          billing_data: complete_billing("EE", "name-prefix-checkout-complete")
        )

      # The persisted order line item is exactly the RAW title — proves
      # the strip never reaches the write/conversion path, only the
      # confirmation page's OWN render of it.
      assert [%{"name" => @prefixed_title}] = order.line_items

      conn = session_conn(conn, session_id, %{"shop_session_trusted" => true})

      {:ok, _view, html} = live(conn, "/checkout/complete/#{order.uuid}")

      assert html =~ @stripped_title
      refute html =~ @prefixed_title
    end
  end
end
