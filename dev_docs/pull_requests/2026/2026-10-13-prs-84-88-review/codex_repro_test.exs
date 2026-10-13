defmodule EcommerceCodexReviewReproTest do
  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Options
  alias PhoenixKitEcommerce.ShopConfig
  alias PhoenixKitEcommerce.Test.Repo
  alias PhoenixKitEcommerce.Web.Helpers
  alias PhoenixKitEcommerce.Shopify.StorefrontClient

  test "category option editing preserves its original key", %{conn: conn} do
    {:ok, category} = Shop.create_category(%{name: %{"en" => "Review Category"}})

    {:ok, category} =
      Options.update_category_options(category, [
        %{"key" => "mounting", "label" => "Mounting", "type" => "text"}
      ])

    conn = put_test_scope(conn, fake_scope())
    {:ok, view, _} = live(conn, "/en/admin/shop/categories/#{category.uuid}/edit")
    render_click(view, "show_edit_opt_modal", %{"key" => "mounting"})

    render_submit(view, "save_category_option", %{
      "option" => %{"label" => "Installation", "type" => "text"}
    })

    assert [%{"key" => "mounting", "label" => "Installation"}] =
             Options.get_category_options(Shop.get_category!(category.uuid))
  end

  test "a legacy record edit link still opens its own editor under the catalogue source", %{
    conn: conn
  } do
    {:ok, product} =
      Shop.create_product(%{title: %{"en" => "Review Product"}, price: Decimal.new("1")})

    Repo.insert!(
      ShopConfig.changeset(%ShopConfig{}, %{
        key: "shop_product_source",
        value: %{"value" => "catalogue"}
      })
    )

    path = Helpers.admin_edit_path(:item, product)
    # The test router defines the locale-prefixed legacy form.
    path = String.replace_prefix(path, "/admin/", "/en/admin/")
    assert {:ok, _view, _html} = live(put_test_scope(conn, fake_scope()), path)
  end

  test "a storefront redirect is followed to a private HTTP address" do
    Req.Test.stub(:codex_redirect_review, fn conn ->
      case conn.host do
        "review.myshopify.com" ->
          conn
          |> Plug.Conn.put_resp_header("location", "http://127.0.0.1/internal")
          |> Plug.Conn.send_resp(302, "")

        "127.0.0.1" ->
          send(self(), {:private_hop, conn.scheme, conn.request_path})

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, Jason.encode!(%{"products" => []}))
      end
    end)

    assert {:ok, []} =
             StorefrontClient.fetch_products("review.myshopify.com",
               req_options: [plug: {Req.Test, :codex_redirect_review}],
               page_delay_ms: 0
             )

    assert_received {:private_hop, :http, "/internal"}
  end
end

defmodule EcommerceCodexGuestReviewReproTest do
  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitEcommerce, as: Shop

  defp guest_cart do
    n = System.unique_integer([:positive])
    {:ok, cart} = Shop.create_cart(session_id: "codex-review-#{n}")

    {:ok, product} =
      Shop.create_product(%{
        title: %{"en" => "Review #{n}"},
        price: Decimal.new("1"),
        status: "active",
        currency: "USD",
        requires_shipping: false
      })

    {:ok, cart} = Shop.add_to_cart(cart, product, 1)
    cart
  end

  test "an old guest order without proof prevents returning guest checkout" do
    email = "review-old-#{System.unique_integer([:positive])}@example.com"
    billing = Map.put(complete_billing("US"), "email", email)
    {:ok, order} = Shop.convert_cart_to_order(guest_cart(), billing_data: billing)
    old_metadata = Map.drop(order.metadata, ["guest_checkout", "guest_checkout_email"])
    Repo.update!(Ecto.Changeset.change(order, metadata: old_metadata))

    assert {:error, :email_already_registered} =
             Shop.convert_cart_to_order(guest_cart(), billing_data: billing)
  end

  test "the proposed old-order backfill would qualify a registered account that forged its source" do
    _bootstrap = fixture_user()
    email = "review-forged-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Auth.register_user(%{"email" => email, "password" => "known-password-123"})

    {:ok, user} =
      Auth.update_user_profile(user, %{"custom_fields" => %{"source" => "guest_checkout"}})

    assert user.custom_fields["source"] == "guest_checkout"
    billing = Map.put(complete_billing("US"), "email", email)

    {:ok, order} =
      Shop.convert_cart_to_order(guest_cart(), user_uuid: user.uuid, billing_data: billing)

    assert order.metadata["source"] == "shop_checkout"
    assert order.billing_snapshot["email"] == email
    refute order.metadata["guest_checkout"]
    assert is_nil(user.confirmed_at)

    metadata =
      Map.merge(order.metadata, %{"guest_checkout" => true, "guest_checkout_email" => email})

    Repo.update!(Ecto.Changeset.change(order, metadata: metadata))
    refreshed_user = Auth.get_user_by_email(email)
    assert refreshed_user.custom_fields["source"] == "guest_checkout"
    assert is_nil(refreshed_user.confirmed_at)

    assert Repo.exists?(
             from(o in PhoenixKitBilling.Order,
               where:
                 o.user_uuid == ^user.uuid and
                   fragment("?->>'guest_checkout' = 'true'", o.metadata) and
                   fragment("?->>'guest_checkout_email' = ?", o.metadata, ^email)
             )
           )

    assert {:ok, guest_order} = Shop.convert_cart_to_order(guest_cart(), billing_data: billing)
    assert guest_order.user_uuid == user.uuid
  end
end
