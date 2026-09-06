defmodule PhoenixKitEcommerce.CartCatalogueTest do
  @moduledoc """
  Cart and order lines for catalogue-backed products — a `%Product{}`
  view-struct (`__meta__.state == :built`) read through
  `ProductSource.Catalogue` from a real `phoenix_kit_cat_items` row.

  Needs `phoenix_kit_catalogue` loaded (with its own migrations applied to
  the test DB) — excluded via `test_helper.exs`'s `catalogue_exclude`
  whenever the optional dependency isn't present, same as
  `catalogue_view_test.exs`/`catalogue_query_test.exs`. `async: false`:
  flips the process-wide `shop_product_source` config key.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  @moduletag :catalogue

  # Quiets the compiler's static xref check for `mix test` runs where the
  # optional `phoenix_kit_catalogue`/`phoenix_kit_entities` dependencies
  # aren't declared — every test in this module is excluded in that case
  # (see `test_helper.exs`), so the calls below are never actually reached.
  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}
  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue.AttributeSets}
  @compile {:no_warn_undefined, PhoenixKitEntities.EntityData}

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.AttributeSets
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.ProductSource.Catalogue, as: CatalogueSource
  alias PhoenixKitEcommerce.ShopConfig
  alias PhoenixKitEcommerce.Test.Repo

  setup do
    set_product_source("catalogue")
    on_exit(fn -> set_product_source("legacy") end)

    {:ok, catalogue} = Catalogue.create_catalogue(%{name: "decor3dprint"})

    {:ok, item} =
      Catalogue.create_item(%{
        catalogue_uuid: catalogue.uuid,
        name: "Catalogue Vase",
        base_price: Decimal.new("23.76"),
        status: "active",
        data: %{"ecommerce" => %{"shop_status" => "active"}}
      })

    product = CatalogueSource.get_product(item.uuid, [])

    %{item: item, product: product}
  end

  # No `PhoenixKitEcommerce.update_config/2` exists yet (that setter is
  # built in a later, app-level task) — writes the `phoenix_kit_shop_config`
  # row directly, mirroring `update_storefront_filters/1`'s own
  # insert-or-update shape.
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

  defp new_cart do
    {:ok, cart} =
      Shop.create_cart(session_id: "cart-catalogue-#{System.unique_integer([:positive])}")

    cart
  end

  describe "add_to_cart/4 with a catalogue-backed product" do
    test "snapshots product_uuid nil and the item uuid in metadata", %{product: product} do
      {:ok, cart} = Shop.add_to_cart(new_cart(), product, 2)

      assert [item] = cart.items
      assert item.product_uuid == nil
      assert item.metadata["catalogue_item_uuid"] == product.uuid
      assert item.product_title == "Catalogue Vase"
      assert Decimal.equal?(item.unit_price, Decimal.new("23.76"))
      assert item.quantity == 2
    end

    test "adding the same product again bumps quantity instead of duplicating the row", %{
      product: product
    } do
      cart = new_cart()
      {:ok, cart} = Shop.add_to_cart(cart, product, 1)
      {:ok, cart} = Shop.add_to_cart(cart, product, 1)

      assert [item] = cart.items
      assert item.quantity == 2
    end

    test "refuses a catalogue product that is no longer active", %{item: item} do
      {:ok, _archived} =
        Catalogue.update_item(item, %{data: %{"ecommerce" => %{"shop_status" => "archived"}}})

      product = CatalogueSource.get_product(item.uuid, [])

      assert {:error, {:product_not_available, _uuid}} =
               Shop.add_to_cart(new_cart(), product, 1)
    end
  end

  describe "add_to_cart/4 with a priced option on a translated (non-primary-language) page" do
    setup do
      AttributeSets.register_deletion_guard()
      PhoenixKit.Settings.update_setting("entities_enabled", "true")
      on_exit(fn -> PhoenixKit.Settings.update_setting("entities_enabled", "false") end)

      {:ok, catalogue} = Catalogue.create_catalogue(%{name: "decor3dprint-colors"})
      {:ok, set} = AttributeSets.create_set(%{name: "Color"}, actor_uuid: Ecto.UUID.generate())

      {:ok, red} =
        AttributeSets.create_value(set, %{label: "Red", slug: "red"},
          actor_uuid: Ecto.UUID.generate()
        )

      {:ok, _} = PhoenixKitEntities.EntityData.set_title_translation(red, "fr-FR", "Rouge")

      {:ok, item} =
        Catalogue.create_item(%{
          catalogue_uuid: catalogue.uuid,
          name: "Colored Vase",
          base_price: Decimal.new("20.00"),
          status: "active",
          data: %{
            "ecommerce" => %{
              "shop_status" => "active",
              "price_modifiers" => %{"color" => %{"red" => "5.00"}}
            }
          }
        })

      {:ok, _} = AttributeSets.attach_set(item.uuid, set.uuid)
      :ok = AttributeSets.set_attachment_selection(item.uuid, set.uuid, ["red"])

      %{item: item}
    end

    test "the fr-FR cart line is priced with the modifier, keyed by the SAME label the fr-FR page showed",
         %{item: item} do
      product = CatalogueSource.get_product(item.uuid, language: "fr-FR")
      assert product.metadata["_option_values"] == %{"color" => ["Rouge"]}
      assert product.metadata["_price_modifiers"] == %{"color" => %{"Rouge" => "5.00"}}

      {:ok, cart} =
        Shop.add_to_cart(new_cart(), product, 1,
          selected_specs: %{"color" => "Rouge"},
          language: "fr-FR"
        )

      assert [cart_item] = cart.items
      assert Decimal.equal?(cart_item.unit_price, Decimal.new("25.00"))
    end
  end

  describe "cart page" do
    test "renders title, price and image for a catalogue-backed line", %{
      conn: conn,
      product: product
    } do
      session_id = "cart-catalogue-page-#{System.unique_integer([:positive])}"
      {:ok, _cart} = Shop.add_to_cart(new_cart_for(session_id), product, 1)

      conn = Plug.Test.init_test_session(conn, %{"shop_session_id" => session_id})
      {:ok, _view, html} = live(conn, "/cart")

      assert html =~ "Catalogue Vase"
    end
  end

  describe "checkout" do
    test "preview_checkout_totals/2 sums a catalogue-backed line", %{product: product} do
      {:ok, method} =
        Shop.create_shipping_method(%{"name" => "Standard", "price" => Decimal.new("5.00")})

      cart = new_cart()
      {:ok, cart} = Shop.add_to_cart(cart, product, 1)
      {:ok, cart} = Shop.set_cart_shipping(cart, method, "US")

      {:ok, previewed} =
        Shop.preview_checkout_totals(cart, billing_data: complete_billing("US"))

      assert Decimal.equal?(previewed.subtotal, Decimal.new("23.76"))
    end

    test "convert_cart_to_order/2 line carries title, price and catalogue_item_uuid", %{
      product: product
    } do
      {:ok, method} =
        Shop.create_shipping_method(%{"name" => "Standard", "price" => Decimal.new("5.00")})

      cart = new_cart()
      {:ok, cart} = Shop.add_to_cart(cart, product, 1)
      {:ok, cart} = Shop.set_cart_shipping(cart, method, "US")

      {:ok, order} = Shop.convert_cart_to_order(cart, billing_data: complete_billing("US"))

      assert [line, _shipping] = order.line_items
      assert line["name"] == "Catalogue Vase"
      assert line["unit_price"] == "23.76"
      assert line["catalogue_item_uuid"] == product.uuid
    end

    test "conversion refuses a cart whose catalogue item was archived after it was added", %{
      item: item,
      product: product
    } do
      {:ok, method} =
        Shop.create_shipping_method(%{"name" => "Standard", "price" => Decimal.new("5.00")})

      cart = new_cart()
      {:ok, cart} = Shop.add_to_cart(cart, product, 1)
      {:ok, cart} = Shop.set_cart_shipping(cart, method, "US")

      {:ok, _archived} =
        Catalogue.update_item(item, %{data: %{"ecommerce" => %{"shop_status" => "archived"}}})

      assert {:error, :product_not_available} =
               Shop.convert_cart_to_order(cart, billing_data: complete_billing("US"))
    end
  end

  describe "legacy path" do
    test "is unchanged: product_uuid stays set, no catalogue_item_uuid key appears" do
      {:ok, legacy_product} =
        Shop.create_product(%{
          "title" => %{"en" => "Legacy Widget"},
          "price" => Decimal.new("9.99"),
          "status" => "active",
          "currency" => "USD"
        })

      {:ok, cart} = Shop.add_to_cart(new_cart(), legacy_product, 1)

      assert [item] = cart.items
      assert item.product_uuid == legacy_product.uuid
      refute Map.has_key?(item.metadata || %{}, "catalogue_item_uuid")
    end
  end

  defp new_cart_for(session_id) do
    {:ok, cart} = Shop.create_cart(session_id: session_id)
    cart
  end
end
