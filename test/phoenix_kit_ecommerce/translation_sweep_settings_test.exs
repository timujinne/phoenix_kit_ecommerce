defmodule PhoenixKitEcommerce.TranslationSweepSettingsTest do
  @moduledoc """
  Unit coverage for `TranslationSweepSettings` (design §4.6, §8): every
  reader's default, and the two behaviors called out as easy to get
  wrong — a malformed stored value degrading to the safe default rather
  than raising, and `languages/0`'s intersection with currently-enabled
  languages.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce.TranslationSweepSettings, as: SweepSettings

  defp enable_languages!(codes) do
    {:ok, _} = Settings.update_boolean_setting_with_module("languages_enabled", true, "languages")

    languages =
      codes
      |> Enum.with_index()
      |> Enum.map(fn {code, index} ->
        %{"code" => code, "name" => code, "is_default" => index == 0, "is_enabled" => true}
      end)

    {:ok, _} =
      Settings.update_json_setting_with_module(
        "languages_config",
        %{"languages" => languages},
        "languages"
      )
  end

  describe "boolean toggles" do
    test "translations_enabled?/0 defaults to false" do
      refute SweepSettings.translations_enabled?()
    end

    test "sweep_enabled?/0 defaults to false" do
      refute SweepSettings.sweep_enabled?()
    end

    test "both read true once set" do
      Settings.update_boolean_setting_with_module("shop_translations_enabled", true, "shop")
      Settings.update_boolean_setting_with_module("shop_translation_sweep_enabled", true, "shop")

      assert SweepSettings.translations_enabled?()
      assert SweepSettings.sweep_enabled?()
    end
  end

  describe "interval_minutes/0" do
    test "defaults to 60" do
      assert SweepSettings.interval_minutes() == 60
    end

    test "reads a configured value" do
      Settings.update_setting_with_module("shop_translation_interval_minutes", "5", "shop")
      assert SweepSettings.interval_minutes() == 5
    end

    test "a non-positive stored value falls back to the default rather than breaking scheduling" do
      Settings.update_setting_with_module("shop_translation_interval_minutes", "0", "shop")
      assert SweepSettings.interval_minutes() == 60

      Settings.update_setting_with_module("shop_translation_interval_minutes", "-5", "shop")
      assert SweepSettings.interval_minutes() == 60
    end

    test "a non-numeric stored value falls back to the default" do
      Settings.update_setting_with_module("shop_translation_interval_minutes", "soon", "shop")
      assert SweepSettings.interval_minutes() == 60
    end
  end

  describe "batch_size/0" do
    test "defaults to 3" do
      assert SweepSettings.batch_size() == 3
    end

    test "reads a configured value, including zero (a valid pause-by-batch)" do
      Settings.update_setting_with_module("shop_translation_batch", "10", "shop")
      assert SweepSettings.batch_size() == 10

      Settings.update_setting_with_module("shop_translation_batch", "0", "shop")
      assert SweepSettings.batch_size() == 0
    end

    test "a negative stored value falls back to the default" do
      Settings.update_setting_with_module("shop_translation_batch", "-1", "shop")
      assert SweepSettings.batch_size() == 3
    end
  end

  describe "max_in_flight/0" do
    test "defaults to 6" do
      assert SweepSettings.max_in_flight() == 6
    end

    test "reads a configured value" do
      Settings.update_setting_with_module("shop_translation_max_in_flight", "20", "shop")
      assert SweepSettings.max_in_flight() == 20
    end
  end

  describe "statuses/0" do
    test "defaults to [\"active\"]" do
      assert SweepSettings.statuses() == ["active"]
    end

    test "reads a configured list" do
      Settings.update_json_setting_with_module(
        "shop_translation_statuses",
        %{"statuses" => ["active", "draft"]},
        "shop"
      )

      assert SweepSettings.statuses() == ["active", "draft"]
    end

    test "a malformed stored value falls back to the default" do
      Settings.update_json_setting_with_module(
        "shop_translation_statuses",
        %{"not_statuses" => "oops"},
        "shop"
      )

      assert SweepSettings.statuses() == ["active"]
    end
  end

  describe "languages/0" do
    test "defaults to every enabled language except the primary" do
      enable_languages!(["en", "de", "fr"])
      assert SweepSettings.languages() == ["de", "fr"]
    end

    test "with Languages disabled (only the content language exists), the default is empty" do
      refute SweepSettings.languages() != []
      assert SweepSettings.languages() == []
    end

    test "a configured selection is intersected with enabled languages — a disabled one silently drops out" do
      enable_languages!(["en", "de", "fr"])

      Settings.update_json_setting_with_module(
        "shop_translation_languages",
        %{"codes" => ["de", "fr", "es"]},
        "shop"
      )

      # "es" was never enabled — dropped, not raised or ignored wholesale.
      assert SweepSettings.languages() == ["de", "fr"]
    end

    test "re-enabling a previously-configured language brings it back without resaving" do
      enable_languages!(["en", "de"])

      Settings.update_json_setting_with_module(
        "shop_translation_languages",
        %{"codes" => ["de", "fr"]},
        "shop"
      )

      assert SweepSettings.languages() == ["de"]

      enable_languages!(["en", "de", "fr"])
      assert SweepSettings.languages() == ["de", "fr"]
    end

    test "a blank language code is dropped, whatever its source" do
      # `languages_config` hands back an empty `code` verbatim if such a row
      # was ever saved. A blank target matches EVERY resource in the
      # candidate SQL and is then rejected by `enqueue/1` on every job:
      # the sweep would fill its batch with the same resources every tick
      # and never enqueue anything.
      enable_languages!(["en", "de", " ", ""])

      assert SweepSettings.languages() == ["de"]

      Settings.update_json_setting_with_module(
        "shop_translation_languages",
        %{"codes" => ["de", " "]},
        "shop"
      )

      assert SweepSettings.languages() == ["de"]
    end

    test "a malformed stored value falls back to the dynamic default" do
      enable_languages!(["en", "de"])

      Settings.update_json_setting_with_module(
        "shop_translation_languages",
        %{"oops" => true},
        "shop"
      )

      assert SweepSettings.languages() == ["de"]
    end
  end
end
