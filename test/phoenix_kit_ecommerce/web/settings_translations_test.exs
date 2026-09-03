defmodule PhoenixKitEcommerce.Web.SettingsTranslationsTest do
  @moduledoc """
  Admin Settings page: the AI Translations existence card (design §4.6).

  Only the EXISTENCE toggle (`shop_translations_enabled`) lives here — the
  operational sweep panel (interval, batch, ceiling, languages, statuses)
  moved to `/admin/shop/translations` itself (design §4.5), covered by
  `PhoenixKitEcommerce.Web.TranslationsTest`.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitEcommerce.TranslationSweepSettings

  setup %{conn: conn} do
    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  # A real, enabled AI endpoint — nothing here ever calls it.
  defp setup_ai! do
    {:ok, _} = PhoenixKitAI.enable_system()

    {:ok, _endpoint} =
      PhoenixKitAI.create_endpoint(%{
        name: "Settings Test Endpoint #{System.unique_integer([:positive])}",
        provider: "test",
        model: "test-chat-model",
        api_key: "unused-test-key"
      })

    :ok
  end

  test "renders the card, toggle off by default", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/en/admin/shop/settings")

    assert html =~ ~s(id="shop-translations-card")
    refute Settings.get_boolean_setting("shop_translations_enabled", false)
  end

  test "without a configured AI endpoint, the toggle is disabled with an explanation", %{
    conn: conn
  } do
    {:ok, _view, html} = live(conn, "/en/admin/shop/settings")

    assert html =~ "Configure an enabled AI endpoint in the AI section first"
    assert html =~ ~s(id="toggle-shop-translations-enabled")
    assert html =~ ~s(disabled="disabled") or html =~ "disabled"
  end

  test "the event handler itself refuses to enable while AI is unavailable", %{conn: conn} do
    # `disabled` on the input is a UX hint, not the enforcement (see
    # `Web.Settings`' own comment on this) — `Phoenix.LiveViewTest` won't
    # even let a real browser-style click reach a `disabled` element, so
    # this fires the raw event directly, the same way a tampered/stale
    # client event would.
    {:ok, view, _html} = live(conn, "/en/admin/shop/settings")

    html = render_click(view, "toggle_shop_translations_enabled", %{})

    refute Settings.get_boolean_setting("shop_translations_enabled", false)
    assert html =~ "Configure an enabled AI endpoint"
  end

  describe "with AI available" do
    setup do
      setup_ai!()
      :ok
    end

    test "enabling flips the setting and logs Activity", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/settings")

      render_click(element(view, "#toggle-shop-translations-enabled"))

      assert Settings.get_boolean_setting("shop_translations_enabled", false)

      assert_activity_logged("shop.translations_enabled_changed",
        metadata_has: %{"enabled" => true}
      )
    end

    test "a link to the translations page appears once enabled", %{conn: conn} do
      {:ok, view, html} = live(conn, "/en/admin/shop/settings")
      refute html =~ "/admin/shop/translations"

      html = render_click(element(view, "#toggle-shop-translations-enabled"))
      assert html =~ Routes.path("/admin/shop/translations")
    end

    test "disabling also disables the sweep, both logged", %{conn: conn} do
      Settings.update_boolean_setting_with_module("shop_translations_enabled", true, "shop")
      Settings.update_boolean_setting_with_module("shop_translation_sweep_enabled", true, "shop")

      {:ok, view, _html} = live(conn, "/en/admin/shop/settings")
      render_click(element(view, "#toggle-shop-translations-enabled"))

      refute TranslationSweepSettings.translations_enabled?()
      refute TranslationSweepSettings.sweep_enabled?()

      assert_activity_logged("shop.translations_enabled_changed",
        metadata_has: %{"enabled" => false}
      )

      assert_activity_logged("shop.translation_sweep_settings_changed",
        metadata_has: %{"sweep_enabled" => false, "reason" => "shop_translations_disabled"}
      )
    end

    test "disabling when the sweep was already off does not log a redundant sweep change", %{
      conn: conn
    } do
      Settings.update_boolean_setting_with_module("shop_translations_enabled", true, "shop")

      {:ok, view, _html} = live(conn, "/en/admin/shop/settings")
      render_click(element(view, "#toggle-shop-translations-enabled"))

      refute_activity_logged("shop.translation_sweep_settings_changed")
    end
  end

  describe "authz" do
    setup %{conn: conn} do
      setup_ai!()
      {:ok, conn: put_test_scope(conn, fake_scope(permissions: ["shop", "shop.manage_catalog"]))}
    end

    test "toggling is denied without shop.manage_settings", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/settings")

      html = render_click(element(view, "#toggle-shop-translations-enabled"))

      assert html =~ "You don&#39;t have permission to do that"
      refute Settings.get_boolean_setting("shop_translations_enabled", false)
    end
  end
end
