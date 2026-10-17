defmodule PhoenixKitEcommerce.API.SettingsTest do
  @moduledoc """
  The e-commerce settings of the admin API: one key and one default, a value
  that is not a sane threshold reads as the default (never as "no limit"),
  and the setting is written only as a whole number from 0 to 1000.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce.API.Settings, as: ApiSettings

  defp store(key, value), do: Settings.update_setting_with_module(key, value, "shop")

  describe "price_change_pct/0" do
    test "is 30 until someone sets it" do
      assert ApiSettings.price_change_pct() == 30
      assert ApiSettings.price_change_pct_key() == "api_confirm_price_change_pct"
      assert ApiSettings.default_price_change_pct() == 30
    end

    test "reads the stored whole number, zero included" do
      store("api_confirm_price_change_pct", "45")
      assert ApiSettings.price_change_pct() == 45

      store("api_confirm_price_change_pct", "0")
      assert ApiSettings.price_change_pct() == 0
    end

    test "a value that is not a threshold is the default, never 'no limit'" do
      for bad <- ["", "lots", "-5", "1001", "99999"] do
        store("api_confirm_price_change_pct", bad)
        assert ApiSettings.price_change_pct() == 30, "#{inspect(bad)} must read as 30"
      end
    end
  end

  describe "price_change_pct/1 when the read fails" do
    test "a read that raises or exits is the default, never 'no limit'" do
      reads = [
        fn _key, _default -> raise "settings are unavailable" end,
        fn _key, _default -> exit(:noproc) end,
        fn _key, _default -> nil end
      ]

      for read <- reads do
        assert ApiSettings.price_change_pct(read) == 30
      end
    end

    test "a value the reader returns is judged like a stored one" do
      assert ApiSettings.price_change_pct(fn _key, _default -> 7 end) == 7
      assert ApiSettings.price_change_pct(fn _key, _default -> 1001 end) == 30
    end
  end

  describe "put_price_change_pct/1" do
    test "stores a whole number from 0 to 1000 under the shop module" do
      assert {:ok, _} = ApiSettings.put_price_change_pct(15)
      assert ApiSettings.price_change_pct() == 15

      assert {:ok, _} = ApiSettings.put_price_change_pct(0)
      assert {:ok, _} = ApiSettings.put_price_change_pct(1000)
    end

    test "refuses anything else and stores nothing" do
      ApiSettings.put_price_change_pct(15)

      for bad <- [-1, 1001, 1.5, "20", nil] do
        assert {:error, :invalid} = ApiSettings.put_price_change_pct(bad)
      end

      assert ApiSettings.price_change_pct() == 15
    end
  end

  test "admin_enabled?/0 is false without core's API, and follows core's switch with it" do
    if ApiSettings.core_available?() do
      previous = ApiSettings.admin_enabled?()

      on_exit(fn ->
        Settings.update_boolean_setting_with_module("api_admin_enabled", previous, "api")
      end)

      Settings.update_boolean_setting_with_module("api_admin_enabled", false, "api")
      refute ApiSettings.admin_enabled?()

      Settings.update_boolean_setting_with_module("api_admin_enabled", true, "api")
      assert ApiSettings.admin_enabled?()
    else
      refute ApiSettings.admin_enabled?()
    end
  end
end
