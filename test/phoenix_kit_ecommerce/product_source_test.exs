defmodule PhoenixKitEcommerce.ProductSourceTest do
  @moduledoc """
  Pins two things for the `ProductSource` switch:

    1. `ProductSource.current/0`'s selection logic: the config key absent
       always falls back to `Legacy`; the key set to "catalogue" selects
       `Catalogue` when `phoenix_kit_catalogue` is loaded (the `:catalogue`
       test bridge in `mix.exs`) and falls back to `Legacy` otherwise (a
       plain `mix test` run, with no dependency on the catalogue package).
    2. The facade's product/category read functions now delegate to
       `ProductSource.current()` with no observable behavior change —
       verified by comparing facade results directly against calling
       `Legacy` ourselves.

  `update_product/2` and `delete_product/2` refusing a `:built` (never
  persisted / view-struct) `%Product{}` is pinned here too — a real bug
  regression test for the future catalogue adapter, whose view-structs
  must never reach `Repo.update/2` or `Repo.delete/2`.
  """

  use PhoenixKitEcommerce.DataCase, async: true

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Category
  alias PhoenixKitEcommerce.Product
  alias PhoenixKitEcommerce.ProductSource
  alias PhoenixKitEcommerce.ProductSource.Catalogue
  alias PhoenixKitEcommerce.ProductSource.Legacy
  alias PhoenixKitEcommerce.ShopConfig
  alias PhoenixKitEcommerce.Test.Repo, as: TestRepo

  defp create_product!(title, attrs \\ %{}) do
    {:ok, product} =
      Shop.create_product(
        Map.merge(
          %{
            "title" => %{"en" => title},
            "price" => Decimal.new("12.34"),
            "status" => "active"
          },
          attrs
        )
      )

    product
  end

  defp put_product_source_config!(value) do
    %ShopConfig{}
    |> ShopConfig.changeset(%{key: "shop_product_source", value: %{"value" => value}})
    |> TestRepo.insert!()
  end

  describe "ProductSource.current/0" do
    test "defaults to Legacy when the config key is absent" do
      assert Shop.get_config("shop_product_source") == nil
      assert ProductSource.current() == Legacy
    end

    test "reads back a stored key via get_config/1" do
      put_product_source_config!("catalogue")
      assert Shop.get_config("shop_product_source") == "catalogue"
    end

    test "\"catalogue\" only selects the Catalogue adapter when phoenix_kit_catalogue is loaded" do
      put_product_source_config!("catalogue")

      # This fork declares `phoenix_kit_catalogue` as an optional dependency
      # (see mix.exs's `catalogue_test_deps/0`) — present under the
      # `:catalogue`-tagged test bridge, absent from a plain `mix test` run.
      # Either way, `ProductSource.current/0` must reflect it precisely:
      # falling back to `Legacy` without the dependency, switching to the
      # `Catalogue` adapter with it.
      expected = if Code.ensure_loaded?(PhoenixKitCatalogue), do: Catalogue, else: Legacy

      assert ProductSource.current() == expected
    end

    test "stays on Legacy for any other stored value" do
      put_product_source_config!("legacy")
      assert ProductSource.current() == Legacy
    end
  end

  describe "facade product/category reads delegate to ProductSource.current/0" do
    test "list_products/1 matches Legacy.list_products/1" do
      product = create_product!("Delegation Fixture")

      via_facade = Shop.list_products(status: "active")
      via_legacy = Legacy.list_products(status: "active")

      assert Enum.map(via_facade, & &1.uuid) == Enum.map(via_legacy, & &1.uuid)
      assert product.uuid in Enum.map(via_facade, & &1.uuid)
    end

    test "list_products_with_count/1 matches Legacy.list_products_with_count/1" do
      create_product!("Fixture A")
      create_product!("Fixture B")

      assert Shop.list_products_with_count(status: "active") ==
               Legacy.list_products_with_count(status: "active")
    end

    test "list_products_by_ids/1 matches Legacy.list_products_by_ids/1" do
      product = create_product!("Fixture By Id")

      assert Shop.list_products_by_ids([product.uuid]) ==
               Legacy.list_products_by_ids([product.uuid])
    end

    test "get_product/2 matches Legacy.get_product/2" do
      product = create_product!("Fixture Get")

      assert Shop.get_product(product.uuid) == Legacy.get_product(product.uuid)
      assert Shop.get_product("not-a-uuid") == nil
    end

    test "list_categories/1 matches Legacy.list_categories/1" do
      {:ok, category} = Shop.create_category(%{"name" => %{"en" => "Delegation Category"}})

      assert Shop.list_categories() |> Enum.map(& &1.uuid) ==
               Legacy.list_categories() |> Enum.map(& &1.uuid)

      assert category.uuid in Enum.map(Shop.list_categories(), & &1.uuid)
    end

    test "get_category/2 matches Legacy.get_category/2" do
      {:ok, category} = Shop.create_category(%{"name" => %{"en" => "Fixture Category"}})

      assert Shop.get_category(category.uuid) == Legacy.get_category(category.uuid)
    end

    test "product_counts_by_category/0 matches Legacy.product_counts_by_category/0" do
      {:ok, category} = Shop.create_category(%{"name" => %{"en" => "Counted Category"}})
      create_product!("Counted Product", %{"category_uuid" => category.uuid})

      assert Shop.product_counts_by_category() == Legacy.product_counts_by_category()
      assert Shop.product_counts_by_category()[category.uuid] == 1
    end

    test "aggregate_filter_values/1 matches Legacy.aggregate_filter_values/1" do
      create_product!("Aggregate Fixture")

      assert Shop.aggregate_filter_values() == Legacy.aggregate_filter_values()
    end

    test "get_price_range_for/1 reflects active product prices" do
      create_product!("Cheap", %{"price" => Decimal.new("5.00")})
      create_product!("Pricey", %{"price" => Decimal.new("50.00")})

      assert Shop.get_price_range_for() == {Decimal.new("5.00"), Decimal.new("50.00")}
      assert Shop.get_price_range_for() == Legacy.get_price_range_for()
    end

    test "get_product_by_slug_localized/3 matches Legacy directly" do
      product = create_product!("Slug Fixture")
      slug = product.slug["en"]

      assert Shop.get_product_by_slug_localized(slug, "en") ==
               Legacy.get_product_by_slug_localized(slug, "en")

      assert {:ok, %Product{uuid: uuid}} = Shop.get_product_by_slug_localized(slug, "en")
      assert uuid == product.uuid
    end

    test "get_product_by_any_slug/2 matches Legacy directly" do
      product = create_product!("Any Slug Fixture")
      slug = product.slug["en"]

      assert Shop.get_product_by_any_slug(slug) == Legacy.get_product_by_any_slug(slug)
    end

    test "get_category_by_slug_localized/3 and get_category_by_any_slug/2 match Legacy directly" do
      {:ok, category} = Shop.create_category(%{"name" => %{"en" => "Slug Category"}})
      slug = category.slug["en"]

      assert Shop.get_category_by_slug_localized(slug, "en") ==
               Legacy.get_category_by_slug_localized(slug, "en")

      assert Shop.get_category_by_any_slug(slug) == Legacy.get_category_by_any_slug(slug)
    end
  end

  describe "update_product/2 and delete_product/2 refuse view-structs" do
    test "update_product/2 returns {:error, :read_only_view} for a :built struct" do
      view = struct(Product, uuid: Ecto.UUID.generate(), title: %{"en" => "View"})
      assert view.__meta__.state == :built

      assert Shop.update_product(view, %{"price" => Decimal.new("2.00")}) ==
               {:error, :read_only_view}
    end

    test "update_product/2 still updates a real (:loaded) product" do
      product = create_product!("Updatable")

      assert {:ok, updated} = Shop.update_product(product, %{"price" => Decimal.new("99.00")})
      assert Decimal.equal?(updated.price, Decimal.new("99.00"))
    end

    test "delete_product/2 returns {:error, :read_only_view} for a :built struct" do
      view = struct(Product, uuid: Ecto.UUID.generate())
      assert Shop.delete_product(view) == {:error, :read_only_view}
    end

    test "delete_product/2 still deletes a real (:loaded) product" do
      product = create_product!("Deletable")

      assert {:ok, _} = Shop.delete_product(product)
      assert Shop.get_product(product.uuid) == nil
    end
  end

  describe "category_image_url/2" do
    test "delegates to Category.get_image_url/2 unchanged" do
      category = %Category{image_uuid: nil, featured_product: nil}

      assert Shop.category_image_url(category, size: "small") ==
               Category.get_image_url(category, size: "small")
    end

    test "resolves a Storage image_uuid the same way Category.get_image_url/2 does" do
      category = %Category{image_uuid: Ecto.UUID.generate(), featured_product: nil}

      assert Shop.category_image_url(category, size: "small") ==
               Category.get_image_url(category, size: "small")
    end
  end
end
