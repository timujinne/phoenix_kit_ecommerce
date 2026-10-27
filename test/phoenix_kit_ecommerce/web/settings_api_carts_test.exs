defmodule PhoenixKitEcommerce.Web.SettingsApiCartsTest do
  @moduledoc """
  The "Assistant carts" card of the shop settings page: the four settings the
  public cart API reads, edited all or nothing, by someone who may manage
  settings.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce.API.CartSettings
  alias PhoenixKitEcommerce.Test.Repo

  setup %{conn: conn} do
    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  defp form(overrides) do
    %{
      "settings" =>
        Map.merge(
          %{
            "idle_days" => "7",
            "claim_ttl_minutes" => "30",
            "signal_per_cart_per_hour" => "3",
            "signal_global_per_hour" => "30"
          },
          overrides
        )
    }
  end

  test "renders the card with the effective values", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/en/admin/shop/settings")

    assert html =~ ~s(id="shop-api-carts-card")
    assert html =~ ~s(id="shop-api-carts-form")
    assert html =~ ~s(name="settings[idle_days]")
    assert html =~ ~s(value="7")
    assert html =~ ~s(name="settings[signal_global_per_hour]")
  end

  test "the numbers are core inputs, and the browser does not judge the ranges first", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, "/en/admin/shop/settings")

    for {id, name} <- [
          {"api-cart-idle-days", "idle_days"},
          {"api-cart-claim-ttl-minutes", "claim_ttl_minutes"},
          {"api-cart-signal-per-cart", "signal_per_cart_per_hour"},
          {"api-cart-signal-global", "signal_global_per_hour"}
        ] do
      assert has_element?(
               view,
               "#shop-api-carts-form input##{id}[type=number][name='settings[#{name}]']"
             )
    end

    assert has_element?(view, "#shop-api-carts-form[novalidate]")
  end

  test "each input steers the spinner with the range the server enforces", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/en/admin/shop/settings")

    for {id, name} <- [
          {"api-cart-idle-days", :idle_days},
          {"api-cart-claim-ttl-minutes", :claim_ttl_minutes},
          {"api-cart-signal-per-cart", :signal_per_cart_per_hour},
          {"api-cart-signal-global", :signal_global_per_hour}
        ] do
      %Range{first: min, last: max} = Map.fetch!(CartSettings.bounds(), name)

      assert has_element?(view, "input##{id}[min='#{min}'][max='#{max}'][step='1']"),
             "#{id} does not carry min #{min}, max #{max}"
    end
  end

  defp stored(key),
    do: Repo.one(from s in "phoenix_kit_settings", where: s.key == ^key, select: s.value)

  test "saving writes only the values that changed", %{conn: conn} do
    keys = Map.values(CartSettings.keys())
    Repo.delete_all(from s in "phoenix_kit_settings", where: s.key in ^keys)
    {:ok, view, _html} = live(conn, "/en/admin/shop/settings")

    # Nothing differs from what is in effect: nothing is stored, nothing is logged.
    html = view |> element("#shop-api-carts-form") |> render_submit(form(%{}))

    assert html =~ "Assistant cart settings updated"
    assert Enum.all?(keys, &is_nil(stored(&1)))
    refute_activity_logged("shop.api_cart_setting_updated")

    # One value differs: only its key is written (and logged), not the other three.
    view |> element("#shop-api-carts-form") |> render_submit(form(%{"idle_days" => "14"}))

    assert stored("api_cart_idle_days") == "14"

    for key <- keys -- ["api_cart_idle_days"],
        do: assert(is_nil(stored(key)), "#{key} was written although it did not change")

    assert_activity_logged("shop.api_cart_setting_updated",
      metadata_has: %{"setting" => "api_cart_idle_days", "value" => 14}
    )

    refute_activity_logged("shop.api_cart_setting_updated",
      metadata_has: %{"setting" => "api_checkout_claim_ttl_minutes"}
    )
  end

  test "saving stores what changed and logs each change", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/en/admin/shop/settings")

    html =
      view
      |> element("#shop-api-carts-form")
      |> render_submit(form(%{"idle_days" => "14", "signal_global_per_hour" => "50"}))

    assert html =~ "Assistant cart settings updated"
    assert CartSettings.idle_days() == 14
    assert CartSettings.signal_global_per_hour() == 50
    assert CartSettings.claim_ttl_minutes() == 30

    assert_activity_logged("shop.api_cart_setting_updated",
      metadata_has: %{"setting" => "api_cart_idle_days", "value" => 14}
    )

    assert_activity_logged("shop.api_cart_setting_updated",
      metadata_has: %{"setting" => "api_signal_global_per_hour", "value" => 50}
    )
  end

  test "zero is accepted for the notification caps", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/en/admin/shop/settings")

    view
    |> element("#shop-api-carts-form")
    |> render_submit(form(%{"signal_per_cart_per_hour" => "0", "signal_global_per_hour" => "0"}))

    assert CartSettings.signal_per_cart_per_hour() == 0
    assert CartSettings.signal_global_per_hour() == 0
  end

  test "one invalid field stores nothing at all", %{conn: conn} do
    {:ok, _} = Settings.update_setting("api_cart_idle_days", "9")
    {:ok, view, _html} = live(conn, "/en/admin/shop/settings")

    for bad <- ["0", "1441", "abc", "7.5", "", " ", "-1"] do
      html =
        view
        |> element("#shop-api-carts-form")
        |> render_submit(form(%{"idle_days" => "10", "claim_ttl_minutes" => bad}))

      assert html =~ "Enter whole numbers within the shown ranges.", inspect(bad)
    end

    assert CartSettings.idle_days() == 9
    assert CartSettings.claim_ttl_minutes() == 30
    refute_activity_logged("shop.api_cart_setting_updated")
  end

  test "a missing, non-map or non-string submission is refused, not a crash", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/en/admin/shop/settings")

    assert render_submit(view, "save_api_cart_settings", %{}) =~ "Invalid value"
    assert render_submit(view, "save_api_cart_settings", %{"settings" => "x"}) =~ "Invalid value"

    assert render_submit(view, "save_api_cart_settings", %{"settings" => %{"idle_days" => ["1"]}}) =~
             "Enter whole numbers within the shown ranges."

    assert CartSettings.idle_days() == 7
  end

  describe "authz" do
    setup %{conn: conn} do
      {:ok, conn: put_test_scope(conn, fake_scope(permissions: ["shop", "shop.manage_catalog"]))}
    end

    test "saving is denied without shop.manage_settings", %{conn: conn} do
      {:ok, view, _html} = live_narrowed(conn, "/en/admin/shop/settings")

      html = render_submit(view, "save_api_cart_settings", form(%{"idle_days" => "30"}))

      assert html =~ "You don&#39;t have permission to do that"
      assert CartSettings.idle_days() == 7
    end
  end
end
