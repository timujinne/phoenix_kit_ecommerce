defmodule PhoenixKitEcommerce.Test.FakeWarehouse do
  @moduledoc """
  Stand-in for `PhoenixKitWarehouse` in the stock-tracking tests, so they run
  the same whether or not the optional `phoenix_kit_warehouse` dependency is
  resolved. Point `PhoenixKitEcommerce.StockTracking` at it with
  `put_state/1`; state lives in the application env and is cleared with
  `reset/0`.
  """

  alias PhoenixKitEcommerce.Test.FakeWarehouse.StockLedger

  @env_key :stock_tracking_modules
  @state_key :fake_warehouse_state

  @doc "Selects what the stub warehouse reports. Keys: `:enabled`, `:default_location`."
  def put_state(state) when is_list(state) do
    Application.put_env(:phoenix_kit_ecommerce, @state_key, state)
    use_fake()
  end

  @doc "Simulates a host where the warehouse package is not installed."
  def put_not_installed do
    Application.put_env(:phoenix_kit_ecommerce, @env_key,
      warehouse: PhoenixKitEcommerce.Test.WarehouseNotInstalled,
      stock_ledger: PhoenixKitEcommerce.Test.WarehouseNotInstalled
    )
  end

  def reset do
    Application.delete_env(:phoenix_kit_ecommerce, @env_key)
    Application.delete_env(:phoenix_kit_ecommerce, @state_key)
  end

  defp use_fake do
    Application.put_env(:phoenix_kit_ecommerce, @env_key,
      warehouse: __MODULE__,
      stock_ledger: StockLedger
    )
  end

  def enabled?, do: state(:enabled, false)

  @doc false
  def state(key, default) do
    :phoenix_kit_ecommerce
    |> Application.get_env(@state_key, [])
    |> Keyword.get(key, default)
  end
end

defmodule PhoenixKitEcommerce.Test.FakeWarehouse.StockLedger do
  @moduledoc false

  alias PhoenixKitEcommerce.Test.FakeWarehouse

  def default_location_uuid, do: FakeWarehouse.state(:default_location, nil)
end

defmodule PhoenixKitEcommerce.Test.RaisingWarehouse do
  @moduledoc false

  def enabled?, do: raise("warehouse probe failed")
end

defmodule PhoenixKitEcommerce.Test.RaisingSettings do
  @moduledoc false

  def get_setting_cached(_key, _default), do: raise("settings read failed")
end

defmodule PhoenixKitEcommerce.Test.ExitingSettings do
  @moduledoc false

  def get_setting_cached(_key, _default), do: exit(:sandbox_owner_exited)
end
