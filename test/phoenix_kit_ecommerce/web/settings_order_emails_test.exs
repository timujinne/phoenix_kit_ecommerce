defmodule PhoenixKitEcommerce.Web.SettingsOrderEmailsTest do
  @moduledoc "The Order emails card of the shop settings page."

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitEcommerce.OrderEmails
  alias PhoenixKitEcommerce.SearchFixtures

  @form "#shop-order-email-recipients-form"

  setup %{conn: conn} do
    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  test "buyer emails start on and can be turned off", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/en/admin/shop/settings")

    assert has_element?(view, "#toggle-order-emails-to-buyer[checked]")

    view |> element("#toggle-order-emails-to-buyer") |> render_click()

    refute has_element?(view, "#toggle-order-emails-to-buyer[checked]")
    refute OrderEmails.buyer_emails_enabled?()
  end

  test "saves the shop's addresses and shows them back", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/en/admin/shop/settings")

    view |> form(@form, addresses: "a@example.com; b@example.com") |> render_submit()

    assert OrderEmails.shop_recipients() == ["a@example.com", "b@example.com"]

    assert has_element?(
             view,
             "#shop-order-email-recipients[value='a@example.com, b@example.com']"
           )
  end

  test "saves the addresses for the copies of the buyer's emails", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/en/admin/shop/settings")

    view
    |> form("#shop-order-email-copy-recipients-form", addresses: "owner@example.com")
    |> render_submit()

    assert OrderEmails.copy_recipients() == ["owner@example.com"]
    assert has_element?(view, "#shop-order-email-copy-recipients[value='owner@example.com']")
  end

  test "offers no language choice on a site with one language", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/en/admin/shop/settings")

    refute has_element?(view, "#shop-order-email-language-form")
  end

  test "chooses the language of the shop's email", %{conn: conn} do
    SearchFixtures.enable_languages!(["en", "et", "ru"])
    {:ok, view, _html} = live(conn, "/en/admin/shop/settings")

    view |> form("#shop-order-email-language-form", language: "ru") |> render_change()

    assert OrderEmails.shop_email_language() == "ru"
    assert has_element?(view, "#shop-order-email-language option[value='ru'][selected]")

    view |> form("#shop-order-email-language-form", language: "") |> render_change()

    assert OrderEmails.chosen_shop_email_language() == nil
  end

  test "says which address is wrong and stores nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/en/admin/shop/settings")

    html = view |> form(@form, addresses: "a@example.com, nonsense") |> render_submit()

    assert html =~ "Not an email address: nonsense"
    assert OrderEmails.shop_recipients() == []
  end
end
