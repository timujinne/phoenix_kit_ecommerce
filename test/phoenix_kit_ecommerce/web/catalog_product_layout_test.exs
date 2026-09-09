defmodule PhoenixKitEcommerce.Web.CatalogProductLayoutTest do
  @moduledoc """
  Pins the storefront product page layout. The gallery, the buy box and the
  description are three sibling grid items: on a wide screen the description
  sits under the gallery in the left column, and on the single column a phone
  gets they stack gallery -> buy box -> description, so the purchase controls
  still come BEFORE the description in the document. The description (Markdown
  as well as raw-ish HTML, both through the same sanitizing `<.markdown>`), the
  `body_html`, the specifications and the category filter all still render.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitEcommerce, as: Shop

  defp lang do
    PhoenixKitEcommerce.SlugResolver.normalize_language_public(
      PhoenixKitEcommerce.Translations.default_language()
    )
  end

  # The changeset wants the base "en" key; the storefront reads the dialect.
  defp t(text), do: %{"en" => text, lang() => text}

  defp create_product(attrs) do
    Shop.create_product(
      Map.merge(
        %{
          "title" => t("Layout Probe"),
          "slug" => %{lang() => "layout-probe-#{System.unique_integer([:positive])}"},
          "price" => Decimal.new("10.00"),
          "status" => "active",
          "currency" => "USD",
          "requires_shipping" => false
        },
        attrs
      )
    )
  end

  test "the buy box precedes the description, which is placed under the gallery", %{
    conn: conn
  } do
    {:ok, product} =
      create_product(%{
        "description" => t("Short **bold** intro"),
        "body_html" => t("## Long supplier text\n\n- point one\n- point two")
      })

    {:ok, _view, html} = live(conn, "/shop/product/#{product.slug[lang()]}")

    add_to_cart_at = :binary.match(html, "phx-click=\"add_to_cart\"") |> elem(0)
    description_at = :binary.match(html, "Short <strong>bold</strong> intro") |> elem(0)
    body_at = :binary.match(html, "Long supplier text") |> elem(0)

    # Document order is what a phone stacks, so the purchase controls stay
    # ahead of the description — the defect #44 fixed. The description is
    # still under the gallery on a wide screen: it is a sibling grid item
    # placed in the gallery's column, one row down.
    assert add_to_cart_at < description_at,
           "Add to Cart must precede the description, which is what a phone stacks"

    assert html =~ ~s(<section class="md:col-start-1 md:row-start-2">),
           "the description must be placed in the gallery's column, one row down"

    assert description_at < body_at
    assert html =~ "<li>point one</li>"
  end

  test "an HTML description is sanitized, not dropped, and whitespace-only text renders nothing",
       %{
         conn: conn
       } do
    {:ok, product} =
      create_product(%{
        "description" => t("<p>Plain <em>html</em></p><script>alert(1)</script>"),
        "body_html" => t("   \n  ")
      })

    {:ok, _view, html} = live(conn, "/shop/product/#{product.slug[lang()]}")

    assert html =~ "Plain <em>html</em>"
    refute html =~ "<script>"
    # A whitespace-only body must not open an empty block under the intro.
    refute html =~ ~s(<div class="mt-4">)
  end

  test "the category filter renders in the buy-box column and honours the setting", %{
    conn: conn
  } do
    {:ok, category} =
      Shop.create_category(%{
        "name" => t("Layout Cat"),
        "slug" => %{lang() => "layout-cat-#{System.unique_integer([:positive])}"},
        "status" => "active"
      })

    {:ok, product} = create_product(%{"category_uuid" => category.uuid})

    {:ok, _view, html} = live(conn, "/shop/product/#{product.slug[lang()]}")
    assert html =~ ~s(id="product-category-filter")
    assert html =~ "Layout Cat"

    # It sits below the cart button, in the same column — not in a panel at
    # the foot of the page.
    cart = :binary.match(html, "add_to_cart") |> elem(0)
    filter = :binary.match(html, ~s(id="product-category-filter")) |> elem(0)
    assert cart < filter
    refute html =~ ~s(<details class="collapse collapse-arrow)

    PhoenixKit.Settings.update_setting("shop_sidebar_show_categories", "false")
    on_exit(fn -> PhoenixKit.Settings.update_setting("shop_sidebar_show_categories", "true") end)

    {:ok, _view, html} = live(conn, "/shop/product/#{product.slug[lang()]}")
    refute html =~ ~s(id="product-category-filter")
  end

  describe "the top row" do
    test "breadcrumbs and the cart share one row, and the bar carries no Shop link", %{
      conn: conn
    } do
      {:ok, product} = create_product(%{})

      {:ok, _view, html} = live(conn, "/shop/product/#{product.slug[lang()]}")

      # One row: the breadcrumbs open it, the cart link closes it, and the
      # page heading comes after both.
      crumbs = :binary.match(html, ~s(class="breadcrumbs text-sm")) |> elem(0)
      cart = :binary.match(html, "/cart") |> elem(0)
      heading = :binary.match(html, ~s(class="text-3xl font-bold)) |> elem(0)

      assert crumbs < cart
      assert cart < heading

      # The bar used to carry its own "Shop" link beside the crumb that
      # already links there; only the crumb is left.
      assert html
             |> String.split(~s(class="breadcrumbs))
             |> hd()
             |> String.contains?("hero-building-storefront") == false
    end
  end
end
