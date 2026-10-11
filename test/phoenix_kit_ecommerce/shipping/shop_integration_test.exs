defmodule PhoenixKitEcommerce.Shipping.ShopIntegrationTest do
  @moduledoc """
  The shop side of shipping: the packing defaults, the packing snapshot of a
  cart line, the parcels of a cart and the module wiring.
  """

  # Changes settings and the application env, so not async.
  use PhoenixKitEcommerce.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.{CartItem, Category}
  alias PhoenixKitEcommerce.Shipping.Cache
  alias PhoenixKitEcommerce.Shipping.Packer.Defaults
  alias PhoenixKitEcommerce.Shipping.Parcel
  alias PhoenixKitEcommerce.Test.Shipping.StubProvider

  @setting "shop_shipping_parcel_defaults"

  defmodule SecondShopify do
    @moduledoc false
    def key, do: "second_shopify"
    def integration, do: %{key: "shopify", name: "Impostor"}
  end

  defmodule NoIntegration do
    @moduledoc false
    def key, do: "no_integration"
    def integration, do: nil
  end

  defmodule RaisingIntegration do
    @moduledoc false
    def key, do: "raising_integration"
    def integration, do: raise("integration blew up")
  end

  defp with_providers(providers) do
    previous = Application.get_env(:phoenix_kit_ecommerce, :shipping_providers)
    Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, providers)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, previous),
        else: Application.delete_env(:phoenix_kit_ecommerce, :shipping_providers)
    end)
  end

  defp product!(attrs \\ %{}) do
    {:ok, product} =
      Shop.create_product(
        Map.merge(
          %{
            "title" => %{"en" => "Widget #{System.unique_integer([:positive])}"},
            "price" => Decimal.new("25.00"),
            "status" => "active",
            "product_type" => "physical",
            "requires_shipping" => true,
            "weight_grams" => 500
          },
          attrs
        )
      )

    product
  end

  defp category!(attrs \\ %{}) do
    {:ok, category} =
      Shop.create_category(
        Map.merge(%{"name" => %{"en" => "Cat #{System.unique_integer([:positive])}"}}, attrs)
      )

    category
  end

  defp new_cart do
    {:ok, cart} = Shop.create_cart(session_id: "ship-#{System.unique_integer([:positive])}")
    cart
  end

  defp lines(cart), do: Repo.all(from i in CartItem, where: i.cart_uuid == ^cart.uuid)

  defp profile_of(cart) do
    assert [line] = lines(cart)
    line.metadata["shipping_profile"]
  end

  describe "shipping_parcel_defaults/0" do
    test "is empty until the shop sets it" do
      assert Shop.shipping_parcel_defaults() == %Defaults{}
    end

    test "reads the saved box and weight" do
      Settings.update_json_setting_with_module(
        @setting,
        %{"length_mm" => 100, "width_mm" => 300, "height_mm" => 200, "weight_g" => 450},
        "shop"
      )

      assert Shop.shipping_parcel_defaults() == %Defaults{box_mm: [100, 300, 200], weight_g: 450}
    end

    test "a partial box is no box, and the weight stands alone" do
      Settings.update_json_setting_with_module(
        @setting,
        %{"length_mm" => 100, "weight_g" => "450"},
        "shop"
      )

      assert Shop.shipping_parcel_defaults() == %Defaults{box_mm: nil, weight_g: 450}
    end

    test "garbage in the setting is ignored" do
      Settings.update_json_setting_with_module(
        @setting,
        %{"length_mm" => "wide", "width_mm" => -1, "height_mm" => nil, "weight_g" => []},
        "shop"
      )

      assert Shop.shipping_parcel_defaults() == %Defaults{}
    end
  end

  describe "update_shipping_parcel_defaults/2" do
    test "validates, stores and returns the defaults" do
      attrs = %{
        "length_mm" => "100",
        "width_mm" => 300,
        "height_mm" => "200",
        "weight_g" => "450"
      }

      assert {:ok, %Defaults{box_mm: [100, 300, 200], weight_g: 450}} =
               Shop.update_shipping_parcel_defaults(attrs)

      assert Settings.get_json_setting(@setting) ==
               %{"length_mm" => 100, "width_mm" => 300, "height_mm" => 200, "weight_g" => 450}

      assert Shop.shipping_parcel_defaults() == %Defaults{box_mm: [100, 300, 200], weight_g: 450}
    end

    test "atom keys work as well" do
      assert {:ok, %Defaults{weight_g: 450}} =
               Shop.update_shipping_parcel_defaults(%{weight_g: 450})
    end

    test "blank and zero values are not stored" do
      assert {:ok, %Defaults{box_mm: nil, weight_g: 450}} =
               Shop.update_shipping_parcel_defaults(%{
                 "length_mm" => "",
                 "width_mm" => "0",
                 "height_mm" => nil,
                 "weight_g" => "450"
               })

      assert Settings.get_json_setting(@setting) == %{"weight_g" => 450}
    end

    test "saving blanks clears the defaults" do
      Shop.update_shipping_parcel_defaults(%{"weight_g" => "450"})

      assert {:ok, %Defaults{} = defaults} = Shop.update_shipping_parcel_defaults(%{})
      assert defaults == %Defaults{}
      assert Shop.shipping_parcel_defaults() == %Defaults{}
    end

    test "rejects negative, fractional and non-numeric values" do
      for bad <- ["-1", "1.5", "abc", -3] do
        assert {:error, [{:weight_g, _}]} =
                 Shop.update_shipping_parcel_defaults(%{"weight_g" => bad})
      end

      assert {:error, errors} =
               Shop.update_shipping_parcel_defaults(%{"length_mm" => "x", "weight_g" => "y"})

      assert Keyword.keys(errors) == [:length_mm, :weight_g]
    end

    test "the sides are all set or all blank" do
      assert {:error, errors} =
               Shop.update_shipping_parcel_defaults(%{"length_mm" => "100", "width_mm" => "50"})

      assert Keyword.keys(errors) == [:height_mm]
    end

    test "a rejected save changes nothing" do
      Shop.update_shipping_parcel_defaults(%{"weight_g" => "450"})
      assert {:error, _} = Shop.update_shipping_parcel_defaults(%{"weight_g" => "-5"})

      assert Shop.shipping_parcel_defaults().weight_g == 450
    end

    test "whitespace is unset, like a blank" do
      assert {:ok, %Defaults{box_mm: nil, weight_g: 450}} =
               Shop.update_shipping_parcel_defaults(%{
                 "length_mm" => "  ",
                 "width_mm" => " \t",
                 "height_mm" => "",
                 "weight_g" => "450"
               })
    end

    test "values above the limit are rejected, the limit itself is fine" do
      assert {:ok, %Defaults{weight_g: 10_000_000}} =
               Shop.update_shipping_parcel_defaults(%{"weight_g" => "10000000"})

      assert {:error, [{:weight_g, message}]} =
               Shop.update_shipping_parcel_defaults(%{"weight_g" => "10000001"})

      assert message =~ "10000000"

      assert {:error, [{:weight_g, _}]} =
               Shop.update_shipping_parcel_defaults(%{"weight_g" => "1e30"})
    end

    test "saving writes no audit row (the caller logs)" do
      assert {:ok, _} = Shop.update_shipping_parcel_defaults(%{"weight_g" => "450"})

      refute_activity_logged("shop.shipping_parcel_defaults_changed")
    end
  end

  describe "the shipping profile of a cart line" do
    test "the dimensions of the product and the weight of its category" do
      category =
        category!(%{
          "parcel_length_mm" => "500",
          "parcel_width_mm" => "400",
          "parcel_height_mm" => "300",
          "parcel_weight_g" => "700"
        })

      product =
        product!(%{
          "category_uuid" => category.uuid,
          "length_mm" => "100",
          "width_mm" => "300",
          "height_mm" => "200"
        })

      {:ok, cart} = Shop.add_to_cart(new_cart(), product, 1)

      assert profile_of(cart) == %{"dims_mm" => [300, 200, 100], "default_weight_g" => 700}
    end

    test "a product without dimensions falls back to the box of the category" do
      category =
        category!(%{
          "parcel_length_mm" => "100",
          "parcel_width_mm" => "400",
          "parcel_height_mm" => "300"
        })

      product = product!(%{"category_uuid" => category.uuid})
      {:ok, cart} = Shop.add_to_cart(new_cart(), product, 1)

      assert profile_of(cart) == %{"dims_mm" => [400, 300, 100], "default_weight_g" => nil}
    end

    test "nothing is known about a product alone" do
      {:ok, cart} = Shop.add_to_cart(new_cart(), product!(), 1)

      assert profile_of(cart) == %{"dims_mm" => nil, "default_weight_g" => nil}
    end

    test "a category without defaults adds nothing" do
      product = product!(%{"category_uuid" => category!().uuid})
      {:ok, cart} = Shop.add_to_cart(new_cart(), product, 1)

      assert profile_of(cart) == %{"dims_mm" => nil, "default_weight_g" => nil}
    end

    test "a category whose parcel defaults are damaged does not block the add" do
      category = category!()

      Repo.update_all(
        from(c in Category, where: c.uuid == ^category.uuid),
        set: [metadata: %{"parcel_defaults" => "junk"}]
      )

      {:ok, cart} = Shop.add_to_cart(new_cart(), product!(%{"category_uuid" => category.uuid}), 1)

      assert profile_of(cart) == %{"dims_mm" => nil, "default_weight_g" => nil}
    end

    test "a failing read in a savepoint leaves the surrounding transaction usable" do
      # The mechanism the category read relies on: add-to-cart runs it inside
      # its transaction, and an unprotected failing statement aborts that.
      assert {:ok, count} =
               Repo.transaction(fn ->
                 assert_raise Postgrex.Error, fn ->
                   Repo.one(from(c in "phoenix_kit_shop_categories", select: c.no_such_column),
                     mode: :savepoint
                   )
                 end

                 Repo.one(from(c in "phoenix_kit_shop_categories", select: count(c.uuid)))
               end)

      assert is_integer(count)
    end

    test "a product whose category vanished is still added" do
      category = category!(%{"parcel_weight_g" => "700"})
      product = product!(%{"category_uuid" => category.uuid})
      {:ok, _} = Shop.delete_category(category)

      {:ok, cart} = Shop.add_to_cart(new_cart(), product, 1)

      assert profile_of(cart) == %{"dims_mm" => nil, "default_weight_g" => nil}
    end

    test "the snapshot is frozen with the line" do
      category = category!(%{"parcel_weight_g" => "700"})
      product = product!(%{"category_uuid" => category.uuid})
      {:ok, cart} = Shop.add_to_cart(new_cart(), product, 1)

      {:ok, _} = Shop.update_category(category, %{"parcel_weight_g" => "900"})
      {:ok, _} = Shop.update_product(product, %{"length_mm" => "1"})
      {:ok, cart} = Shop.add_to_cart(cart, Shop.get_product!(product.uuid), 1)

      assert profile_of(cart)["default_weight_g"] == 700
      assert [%CartItem{quantity: 2}] = lines(cart)
    end

    test "the category defaults are read from the metadata of the legacy category" do
      category = category!()
      assert %Category{} = category

      Repo.update_all(
        from(c in Category, where: c.uuid == ^category.uuid),
        set: [metadata: %{"parcel_defaults" => %{"weight_g" => 320}}]
      )

      {:ok, cart} = Shop.add_to_cart(new_cart(), product!(%{"category_uuid" => category.uuid}), 1)

      assert profile_of(cart)["default_weight_g"] == 320
    end
  end

  describe "cart_parcels/1" do
    test "an empty cart has no parcels" do
      assert Shop.cart_parcels(new_cart()) == []
    end

    test "packs the shipping lines into one parcel" do
      Shop.update_shipping_parcel_defaults(%{
        "length_mm" => 100,
        "width_mm" => 100,
        "height_mm" => 100
      })

      product = product!(%{"length_mm" => 300, "width_mm" => 200, "height_mm" => 100})
      {:ok, cart} = Shop.add_to_cart(new_cart(), product, 2)

      assert [%Parcel{weight_g: 1000, length_mm: 300, width_mm: 200, height_mm: 200}] =
               Shop.cart_parcels(cart)
    end

    test "digital lines are not packed" do
      digital = product!(%{"product_type" => "digital", "requires_shipping" => false})
      {:ok, cart} = Shop.add_to_cart(new_cart(), digital, 1)

      assert Shop.cart_parcels(cart) == []

      {:ok, cart} = Shop.add_to_cart(cart, product!(%{"weight_grams" => 300}), 1)

      assert [%Parcel{weight_g: 300}] = Shop.cart_parcels(cart)
    end

    test "a line without a weight takes the category weight, then the shop weight" do
      Shop.update_shipping_parcel_defaults(%{"weight_g" => 100})
      category = category!(%{"parcel_weight_g" => "250"})

      with_category = product!(%{"weight_grams" => 0, "category_uuid" => category.uuid})
      without = product!(%{"weight_grams" => 0})

      {:ok, cart} = Shop.add_to_cart(new_cart(), with_category, 2)
      {:ok, cart} = Shop.add_to_cart(cart, without, 1)

      capture_log(fn ->
        assert [%Parcel{weight_g: 600}] = Shop.cart_parcels(cart)
      end)
    end

    test "works on a cart that carries its items" do
      {:ok, cart} = Shop.add_to_cart(new_cart(), product!(%{"weight_grams" => 120}), 3)
      loaded = Repo.preload(cart, :items)

      assert [%Parcel{weight_g: 360}] = Shop.cart_parcels(loaded)
    end
  end

  describe "module wiring" do
    test "integration_providers/0 adds the integration of shipping providers" do
      with_providers([StubProvider])

      keys = Enum.map(Shop.integration_providers(), & &1.key)

      assert "stub" in keys
      assert "shopify" in keys
    end

    test "Shopify stays first and exactly once" do
      with_providers([StubProvider, SecondShopify])

      definitions = Shop.integration_providers()
      keys = Enum.map(definitions, & &1.key)

      assert keys == Enum.uniq(keys)
      assert hd(keys) == "shopify"
      assert hd(definitions).name != "Impostor"
    end

    test "the built-in providers contribute nothing" do
      with_providers([])

      assert Enum.map(Shop.integration_providers(), & &1.key) == ["shopify"]
    end

    test "providers without a usable integration are skipped" do
      with_providers([NoIntegration, RaisingIntegration, StubProvider])

      log =
        capture_log(fn ->
          assert Enum.map(Shop.integration_providers(), & &1.key) == ["shopify", "stub"]
        end)

      assert log =~ "integration blew up"
    end

    test "Shopify off leaves only the shipping integrations" do
      with_providers([StubProvider])
      Settings.update_setting_with_module("shop_shopify_enabled", "false", "shop")

      assert Enum.map(Shop.integration_providers(), & &1.key) == ["stub"]
    end

    test "children/0 is the shipping cache, and starting it twice is harmless" do
      assert Shop.children() == [Cache]

      start_supervised!(Cache)
      pid = Process.whereis(Cache)

      supervisor =
        start_supervised!(%{
          id: :second_start,
          start: {Supervisor, :start_link, [Shop.children(), [strategy: :one_for_one]]}
        })

      # The second start was ignored: the original process still owns the name
      # and the supervisor has no child of its own.
      assert Process.whereis(Cache) == pid
      assert [{Cache, :undefined, :worker, _}] = Supervisor.which_children(supervisor)
    end
  end
end
