defmodule PhoenixKitEcommerce.API.CartSettingsTest do
  @moduledoc """
  The four settings of the public cart API that this module owns. Every reader
  must return its default for a missing, junk or out-of-range value.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce.API.CartSettings

  test "defaults when nothing is stored" do
    assert CartSettings.idle_days() == 7
    assert CartSettings.claim_ttl_minutes() == 30
    assert CartSettings.signal_per_cart_per_hour() == 3
    assert CartSettings.signal_global_per_hour() == 30
  end

  test "stored values are read" do
    {:ok, _} = Settings.update_setting("api_cart_idle_days", "14")
    {:ok, _} = Settings.update_setting("api_checkout_claim_ttl_minutes", "45")
    {:ok, _} = Settings.update_setting("api_signal_per_cart_per_hour", "5")
    {:ok, _} = Settings.update_setting("api_signal_global_per_hour", "100")

    assert CartSettings.idle_days() == 14
    assert CartSettings.claim_ttl_minutes() == 45
    assert CartSettings.signal_per_cart_per_hour() == 5
    assert CartSettings.signal_global_per_hour() == 100
  end

  test "junk and out-of-range values fall back to the default" do
    for junk <- ["abc", "0", "-3", "7.5", "9999"] do
      {:ok, _} = Settings.update_setting("api_cart_idle_days", junk)
      assert CartSettings.idle_days() == 7, "idle_days accepted #{inspect(junk)}"
    end

    {:ok, _} = Settings.update_setting("api_checkout_claim_ttl_minutes", "5000")
    assert CartSettings.claim_ttl_minutes() == 30
  end

  test "zero is a valid cap: it switches assistant notifications off" do
    {:ok, _} = Settings.update_setting("api_signal_per_cart_per_hour", "0")
    {:ok, _} = Settings.update_setting("api_signal_global_per_hour", "0")

    assert CartSettings.signal_per_cart_per_hour() == 0
    assert CartSettings.signal_global_per_hour() == 0
  end

  test "keys, defaults and bounds describe the same four settings" do
    assert Map.keys(CartSettings.keys()) |> Enum.sort() ==
             Map.keys(CartSettings.defaults()) |> Enum.sort()

    assert Map.keys(CartSettings.keys()) |> Enum.sort() ==
             Map.keys(CartSettings.bounds()) |> Enum.sort()

    for {name, default} <- CartSettings.defaults() do
      assert default in Map.fetch!(CartSettings.bounds(), name)
      assert CartSettings.get(name) == default
    end
  end

  test "an unknown setting name is a programming error, not a default" do
    assert_raise FunctionClauseError, fn -> CartSettings.get(:nope) end
  end
end
