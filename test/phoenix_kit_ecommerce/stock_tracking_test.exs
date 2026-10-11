defmodule PhoenixKitEcommerce.StockTrackingTest do
  @moduledoc """
  The shop's "Stock tracking" switch (spec 8.1): the stored setting, the
  Warehouse probe, and the effective state `setting AND Warehouse installed
  AND Warehouse enabled`.

  The Warehouse side is the stub from `test/support/fake_warehouse.ex`, so the
  suite does not depend on `phoenix_kit_warehouse` being resolved.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.StockTracking
  alias PhoenixKitEcommerce.Test.FakeWarehouse

  setup do
    on_exit(fn ->
      Settings.update_boolean_setting_with_module("shop_stock_tracking_enabled", false, "shop")
      FakeWarehouse.reset()
    end)

    :ok
  end

  describe "warehouse_status/0" do
    test "not installed when the Warehouse module is not loaded" do
      FakeWarehouse.put_not_installed()
      assert Shop.warehouse_status() == :not_installed
    end

    test "disabled when installed but switched off" do
      FakeWarehouse.put_state(enabled: false, default_location: "loc-1")
      assert Shop.warehouse_status() == :disabled
    end

    test "no default location when enabled without one" do
      FakeWarehouse.put_state(enabled: true, default_location: nil)
      assert Shop.warehouse_status() == :no_default_location
    end

    test "ready when enabled with a default location" do
      FakeWarehouse.put_state(enabled: true, default_location: "loc-1")
      assert Shop.warehouse_status() == :ready
    end

    test "a probe that raises counts as disabled" do
      Application.put_env(:phoenix_kit_ecommerce, :stock_tracking_modules,
        warehouse: PhoenixKitEcommerce.Test.RaisingWarehouse
      )

      assert Shop.warehouse_status() == :disabled
    end
  end

  describe "stock_tracking_enabled?/0" do
    test "defaults to off" do
      FakeWarehouse.put_state(enabled: true, default_location: "loc-1")
      refute Shop.stock_tracking_enabled?()
      refute StockTracking.setting_enabled?()
    end

    test "on when the setting is on and Warehouse is ready" do
      FakeWarehouse.put_state(enabled: true, default_location: "loc-1")
      assert {:ok, true} = StockTracking.set_enabled(true)
      assert Shop.stock_tracking_enabled?()
    end

    test "on when Warehouse is enabled but has no default location yet" do
      FakeWarehouse.put_state(enabled: true, default_location: nil)
      assert {:ok, true} = StockTracking.set_enabled(true)
      assert Shop.stock_tracking_enabled?()
    end

    test "turns off by itself when Warehouse is disabled, setting untouched" do
      FakeWarehouse.put_state(enabled: true, default_location: "loc-1")
      assert {:ok, true} = StockTracking.set_enabled(true)

      FakeWarehouse.put_state(enabled: false, default_location: "loc-1")
      refute Shop.stock_tracking_enabled?()
      assert StockTracking.setting_enabled?()

      FakeWarehouse.put_state(enabled: true, default_location: "loc-1")
      assert Shop.stock_tracking_enabled?()
    end

    test "turns off by itself when Warehouse is removed" do
      FakeWarehouse.put_state(enabled: true, default_location: "loc-1")
      assert {:ok, true} = StockTracking.set_enabled(true)

      FakeWarehouse.put_not_installed()
      refute Shop.stock_tracking_enabled?()
    end

    test "a failing setting read counts as off" do
      FakeWarehouse.put_state(enabled: true, default_location: "loc-1")
      assert {:ok, true} = StockTracking.set_enabled(true)
      assert Shop.stock_tracking_enabled?()

      for settings <- [
            PhoenixKitEcommerce.Test.RaisingSettings,
            PhoenixKitEcommerce.Test.ExitingSettings
          ] do
        Application.put_env(:phoenix_kit_ecommerce, :stock_tracking_modules,
          warehouse: FakeWarehouse,
          stock_ledger: FakeWarehouse.StockLedger,
          settings: settings
        )

        refute StockTracking.setting_enabled?()
        refute Shop.stock_tracking_enabled?()
      end
    end
  end

  describe "enabled?/1" do
    test "uses the given status instead of probing Warehouse again" do
      FakeWarehouse.put_state(enabled: true, default_location: "loc-1")
      assert {:ok, true} = StockTracking.set_enabled(true)

      FakeWarehouse.put_not_installed()
      assert StockTracking.enabled?(:ready)
      assert StockTracking.enabled?(:no_default_location)
      refute StockTracking.enabled?(:disabled)
      refute StockTracking.enabled?(:not_installed)
    end
  end

  describe "set_enabled/1" do
    test "refuses to turn on while Warehouse is not installed" do
      FakeWarehouse.put_not_installed()
      assert {:error, :warehouse_not_installed} = StockTracking.set_enabled(true)
      refute StockTracking.setting_enabled?()
    end

    test "refuses to turn on while Warehouse is disabled" do
      FakeWarehouse.put_state(enabled: false)
      assert {:error, :warehouse_disabled} = StockTracking.set_enabled(true)
      refute StockTracking.setting_enabled?()
    end

    test "turning off is always allowed" do
      FakeWarehouse.put_state(enabled: true, default_location: "loc-1")
      assert {:ok, true} = StockTracking.set_enabled(true)

      FakeWarehouse.put_not_installed()
      assert {:ok, false} = StockTracking.set_enabled(false)
      refute StockTracking.setting_enabled?()
    end
  end

  # The rest of this file points StockTracking at a stub, so the shipped
  # defaults (the real Warehouse module names) never run there. This block
  # clears the override and talks to the real package, which is only in the
  # build when the optional dependency is resolved.
  if Code.ensure_loaded?(PhoenixKitWarehouse) do
    describe "real Warehouse wiring (no stub)" do
      test "the Warehouse API the shop calls exists" do
        # function_exported?/3 is false for a module that is not loaded yet.
        assert Code.ensure_loaded?(PhoenixKitWarehouse)
        assert Code.ensure_loaded?(PhoenixKitWarehouse.StockLedger)
        assert function_exported?(PhoenixKitWarehouse, :enabled?, 0)
        assert function_exported?(PhoenixKitWarehouse.StockLedger, :default_location_uuid, 0)
      end

      test "status and effective state follow the real module, which is off in the test DB" do
        FakeWarehouse.reset()
        refute PhoenixKitWarehouse.enabled?()

        assert StockTracking.warehouse_status() == :disabled
        refute StockTracking.enabled?()
        refute Shop.stock_tracking_enabled?()
      end

      test "an enabled real Warehouse reports its default location" do
        FakeWarehouse.reset()

        on_exit(fn ->
          Settings.update_boolean_setting_with_module("warehouse_enabled", false, "warehouse")
          PhoenixKitWarehouse.StockLedger.set_default_location_uuid(nil)
        end)

        Settings.update_boolean_setting_with_module("warehouse_enabled", true, "warehouse")
        PhoenixKitWarehouse.StockLedger.set_default_location_uuid(nil)
        assert StockTracking.warehouse_status() == :no_default_location

        PhoenixKitWarehouse.StockLedger.set_default_location_uuid(Ecto.UUID.generate())
        assert StockTracking.warehouse_status() == :ready

        assert {:ok, true} = StockTracking.set_enabled(true)
        assert StockTracking.enabled?()
      end

      test "turning it on is refused while the real Warehouse module is disabled" do
        FakeWarehouse.reset()

        assert {:error, :warehouse_disabled} = StockTracking.set_enabled(true)
        refute StockTracking.setting_enabled?()
      end
    end
  end
end
