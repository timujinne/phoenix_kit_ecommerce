defmodule PhoenixKitEcommerce.Integration.ContextTest do
  @moduledoc """
  CRUD and total-recalculation coverage for the public `PhoenixKitEcommerce`
  context functions that run without external/payment APIs.
  """

  use PhoenixKitEcommerce.DataCase, async: true

  alias PhoenixKitEcommerce, as: Shop

  defp product_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "title" => %{"en" => "Widget #{System.unique_integer([:positive])}"},
        "price" => Decimal.new("19.99"),
        "status" => "active"
      },
      overrides
    )
  end

  describe "products" do
    test "create_product/1 inserts and returns the product" do
      assert {:ok, product} = Shop.create_product(product_attrs())
      assert product.title["en"] =~ "Widget"
      assert Decimal.equal?(product.price, Decimal.new("19.99"))
    end

    test "create_product/1 returns an error changeset for missing price" do
      assert {:error, cs} = Shop.create_product(%{"title" => %{"en" => "No Price"}})
      assert %{price: [_ | _]} = errors_on(cs)
    end

    test "get_product/1 fetches by uuid and nil for unknown" do
      {:ok, product} = Shop.create_product(product_attrs())
      assert Shop.get_product(product.uuid).uuid == product.uuid
      assert Shop.get_product(Ecto.UUID.generate()) == nil
      # Non-UUID binary returns nil rather than raising.
      assert Shop.get_product("not-a-uuid") == nil
    end

    test "update_product/2 changes fields" do
      {:ok, product} = Shop.create_product(product_attrs())
      assert {:ok, updated} = Shop.update_product(product, %{"price" => Decimal.new("25.00")})
      assert Decimal.equal?(updated.price, Decimal.new("25.00"))
    end

    test "list_products/1 returns inserted products" do
      {:ok, product} = Shop.create_product(product_attrs())
      uuids = Enum.map(Shop.list_products(), & &1.uuid)
      assert product.uuid in uuids
    end

    test "delete_product/1 removes the product" do
      {:ok, product} = Shop.create_product(product_attrs())
      assert {:ok, _} = Shop.delete_product(product)
      assert Shop.get_product(product.uuid) == nil
    end
  end

  describe "categories" do
    test "create_category/1 and get_category/1" do
      assert {:ok, cat} = Shop.create_category(%{"name" => %{"en" => "Books"}})
      assert Shop.get_category(cat.uuid).uuid == cat.uuid
    end

    test "create_category/1 error for missing name" do
      assert {:error, cs} = Shop.create_category(%{})
      assert %{name: [_ | _]} = errors_on(cs)
    end

    test "update_category/2 changes the name" do
      {:ok, cat} = Shop.create_category(%{"name" => %{"en" => "Old"}})
      assert {:ok, updated} = Shop.update_category(cat, %{"name" => %{"en" => "New"}})
      assert updated.name["en"] == "New"
    end

    test "nesting: child category references its parent" do
      {:ok, parent} = Shop.create_category(%{"name" => %{"en" => "Parent"}})

      assert {:ok, child} =
               Shop.create_category(%{"name" => %{"en" => "Child"}, "parent_uuid" => parent.uuid})

      assert child.parent_uuid == parent.uuid
      roots = Enum.map(Shop.list_root_categories(), & &1.uuid)
      assert parent.uuid in roots
      refute child.uuid in roots
    end
  end

  describe "shipping methods" do
    test "create / get / update / delete" do
      assert {:ok, method} =
               Shop.create_shipping_method(%{"name" => "Std", "price" => Decimal.new("5")})

      assert Shop.get_shipping_method(method.uuid).uuid == method.uuid

      assert {:ok, updated} =
               Shop.update_shipping_method(method, %{"price" => Decimal.new("8")})

      assert Decimal.equal?(updated.price, Decimal.new("8"))

      assert {:ok, _} = Shop.delete_shipping_method(updated)
      assert Shop.get_shipping_method(method.uuid) == nil
    end

    test "list_shipping_methods/1 with active filter" do
      {:ok, _active} =
        Shop.create_shipping_method(%{"name" => "Active", "price" => "1", "active" => true})

      {:ok, _inactive} =
        Shop.create_shipping_method(%{"name" => "Inactive", "price" => "1", "active" => false})

      active = Shop.list_shipping_methods(active: true)
      assert Enum.all?(active, & &1.active)
    end
  end

  describe "carts and totals" do
    setup do
      {:ok, product} =
        Shop.create_product(product_attrs(%{"price" => Decimal.new("10.00")}))

      {:ok, method} =
        Shop.create_shipping_method(%{"name" => "Flat", "price" => Decimal.new("4.00")})

      {:ok, cart} = Shop.create_cart(session_id: "ctx-#{System.unique_integer([:positive])}")
      %{product: product, method: method, cart: cart}
    end

    test "create_cart/1 starts empty and active", %{cart: cart} do
      assert cart.status == "active"
      assert cart.items_count == 0
      assert Decimal.equal?(cart.total, Decimal.new("0"))
    end

    test "add_to_cart/3 recalculates subtotal and items_count", %{cart: cart, product: product} do
      {:ok, cart} = Shop.add_to_cart(cart, product, 3)
      assert cart.items_count == 3
      assert Decimal.equal?(cart.subtotal, Decimal.new("30.00"))
      assert length(cart.items) == 1
    end

    test "adding the same product again merges quantity", %{cart: cart, product: product} do
      {:ok, cart} = Shop.add_to_cart(cart, product, 1)
      {:ok, cart} = Shop.add_to_cart(cart, product, 2)
      assert cart.items_count == 3
      assert length(cart.items) == 1
    end

    test "remove_from_cart/1 recalculates totals", %{cart: cart, product: product} do
      {:ok, cart} = Shop.add_to_cart(cart, product, 2)
      [item] = cart.items
      {:ok, cart} = Shop.remove_from_cart(item)
      assert cart.items_count == 0
      assert Decimal.equal?(cart.subtotal, Decimal.new("0"))
    end

    test "update_cart_item/2 changes quantity and totals", %{cart: cart, product: product} do
      {:ok, cart} = Shop.add_to_cart(cart, product, 1)
      [item] = cart.items
      {:ok, cart} = Shop.update_cart_item(item, 5)
      assert cart.items_count == 5
      assert Decimal.equal?(cart.subtotal, Decimal.new("50.00"))
    end

    test "set_cart_shipping/3 adds shipping into the total", %{
      cart: cart,
      product: product,
      method: method
    } do
      {:ok, cart} = Shop.add_to_cart(cart, product, 1)
      {:ok, cart} = Shop.set_cart_shipping(cart, method, "US")
      assert cart.shipping_country == "US"
      assert Decimal.equal?(cart.shipping_amount, Decimal.new("4.00"))
      # subtotal 10 + shipping 4 (tax disabled by default) = 14
      assert Decimal.equal?(cart.total, Decimal.new("14.00"))
    end

    test "clear_cart/1 empties the cart", %{cart: cart, product: product} do
      {:ok, cart} = Shop.add_to_cart(cart, product, 2)
      {:ok, cart} = Shop.clear_cart(cart)
      assert cart.items_count == 0
    end

    test "get_cart!/1 raises for unknown uuid" do
      assert_raise Ecto.NoResultsError, fn -> Shop.get_cart!(Ecto.UUID.generate()) end
    end
  end

  describe "storefront filters (shop_config-backed)" do
    test "update_storefront_filters/1 persists and get_storefront_filters/0 reads back" do
      filters = [%{"type" => "vendor", "enabled" => true}]
      assert {:ok, _} = Shop.update_storefront_filters(filters)
      assert Shop.get_storefront_filters() == filters
    end
  end

  describe "import configs" do
    test "create_import_config/1 and get_import_config/1" do
      name = "cfg-#{System.unique_integer([:positive])}"
      assert {:ok, cfg} = Shop.create_import_config(%{name: name})
      assert Shop.get_import_config(cfg.uuid).uuid == cfg.uuid
    end

    test "update_import_config/2 and delete_import_config/1" do
      {:ok, cfg} = Shop.create_import_config(%{name: "cfg-#{System.unique_integer([:positive])}"})
      assert {:ok, updated} = Shop.update_import_config(cfg, %{skip_filter: true})
      assert updated.skip_filter
      assert {:ok, _} = Shop.delete_import_config(updated)
      assert Shop.get_import_config(cfg.uuid) == nil
    end
  end

  describe "import logs" do
    test "create / start / complete lifecycle" do
      assert {:ok, log} = Shop.create_import_log(%{filename: "x.csv"})
      assert log.status == "pending"

      assert {:ok, started} = Shop.start_import(log, 10)
      assert started.status == "processing"
      assert started.total_rows == 10

      assert {:ok, done} =
               Shop.complete_import(started, %{imported_count: 8, updated_count: 2})

      assert done.status == "completed"
      assert done.imported_count == 8
    end
  end
end
