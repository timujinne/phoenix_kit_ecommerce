defmodule PhoenixKitEcommerce.API.OptionLabelsCatalogueTest do
  @moduledoc """
  What a buyer and an agent read of a cart line's options on the catalogue
  source, where a value's key (`5-inches-13-cm`) and what it is shown as
  (`5 inches (13 cm)`, `5 Zoll (13 cm)`) differ and the label depends on the
  language: the cart tools answer both, in the language of the request, and the
  claim page shows the label of the claim's language, never the key. The same
  item prices the option, so `shop.get_products` quotes each value.

  Needs `phoenix_kit_catalogue` loaded (`:catalogue`). `async: false`: flips the
  process-wide `shop_product_source` key.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  @moduletag :requires_core_api
  @moduletag :catalogue

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}
  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue.AttributeSets}

  import PhoenixKitEcommerce.CartApiFixtures
  import PhoenixKitEcommerce.SearchFixtures, only: [enable_languages!: 1, set_product_source!: 1]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.AttributeSets
  alias PhoenixKitEcommerce.API.CartStore
  alias PhoenixKitEcommerce.API.CartToken
  alias PhoenixKitEcommerce.API.CartView
  alias PhoenixKitEcommerce.API.Claims

  @labels [
    {"en-US", "5 inches (13 cm)"},
    {"de-DE", "5 Zoll (13 cm)"},
    {"fr-FR", "5 pouces (13 cm)"}
  ]

  setup %{conn: conn} do
    put_secret!()
    ensure_currencies!()
    enable_languages!(["en-US", "de-DE", "fr-FR"])
    set_product_source!("catalogue")
    AttributeSets.register_deletion_guard()
    PhoenixKit.Settings.update_setting("entities_enabled", "true")

    {:ok, catalogue} = Catalogue.create_catalogue(%{name: "decor3dprint"})

    {:ok, item} =
      Catalogue.create_item(%{
        catalogue_uuid: catalogue.uuid,
        name: "Wall Art",
        base_price: Decimal.new("20.00"),
        status: "active",
        slug: %{"en-US" => "wall-art"},
        data: %{
          "ecommerce" => %{
            "shop_status" => "active",
            "price_modifiers" => %{
              "size" => %{"5-inches-13-cm" => "0.00", "10-inches-25-cm" => "15.00"}
            }
          }
        }
      })

    actor = [actor_uuid: Ecto.UUID.generate()]
    {:ok, set} = AttributeSets.create_set(%{name: "Size", slug: "size"}, actor)

    for {slug, en, de, fr} <- [
          {"5-inches-13-cm", "5 inches (13 cm)", "5 Zoll (13 cm)", "5 pouces (13 cm)"},
          {"10-inches-25-cm", "10 inches (25 cm)", "10 Zoll (25 cm)", "10 pouces (25 cm)"}
        ] do
      {:ok, value} = AttributeSets.create_value(set, %{label: en, slug: slug}, actor)
      {:ok, value} = PhoenixKitEntities.EntityData.set_title_translation(value, "de-DE", de)
      {:ok, _} = PhoenixKitEntities.EntityData.set_title_translation(value, "fr-FR", fr)
    end

    {:ok, _} = AttributeSets.attach_set(item.uuid, set.uuid)

    :ok =
      AttributeSets.set_attachment_selection(item.uuid, set.uuid, [
        "5-inches-13-cm",
        "10-inches-25-cm"
      ])

    conn = Plug.Test.init_test_session(conn, %{"shop_session_id" => "labels-#{unique_ip()}"})
    %{conn: conn, item: item}
  end

  defp set_line(token, item, language) do
    {200, body, _} =
      call_tool("shop.set_cart_items", %{
        "cart_token" => token,
        "language" => language,
        "items" => [
          %{
            "product_id" => item.uuid,
            "quantity" => 1,
            "options" => [%{"attribute_key" => "size", "value_key" => "5-inches-13-cm"}]
          }
        ]
      })

    body
  end

  defp only_option(%{"cart" => %{"lines" => [%{"options" => [option]}]}}), do: option

  test "set_cart_items answers the labels of the request's language beside the keys", t do
    token = new_token!()

    for {language, label} <- @labels do
      assert only_option(set_line(token, t.item, language)) == %{
               "attribute_key" => "size",
               "value_key" => "5-inches-13-cm",
               "attribute_label" => "Size",
               "value_label" => label
             }
    end
  end

  test "get_cart answers the same labels", t do
    token = new_token!()
    set_line(token, t.item, "en-US")

    for {language, label} <- @labels do
      {200, body, _} =
        call_tool("shop.get_cart", %{"cart_token" => token, "language" => language})

      assert %{"attribute_label" => "Size", "value_label" => ^label} =
               only_option(%{"cart" => body})
    end
  end

  test "CartView.build/2 takes the language of the labels", t do
    token = new_token!()
    set_line(token, t.item, "en-US")
    {:ok, hash} = CartToken.verify(token)
    {:ok, cart} = CartStore.resolve(hash)

    view = CartView.build(cart, "fr-FR")

    assert [%{options: [%{value_label: "5 pouces (13 cm)", attribute_label: "Size"}]}] =
             view.lines
  end

  test "the claim page shows the label of the claim's language, never the key", t do
    token = new_token!()
    set_line(token, t.item, "en-US")
    {:ok, hash} = CartToken.verify(token)
    {:ok, cart} = CartStore.resolve(hash)

    for {language, label} <- @labels do
      {:ok, %{token: raw}} = Claims.issue(cart, hash, language)
      conn = get(t.conn, Claims.path(raw))
      html = html_response(conn, 200)
      [line] = cart.items

      text =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#claim-line-#{line.uuid}-options")
        |> LazyHTML.text()

      assert text =~ label
      assert text =~ "Size"
      refute html =~ "5-inches-13-cm"
    end
  end

  test "get_products quotes the price of each size in the request's language and currency", t do
    {200, body, _} =
      call_tool("shop.get_products", %{
        "ids" => [t.item.uuid],
        "language" => "de-DE",
        "currency" => "EUR"
      })

    assert %{"results" => [%{"product" => %{"options" => [size]}}]} = body

    assert size["affects_price"] == true

    assert Map.new(size["values"], &{&1["key"], {&1["label"], &1["price"]}}) == %{
             "5-inches-13-cm" => {"5 Zoll (13 cm)", %{"amount" => "18.18", "currency" => "EUR"}},
             "10-inches-25-cm" => {"10 Zoll (25 cm)", %{"amount" => "31.82", "currency" => "EUR"}}
           }
  end
end
