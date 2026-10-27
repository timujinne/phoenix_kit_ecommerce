defmodule PhoenixKitEcommerce.Web.ShippingParcelFieldsTest do
  @moduledoc """
  The parcel inputs of the admin forms: a legacy product's weight and size, a
  legacy category's default parcel, and the shop-wide default parcel on the
  settings page.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Category
  alias PhoenixKitEcommerce.Product

  setup %{conn: conn} do
    %{conn: put_test_scope(conn, fake_scope())}
  end

  describe "product form" do
    test "saves the weight and the size of one unit", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/products/new")

      assert has_element?(view, "#product-dimensions")

      view
      |> form("#product-form", %{
        "product" => %{
          "title" => "Crate",
          "price" => "10.00",
          "weight_grams" => "1200",
          "length_mm" => "400",
          "width_mm" => "300",
          "height_mm" => "200"
        }
      })
      |> render_submit()

      product = Enum.find(Shop.list_products(), &(&1.title["en"] == "Crate"))

      assert product.weight_grams == 1200
      assert Product.dimensions_mm(Product.with_dimensions(product)) == [400, 300, 200]
    end

    test "the weight starts empty and an empty weight is stored as 0 (unknown)", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/products/new")

      assert has_element?(view, ~s(#product-weight-grams[value=""]))

      view
      |> form("#product-form", %{"product" => %{"title" => "Light", "price" => "1"}})
      |> render_submit()

      assert Enum.find(Shop.list_products(), &(&1.title["en"] == "Light")).weight_grams == 0
    end

    test "prefills the stored size, and clearing it removes it", %{conn: conn} do
      {:ok, product} =
        Shop.create_product(%{
          "title" => %{"en" => "Stored crate"},
          "price" => Decimal.new("10.00"),
          "weight_grams" => 900,
          "length_mm" => 350,
          "width_mm" => 250,
          "height_mm" => 150
        })

      {:ok, view, _html} = live(conn, "/en/admin/shop/products/#{product.uuid}/edit")

      assert has_element?(view, "#product-length-mm[value='350']")
      assert has_element?(view, "#product-width-mm[value='250']")
      assert has_element?(view, "#product-height-mm[value='150']")
      assert has_element?(view, "#product-weight-grams[value='900']")

      view
      |> form("#product-form", %{
        "product" => %{"length_mm" => "", "width_mm" => "", "height_mm" => ""}
      })
      |> render_submit()

      product = Shop.get_product!(product.uuid)

      assert Product.dimensions_mm(Product.with_dimensions(product)) == nil
      refute Map.has_key?(product.metadata, "dimensions_mm")
      assert product.weight_grams == 900
    end

    test "a negative side is refused with an error", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/products/new")

      view
      |> form("#product-form", %{
        "product" => %{"title" => "Crate", "price" => "10", "length_mm" => "-5"}
      })
      |> render_change()

      assert has_element?(view, "#product-dimensions", "must be greater than or equal to")
    end
  end

  describe "category form" do
    test "saves the default parcel", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/categories/new")

      assert has_element?(view, "#category-parcel-defaults")

      view
      |> form("#category-form", %{
        "category" => %{
          "name" => "Crates",
          "parcel_length_mm" => "500",
          "parcel_width_mm" => "400",
          "parcel_height_mm" => "300",
          "parcel_weight_g" => "2500"
        }
      })
      |> render_submit()

      category = Enum.find(Shop.list_categories(), &(&1.name["en"] == "Crates"))

      assert Category.parcel_defaults(category) == %{
               dims_mm: [500, 400, 300],
               weight_g: 2500
             }
    end

    test "prefills the stored default parcel, and clearing it removes it", %{conn: conn} do
      {:ok, category} =
        Shop.create_category(%{
          "name" => %{"en" => "Stored crates"},
          "parcel_length_mm" => 500,
          "parcel_width_mm" => 400,
          "parcel_height_mm" => 300,
          "parcel_weight_g" => 2500
        })

      {:ok, view, _html} = live(conn, "/en/admin/shop/categories/#{category.uuid}/edit")

      assert has_element?(view, "#category-parcel-length-mm[value='500']")
      assert has_element?(view, "#category-parcel-weight-g[value='2500']")

      view
      |> form("#category-form", %{
        "category" => %{
          "parcel_length_mm" => "",
          "parcel_width_mm" => "",
          "parcel_height_mm" => "",
          "parcel_weight_g" => ""
        }
      })
      |> render_submit()

      category = Shop.get_category!(category.uuid)

      assert Category.parcel_defaults(category) == %{dims_mm: nil, weight_g: nil}
      refute Map.has_key?(category.metadata, "parcel_defaults")
    end
  end

  describe "settings page" do
    test "saves the default parcel, logs it and shows it again", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/settings")

      assert has_element?(view, "#shipping-parcel-defaults-form")

      view
      |> form("#shipping-parcel-defaults-form", %{
        "parcel" => %{
          "length_mm" => "300",
          "width_mm" => "200",
          "height_mm" => "100",
          "weight_g" => "500"
        }
      })
      |> render_submit()

      defaults = Shop.shipping_parcel_defaults()
      assert defaults.box_mm == [300, 200, 100]
      assert defaults.weight_g == 500

      assert_activity_logged("shop.shipping_parcel_defaults_changed",
        metadata_has: %{"length_mm" => 300, "height_mm" => 100, "weight_g" => 500}
      )

      {:ok, view, _html} = live(conn, "/en/admin/shop/settings")
      assert has_element?(view, "#shipping-parcel-length-mm[value='300']")
      assert has_element?(view, "#shipping-parcel-weight-g[value='500']")
    end

    test "rejects invalid input per field and stores nothing", %{conn: conn} do
      Shop.update_shipping_parcel_defaults(%{
        "length_mm" => 300,
        "width_mm" => 200,
        "height_mm" => 100,
        "weight_g" => 500
      })

      {:ok, view, _html} = live(conn, "/en/admin/shop/settings")

      view
      |> form("#shipping-parcel-defaults-form", %{
        "parcel" => %{
          "length_mm" => "abc",
          "width_mm" => "200",
          "height_mm" => "100",
          "weight_g" => "500"
        }
      })
      |> render_submit()

      assert has_element?(view, "#shipping-parcel-defaults-form", "must be a whole number")
      assert Shop.shipping_parcel_defaults().box_mm == [300, 200, 100]
      refute_activity_logged("shop.shipping_parcel_defaults_changed")
    end

    test "all three sides or none", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/settings")

      view
      |> form("#shipping-parcel-defaults-form", %{
        "parcel" => %{
          "length_mm" => "300",
          "width_mm" => "",
          "height_mm" => "",
          "weight_g" => ""
        }
      })
      |> render_submit()

      assert has_element?(
               view,
               "#shipping-parcel-defaults-form",
               "is required when the other sides are set"
             )

      assert Shop.shipping_parcel_defaults().box_mm == nil
    end

    test "empty input clears the defaults", %{conn: conn} do
      Shop.update_shipping_parcel_defaults(%{"length_mm" => 3, "width_mm" => 2, "height_mm" => 1})

      {:ok, view, _html} = live(conn, "/en/admin/shop/settings")

      view
      |> form("#shipping-parcel-defaults-form", %{
        "parcel" => %{"length_mm" => "", "width_mm" => "", "height_mm" => "", "weight_g" => ""}
      })
      |> render_submit()

      assert Shop.shipping_parcel_defaults().box_mm == nil
      assert_activity_logged("shop.shipping_parcel_defaults_changed")
    end

    test "a caller without manage_settings changes nothing", %{conn: conn} do
      conn =
        put_test_scope(
          conn,
          fake_scope(permissions: ["shop", "shop.manage_catalog"], roles: ["Employee"])
        )

      {:ok, view, _html} = live_narrowed(conn, "/en/admin/shop/settings")

      view
      |> form("#shipping-parcel-defaults-form", %{
        "parcel" => %{
          "length_mm" => "300",
          "width_mm" => "200",
          "height_mm" => "100",
          "weight_g" => "500"
        }
      })
      |> render_submit()

      assert Shop.shipping_parcel_defaults().box_mm == nil
      assert Settings.get_json_setting("shop_shipping_parcel_defaults", %{}) == %{}
      refute_activity_logged("shop.shipping_parcel_defaults_changed")
    end
  end
end
