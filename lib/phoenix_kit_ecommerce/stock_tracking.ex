defmodule PhoenixKitEcommerce.StockTracking do
  @moduledoc """
  The shop's "Stock tracking" switch, and the shop's only door to Warehouse's
  stock.

  The stored setting is `shop_stock_tracking_enabled` (module `shop`, default
  `"false"`). It only takes effect while the Warehouse module is installed and
  enabled: the effective state is `setting AND Warehouse installed AND
  Warehouse enabled`, so disabling or removing Warehouse later switches
  tracking off without anyone touching the setting.

  ## What is counted

  While tracking is in force (`location/0` answers a location) a sale is limited
  to the stock at Warehouse's default location, and a paid order writes that
  stock off (`PhoenixKitEcommerce.OrderStockHandler`). A catalogue item that
  ships is counted, and one with no stock row there has none: an item nobody
  has received is out of stock, as Warehouse itself reads it. A Legacy product
  has no warehouse item and an item that does not ship is not goods, so neither
  is limited (`item_uuid/1`).

  Stock is not reserved. A cart or an unpaid order holds nothing, so two
  shoppers can both be sold the last unit; the write-off of the second order
  finds the line short and flags it for the keeper.

  `phoenix_kit_warehouse` is an OPTIONAL dependency (see mix.exs). Its modules
  are reached through variable-module calls guarded by `Code.ensure_loaded?/1`,
  which is why no `@compile {:no_warn_undefined, ...}` is needed and why a host
  without the package compiles and runs this module unchanged.

  The Warehouse modules and the settings reader can be replaced through the
  `:stock_tracking_modules` application env (keys `:warehouse`,
  `:stock_ledger`, `:goods_issues`, `:settings`); tests use it to simulate a
  missing package.
  """

  require Logger

  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce.CartItem
  alias PhoenixKitEcommerce.Product
  alias PhoenixKitEcommerce.WarehouseSourceKind

  @setting_key "shop_stock_tracking_enabled"

  @type warehouse_status :: :not_installed | :disabled | :no_default_location | :ready

  @type shortage :: %{
          item_uuid: String.t(),
          requested: pos_integer(),
          available: non_neg_integer()
        }

  @doc "The stored setting alone. A read error counts as off."
  @spec setting_enabled?() :: boolean()
  def setting_enabled? do
    module(:settings, Settings).get_setting_cached(@setting_key, "false") == "true"
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @doc """
  What the Warehouse module currently offers the shop.

  `:not_installed` when the package is not loaded, `:disabled` when it is
  installed but switched off (or its state cannot be read),
  `:no_default_location` when it is enabled but no default warehouse location
  is chosen yet, `:ready` otherwise.
  """
  @spec warehouse_status() :: warehouse_status()
  def warehouse_status do
    warehouse = module(:warehouse, PhoenixKitWarehouse)

    cond do
      not Code.ensure_loaded?(warehouse) -> :not_installed
      not warehouse_enabled?(warehouse) -> :disabled
      is_nil(default_location_uuid()) -> :no_default_location
      true -> :ready
    end
  end

  @doc "Effective state: the setting is on and Warehouse is installed and enabled."
  @spec enabled?() :: boolean()
  def enabled?, do: enabled?(warehouse_status())

  @doc "Effective state for a `warehouse_status/0` the caller already has."
  @spec enabled?(warehouse_status()) :: boolean()
  def enabled?(status) do
    setting_enabled?() and status in [:no_default_location, :ready]
  end

  @doc """
  The warehouse location stock is counted at, or `nil` while nothing is limited:
  tracking is off, or it is on and no default warehouse is chosen yet.
  """
  @spec location() :: String.t() | nil
  def location do
    if setting_enabled?() and warehouse_status() == :ready, do: default_location_uuid()
  end

  @doc """
  The warehouse item a product or a cart line is counted against, or `nil` when
  it is not counted (see the module doc). A line stored before lines carried
  `"requires_shipping"` counts as shipping.
  """
  @spec item_uuid(term()) :: String.t() | nil
  def item_uuid(%Product{requires_shipping: false}), do: nil
  def item_uuid(%Product{origin: :catalogue, uuid: uuid}), do: uuid
  def item_uuid(%CartItem{metadata: %{"requires_shipping" => false}}), do: nil

  def item_uuid(%CartItem{metadata: %{"catalogue_item_uuid" => uuid}}) when is_binary(uuid),
    do: uuid

  def item_uuid(_other), do: nil

  @doc """
  Whole units on hand of each item at `location/0`, every item in the answer
  (none on hand is `0`), or `:off` while nothing is limited.

  A read that fails is logged and counts as `:off`, like a broken availability
  hook: a Warehouse problem must not stop the shop from selling.
  """
  @spec on_hand([String.t()]) :: %{String.t() => non_neg_integer()} | :off
  def on_hand(item_uuids) when is_list(item_uuids) do
    case location() do
      nil -> :off
      location -> read_on_hand(item_uuids, location)
    end
  end

  # Cart quantities are whole units, so a fraction left in stock cannot be sold.
  defp read_on_hand(item_uuids, location) do
    ledger = module(:stock_ledger, PhoenixKitWarehouse.StockLedger)

    counted =
      item_uuids
      |> ledger.stock_for_items_at_location(location)
      |> Map.new(fn row ->
        {row.item_uuid, row.quantity |> Decimal.round(0, :floor) |> Decimal.to_integer()}
      end)

    Map.new(item_uuids, &{&1, Map.get(counted, &1, 0)})
  rescue
    error ->
      Logger.warning("[Shop] stock could not be read: #{Exception.message(error)}")
      :off
  end

  @doc "The items of `wanted` (`%{item_uuid => quantity}`) that stock does not cover."
  @spec shortages(%{String.t() => pos_integer()}) :: [shortage()]
  def shortages(wanted) when map_size(wanted) == 0, do: []

  def shortages(wanted) when is_map(wanted) do
    case on_hand(Map.keys(wanted)) do
      :off ->
        []

      stock ->
        for {item_uuid, requested} <- wanted, requested > stock[item_uuid] do
          %{item_uuid: item_uuid, requested: requested, available: stock[item_uuid]}
        end
    end
  end

  @doc """
  Posts the goods issue that takes a paid order's `lines` out of stock at
  `location`. Warehouse answers as `GoodsIssues.create_and_post/2` does: all the
  lines or none, and the order number as `external_ref` makes a second call
  `{:ok, :already_posted, issue}`. No person performs it, so it names no user.
  """
  @spec post_sale(map(), [map()], String.t()) ::
          {:ok, struct()} | {:ok, :already_posted, struct()} | {:error, term()}
  def post_sale(%{uuid: uuid, order_number: order_number}, lines, location) do
    module(:goods_issues, PhoenixKitWarehouse.GoodsIssues).create_and_post(
      %{
        location_uuid: location,
        lines: lines,
        reason: "sale",
        external_ref: order_number,
        source_refs: [%{"type" => WarehouseSourceKind.kind(), "uuid" => uuid}]
      },
      nil
    )
  end

  @doc """
  Stores the setting. Turning it on while Warehouse is missing or off is
  refused here, not only greyed out in the UI; turning it off always works.
  """
  @spec set_enabled(boolean()) ::
          {:ok, boolean()}
          | {:error, :warehouse_not_installed | :warehouse_disabled | :update_failed}
  def set_enabled(false), do: store(false)

  def set_enabled(true) do
    case warehouse_status() do
      :not_installed -> {:error, :warehouse_not_installed}
      :disabled -> {:error, :warehouse_disabled}
      _enabled -> store(true)
    end
  end

  defp store(value) do
    case Settings.update_boolean_setting_with_module(@setting_key, value, "shop") do
      {:ok, _} -> {:ok, value}
      _error -> {:error, :update_failed}
    end
  end

  defp warehouse_enabled?(warehouse) do
    warehouse.enabled?() == true
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp default_location_uuid do
    module(:stock_ledger, PhoenixKitWarehouse.StockLedger).default_location_uuid()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp module(key, default) do
    :phoenix_kit_ecommerce
    |> Application.get_env(:stock_tracking_modules, [])
    |> Keyword.get(key, default)
  end
end
