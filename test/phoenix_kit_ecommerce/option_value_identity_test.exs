defmodule PhoenixKitEcommerce.OptionValueIdentityTest do
  @moduledoc """
  On the catalogue source an option value is identified by its key (the
  attribute-set value's slug), never by its label: a label is a translation,
  and two values may share one in some language.

  The set here is "Color", priced per value, with:

    * `red` "Red" (+5.00) and `crimson` "Red" (+9.00) — the same label in
      English, different ones in Russian;
    * `blue` "Blue" (+2.00) and `navy` "Navy" (+7.00) — different in English
      and Estonian, the same ("Синий") in Russian.

  Cart lines stored before keys were the identity hold the label and no
  snapshot; they keep displaying, updating and converting as they are.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  @moduletag :catalogue

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}
  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue.AttributeSets}
  @compile {:no_warn_undefined, PhoenixKitEntities.EntityData}

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.AttributeSets
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.CartItem
  alias PhoenixKitEcommerce.ProductSource.Catalogue, as: CatalogueSource
  alias PhoenixKitEcommerce.SelectedSpecs
  alias PhoenixKitEcommerce.ShopConfig
  alias PhoenixKitEcommerce.Test.Repo
  alias PhoenixKitEntities.EntityData

  @slug "two-reds-vase"

  # {key, en label, ru label, et label, modifier}, in the set's own order.
  @values [
    {"red", "Red", "Красный", "Punane", "5.00"},
    {"crimson", "Red", "Малиновый", "Karmiinpunane", "9.00"},
    {"blue", "Blue", "Синий", "Sinine", "2.00"},
    {"navy", "Navy", "Синий", "Meresinine", "7.00"}
  ]

  setup %{conn: conn} do
    set_product_source("catalogue")
    on_exit(fn -> set_product_source("legacy") end)

    AttributeSets.register_deletion_guard()
    PhoenixKit.Settings.update_setting("entities_enabled", "true")
    on_exit(fn -> PhoenixKit.Settings.update_setting("entities_enabled", "false") end)

    {:ok, catalogue} = Catalogue.create_catalogue(%{name: "decor3dprint"})

    {:ok, item} =
      Catalogue.create_item(%{
        catalogue_uuid: catalogue.uuid,
        name: "Two Reds Vase",
        base_price: Decimal.new("20.00"),
        status: "active",
        slug: %{"en-US" => @slug},
        data: %{
          "ecommerce" => %{
            "shop_status" => "active",
            "price_modifiers" => %{
              "color" => Map.new(@values, fn {key, _, _, _, amount} -> {key, amount} end)
            }
          }
        }
      })

    actor = [actor_uuid: Ecto.UUID.generate()]
    {:ok, set} = AttributeSets.create_set(%{name: "Color", slug: "color"}, actor)

    for {key, en, ru, et, _amount} <- @values do
      {:ok, value} = AttributeSets.create_value(set, %{label: en, slug: key}, actor)
      {:ok, value} = EntityData.set_title_translation(value, "ru", ru)
      {:ok, _} = EntityData.set_title_translation(value, "et", et)
    end

    {:ok, _} = AttributeSets.attach_set(item.uuid, set.uuid)

    :ok =
      AttributeSets.set_attachment_selection(
        item.uuid,
        set.uuid,
        Enum.map(@values, &elem(&1, 0))
      )

    session_id = "option-identity-#{System.unique_integer([:positive])}"
    conn = Plug.Test.init_test_session(conn, %{"shop_session_id" => session_id})

    %{conn: conn, item: item, session_id: session_id}
  end

  defp set_product_source(value) do
    case Repo.get(ShopConfig, "shop_product_source") do
      nil ->
        %ShopConfig{}
        |> ShopConfig.changeset(%{key: "shop_product_source", value: %{"value" => value}})
        |> Repo.insert!()

      config ->
        config
        |> ShopConfig.changeset(%{value: %{"value" => value}})
        |> Repo.update!()
    end
  end

  defp product(item, language \\ nil),
    do: CatalogueSource.get_product(item.uuid, language: language, preload: [:category])

  defp cart_for(session_id) do
    case Shop.find_active_cart(session_id: session_id) do
      nil ->
        {:ok, cart} = Shop.create_cart(session_id: session_id)
        cart

      cart ->
        cart
    end
  end

  defp lines(session_id) do
    case Shop.find_active_cart(session_id: session_id) do
      %{items: items} -> items
      nil -> []
    end
  end

  # A line as add-to-cart wrote it before keys were the identity: the label
  # of the language it was added in, no snapshot, its own frozen price.
  defp insert_label_line!(cart, item, label, unit_price) do
    %CartItem{}
    |> CartItem.changeset(%{
      cart_uuid: cart.uuid,
      product_title: "Two Reds Vase",
      product_slug: @slug,
      unit_price: Decimal.new(unit_price),
      base_unit_price: Decimal.new(unit_price),
      currency: cart.currency || "USD",
      quantity: 1,
      selected_specs: %{"color" => label},
      metadata: %{"catalogue_item_uuid" => item.uuid, "requires_shipping" => false}
    })
    |> Repo.insert!()
  end

  defp convert!(cart) do
    {:ok, order} =
      Shop.convert_cart_to_order(Shop.get_cart(cart.uuid), billing_data: complete_billing("US"))

    Enum.find(order.line_items, &(&1["type"] == "product"))
  end

  describe "the product's option values" do
    test "are keyed by value key, labelled per language, with nothing folded", %{item: item} do
      en = product(item, "en-US").metadata
      ru = product(item, "ru").metadata
      et = product(item, "et").metadata

      for metadata <- [en, ru, et] do
        assert metadata["_option_values"] == %{"color" => ~w(red crimson blue navy)}

        assert metadata["_price_modifiers"] == %{
                 "color" => %{
                   "red" => "5.00",
                   "crimson" => "9.00",
                   "blue" => "2.00",
                   "navy" => "7.00"
                 }
               }
      end

      assert en["_value_labels"]["color"] == %{
               "red" => "Red",
               "crimson" => "Red",
               "blue" => "Blue",
               "navy" => "Navy"
             }

      assert ru["_value_labels"]["color"]["blue"] == "Синий"
      assert ru["_value_labels"]["color"]["navy"] == "Синий"
      assert et["_value_labels"]["color"]["navy"] == "Meresinine"

      # The way back from a label answers the first value in the set's order.
      assert en["_value_slugs"]["color"]["Red"] == "red"
      assert ru["_value_slugs"]["color"]["Синий"] == "blue"
      assert et["_value_slugs"]["color"]["Meresinine"] == "navy"
    end
  end

  describe "duplicate labels in one language" do
    test "are two picker entries, each priced and carted as itself", %{
      conn: conn,
      session_id: session_id
    } do
      {:ok, view, _html} = live(conn, "/shop/product/#{@slug}")

      red = element(view, ~s(button[phx-click="select_spec"][phx-value-opt="red"]))
      crimson = element(view, ~s(button[phx-click="select_spec"][phx-value-opt="crimson"]))

      assert render(red) =~ "Red"
      assert render(red) =~ "25.00"
      assert render(crimson) =~ "Red"
      assert render(crimson) =~ "29.00"

      render_click(crimson)
      assert view |> element("span.text-3xl.text-primary") |> render() =~ "29.00"

      view |> element("button[phx-click=add_to_cart]") |> render_click()

      assert [line] = lines(session_id)
      assert line.selected_specs == %{"color" => "crimson"}
      assert Decimal.equal?(line.base_unit_price, Decimal.new("29.00"))
      assert SelectedSpecs.labels(line) == %{"color" => "Red"}

      # The other "Red" is a line of its own, at its own price.
      render_click(red)
      view |> element("button[phx-click=add_to_cart]") |> render_click()

      prices =
        session_id
        |> lines()
        |> Map.new(&{&1.selected_specs["color"], Decimal.to_string(&1.base_unit_price)})

      assert prices == %{"crimson" => "29.00", "red" => "25.00"}
    end
  end

  describe "a label shared in one language only" do
    test "in Russian the two «Синий» values stay two values with two prices", %{
      item: item,
      session_id: session_id
    } do
      ru = product(item, "ru")
      cart = cart_for(session_id)

      {:ok, _} =
        Shop.add_to_cart(cart, ru, 1, selected_specs: %{"color" => "navy"}, language: "ru")

      {:ok, _} =
        Shop.add_to_cart(cart, ru, 1, selected_specs: %{"color" => "blue"}, language: "ru")

      by_key = Map.new(lines(session_id), &{&1.selected_specs["color"], &1})

      assert Decimal.equal?(by_key["navy"].base_unit_price, Decimal.new("27.00"))
      assert Decimal.equal?(by_key["blue"].base_unit_price, Decimal.new("22.00"))
      assert SelectedSpecs.labels(by_key["navy"]) == %{"color" => "Синий"}
      assert SelectedSpecs.labels(by_key["blue"]) == %{"color" => "Синий"}
    end

    test "the same key added from an Estonian and a Russian page is one line", %{
      item: item,
      session_id: session_id
    } do
      cart = cart_for(session_id)

      {:ok, _} =
        Shop.add_to_cart(cart, product(item, "et"), 1,
          selected_specs: %{"color" => "navy"},
          language: "et"
        )

      {:ok, _} =
        Shop.add_to_cart(cart, product(item, "ru"), 1,
          selected_specs: %{"color" => "navy"},
          language: "ru"
        )

      assert [line] = lines(session_id)
      assert line.quantity == 2
      # The label the buyer saw when the line was made is the one it keeps.
      assert SelectedSpecs.labels(line) == %{"color" => "Meresinine"}
    end
  end

  describe "add-to-cart refuses a value that is not the product's own" do
    test "a crafted key, and a label sent where a key belongs", %{
      item: item,
      session_id: session_id
    } do
      cart = cart_for(session_id)

      for value <- ["teal", "Red", "Синий"] do
        assert {:error, :invalid_option_value, %{key: "color", value: ^value}} =
                 Shop.add_to_cart(cart, product(item, "ru"), 1,
                   selected_specs: %{"color" => value},
                   language: "ru"
                 )
      end

      assert lines(session_id) == []
    end

    test "a crafted key pushed at the product page puts nothing in the cart", %{
      conn: conn,
      session_id: session_id
    } do
      {:ok, view, _html} = live(conn, "/shop/product/#{@slug}")

      render_click(view, "select_spec", %{"key" => "color", "opt" => "teal"})
      view |> element("button[phx-click=add_to_cart]") |> render_click()

      assert lines(session_id) == []
    end
  end

  describe "a cart line stored before keys were the identity" do
    test "still displays, updates its quantity at its own price, and converts unchanged", %{
      conn: conn,
      item: item,
      session_id: session_id
    } do
      {:ok, method} =
        Shop.create_shipping_method(%{"name" => "Standard", "price" => Decimal.new("5.00")})

      cart = cart_for(session_id)
      # Priced as the shopper was charged then — not what any value costs now.
      line = insert_label_line!(cart, item, "Red", "24.00")

      {:ok, _view, html} = live(conn, "/cart")
      assert html =~ "Red"

      {:ok, _cart} = Shop.update_cart_item(line, 3)
      reloaded = Repo.get!(CartItem, line.uuid)
      assert reloaded.quantity == 3
      assert Decimal.equal?(reloaded.unit_price, Decimal.new("24.00"))
      assert reloaded.selected_specs == %{"color" => "Red"}
      refute SelectedSpecs.keyed?(reloaded)

      {:ok, cart} = Shop.set_cart_shipping(Shop.get_cart(cart.uuid), method, "US")
      order_line = convert!(cart)

      assert order_line["selected_specs"] == %{"color" => "Red"}
      refute Map.has_key?(order_line, "selected_spec_keys")
      assert order_line["unit_price"] == "24.00"
      assert order_line["description"] =~ "Color: Red"
    end

    test "is recognised as the selection it resolves to, first value of the label", %{
      conn: conn,
      item: item,
      session_id: session_id
    } do
      insert_label_line!(cart_for(session_id), item, "Red", "24.00")

      {:ok, view, _html} = live(conn, "/shop/product/#{@slug}")

      render_click(view, "select_spec", %{"key" => "color", "opt" => "red"})
      assert render(view) =~ "Already in cart:"

      render_click(view, "select_spec", %{"key" => "color", "opt" => "crimson"})
      refute render(view) =~ "Already in cart:"
    end

    test "a keyed add never lands on it, even where its label reads like a key", %{
      item: item,
      session_id: session_id
    } do
      cart = cart_for(session_id)
      old = insert_label_line!(cart, item, "crimson", "24.00")

      {:ok, _} =
        Shop.add_to_cart(cart, product(item, "en-US"), 1,
          selected_specs: %{"color" => "crimson"},
          language: "en-US"
        )

      assert [_old, _new] = lines(session_id)
      assert Repo.get!(CartItem, old.uuid).quantity == 1
    end
  end

  describe "a keyed cart line" do
    test "converts with the label on the order line and the key beside it", %{
      item: item,
      session_id: session_id
    } do
      {:ok, method} =
        Shop.create_shipping_method(%{"name" => "Standard", "price" => Decimal.new("5.00")})

      cart = cart_for(session_id)

      {:ok, _} =
        Shop.add_to_cart(cart, product(item, "en-US"), 1,
          selected_specs: %{"color" => "crimson"},
          language: "en-US"
        )

      {:ok, cart} = Shop.set_cart_shipping(Shop.get_cart(cart.uuid), method, "US")
      order_line = convert!(cart)

      assert order_line["selected_specs"] == %{"color" => "Red"}
      assert order_line["selected_spec_keys"] == %{"color" => "crimson"}
      assert order_line["unit_price"] == "29.00"
      assert order_line["description"] =~ "Color: Red"
      refute order_line["description"] =~ "crimson"
    end

    test "shows its label on the cart page, not its key", %{
      conn: conn,
      item: item,
      session_id: session_id
    } do
      {:ok, _} =
        Shop.add_to_cart(cart_for(session_id), product(item, "et"), 1,
          selected_specs: %{"color" => "navy"},
          language: "et"
        )

      {:ok, _view, html} = live(conn, "/cart")

      assert html =~ "Meresinine"
      refute html =~ ~r/>\s*navy\s*</
    end
  end
end
