defmodule PhoenixKitEcommerce.Web.StorefrontHeadTagsTest do
  @moduledoc """
  The storefront hands the host's root layout three assigns: `og`,
  `canonical_url` and `hreflang_links`. The test root layout renders them
  the way a host has to, so each page is checked for what actually lands
  in `<head>` on the first (crawler-visible) render.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Web.SEOHelpers

  setup do
    Settings.update_setting("languages_enabled", "true")

    Settings.update_json_setting("languages_config", %{
      "languages" => [
        %{"code" => "en-US", "name" => "English", "is_default" => true, "is_enabled" => true},
        %{"code" => "fr", "name" => "French", "is_default" => false, "is_enabled" => true}
      ]
    })

    on_exit(fn -> Settings.update_setting("languages_enabled", "false") end)
    :ok
  end

  defp head_html(conn, path) do
    html = conn |> get(path) |> html_response(200)
    [head, _body] = String.split(html, "</head>", parts: 2)
    head
  end

  defp assert_head_tags(head, seo) do
    assert head =~ ~s(<link rel="canonical" href="#{seo.canonical_url}">)
    assert head =~ ~s(<meta property="og:url" content="#{seo.og.url}">)
    assert head =~ ~s(<meta property="og:type" content="#{seo.og.type}">)

    assert seo.hreflang_links != []

    for %{code: code, url: url} <- seo.hreflang_links do
      assert head =~ ~s(<link rel="alternate" hreflang="#{code}" href="#{url}">)
    end
  end

  test "the catalog page", %{conn: conn} do
    seo = SEOHelpers.catalog_seo("en-US")

    assert Enum.map(seo.hreflang_links, & &1.code) |> Enum.sort() == ["en", "fr"]
    assert_head_tags(head_html(conn, "/shop"), seo)
  end

  test "a category page", %{conn: conn} do
    {:ok, category} =
      Shop.create_category(%{
        "name" => %{"en-US" => "Vases", "fr" => "Les Vases"},
        "slug" => %{"en-US" => "vases", "fr" => "les-vases"},
        "status" => "active"
      })

    seo = SEOHelpers.category_seo(category, "en-US")

    head = head_html(conn, "/shop/category/vases")
    assert_head_tags(head, seo)
    assert head =~ ~s(<meta property="og:title" content="#{seo.og.title}">)
  end

  test "a product page", %{conn: conn} do
    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en-US" => "Tall Vase", "fr" => "Grand Vase"},
        "slug" => %{"en-US" => "tall-vase", "fr" => "grand-vase"},
        "price" => Decimal.new("12.00"),
        "currency" => "USD",
        "status" => "active"
      })

    seo = SEOHelpers.product_seo(product, "en-US")

    head = head_html(conn, "/shop/product/tall-vase")
    assert_head_tags(head, seo)
    assert head =~ ~s(<meta property="og:title" content="#{seo.og.title}">)
  end
end
