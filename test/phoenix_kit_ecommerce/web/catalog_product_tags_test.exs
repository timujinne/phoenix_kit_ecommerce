defmodule PhoenixKitEcommerce.Web.CatalogProductTagsTest do
  @moduledoc """
  Tags reach the storefront from Shopify as one untranslated list on
  `data["ecommerce"]["tags"]` — there is no per-language variant. Shown on
  a translated page they would be its only untranslated text, so they stay
  on the default-language page and are hidden elsewhere.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Web.Helpers

  defp lang do
    PhoenixKitEcommerce.SlugResolver.normalize_language_public(
      PhoenixKitEcommerce.Translations.default_language()
    )
  end

  describe "tags_visible?/1" do
    setup do
      Settings.update_json_setting("languages_config", %{
        "languages" => [
          %{"code" => "en", "name" => "English", "is_default" => true, "is_enabled" => true},
          %{"code" => "fr", "name" => "French", "is_default" => false, "is_enabled" => true},
          %{"code" => "de", "name" => "German", "is_default" => false, "is_enabled" => true}
        ]
      })

      :ok
    end

    test "a page dialect matches a base-code default" do
      assert Helpers.tags_visible?("en-US")
      assert Helpers.tags_visible?("en")
    end

    test "every other language may not" do
      refute Helpers.tags_visible?("fr")
      refute Helpers.tags_visible?("de")
      refute Helpers.tags_visible?(nil)
    end
  end

  test "tags stay visible when the configured default is a non-canonical dialect" do
    Settings.update_json_setting("languages_config", %{
      "languages" => [
        %{
          "code" => "en-GB",
          "name" => "English (UK)",
          "is_default" => true,
          "is_enabled" => true
        },
        %{"code" => "fr", "name" => "French", "is_default" => false, "is_enabled" => true}
      ]
    })

    # The storefront resolves `"en"` to the canonical dialect `"en-US"`;
    # comparing dialects would hide tags on the shop's own default page.
    assert Helpers.tags_visible?("en-US")
    assert Helpers.tags_visible?("en-GB")
    refute Helpers.tags_visible?("fr")
  end

  test "the default-language product page renders the badges", %{conn: conn} do
    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Wall shelf", lang() => "Wall shelf"},
        "slug" => %{lang() => "tags-#{System.unique_integer([:positive])}"},
        "price" => Decimal.new("40.00"),
        "status" => "active",
        "currency" => "USD",
        "tags" => ["mushroom", "wall decor"]
      })

    {:ok, _view, html} = live(conn, "/shop/product/#{product.slug[lang()]}")

    assert html =~ "mushroom"
    assert html =~ "wall decor"
  end
end
