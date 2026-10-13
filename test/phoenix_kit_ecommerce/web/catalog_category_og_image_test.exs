defmodule PhoenixKitEcommerce.Web.CatalogCategoryOgImageTest do
  @moduledoc """
  The category page hands core's root layout an `og.image`, chosen like the
  image the storefront itself shows for the category: its own image, else
  its featured product's. The fallback only works when the page loads the
  featured product, so this pins the observable `og` assign on the
  rendered page rather than `SEOHelpers.category_seo/2` alone — a page
  that forgot the preload would pass the helper's tests and ship no image.

  The catalogue half needs `phoenix_kit_catalogue` loaded and is tagged
  `:catalogue`; `async: false` because it flips the process-wide
  `shop_product_source` config key.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.ShopConfig
  alias PhoenixKitEcommerce.Test.Repo

  defp lang do
    PhoenixKitEcommerce.SlugResolver.normalize_language_public(
      PhoenixKitEcommerce.Translations.default_language()
    )
  end

  defp t(text), do: %{"en" => text, lang() => text}

  defp stored_image do
    {:ok, file} =
      Storage.create_file(%{
        original_file_name: "probe.png",
        file_name: "probe.png",
        mime_type: "image/png",
        file_type: "image",
        ext: "png",
        file_checksum: "c#{System.unique_integer([:positive])}",
        user_file_checksum: "u#{System.unique_integer([:positive])}",
        size: 100,
        status: "active",
        user_uuid: PhoenixKitEcommerce.DataCase.fixture_user().uuid
      })

    {:ok, _} =
      Storage.create_file_instance(%{
        file_uuid: file.uuid,
        variant_name: "large",
        file_name: "probe-large.png",
        mime_type: "image/png",
        ext: "png",
        checksum: "i#{System.unique_integer([:positive])}",
        size: 100
      })

    file.uuid
  end

  defp create_product(attrs) do
    {:ok, product} =
      Shop.create_product(
        Map.merge(
          %{
            "title" => t("OG Product"),
            "slug" => %{lang() => "og-product-#{System.unique_integer([:positive])}"},
            "price" => Decimal.new("10.00"),
            "status" => "active",
            "currency" => "USD",
            "requires_shipping" => false
          },
          attrs
        )
      )

    product
  end

  defp create_category(attrs) do
    {:ok, category} =
      Shop.create_category(
        Map.merge(
          %{
            "name" => t("OG Category"),
            "slug" => %{lang() => "og-category-#{System.unique_integer([:positive])}"},
            "status" => "active"
          },
          attrs
        )
      )

    category
  end

  defp og(view), do: :sys.get_state(view.pid).socket.assigns.og

  defp large(image), do: Routes.base_url() <> URLSigner.signed_url(image, "large")

  describe "legacy source" do
    test "a category's own image is the og image", %{conn: conn} do
      image = stored_image()
      category = create_category(%{"image_uuid" => image})

      {:ok, view, _html} = live(conn, "/shop/category/#{category.slug[lang()]}")

      assert og(view).image == large(image)
      assert og(view).image_alt == "OG Category"
    end

    test "without an image of its own, the featured product's image is", %{conn: conn} do
      image = stored_image()
      product = create_product(%{"featured_image_uuid" => image})
      category = create_category(%{"featured_product_uuid" => product.uuid})

      {:ok, view, _html} = live(conn, "/shop/category/#{category.slug[lang()]}")

      assert og(view).image == large(image)
    end

    test "its own image wins over the featured product's", %{conn: conn} do
      own = stored_image()
      other = stored_image()
      product = create_product(%{"featured_image_uuid" => other})

      category =
        create_category(%{"image_uuid" => own, "featured_product_uuid" => product.uuid})

      {:ok, view, _html} = live(conn, "/shop/category/#{category.slug[lang()]}")

      assert og(view).image == large(own)
    end

    test "a category with no image anywhere assigns no og image", %{conn: conn} do
      category = create_category(%{})

      {:ok, view, _html} = live(conn, "/shop/category/#{category.slug[lang()]}")

      refute Map.has_key?(og(view), :image)
      refute Map.has_key?(og(view), :image_alt)
    end
  end

  describe "catalogue source" do
    @describetag :catalogue

    setup do
      case Repo.get(ShopConfig, "shop_product_source") do
        nil ->
          %ShopConfig{}
          |> ShopConfig.changeset(%{key: "shop_product_source", value: %{"value" => "catalogue"}})
          |> Repo.insert!()

        config ->
          config |> ShopConfig.changeset(%{value: %{"value" => "catalogue"}}) |> Repo.update!()
      end

      on_exit(fn ->
        Repo.get(ShopConfig, "shop_product_source")
        |> ShopConfig.changeset(%{value: %{"value" => "legacy"}})
        |> Repo.update!()
      end)

      {:ok, catalogue} = PhoenixKitCatalogue.Catalogue.create_catalogue(%{name: "decor3dprint"})
      %{catalogue: catalogue}
    end

    defp catalogue_category(catalogue, slug, data \\ %{}) do
      {:ok, category} =
        PhoenixKitCatalogue.Catalogue.create_category(%{
          name: "Catalogue Category",
          catalogue_uuid: catalogue.uuid,
          slug: %{"en-US" => slug},
          data: Map.merge(%{"ecommerce" => %{"shop_status" => "active"}}, data)
        })

      category
    end

    defp catalogue_item(catalogue, category, data) do
      {:ok, item} =
        PhoenixKitCatalogue.Catalogue.create_item(%{
          catalogue_uuid: catalogue.uuid,
          category_uuid: category.uuid,
          name: "Catalogue Item",
          base_price: Decimal.new("12.00"),
          status: "active",
          slug: %{"en-US" => "item-#{System.unique_integer([:positive])}"},
          data: Map.merge(%{"ecommerce" => %{"shop_status" => "active"}}, data)
        })

      item
    end

    test "without an image of its own, the category takes its item's image", %{
      conn: conn,
      catalogue: catalogue
    } do
      image = stored_image()
      category = catalogue_category(catalogue, "og-catalogue-fallback")
      catalogue_item(catalogue, category, %{"featured_image_uuid" => image})

      {:ok, view, _html} = live(conn, "/shop/category/og-catalogue-fallback")

      assert og(view).image == large(image)
      assert og(view).image_alt == "Catalogue Category"
    end

    test "a catalogue category whose items carry no image assigns none", %{
      conn: conn,
      catalogue: catalogue
    } do
      category = catalogue_category(catalogue, "og-catalogue-bare")
      catalogue_item(catalogue, category, %{})

      {:ok, view, _html} = live(conn, "/shop/category/og-catalogue-bare")

      refute Map.has_key?(og(view), :image)
    end
  end
end
