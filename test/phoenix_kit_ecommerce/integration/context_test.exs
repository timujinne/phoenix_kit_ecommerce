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

  describe "product search" do
    test "list_products/1 :search matches localized title" do
      {:ok, product} =
        Shop.create_product(product_attrs(%{"title" => %{"en" => "Skeleton Wall Mask"}}))

      uuids = Enum.map(Shop.list_products(search: "skeleton wall"), & &1.uuid)
      assert product.uuid in uuids

      assert Shop.list_products(search: "no-such-product-anywhere") == []
    end

    test "list_products/1 :search matches metadata sku" do
      {:ok, product} =
        Shop.create_product(product_attrs(%{"metadata" => %{"sku" => "MASK-042-BLK"}}))

      {:ok, other} = Shop.create_product(product_attrs())

      uuids = Enum.map(Shop.list_products(search: "mask-042"), & &1.uuid)
      assert product.uuid in uuids
      refute other.uuid in uuids
    end

    test "list_products/1 :search composes with :exclude_hidden_categories" do
      # Regression: the search fragment referenced unqualified columns
      # (title/description), which turn ambiguous once the hidden-category
      # left join is applied — the exact combination the public storefront
      # always uses.
      {:ok, product} =
        Shop.create_product(product_attrs(%{"title" => %{"en" => "Skeleton Wall Mask"}}))

      {products, total} =
        Shop.list_products_with_count(
          search: "skeleton",
          exclude_hidden_categories: true,
          status: "active"
        )

      assert total == 1
      assert [%{uuid: uuid}] = products
      assert uuid == product.uuid
    end

    test "list_products/1 :search matches tags" do
      {:ok, product} =
        Shop.create_product(product_attrs(%{"tags" => ["halloween", "wall-decor"]}))

      {:ok, other} = Shop.create_product(product_attrs())

      uuids = Enum.map(Shop.list_products(search: "hallowee"), & &1.uuid)
      assert product.uuid in uuids
      refute other.uuid in uuids
    end

    test "list_products/1 :search treats % as a literal character" do
      {:ok, cotton} =
        Shop.create_product(product_attrs(%{"title" => %{"en" => "100% Cotton Shirt"}}))

      {:ok, decoy} =
        Shop.create_product(product_attrs(%{"title" => %{"en" => "100 Count Wool Socks"}}))

      uuids = Enum.map(Shop.list_products(search: "100%"), & &1.uuid)
      assert cotton.uuid in uuids
      refute decoy.uuid in uuids
    end

    test "list_products/1 :search treats _ in an SKU as a literal character" do
      {:ok, target} = Shop.create_product(product_attrs(%{"metadata" => %{"sku" => "AB_100"}}))
      {:ok, decoy} = Shop.create_product(product_attrs(%{"metadata" => %{"sku" => "ABX100"}}))

      uuids = Enum.map(Shop.list_products(search: "AB_100"), & &1.uuid)
      assert target.uuid in uuids
      refute decoy.uuid in uuids
    end

    test "list_products/1 :search with a trailing backslash still substring-matches" do
      {:ok, product} =
        Shop.create_product(product_attrs(%{"title" => %{"en" => "path foo\\bar demo"}}))

      uuids = Enum.map(Shop.list_products(search: "foo\\"), & &1.uuid)
      assert product.uuid in uuids
    end

    test "list_products/1 :search survives pathological terms" do
      {:ok, _} = Shop.create_product(product_attrs())

      # Unbounded-length pattern must not blow up (term is capped)
      assert Shop.list_products(search: String.duplicate("a%_", 5_000)) == []

      # NUL byte would raise in Postgres text params unless stripped
      assert Shop.list_products(search: "abc" <> <<0>> <> "def") == []
    end

    test "list_categories/1 :search treats % as a literal character" do
      {:ok, sale} = Shop.create_category(%{"name" => %{"en" => "50% Off Corner"}})
      {:ok, decoy} = Shop.create_category(%{"name" => %{"en" => "50 Shades of Grey Paint"}})

      uuids = Enum.map(Shop.list_categories(search: "50%"), & &1.uuid)
      assert sale.uuid in uuids
      refute decoy.uuid in uuids
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

    test "default_storefront_filters/0 includes an enabled search filter first" do
      assert [%{"key" => "search", "type" => "search", "enabled" => true} | _] =
               Enum.sort_by(Shop.default_storefront_filters(), & &1["position"])
    end

    test "merge_missing_builtin_filters/1 adds absent built-ins as disabled" do
      saved = [%{"key" => "price", "type" => "price_range", "enabled" => true}]
      merged = Shop.merge_missing_builtin_filters(saved)

      price = Enum.find(merged, &(&1["key"] == "price"))
      assert price == List.first(saved)
      search = Enum.find(merged, &(&1["key"] == "search"))
      assert search["type"] == "search"
      refute search["enabled"]
    end

    test "merge_missing_builtin_filters/1 sorts the merged-in filter before saved ones" do
      # Regression: a config saved under the pre-`search` position numbering
      # already holds "price" at position 0. Reusing `search`'s default
      # position (also 0) would tie, and the stable sort in
      # `get_enabled_storefront_filters/0` would then keep list order —
      # silently placing `search` after `price` once enabled, instead of
      # first as the storefront sidebar expects.
      saved = [
        %{"key" => "price", "type" => "price_range", "enabled" => true, "position" => 0}
      ]

      merged =
        saved
        |> Shop.merge_missing_builtin_filters()
        |> Enum.map(fn f -> if f["key"] == "search", do: Map.put(f, "enabled", true), else: f end)

      sorted_keys =
        merged
        |> Enum.filter(& &1["enabled"])
        |> Enum.sort_by(& &1["position"])
        |> Enum.map(& &1["key"])

      assert sorted_keys == ["search", "price"]
    end

    test "merge_missing_builtin_filters/1 leaves a complete config untouched" do
      complete = Shop.default_storefront_filters()
      assert Shop.merge_missing_builtin_filters(complete) == complete
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
