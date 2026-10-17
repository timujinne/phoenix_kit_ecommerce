defmodule PhoenixKitEcommerce.API.CartShippingCalculatedTest do
  @moduledoc """
  A carrier-priced shipping method (`ShippingMethod.calculated?/1`) is priced
  after the buyer has chosen a destination on the site; the cart API never
  reads an address. The API must not present the method's fallback figure as the
  price, and must say that the quote is still to come.
  """

  # async: false - the provider registry is application env.
  use PhoenixKitEcommerce.DataCase, async: false
  @moduletag :requires_core_api

  import PhoenixKitEcommerce.CartApiFixtures

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.API.CartHandlers
  alias PhoenixKitEcommerce.Test.Shipping.StubProvider

  setup do
    put_secret!()
    ensure_currencies!()

    previous = Application.get_env(:phoenix_kit_ecommerce, :shipping_providers)
    Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, [StubProvider])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, previous),
        else: Application.delete_env(:phoenix_kit_ecommerce, :shipping_providers)
    end)

    StubProvider.put(%{})

    {:ok, carrier} =
      Shop.create_shipping_method(%{
        "name" => "Carrier",
        "price" => "7.00",
        "active" => true,
        "shipping_provider" => %{
          "provider" => "stub",
          "service" => "branch",
          "settings" => %{"sender_city" => %{"id" => "c1", "name" => "Springfield"}},
          "pricing" => %{"markup_percent" => "0", "markup_fixed" => "0", "round_to" => "1"}
        }
      })

    {:ok, plain} =
      Shop.create_shipping_method(%{"name" => "Plain", "price" => "4.00", "active" => true})

    token = new_token!()
    ctx = ctx_for(token)

    {:ok, _} =
      CartHandlers.set_cart_items(
        %{
          "cart_token" => token,
          "items" => [%{"product_id" => physical_product!().uuid, "quantity" => 1}]
        },
        ctx
      )

    %{carrier: carrier, plain: plain, token: token, ctx: ctx}
  end

  test "the options mark the carrier method and leave its price out", t do
    assert {:ok, %{methods: methods}} =
             CartHandlers.get_shipping_options(
               %{"cart_token" => t.token, "country" => "US"},
               t.ctx
             )

    by_id = Map.new(methods, &{&1.id, &1})

    assert by_id[t.carrier.uuid].calculated == true
    refute Map.has_key?(by_id[t.carrier.uuid], :price)
    assert by_id[t.plain.uuid].calculated == false
    assert by_id[t.plain.uuid].price == %{amount: "4.00", currency: "USD"}
  end

  test "a chosen carrier method says its quote is still to come; a plain one is priced", t do
    input = fn method ->
      %{"cart_token" => t.token, "country" => "US", "method_id" => method.uuid}
    end

    assert {:ok, %{shipping: %{method: carrier}}} =
             CartHandlers.set_shipping(input.(t.carrier), t.ctx)

    assert carrier.calculated == true
    assert carrier.quote_status == "needs_destination"
    refute Map.has_key?(carrier, :price)

    assert {:ok, %{shipping: %{method: plain}}} =
             CartHandlers.set_shipping(input.(t.plain), t.ctx)

    assert plain.calculated == false
    assert plain.quote_status == "not_needed"
    assert plain.price == %{amount: "4.00", currency: "USD"}
  end
end
