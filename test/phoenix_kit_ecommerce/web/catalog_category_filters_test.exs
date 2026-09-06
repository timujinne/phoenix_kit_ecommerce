defmodule PhoenixKitEcommerce.Web.CatalogCategoryFiltersTest do
  @moduledoc """
  Per-category `storefront_filters` overrides on the public category page
  (2026-09-06 plan, Task 2): a filter key configured only on the category
  (absent from the global storefront filter config) still renders in the
  sidebar.

  Needs `phoenix_kit_catalogue` loaded — excluded via `test_helper.exs`
  whenever the optional dependency isn't present, same as every other
  `:catalogue` test. `async: false`: flips the process-wide
  `shop_product_source` config key.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  @moduletag :catalogue

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}
  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue.AttributeSets}

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.AttributeSets
  alias PhoenixKitEcommerce.ShopConfig
  alias PhoenixKitEcommerce.Test.Repo

  setup do
    set_product_source("catalogue")
    on_exit(fn -> set_product_source("legacy") end)

    {:ok, catalogue} = Catalogue.create_catalogue(%{name: "decor3dprint"})

    {:ok, category} =
      Catalogue.create_category(%{
        name: "Gadgets",
        catalogue_uuid: catalogue.uuid,
        slug: %{"en-US" => "gadgets"},
        data: %{
          "ecommerce" => %{
            "storefront_filters" => %{
              "brand" => %{
                "type" => "vendor",
                "label" => "Brand Spotlight",
                "enabled" => true,
                "position" => 5
              }
            }
          }
        }
      })

    %{catalogue: catalogue, category: category, path: "/shop/category/gadgets"}
  end

  defp set_product_source(value) do
    case Repo.get(ShopConfig, "shop_product_source") do
      nil ->
        %ShopConfig{}
        |> ShopConfig.changeset(%{key: "shop_product_source", value: %{"value" => value}})
        |> Repo.insert!()

      config ->
        config
        |> ShopConfig.changeset(%{value: %{"value" => value}})
        |> Repo.update!()
    end
  end

  test "a category-only filter key (absent from the global config) renders in the sidebar",
       %{conn: conn, path: path} do
    {:ok, _view, html} = live(conn, path)

    assert html =~ "Brand Spotlight"
  end

  describe "per-language attribute-set filter label (2026-09-06 plan, Task 3)" do
    setup %{catalogue: catalogue} do
      # Entities gates on a settings toggle (default false) — same setup
      # `Catalogue.FiltersTest` uses.
      AttributeSets.register_deletion_guard()
      PhoenixKit.Settings.update_setting("entities_enabled", "true")
      on_exit(fn -> PhoenixKit.Settings.update_setting("entities_enabled", "false") end)

      {:ok, set} = AttributeSets.create_set(%{name: "Size"}, actor_uuid: Ecto.UUID.generate())

      {:ok, _} =
        PhoenixKitEntities.set_entity_translation(set, "fr-FR", %{"display_name" => "Taille"})

      {:ok, category} =
        Catalogue.create_category(%{
          name: "Sized goods",
          catalogue_uuid: catalogue.uuid,
          slug: %{"en-US" => "sized-goods", "fr-FR" => "articles-tailles"},
          data: %{
            "ecommerce" => %{
              "storefront_filters" => %{
                "size" => %{
                  "type" => "attribute_set",
                  "set_slug" => "size",
                  "label" => "Size",
                  "enabled" => true,
                  "position" => 6
                }
              }
            }
          }
        })

      %{set: set, category: category}
    end

    test "the sidebar shows the set's own display name, translated for the current locale",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, "/shop/category/sized-goods")
      assert html =~ "Size"

      # The category's OWN fr-FR slug — visiting the en-US slug under
      # `/fr/...` would hit the cross-language redirect path instead of
      # rendering directly (`CatalogCategory.handle_cross_language_redirect/3`).
      {:ok, _view, fr_html} = live(conn, "/fr/shop/category/articles-tailles")
      assert fr_html =~ "Taille"
      refute fr_html =~ ">Size<"
    end
  end
end
