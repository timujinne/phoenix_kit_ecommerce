defmodule PhoenixKitEcommerce.DashboardStatsSourceTest do
  @moduledoc """
  The admin dashboard's totals and the settings page's discovered option
  keys describe the ACTIVE product source — the same one the Products tab
  lists — not whatever happens to sit in the legacy tables.

  Needs `phoenix_kit_catalogue`; `async: false` because it flips the
  process-wide `shop_product_source` key.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :catalogue
  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.ShopConfig
  alias PhoenixKitEcommerce.Test.Repo

  defp lang do
    PhoenixKitEcommerce.SlugResolver.normalize_language_public(
      PhoenixKitEcommerce.Translations.default_language()
    )
  end

  defp set_product_source(value) do
    case Repo.get(ShopConfig, "shop_product_source") do
      nil ->
        %ShopConfig{}
        |> ShopConfig.changeset(%{key: "shop_product_source", value: %{"value" => value}})
        |> Repo.insert!()

      config ->
        config |> ShopConfig.changeset(%{value: %{"value" => value}}) |> Repo.update!()
    end
  end

  defp item(catalogue, name, ecommerce) do
    {:ok, item} =
      Catalogue.create_item(%{
        catalogue_uuid: catalogue.uuid,
        name: name,
        base_price: Decimal.new("10.00"),
        status: "active",
        data: %{"ecommerce" => ecommerce}
      })

    item
  end

  setup do
    on_exit(fn -> set_product_source("legacy") end)

    {:ok, catalogue} = Catalogue.create_catalogue(%{name: "decor3dprint"})
    {:ok, _} = Catalogue.create_category(%{catalogue_uuid: catalogue.uuid, name: "Vases"})
    {:ok, _} = Catalogue.create_category(%{catalogue_uuid: catalogue.uuid, name: "Bowls"})

    item(catalogue, "Red Vase", %{"shop_status" => "active"})
    item(catalogue, "Blue Vase", %{"shop_status" => "active", "product_type" => "digital"})
    item(catalogue, "Green Bowl", %{"shop_status" => "draft"})

    # One legacy product, with an option key only the legacy table knows.
    {:ok, _} =
      Shop.create_product(%{
        "title" => %{"en" => "Legacy Wand", lang() => "Legacy Wand"},
        "slug" => %{lang() => "legacy-wand-#{System.unique_integer([:positive])}"},
        "price" => Decimal.new("5.00"),
        "status" => "active",
        "currency" => "USD",
        "metadata" => %{"_option_values" => %{"size" => ["S"]}}
      })

    :ok
  end

  test "under the catalogue source the totals count catalogue items and categories" do
    set_product_source("catalogue")

    stats = Shop.get_dashboard_stats()

    assert stats.total_products == 3
    assert stats.active_products == 2
    assert stats.draft_products == 1
    assert stats.archived_products == 0
    assert stats.physical_products == 2
    assert stats.digital_products == 1
    assert stats.total_categories == 2

    assert %{products_count: 3, categories_count: 2} = Shop.get_config()
    assert Shop.discover_filterable_options() == []
  end

  test "under the legacy source they count the legacy tables" do
    set_product_source("legacy")

    stats = Shop.get_dashboard_stats()

    assert stats.total_products == 1
    assert stats.active_products == 1
    assert stats.draft_products == 0
    assert stats.physical_products == 1
    assert stats.total_categories == 0

    assert Shop.discover_filterable_options() == [%{key: "size", count: 1}]
  end
end
