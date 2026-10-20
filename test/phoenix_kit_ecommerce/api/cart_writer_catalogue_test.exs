defmodule PhoenixKitEcommerce.API.CartWriterCatalogueTest do
  @moduledoc """
  `shop.set_cart_items` on the catalogue source with a real item whose options
  come from two attached attribute sets (the shape of the stand's products): the
  keys the product card announces are the keys the cart accepts and echoes, the
  required options are enforced, and the line is priced with the option's
  modifier.

  Needs `phoenix_kit_catalogue` loaded (`:catalogue`). `async: false`: flips the
  process-wide `shop_product_source` key.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :requires_core_api
  @moduletag :catalogue

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}
  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue.AttributeSets}

  import PhoenixKitEcommerce.CartApiFixtures
  import PhoenixKitEcommerce.SearchFixtures, only: [set_product_source!: 1]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.AttributeSets
  alias PhoenixKitEcommerce.API.CartStore
  alias PhoenixKitEcommerce.API.CartToken
  alias PhoenixKitEcommerce.API.CartView
  alias PhoenixKitEcommerce.API.CartWriter
  alias PhoenixKitEcommerce.API.Loader
  alias PhoenixKitEcommerce.Search.OptionKeys

  setup do
    put_secret!()
    ensure_currencies!()
    set_product_source!("catalogue")
    AttributeSets.register_deletion_guard()
    PhoenixKit.Settings.update_setting("entities_enabled", "true")

    {:ok, catalogue} = Catalogue.create_catalogue(%{name: "decor3dprint"})

    {:ok, item} =
      Catalogue.create_item(%{
        catalogue_uuid: catalogue.uuid,
        name: "Coffee Splash",
        base_price: Decimal.new("35.52"),
        status: "active",
        slug: %{"en-US" => "coffee-splash"},
        data: %{
          "ecommerce" => %{
            "shop_status" => "active",
            "price_modifiers" => %{
              "liquid_color" => %{"black" => "32.00", "blue" => "32.00"},
              "cup_color" => %{"white" => "0.00", "gold" => "0.00"}
            }
          }
        }
      })

    attach_set(item, "Liquid Color", "liquid_color", [{"Black", "black"}, {"Blue", "blue"}])
    attach_set(item, "Cup Color", "cup_color", [{"White", "white"}, {"Gold", "gold"}])

    token = new_token!()
    %{item: item, catalogue: catalogue, token: token, ctx: ctx_for(token)}
  end

  defp attach_set(item, name, slug, values) do
    actor = [actor_uuid: Ecto.UUID.generate()]
    {:ok, set} = AttributeSets.create_set(%{name: name, slug: slug}, actor)

    for {label, value_slug} <- values do
      {:ok, _} = AttributeSets.create_value(set, %{label: label, slug: value_slug}, actor)
    end

    {:ok, _} = AttributeSets.attach_set(item.uuid, set.uuid)

    :ok =
      AttributeSets.set_attachment_selection(item.uuid, set.uuid, Enum.map(values, &elem(&1, 1)))
  end

  defp set(token, ctx, item, quantity, options) do
    {:ok, hash} = CartToken.verify(token)

    CartWriter.set_items(
      hash,
      %{
        "items" => [
          %{"product_id" => item.uuid, "quantity" => quantity, "options" => options}
        ]
      },
      ctx
    )
  end

  test "a line without its options says which one is missing and which keys are on offer", t do
    assert {:ok, %{results: [%{action: "error", error: error}]}} =
             set(t.token, t.ctx, t.item, 1, [])

    assert error.code == "option_required"
    assert error.attribute_key == "cup_color"
    assert error.allowed == ["white", "gold"]
  end

  test "the keys the product card announces are accepted, priced and echoed", t do
    record = Map.fetch!(Loader.load([t.item.uuid], language: "en-US"), t.item.uuid)

    options =
      for option <- OptionKeys.extract(record.product),
          do: %{"attribute_key" => option.key, "value_key" => List.last(option.values).key}

    assert Enum.sort(Enum.map(options, & &1["attribute_key"])) == ["cup_color", "liquid_color"]

    assert {:ok, result} = set(t.token, t.ctx, t.item, 2, options)

    assert [%{action: "created"}] = result.results
    assert [line] = result.cart.lines
    assert line.unit_price == %{amount: "67.52", currency: "USD"}
    assert line.line_total == %{amount: "135.04", currency: "USD"}

    assert Enum.sort_by(line.options, & &1.attribute_key) == [
             %{
               attribute_key: "cup_color",
               value_key: "gold",
               attribute_label: "Cup Color",
               value_label: "Gold"
             },
             %{
               attribute_key: "liquid_color",
               value_key: "blue",
               attribute_label: "Liquid Color",
               value_label: "Blue"
             }
           ]

    {:ok, hash} = CartToken.verify(t.token)
    {:ok, cart} = CartStore.resolve(hash)
    assert [read] = CartView.build(cart).lines

    assert Enum.sort_by(read.options, & &1.attribute_key) ==
             Enum.sort_by(line.options, & &1.attribute_key)
  end

  describe "an item whose category carries the option schema" do
    setup %{catalogue: catalogue} do
      {:ok, category} =
        Catalogue.create_category(%{
          name: "Engraved",
          catalogue_uuid: catalogue.uuid,
          data: %{
            "ecommerce" => %{
              "shop_status" => "active",
              "option_schema" => [
                %{
                  "key" => "engraving",
                  "label" => "Engraving",
                  "type" => "select",
                  "options" => ["Yes", "No"],
                  "required" => true,
                  "position" => 0
                }
              ]
            }
          }
        })

      {:ok, item} =
        Catalogue.create_item(%{
          catalogue_uuid: catalogue.uuid,
          category_uuid: category.uuid,
          name: "Engraved Plaque",
          base_price: Decimal.new("10.00"),
          status: "active",
          slug: %{"en-US" => "engraved-plaque"},
          data: %{"ecommerce" => %{"shop_status" => "active"}}
        })

      %{plaque: item}
    end

    test "a missing required option of the category is that line's error, not a retry", t do
      assert {:ok, %{results: [%{action: "error", error: error}]}} =
               set(t.token, t.ctx, t.plaque, 1, [])

      assert error.code == "option_required"
      assert error.attribute_key == "engraving"
      assert error.allowed == ["yes", "no"]
    end

    test "the category's option is offered, accepted and echoed", t do
      options = [%{"attribute_key" => "engraving", "value_key" => "yes"}]

      assert {:ok, result} = set(t.token, t.ctx, t.plaque, 2, options)

      assert [%{action: "created"}] = result.results

      assert [%{quantity: 2, options: [%{attribute_key: "engraving", value_key: "yes"}]}] =
               result.cart.lines
    end

    test "a value the category does not offer lists the ones it does", t do
      options = [%{"attribute_key" => "engraving", "value_key" => "maybe"}]

      assert {:ok, %{results: [%{action: "error", error: error}]}} =
               set(t.token, t.ctx, t.plaque, 1, options)

      assert error.code == "option_invalid"
      assert error.allowed == ["yes", "no"]
    end
  end
end
