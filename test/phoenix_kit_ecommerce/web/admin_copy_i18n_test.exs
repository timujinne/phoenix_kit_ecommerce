defmodule PhoenixKitEcommerce.Web.AdminCopyI18nTest do
  @moduledoc """
  Admin copy that used to be hardcoded English is looked up in the module's
  catalogue: under a non-English locale the options page, the import
  configurations page, the translation tabs and the text stored on an
  order's shipping line come out translated.

  The pages are read through their dead render, which runs in the test
  process and so under the locale set here.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  import Phoenix.Component, only: [sigil_H: 2]

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Options
  alias PhoenixKitEcommerce.Web.Components.TranslationTabs

  @backend PhoenixKitEcommerce.Gettext

  setup %{conn: conn} do
    original = Gettext.get_locale(@backend)
    Gettext.put_locale(@backend, "ru")
    on_exit(fn -> Gettext.put_locale(@backend, original) end)

    %{conn: put_test_scope(conn, fake_scope())}
  end

  test "the product options page", %{conn: conn} do
    {:ok, _} =
      Options.update_global_options([
        %{"key" => "finish", "label" => "Finish", "type" => "text", "required" => true}
      ])

    html = conn |> get("/en/admin/shop/settings/options") |> html_response(200)

    assert html =~ "Параметры товара"
    assert html =~ "Глобальные опции"
    assert html =~ "1 опция"
    assert html =~ ~s(data-confirm="Удалить эту опцию? Это действие нельзя отменить.")
    assert html =~ ~s(data-tip="Отключить")
    assert html =~ "Справка по типам опций"

    refute html =~ "Global Options"
    refute html =~ "Delete this option?"
    refute html =~ "Option Types Reference"
  end

  test "the product options page without options", %{conn: conn} do
    {:ok, _} = Options.update_global_options([])

    html = conn |> get("/en/admin/shop/settings/options") |> html_response(200)

    assert html =~ "Опций пока нет"
    assert html =~ "Создать первую опцию"
    assert html =~ "0 опций"
  end

  test "the import configurations page", %{conn: conn} do
    {:ok, _} =
      Shop.create_import_config(%{
        name: "i18n_config",
        include_keywords: ["vase"],
        skip_filter: true,
        download_images: true
      })

    html = conn |> get("/en/admin/shop/settings/import-configs") |> html_response(200)

    assert html =~ "Конфигурации импорта"
    assert html =~ "Добавить конфигурацию"
    assert html =~ "Конфигурации фильтров импорта"
    assert html =~ "Назначить по умолчанию"
    assert html =~ ~s(data-confirm="Удалить эту конфигурацию?")
    assert html =~ "включающих: 1"
    assert html =~ "0 правил"
    assert html =~ "Без фильтра"
    assert html =~ "Загружать изображения"

    refute html =~ "Import Configurations"
    refute html =~ "Set Default"
    refute html =~ "Delete this configuration?"
    refute html =~ "Skip Filter"
  end

  test "the translation tabs' default-language copy" do
    assigns = %{}

    fields =
      rendered_to_string(~H"""
      <TranslationTabs.translation_fields
        language="en"
        fields={[%{key: :title, label: "Title", type: :text}]}
        form_prefix="product"
        is_default_language={true}
      />
      """)

    assert fields =~ "Это язык по умолчанию."
    refute fields =~ "This is the default language."
  end

  test "an order's shipping line is named in the buyer's locale" do
    {:ok, method} =
      Shop.create_shipping_method(%{
        "name" => "Courier #{System.unique_integer([:positive])}",
        "price" => "5.00",
        "countries" => [],
        "active" => true
      })

    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Shipped Widget"},
        "price" => Decimal.new("25.00"),
        "status" => "active",
        "currency" => "USD",
        "product_type" => "physical",
        "requires_shipping" => true,
        "weight_grams" => 500
      })

    {:ok, cart} = Shop.create_cart(session_id: "i18n-ship-#{System.unique_integer([:positive])}")
    {:ok, cart} = Shop.add_to_cart(cart, product, 1)
    {:ok, cart} = Shop.set_cart_shipping(cart, method, "EE")

    {:ok, order} =
      Shop.convert_cart_to_order(cart, billing_data: complete_billing("EE", "i18n-ship"))

    line = Enum.find(order.line_items, &(&1["type"] == "shipping"))
    assert line["name"] == "Доставка: #{method.name}"
  end
end
