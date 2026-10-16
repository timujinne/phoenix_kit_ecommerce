defmodule PhoenixKitEcommerce.WholeSetAttachmentTest do
  @moduledoc """
  An attribute-set attachment with an EMPTY selection is the catalogue's
  "the whole set applies": the storefront offers every published value of
  the set, in the set's own order, each with its price modifier.

  Driven through the real product page and add-to-cart. `async: false`:
  flips the process-wide `shop_product_source` config key.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  @moduletag :catalogue

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}
  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue.AttributeSets}
  @compile {:no_warn_undefined, PhoenixKitEntities.EntityData}

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.AttributeSets
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.ProductSource.Catalogue, as: CatalogueSource
  alias PhoenixKitEcommerce.ShopConfig
  alias PhoenixKitEcommerce.Test.Repo
  alias PhoenixKitEntities.EntityData

  @slug "whole-set-mug"

  setup %{conn: conn} do
    set_product_source("catalogue")
    on_exit(fn -> set_product_source("legacy") end)

    AttributeSets.register_deletion_guard()
    PhoenixKit.Settings.update_setting("entities_enabled", "true")
    on_exit(fn -> PhoenixKit.Settings.update_setting("entities_enabled", "false") end)

    {:ok, catalogue} = Catalogue.create_catalogue(%{name: "decor3dprint"})

    session_id = "whole-set-#{System.unique_integer([:positive])}"
    conn = Plug.Test.init_test_session(conn, %{"shop_session_id" => session_id})

    %{conn: conn, catalogue: catalogue, session_id: session_id}
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

  defp item!(catalogue, modifiers) do
    {:ok, item} =
      Catalogue.create_item(%{
        catalogue_uuid: catalogue.uuid,
        name: "Whole Set Mug",
        base_price: Decimal.new("10.00"),
        status: "active",
        slug: %{"en-US" => @slug},
        data: %{
          "ecommerce" => %{"shop_status" => "active", "price_modifiers" => %{"size" => modifiers}}
        }
      })

    item
  end

  # `values`: `{label, slug, status}`; `selection`: the attachment's slugs.
  defp attach!(item, values, selection) do
    actor = [actor_uuid: Ecto.UUID.generate()]
    {:ok, set} = AttributeSets.create_set(%{name: "Size", slug: "size"}, actor)

    for {label, slug, status} <- values do
      {:ok, value} = AttributeSets.create_value(set, %{label: label, slug: slug}, actor)
      if status != "published", do: {:ok, _} = EntityData.update(value, %{status: status})
    end

    {:ok, _} = AttributeSets.attach_set(item.uuid, set.uuid)
    :ok = AttributeSets.set_attachment_selection(item.uuid, set.uuid, selection)
    set
  end

  defp size_buttons(view) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(~s(button[phx-click="select_spec"][phx-value-key="size"]))
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  defp lines(session_id) do
    case Shop.find_active_cart(session_id: session_id) do
      %{items: items} -> items
      nil -> []
    end
  end

  test "an empty selection offers every published value, priced, in the set's order", %{
    conn: conn,
    catalogue: catalogue,
    session_id: session_id
  } do
    item = item!(catalogue, %{"small" => "0.00", "medium" => "3.00", "large" => "6.00"})

    attach!(
      item,
      [
        {"Small", "small", "published"},
        {"Medium", "medium", "published"},
        {"Large", "large", "published"},
        {"Pending", "pending", "draft"},
        {"Retired", "retired", "archived"}
      ],
      []
    )

    {:ok, view, _html} = live(conn, "/shop/product/#{@slug}")

    assert [small, medium, large] = size_buttons(view)
    assert small =~ "Small" and small =~ "10.00"
    assert medium =~ "Medium" and medium =~ "13.00"
    assert large =~ "Large" and large =~ "16.00"

    view
    |> element(~s(button[phx-click="select_spec"][phx-value-key="size"]), "Large")
    |> render_click()

    view |> element("button[phx-click=add_to_cart]") |> render_click()

    assert [line] = lines(session_id)
    assert Decimal.equal?(line.base_unit_price, Decimal.new("16.00"))
  end

  test "the context refuses a value the whole set does not offer", %{catalogue: catalogue} do
    item = item!(catalogue, %{"small" => "0.00", "pending" => "1.00"})
    attach!(item, [{"Small", "small", "published"}, {"Pending", "pending", "draft"}], [])

    product = CatalogueSource.get_product(item.uuid, preload: [:category])
    [offered] = product.metadata["_option_values"]["size"]
    {:ok, cart} = Shop.create_cart(session_id: "whole-set-ctx")

    assert {:ok, _cart} = Shop.add_to_cart(cart, product, 1, selected_specs: %{"size" => offered})

    for refused <- ["pending", "Pending"] do
      assert {:error, :invalid_option_value, _} =
               Shop.add_to_cart(cart, product, 1, selected_specs: %{"size" => refused})
    end
  end

  test "a set with no published value offers nothing, and the product sells at its base", %{
    conn: conn,
    catalogue: catalogue,
    session_id: session_id
  } do
    item = item!(catalogue, %{"pending" => "4.00"})
    attach!(item, [{"Pending", "pending", "draft"}, {"Retired", "retired", "archived"}], [])

    {:ok, view, _html} = live(conn, "/shop/product/#{@slug}")

    assert size_buttons(view) == []

    view |> element("button[phx-click=add_to_cart]") |> render_click()

    assert [line] = lines(session_id)
    assert Decimal.equal?(line.base_unit_price, Decimal.new("10.00"))
  end

  test "an explicit selection still offers only what it names", %{
    conn: conn,
    catalogue: catalogue
  } do
    item = item!(catalogue, %{"small" => "0.00", "large" => "6.00"})
    attach!(item, [{"Small", "small", "published"}, {"Large", "large", "published"}], ["large"])

    {:ok, view, _html} = live(conn, "/shop/product/#{@slug}")

    assert [large] = size_buttons(view)
    assert large =~ "Large"
  end

  test "a large whole set is offered in full — nothing is cut off", %{
    conn: conn,
    catalogue: catalogue
  } do
    values = for n <- 1..60, do: {"Size #{n}", "size-#{n}", "published"}
    item = item!(catalogue, Map.new(values, fn {_, slug, _} -> {slug, "1.00"} end))
    attach!(item, values, [])

    {:ok, view, _html} = live(conn, "/shop/product/#{@slug}")

    labels = size_buttons(view)
    assert length(labels) == 60
    assert hd(labels) =~ "Size 1"
    assert List.last(labels) =~ "Size 60"
  end
end
