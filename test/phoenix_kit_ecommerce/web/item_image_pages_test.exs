defmodule PhoenixKitEcommerce.Web.ItemImagePagesTest do
  @moduledoc """
  The cart page and the checkout summary draw a line's picture through
  `PhoenixKitEcommerce.ItemImage.url/1`: the host app's fallback fills in for
  a line without a product photo, and the module's icon stays otherwise.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitEcommerce, as: Shop

  defmodule Art do
    def item_url(_item, prefix), do: "#{prefix}/widget.svg"
  end

  setup %{conn: conn} do
    previous = Application.get_env(:phoenix_kit_ecommerce, :item_image_fallback)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit_ecommerce, :item_image_fallback, previous),
        else: Application.delete_env(:phoenix_kit_ecommerce, :item_image_fallback)
    end)

    Application.delete_env(:phoenix_kit_ecommerce, :item_image_fallback)

    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Item Image Widget"},
        "price" => Decimal.new("25.00"),
        "status" => "active",
        "currency" => "USD",
        "product_type" => "digital",
        "requires_shipping" => false
      })

    session_id = "item-image-pages-#{System.unique_integer([:positive])}"
    {:ok, cart} = Shop.create_cart(session_id: session_id)
    {:ok, _cart} = Shop.add_to_cart(cart, product, 1)

    %{conn: Plug.Test.init_test_session(conn, %{"shop_session_id" => session_id})}
  end

  for path <- ["/cart", "/checkout"] do
    test "#{path}: a line without a photo shows the host app's picture", %{conn: conn} do
      Application.put_env(
        :phoenix_kit_ecommerce,
        :item_image_fallback,
        {Art, :item_url, ["/art"]}
      )

      html = line_html(conn, unquote(path))

      assert html =~ ~s(src="/art/widget.svg")
      refute html =~ "hero-cube"
    end

    test "#{path}: with no fallback configured, the icon stays", %{conn: conn} do
      html = line_html(conn, unquote(path))

      assert html =~ "hero-cube"
      refute html =~ "/art/widget.svg"
    end
  end

  # The cart page lists its lines on mount; the checkout lists them in the
  # order summary of the review step, reached through the billing form.
  defp line_html(conn, "/cart") do
    {:ok, _view, html} = live(conn, "/cart")
    html
  end

  defp line_html(conn, "/checkout") do
    {:ok, view, _html} = live(conn, "/checkout")

    view |> fill_billing_form(country: "EE") |> render_change()
    view |> element("button[phx-click='proceed_to_review']") |> render_click()
  end
end
