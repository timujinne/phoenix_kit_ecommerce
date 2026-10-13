defmodule PhoenixKitEcommerce.CartQuantityBoundsTest do
  @moduledoc """
  A cart line's quantity is typed by an anonymous shopper into an int4
  column. It is bounded in the changeset and in the context, and the two
  storefront pages that send it survive any value.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.CartItem

  @max CartItem.max_quantity()
  @huge 99_999_999_999

  defp lang do
    PhoenixKitEcommerce.SlugResolver.normalize_language_public(
      PhoenixKitEcommerce.Translations.default_language()
    )
  end

  setup %{conn: conn} do
    n = System.unique_integer([:positive])

    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Bolt #{n}", lang() => "Bolt #{n}"},
        "slug" => %{lang() => "qty-bounds-#{n}"},
        "price" => Decimal.new("2.00"),
        "status" => "active",
        "currency" => "USD",
        "requires_shipping" => false
      })

    session_id = "qty-bounds-#{n}"
    {:ok, cart} = Shop.create_cart(session_id: session_id)
    conn = Plug.Test.init_test_session(conn, %{"shop_session_id" => session_id})

    %{conn: conn, cart: cart, product: product}
  end

  defp line(cart), do: hd(Shop.get_cart!(cart.uuid).items)

  describe "CartItem.changeset/2" do
    test "accepts the ceiling and refuses one past it" do
      attrs = %{
        cart_uuid: Ecto.UUID.generate(),
        product_title: "x",
        unit_price: Decimal.new("1"),
        currency: "USD"
      }

      assert CartItem.changeset(%CartItem{}, Map.put(attrs, :quantity, @max)).valid?

      changeset = CartItem.changeset(%CartItem{}, Map.put(attrs, :quantity, @max + 1))
      assert %{quantity: [_]} = errors_on(changeset)
    end
  end

  describe "add_to_cart/4" do
    for {label, quantity} <- [
          {"past the ceiling", @max + 1},
          {"past int4", @huge},
          {"zero", 0},
          {"negative", -3},
          {"not an integer", "12"}
        ] do
      test "refuses a quantity #{label}", %{cart: cart, product: product} do
        assert {:error, :invalid_quantity} = Shop.add_to_cart(cart, product, unquote(quantity))

        assert {:error, :invalid_quantity} =
                 Shop.add_to_cart(cart, product, unquote(quantity), language: lang())

        assert Shop.get_cart!(cart.uuid).items == []
      end
    end

    test "adding to an existing line stops at the ceiling", %{cart: cart, product: product} do
      {:ok, cart} = Shop.add_to_cart(cart, product, @max - 1)
      {:ok, cart} = Shop.add_to_cart(cart, product, 5)

      assert line(cart).quantity == @max
    end
  end

  describe "update_cart_item/2" do
    for {label, quantity} <- [
          {"past the ceiling", @max + 1},
          {"past int4", @huge},
          {"negative", -1},
          {"not an integer", "12"}
        ] do
      test "refuses a quantity #{label}", %{cart: cart, product: product} do
        {:ok, cart} = Shop.add_to_cart(cart, product, 2)

        assert {:error, :invalid_quantity} =
                 Shop.update_cart_item(line(cart), unquote(quantity))

        assert line(cart).quantity == 2
      end
    end

    test "accepts the ceiling", %{cart: cart, product: product} do
      {:ok, cart} = Shop.add_to_cart(cart, product, 2)

      assert {:ok, _cart} = Shop.update_cart_item(line(cart), @max)
      assert line(cart).quantity == @max
    end
  end

  describe "the cart page" do
    setup %{cart: cart, product: product} do
      {:ok, cart} = Shop.add_to_cart(cart, product, 2)
      %{item: line(cart)}
    end

    test "a huge quantity is clamped, not a crash", %{conn: conn, cart: cart, item: item} do
      {:ok, view, _html} = live(conn, "/cart")

      render_change(view, "update_quantity", %{
        "item_uuid" => item.uuid,
        "quantity" => "#{@huge}"
      })

      assert line(cart).quantity == @max
    end

    for {label, quantity} <- [{"negative", "-5"}, {"text", "lots"}, {"a map", %{"a" => 1}}] do
      test "#{label} falls back to one", %{conn: conn, cart: cart, item: item} do
        {:ok, view, _html} = live(conn, "/cart")

        render_change(view, "update_quantity", %{
          "item_uuid" => item.uuid,
          "quantity" => unquote(Macro.escape(quantity))
        })

        assert line(cart).quantity == 1
      end
    end

    test "an event without its fields is ignored", %{conn: conn, cart: cart} do
      {:ok, view, _html} = live(conn, "/cart")

      render_change(view, "update_quantity", %{})

      assert line(cart).quantity == 2
    end
  end

  describe "the product page" do
    test "a huge typed quantity adds the ceiling, not a crash", ctx do
      %{conn: conn, cart: cart, product: product} = ctx
      {:ok, view, _html} = live(conn, "/shop/product/#{product.slug[lang()]}")

      render_change(view, "set_quantity", %{"quantity" => "#{@huge}"})
      render_click(view, "add_to_cart", %{})

      assert line(cart).quantity == @max
    end

    test "incrementing stops at the ceiling", %{conn: conn, product: product} do
      {:ok, view, _html} = live(conn, "/shop/product/#{product.slug[lang()]}")

      render_change(view, "set_quantity", %{"quantity" => "#{@max}"})
      html = render_click(view, "increment", %{})

      assert html =~ ~s(value="#{@max}")
    end

    test "text, a negative or a missing value leaves the page standing", ctx do
      %{conn: conn, product: product} = ctx
      {:ok, view, _html} = live(conn, "/shop/product/#{product.slug[lang()]}")

      assert render_change(view, "set_quantity", %{"quantity" => "lots"}) =~ ~s(value="1")
      assert render_change(view, "set_quantity", %{"quantity" => "-9"}) =~ ~s(value="1")
      assert render_change(view, "set_quantity", %{}) =~ ~s(value="1")
    end
  end
end
