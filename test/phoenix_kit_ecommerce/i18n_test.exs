defmodule PhoenixKitEcommerce.I18nTest do
  @moduledoc """
  Smoke test for the per-module i18n wiring.

  Confirms that:
    * Every tab registered by `PhoenixKitEcommerce.admin_tabs/0`,
      `settings_tabs/0`, and `user_dashboard_tabs/0` carries
      `gettext_backend: PhoenixKitEcommerce.Gettext`.
    * The shipped `priv/gettext/<locale>/LC_MESSAGES/default.po`
      catalogues resolve through the backend directly and through
      `Tab.localized_label/1`.
    * Falls back to the raw msgid for an unknown locale.
  """

  use ExUnit.Case, async: false

  # Excluded by `test/test_helper.exs` when running against a `phoenix_kit`
  # release that pre-dates the `gettext_backend` API (PR BeamLabEU/phoenix_kit#522).
  # Once the consumer's `phoenix_kit` dep resolves to a release that ships
  # `Tab.localized_label/1`, the helper detects it and these tests run
  # automatically — no follow-up edit needed.
  @moduletag :requires_phoenix_kit_i18n_api

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKitEcommerce.Gettext, as: EcommerceGettext

  setup do
    original = Gettext.get_locale(EcommerceGettext)
    on_exit(fn -> Gettext.put_locale(EcommerceGettext, original) end)
    :ok
  end

  describe "tab wiring" do
    test "every registered tab carries the module's own gettext backend" do
      tabs =
        PhoenixKitEcommerce.admin_tabs() ++
          PhoenixKitEcommerce.settings_tabs() ++
          PhoenixKitEcommerce.user_dashboard_tabs()

      # Sanity: 7 admin + 1 settings + 2 user-dashboard = 10 sites.
      assert length(tabs) == 10

      for tab <- tabs do
        assert tab.gettext_backend == EcommerceGettext,
               "Tab #{inspect(tab.id)} is missing or wrong gettext_backend " <>
                 "(got #{inspect(tab.gettext_backend)})"

        assert tab.gettext_domain == "default"
      end
    end
  end

  describe "backend catalogue lookup" do
    test "ru locale resolves 'E-Commerce' through the backend directly" do
      Gettext.put_locale(EcommerceGettext, "ru")
      assert Gettext.gettext(EcommerceGettext, "E-Commerce") == "Электронная коммерция"
    end

    test "et locale resolves 'My Cart' through the backend directly" do
      Gettext.put_locale(EcommerceGettext, "et")
      assert Gettext.gettext(EcommerceGettext, "My Cart") == "Minu ostukorv"
    end
  end

  describe "Tab.localized_label/1 against the module's catalogue" do
    test "ru locale resolves the parent 'E-Commerce' tab to 'Электронная коммерция'" do
      Gettext.put_locale(EcommerceGettext, "ru")

      parent = admin_shop_tab()
      assert Tab.localized_label(parent) == "Электронная коммерция"
    end

    test "et locale resolves the parent 'E-Commerce' tab to 'E-kaubandus'" do
      Gettext.put_locale(EcommerceGettext, "et")

      parent = admin_shop_tab()
      assert Tab.localized_label(parent) == "E-kaubandus"
    end

    test "unknown locale falls back to the raw msgid" do
      Gettext.put_locale(EcommerceGettext, "zz")

      parent = admin_shop_tab()
      assert Tab.localized_label(parent) == parent.label
    end
  end

  defp admin_shop_tab do
    Enum.find(PhoenixKitEcommerce.admin_tabs(), &(&1.id == :admin_shop))
  end
end
