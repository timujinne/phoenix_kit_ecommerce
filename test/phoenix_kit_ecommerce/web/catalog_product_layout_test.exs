defmodule PhoenixKitEcommerce.Web.CatalogProductLayoutTest do
  @moduledoc """
  Pins the storefront product page layout after the description moved out
  of the buy box: the purchase controls come BEFORE the description in the
  document, and the description (Markdown as well as raw-ish HTML, both
  through the same sanitizing `<.markdown>`), the `body_html`, the
  specifications and the collapsed category panel all still render.
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

  test "buy box precedes the description; Markdown and body_html both render below", %{
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

    assert add_to_cart_at < description_at,
           "the Add to Cart button must come before the description in the document"

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

  test "the category panel renders collapsed under the product and honours the setting", %{
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
    assert html =~ ~s(<details class="collapse collapse-arrow)
    assert html =~ "Layout Cat"

    PhoenixKit.Settings.update_setting("shop_sidebar_show_categories", "false")
    on_exit(fn -> PhoenixKit.Settings.update_setting("shop_sidebar_show_categories", "true") end)

    {:ok, _view, html} = live(conn, "/shop/product/#{product.slug[lang()]}")
    refute html =~ ~s(<details class="collapse collapse-arrow)
  end
end
