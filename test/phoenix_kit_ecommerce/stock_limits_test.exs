defmodule PhoenixKitEcommerce.StockLimitsTest do
  @moduledoc """
  What a shopper can buy while stock tracking is in force: the cart and the
  checkout refuse a quantity the default warehouse does not hold. Real catalogue
  items and real stock rows; the write-off of a paid order is
  `order_stock_handler_test.exs`. `async: false`: flips the process-wide
  `shop_product_source` key.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :catalogue
  @moduletag :warehouse

  @compile {:no_warn_undefined, PhoenixKitWarehouse.StockLedger}

  import ExUnit.CaptureLog
  import PhoenixKitEcommerce.CheckoutFixtures

  import PhoenixKitEcommerce.SearchFixtures,
    only: [catalogue_item!: 2, catalogue_item!: 3, catalogue_source!: 0]

  import PhoenixKitEcommerce.StockFixtures

  alias PhoenixKit.Settings
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Availability
  alias PhoenixKitEcommerce.Cart
  alias PhoenixKitEcommerce.CartItem
  alias PhoenixKitEcommerce.Product
  alias PhoenixKitEcommerce.ProductSource.Catalogue, as: CatalogueSource
  alias PhoenixKitEcommerce.StockTracking
  alias PhoenixKitEcommerce.Test.FakeWarehouse
  alias PhoenixKitWarehouse.StockLedger

  setup do
    catalogue = catalogue_source!()
    track_stock!()

    item = catalogue_item!(catalogue, "Vase")
    put_stock!(item.uuid, 3)

    %{catalogue: catalogue, item: item, product: CatalogueSource.get_product(item.uuid, [])}
  end

  defp new_cart do
    {:ok, cart} = Shop.create_cart(session_id: "stock-#{System.unique_integer([:positive])}")
    cart
  end

  # A second selection of the same item: its own line, the same stock.
  defp add_sibling_line!(%Cart{items: [line | _]} = cart, quantity) do
    line
    |> Map.take([
      :cart_uuid,
      :product_title,
      :product_slug,
      :unit_price,
      :currency,
      :metadata,
      :weight_grams,
      :taxable
    ])
    |> Map.merge(%{quantity: quantity, selected_specs: %{"color" => "red"}})
    |> then(&CartItem.changeset(%CartItem{}, &1))
    |> Repo.insert!()

    Shop.get_cart(cart.uuid)
  end

  describe "add_to_cart/4" do
    test "takes what the warehouse holds", %{product: product} do
      assert {:ok, %{items: [%{quantity: 3}]}} = Shop.add_to_cart(new_cart(), product, 3)
    end

    test "refuses more, and leaves the cart as it was", %{product: product} do
      cart = new_cart()

      assert {:error, {:insufficient_stock, [%{requested: 4, available: 3}]}} =
               Shop.add_to_cart(cart, product, 4)

      assert %{items: []} = Shop.get_cart(cart.uuid)
    end

    test "counts what the cart already holds", %{product: product} do
      {:ok, cart} = Shop.add_to_cart(new_cart(), product, 2)

      assert {:error, {:insufficient_stock, [%{requested: 4, available: 3}]}} =
               Shop.add_to_cart(cart, product, 2)

      assert {:ok, %{items: [%{quantity: 3}]}} = Shop.add_to_cart(cart, product, 1)
    end

    test "counts the item's other lines", %{product: product} do
      {:ok, cart} = Shop.add_to_cart(new_cart(), product, 1)
      cart = add_sibling_line!(cart, 2)

      assert {:error, {:insufficient_stock, [%{requested: 4, available: 3}]}} =
               Shop.add_to_cart(cart, product, 1)
    end

    test "an item nobody has received is out of stock", %{catalogue: catalogue} do
      item = catalogue_item!(catalogue, "Plate")
      product = CatalogueSource.get_product(item.uuid, [])

      assert {:error, {:insufficient_stock, [%{requested: 1, available: 0}]}} =
               Shop.add_to_cart(new_cart(), product, 1)
    end

    test "a fraction left in stock is not a unit", %{item: item, product: product} do
      put_stock!(item.uuid, "1.5")

      assert {:error, {:insufficient_stock, [%{requested: 2, available: 1}]}} =
               Shop.add_to_cart(new_cart(), product, 2)
    end

    test "stock at another location does not count", %{item: item, product: product} do
      {:ok, _} = StockLedger.upsert_quantity(item.uuid, 50, location_uuid: Ecto.UUID.generate())

      assert {:error, {:insufficient_stock, [%{available: 3}]}} =
               Shop.add_to_cart(new_cart(), product, 4)
    end

    test "what does not ship is not limited", %{catalogue: catalogue} do
      data = %{"ecommerce" => %{"shop_status" => "active", "requires_shipping" => false}}
      item = catalogue_item!(catalogue, "E-book", %{data: data})
      product = CatalogueSource.get_product(item.uuid, [])

      assert {:ok, %{items: [%{quantity: 5}]}} = Shop.add_to_cart(new_cart(), product, 5)
    end
  end

  describe "when nothing is limited" do
    test "tracking is off", %{product: product} do
      {:ok, false} = StockTracking.set_enabled(false)

      assert {:ok, %{items: [%{quantity: 9}]}} = Shop.add_to_cart(new_cart(), product, 9)
    end

    test "Warehouse is off", %{product: product} do
      Settings.update_boolean_setting_with_module("warehouse_enabled", false, "warehouse")

      assert {:ok, %{items: [%{quantity: 9}]}} = Shop.add_to_cart(new_cart(), product, 9)
    end

    test "no default warehouse is chosen yet", %{product: product} do
      StockLedger.set_default_location_uuid(nil)

      assert StockTracking.enabled?()
      assert StockTracking.location() == nil
      assert {:ok, %{items: [%{quantity: 9}]}} = Shop.add_to_cart(new_cart(), product, 9)
    end

    test "stock cannot be read: the sale goes on, and the log says why", %{product: product} do
      on_exit(&FakeWarehouse.reset/0)
      FakeWarehouse.put_state(enabled: true, default_location: Ecto.UUID.generate())

      Application.put_env(:phoenix_kit_ecommerce, :stock_tracking_modules,
        warehouse: FakeWarehouse,
        stock_ledger: PhoenixKitEcommerce.Test.RaisingStockLedger
      )

      log =
        capture_log(fn ->
          assert {:ok, %{items: [%{quantity: 9}]}} = Shop.add_to_cart(new_cart(), product, 9)
        end)

      assert log =~ "stock could not be read"
    end

    test "a legacy product has no warehouse item" do
      loaded = Ecto.put_meta(%Product{uuid: Ecto.UUID.generate()}, state: :loaded)

      assert StockTracking.item_uuid(loaded) == nil
      assert StockTracking.item_uuid(%CartItem{product_uuid: loaded.uuid, metadata: %{}}) == nil
    end

    test "an unpersisted legacy product has no warehouse item" do
      assert StockTracking.item_uuid(%Product{uuid: Ecto.UUID.generate()}) == nil
    end
  end

  describe "update_cart_item/2" do
    test "a stale larger quantity cannot bypass stock limits", %{item: item, product: product} do
      {:ok, %{items: [line]}} = Shop.add_to_cart(new_cart(), product, 3)
      assert {:ok, _} = Shop.update_cart_item(line, 1)
      put_stock!(item.uuid, 1)

      assert {:error, {:insufficient_stock, [%{requested: 2, available: 1}]}} =
               Shop.update_cart_item(line, 2)

      assert %{quantity: 1} = Repo.get!(CartItem, line.uuid)
    end

    test "an update uses the stored quantity even when the snapshot matches the target",
         %{product: product} do
      {:ok, %{items: [line]}} = Shop.add_to_cart(new_cart(), product, 3)
      assert {:ok, _} = Shop.update_cart_item(line, 1)

      assert {:ok, %{items: [%{quantity: 3}]}} = Shop.update_cart_item(line, 3)
    end

    test "a stock refusal leaves an enclosing transaction usable", %{product: product} do
      {:ok, %{items: [line]}} = Shop.add_to_cart(new_cart(), product, 1)

      assert {:ok, :still_usable} =
               Repo.transaction(fn ->
                 assert {:error, {:insufficient_stock, _}} = Shop.update_cart_item(line, 4)
                 assert %{quantity: 1} = Repo.get!(CartItem, line.uuid)
                 :still_usable
               end)
    end

    test "refuses to raise a line above the stock", %{product: product} do
      {:ok, %{items: [line]}} = Shop.add_to_cart(new_cart(), product, 2)

      assert {:error, {:insufficient_stock, [%{requested: 4, available: 3}]}} =
               Shop.update_cart_item(line, 4)

      assert {:ok, %{items: [%{quantity: 3}]}} = Shop.update_cart_item(line, 3)
    end

    test "counts the item's other lines and not the line itself", %{product: product} do
      {:ok, cart} = Shop.add_to_cart(new_cart(), product, 1)
      %{items: lines} = add_sibling_line!(cart, 1)
      line = Enum.find(lines, &(&1.selected_specs == %{}))

      assert {:ok, _cart} = Shop.update_cart_item(line, 2)

      assert {:error, {:insufficient_stock, [%{requested: 4, available: 3}]}} =
               Shop.update_cart_item(%{line | quantity: 2}, 3)
    end

    test "a line left above the stock can still come down", %{item: item, product: product} do
      {:ok, %{items: [line]}} = Shop.add_to_cart(new_cart(), product, 3)
      put_stock!(item.uuid, 1)

      assert {:ok, %{items: [%{quantity: 2}]}} = Shop.update_cart_item(line, 2)
    end
  end

  describe "convert_cart_to_order/2" do
    setup %{product: product} do
      {:ok, method} =
        Shop.create_shipping_method(%{"name" => "Standard", "price" => Decimal.new("5.00")})

      {:ok, cart} = Shop.add_to_cart(new_cart(), product, 2)
      {:ok, cart} = Shop.set_cart_shipping(cart, method, "US")

      %{cart: cart}
    end

    test "places an order the stock covers, and takes nothing yet", %{cart: cart, item: item} do
      assert {:ok, order} = Shop.convert_cart_to_order(cart, billing_data: complete_billing("US"))

      assert [%{"requires_shipping" => true}, %{"type" => "shipping"}] = order.line_items
      assert Decimal.equal?(on_hand(item.uuid), 3)
    end

    test "refuses a cart the stock no longer covers and names the line", %{
      cart: cart,
      item: item
    } do
      put_stock!(item.uuid, 1)

      assert {:error, {:insufficient_stock, [line]}} =
               Shop.convert_cart_to_order(cart, billing_data: complete_billing("US"))

      assert %{name: "Vase", requested: 2, available: 1} = line
      assert %{status: "active"} = Shop.get_cart(cart.uuid)
      assert Billing.list_orders() == []
    end

    test "adds up the item's lines", %{cart: cart, item: item} do
      cart = add_sibling_line!(cart, 1)
      put_stock!(item.uuid, 2)

      assert {:error, {:insufficient_stock, [%{requested: 3, available: 2}]}} =
               Shop.convert_cart_to_order(cart, billing_data: complete_billing("US"))
    end
  end

  describe "Availability.available?/1" do
    test "is false only for a counted item with nothing on hand", ctx do
      assert Availability.available?(ctx.product)

      put_stock!(ctx.item.uuid, 0)
      refute Availability.available?(ctx.product)

      {:ok, false} = StockTracking.set_enabled(false)
      assert Availability.available?(ctx.product)
    end

    test "an application's hook answers instead", %{item: item, product: product} do
      Application.put_env(:phoenix_kit_ecommerce, :availability, {__MODULE__, :always_available})
      on_exit(fn -> Application.delete_env(:phoenix_kit_ecommerce, :availability) end)
      put_stock!(item.uuid, 0)

      assert Availability.available?(product)
    end
  end

  def always_available(_product), do: true
end
