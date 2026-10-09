defmodule PhoenixKitEcommerce.Shipping.QuoteSnapshotTest do
  @moduledoc """
  `PhoenixKitEcommerce.shipping_quote_snapshot/2`: everything a page needs of
  the shipping of a cart, worked out once, and the same answers the single
  functions give.
  """

  # Changes the application env (provider registry).
  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Shipping.{Destination, Locality, PickupPoint, Service}
  alias PhoenixKitEcommerce.Test.Shipping.StubProvider

  @destination %Destination{
    locality: %Locality{id: "L1", name: "Kyiv"},
    pickup_point: %PickupPoint{id: "P1", name: "Branch 1"}
  }

  setup do
    previous = Application.get_env(:phoenix_kit_ecommerce, :shipping_providers)
    Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, [StubProvider])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, previous),
        else: Application.delete_env(:phoenix_kit_ecommerce, :shipping_providers)
    end)

    StubProvider.put(%{})
    :ok
  end

  defp method!(attrs \\ %{}) do
    {:ok, method} =
      Shop.create_shipping_method(
        Map.merge(
          %{
            "name" => "Carrier #{System.unique_integer([:positive])}",
            "price" => "7.00",
            "active" => true,
            "shipping_provider" => %{
              "provider" => "stub",
              "service" => "branch",
              "settings" => %{"sender_city" => %{"id" => "c1", "name" => "Springfield"}},
              "pricing" => %{"markup_percent" => "0", "markup_fixed" => "0", "round_to" => "1"}
            }
          },
          attrs
        )
      )

    method
  end

  defp cart!(method) do
    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Widget #{System.unique_integer([:positive])}"},
        "price" => Decimal.new("25.00"),
        "status" => "active",
        "currency" => "USD",
        "product_type" => "physical",
        "requires_shipping" => true,
        "weight_grams" => 500
      })

    {:ok, cart} = Shop.create_cart(session_id: "snap-#{System.unique_integer([:positive])}")
    {:ok, cart} = Shop.add_to_cart(cart, product, 1)
    {:ok, cart} = Shop.set_cart_shipping(cart, method, "US")
    cart
  end

  test "without a method there is nothing to wait for" do
    cart = cart!(method!())

    assert %{status: :not_needed, blocks?: false, presented: nil, service: nil} =
             Shop.shipping_quote_snapshot(cart, nil)
  end

  test "an ordinary method has a price and no service" do
    {:ok, method} =
      Shop.create_shipping_method(%{
        "name" => "Plain #{System.unique_integer([:positive])}",
        "price" => "5.00",
        "active" => true
      })

    cart = cart!(method)

    snapshot = Shop.shipping_quote_snapshot(cart)

    assert snapshot.status == :not_needed
    refute snapshot.blocks?
    assert snapshot.service == nil
    assert snapshot.presented.quote_status == :not_needed
    assert snapshot.presented == Shop.present_shipping_method(cart, method)
  end

  test "a calculated method without a place needs one, and the service says what it asks" do
    cart = cart!(method!())

    snapshot = Shop.shipping_quote_snapshot(cart)

    assert snapshot.status == :needs_destination
    assert snapshot.blocks?
    assert %Service{key: "branch", destination: :pickup_point} = snapshot.service
    assert snapshot.service_error == nil
    refute snapshot.transient?
    assert snapshot.entry == nil
  end

  test "a quote is current, with the entry and the presented estimate" do
    cart = cart!(method!())
    {:ok, cart} = Shop.set_cart_shipping_destination(cart, @destination)
    assert Shop.shipping_quote_snapshot(cart).status == :missing

    {:ok, cart} = Shop.quote_cart_shipping(cart)
    snapshot = Shop.shipping_quote_snapshot(cart)

    assert snapshot.status == :ok
    refute snapshot.blocks?
    assert %{status: :ok, quote: %{amount: _}} = snapshot.entry
    assert snapshot.presented.estimate.amount
    assert snapshot.status == Shop.shipping_quote_status(cart)
    assert snapshot.entry == Shop.cart_shipping_quote(cart)
    assert snapshot.blocks? == Shop.shipping_quote_blocks_checkout?(cart)
  end

  test "present_shipping_method/2 is the snapshot's presentation, for any method" do
    method = method!()
    other = method!()
    cart = cart!(method)
    {:ok, cart} = Shop.set_cart_shipping_destination(cart, @destination)
    {:ok, cart} = Shop.quote_cart_shipping(cart)

    assert Shop.present_shipping_method(cart, method) ==
             Shop.shipping_quote_snapshot(cart, method).presented

    # A calculated method that is not the selected one has no quote.
    snapshot = Shop.shipping_quote_snapshot(cart, other)
    assert snapshot.status == :missing
    assert snapshot.service == nil
    assert snapshot.presented == Shop.present_shipping_method(cart, other)
  end

  test "a service list that cannot be had may pass: it is transient" do
    cart = cart!(method!())
    StubProvider.put(%{modes: %{services: :crash}})

    snapshot = Shop.shipping_quote_snapshot(cart)

    assert snapshot.status == :unavailable
    assert snapshot.blocks?
    assert snapshot.service == nil
    assert {:provider_crashed, _message} = snapshot.service_error
    assert snapshot.transient?
  end

  test "a provider that is gone is not transient" do
    cart = cart!(method!())
    Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, [])

    snapshot = Shop.shipping_quote_snapshot(cart)

    assert snapshot.status == :unavailable
    assert snapshot.service_error == :unknown_provider
    refute snapshot.transient?
  end
end
