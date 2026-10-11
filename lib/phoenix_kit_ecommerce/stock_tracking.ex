defmodule PhoenixKitEcommerce.StockTracking do
  @moduledoc """
  The shop's "Stock tracking" switch.

  The stored setting is `shop_stock_tracking_enabled` (module `shop`, default
  `"false"`). It only takes effect while the Warehouse module is installed and
  enabled: the effective state is `setting AND Warehouse installed AND
  Warehouse enabled`, so disabling or removing Warehouse later switches
  tracking off without anyone touching the setting.

  `phoenix_kit_warehouse` is an OPTIONAL dependency (see mix.exs). Its modules
  are reached through variable-module calls guarded by `Code.ensure_loaded?/1`,
  which is why no `@compile {:no_warn_undefined, ...}` is needed and why a host
  without the package compiles and runs this module unchanged.

  The Warehouse modules and the settings reader can be replaced through the
  `:stock_tracking_modules` application env (keys `:warehouse`,
  `:stock_ledger`, `:settings`); tests use it to simulate a missing package.
  """

  alias PhoenixKit.Settings

  @setting_key "shop_stock_tracking_enabled"

  @type warehouse_status :: :not_installed | :disabled | :no_default_location | :ready

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
  def enabled? do
    setting_enabled?() and warehouse_status() in [:no_default_location, :ready]
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
