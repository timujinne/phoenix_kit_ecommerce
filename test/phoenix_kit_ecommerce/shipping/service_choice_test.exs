defmodule PhoenixKitEcommerce.Shipping.ServiceChoiceTest do
  @moduledoc """
  The shopper chooses the service among those a calculated method allows: what
  is stored on the cart, what it does to the destination, the request, the
  quote, the snapshot and the order.
  """

  # Changes the application env (provider registry).
  use PhoenixKitEcommerce.DataCase, async: false

  import PhoenixKitEcommerce.CheckoutFixtures, only: [complete_billing: 1]

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.{Cart, Events, ShippingMethod}

  alias PhoenixKitEcommerce.Shipping.{
    Address,
    CartQuote,
    Destination,
    Locality,
    PickupPoint,
    Quote,
    Service
  }

  alias PhoenixKitEcommerce.Test.Shipping.StubProvider

  @city %{"id" => "c1", "name" => "Springfield"}
  @locality %Locality{id: "L1", name: "Kyiv"}

  @services [
    %Service{key: "branch", label: "Branch", destination: :pickup_point, lookup: :search},
    %Service{key: "locker", label: "Locker", destination: :pickup_point, lookup: :search},
    %Service{
      key: "post_office",
      label: "Post office",
      destination: :pickup_point,
      lookup: :manual
    },
    %Service{
      key: "post_express",
      label: "Post office express",
      destination: :pickup_point,
      lookup: :manual
    },
    %Service{key: "courier", label: "Courier", destination: :address, lookup: :search},
    %Service{key: "door", label: "To the door", destination: :address, lookup: :manual}
  ]

  setup do
    previous = Application.get_env(:phoenix_kit_ecommerce, :shipping_providers)
    Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, [StubProvider])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, previous),
        else: Application.delete_env(:phoenix_kit_ecommerce, :shipping_providers)
    end)

    StubProvider.put(%{services: @services})
    :ok
  end

  defp flush_stub_calls do
    receive do
      {:stub_called, _operation, _args} -> flush_stub_calls()
    after
      0 -> :ok
    end
  end

  defp stub_service_calls(count \\ 0) do
    receive do
      {:stub_called, :services, _args} -> stub_service_calls(count + 1)
      {:stub_called, _operation, _args} -> stub_service_calls(count)
    after
      0 -> count
    end
  end

  defp product! do
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

    product
  end

  defp method!(block \\ %{}) do
    provider =
      Map.merge(
        %{
          "provider" => "stub",
          "services" => ["branch", "locker", "courier"],
          "settings" => %{"sender_city" => @city},
          "pricing" => %{"markup_percent" => "0", "markup_fixed" => "0", "round_to" => "1"}
        },
        block
      )

    {:ok, method} =
      Shop.create_shipping_method(%{
        "name" => "Carrier #{System.unique_integer([:positive])}",
        "price" => "7.00",
        "active" => true,
        "shipping_provider" => provider
      })

    method
  end

  defp cart_with!(method) do
    {:ok, cart} = Shop.create_cart(session_id: "sc-#{System.unique_integer([:positive])}")
    {:ok, cart} = Shop.add_to_cart(cart, product!(), 2)
    {:ok, cart} = Shop.set_cart_shipping(cart, method, "US")
    cart
  end

  defp branch(id \\ "P1"),
    do: %Destination{
      locality: @locality,
      pickup_point: %PickupPoint{id: id, name: "Branch #{id}"}
    }

  defp address,
    do: %Destination{
      locality: @locality,
      address: %Address{street: "Main", house: "1", postcode: "01001"}
    }

  defp reload(cart), do: Shop.get_cart!(cart.uuid)

  # A destination that is complete for any service, so the request can be built.
  defp request_service!(cart) do
    {:ok, cart} =
      Shop.set_cart_shipping_destination(cart, %{branch() | address: address().address})

    {:ok, request} = Shop.build_cart_rate_request(cart)
    request.service
  end

  describe "CartQuote service helpers" do
    test "the choice is read, stored, removed and counted" do
      assert CartQuote.service(%{}) == nil
      assert CartQuote.service(nil) == nil
      assert CartQuote.service(%{"shipping_service" => " locker "}) == "locker"
      assert CartQuote.service(%{"shipping_service" => ""}) == nil

      metadata = CartQuote.put_service(%{"note" => "x"}, "locker")
      assert metadata == %{"note" => "x", "shipping_service" => "locker"}
      assert CartQuote.any?(metadata)
      assert CartQuote.drop_all(metadata) == %{"note" => "x"}
      assert CartQuote.put_service(metadata, nil) == %{"note" => "x"}
    end

    test "carry_destination keeps what means the same to both services" do
      by_key = Map.new(@services, &{&1.key, &1})
      carry = fn d, from, to -> CartQuote.carry_destination(d, by_key[from], by_key[to]) end

      assert carry.(address(), "courier", "door") == address()
      assert carry.(branch(), "post_office", "post_express") == branch()

      assert carry.(branch(), "branch", "locker") == %Destination{locality: @locality}
      assert carry.(branch(), "branch", "courier") == %Destination{locality: @locality}
      assert carry.(address(), "courier", "branch") == %Destination{locality: @locality}
      assert carry.(%Destination{pickup_point: %PickupPoint{id: "P"}}, "branch", "locker") == nil
      assert carry.(nil, "branch", "locker") == nil
      assert CartQuote.carry_destination(branch(), nil, by_key["locker"]).pickup_point == nil
    end
  end

  describe "the effective service of a cart" do
    test "is the default of the method until the shopper chooses" do
      cart = cart_with!(method!())

      assert Shop.cart_shipping_service_key(cart) == "branch"
      assert request_service!(cart) == "branch"
    end

    test "is the choice when the method allows it" do
      cart = cart_with!(method!())

      {:ok, cart} = Shop.set_cart_shipping_service(cart, "locker")

      assert CartQuote.service(cart.metadata) == "locker"
      assert Shop.cart_shipping_service_key(cart) == "locker"
      assert request_service!(cart) == "locker"
    end

    test "falls back to the default when the choice is no longer allowed" do
      method = method!()
      cart = cart_with!(method)
      {:ok, cart} = Shop.set_cart_shipping_service(cart, "courier")

      set_block!(method, %{"services" => ["branch", "locker"]})
      cart = reload(cart)

      assert CartQuote.service(cart.metadata) == "courier"
      assert Shop.cart_shipping_service_key(cart) == "branch"
      assert Shop.shipping_quote_snapshot(cart).service.key == "branch"
    end

    test "a place picked for a service the method stopped allowing is asked for again" do
      method = method!()
      cart = cart_with!(method)
      {:ok, cart} = Shop.set_cart_shipping_service(cart, "locker")
      {:ok, cart} = Shop.set_cart_shipping_destination(cart, branch())
      {:ok, cart} = Shop.quote_cart_shipping(cart)
      assert Shop.shipping_quote_status(cart) == :ok

      set_block!(method, %{"services" => ["branch", "courier"]})
      cart = reload(cart)

      assert Shop.cart_shipping_service_key(cart) == "branch"
      assert Shop.shipping_quote_status(cart) == :needs_destination
      assert {:error, :needs_destination} = Shop.build_cart_rate_request(cart)

      # Choosing a service on offer replaces the stale choice and its place.
      {:ok, cart} = Shop.set_cart_shipping_service(cart, "branch")

      assert CartQuote.service(cart.metadata) == "branch"
      assert Shop.cart_shipping_destination(cart) == %Destination{locality: @locality}
    end

    test "a destination picked for the default remembers its service when the admin removes it" do
      method = method!()
      cart = cart_with!(method)
      {:ok, cart} = Shop.set_cart_shipping_destination(cart, branch("OLD"))
      {:ok, cart} = Shop.quote_cart_shipping(cart)

      set_block!(method, %{"services" => ["locker", "courier"]})
      cart = reload(cart)

      assert Shop.cart_shipping_service_key(cart) == "locker"
      assert Shop.shipping_quote_status(cart) == :needs_destination
      assert {:error, :needs_destination} = Shop.build_cart_rate_request(cart)

      assert {:error, :shipping_quote_required} =
               Shop.convert_cart_to_order(cart, billing_data: complete_billing("US"))
    end

    test "a destination keeps its service when the admin changes only the default" do
      method = method!()
      cart = cart_with!(method)
      {:ok, cart} = Shop.set_cart_shipping_destination(cart, branch())

      set_block!(method, %{"service" => "locker"})

      assert Shop.cart_shipping_service_key(reload(cart)) == "branch"
    end

    test "a legacy destination without a recorded service needs confirmation once" do
      cart = cart_with!(method!())
      {:ok, cart} = Shop.set_cart_shipping_destination(cart, branch("OLD"))
      {:ok, cart} = Shop.quote_cart_shipping(cart)

      cart =
        cart
        |> Ecto.Changeset.change(metadata: CartQuote.put_service(cart.metadata, nil))
        |> Repo.update!()

      assert Shop.shipping_quote_status(cart) == :needs_destination
      assert {:error, :needs_destination} = Shop.build_cart_rate_request(cart)

      {:ok, cart} = Shop.set_cart_shipping_destination(cart, branch("CONFIRMED"))
      assert Shop.cart_shipping_service_key(cart) == "branch"
      assert {:ok, cart} = Shop.quote_cart_shipping(cart)
      assert Shop.shipping_quote_status(cart) == :ok
    end

    test "a new place picked after the service went stale prices the service in effect" do
      for remaining <- [["branch", "courier"], ["branch"]] do
        method = method!()
        cart = cart_with!(method)
        {:ok, cart} = Shop.set_cart_shipping_service(cart, "locker")
        {:ok, cart} = Shop.set_cart_shipping_destination(cart, branch("OLD"))
        set_block!(method, %{"services" => remaining})

        {:ok, cart} = Shop.set_cart_shipping_destination(reload(cart), branch("NEW"))

        assert CartQuote.service(cart.metadata) == "branch"
        assert Shop.shipping_quote_status(cart) == :missing
        assert {:ok, cart} = Shop.quote_cart_shipping(cart)
        assert Shop.shipping_quote_status(cart) == :ok
        assert Shop.cart_shipping_service_key(cart) == "branch"
      end
    end

    test "an order made from a stale choice does not record the old place" do
      method = method!(%{"services" => ["branch", "locker"]})
      cart = cart_with!(method)
      {:ok, cart} = Shop.set_cart_shipping_service(cart, "locker")
      {:ok, cart} = Shop.set_cart_shipping_destination(cart, branch("OLD"))
      set_block!(method, %{"services" => ["branch"]})
      cart = reload(cart)

      assert {:error, :shipping_quote_required} =
               Shop.convert_cart_to_order(cart, billing_data: complete_billing("US"))

      {:ok, cart} = Shop.set_cart_shipping_destination(cart, branch("NEW"))
      {:ok, cart} = Shop.quote_cart_shipping(cart)
      {:ok, order} = Shop.convert_cart_to_order(cart, billing_data: complete_billing("US"))

      assert order.metadata["shipping_provider"]["service"] == "branch"
      assert order.metadata["shipping_destination"]["pickup_point"]["id"] == "NEW"
    end

    test "the order of a stale choice whose service in effect needs no place has only the locality" do
      services = [%Service{key: "nodest", label: "No place", destination: :none} | @services]
      StubProvider.put(%{services: services})

      method = method!(%{"services" => ["nodest", "locker", "branch"]})
      cart = cart_with!(method)
      {:ok, cart} = Shop.set_cart_shipping_service(cart, "locker")
      {:ok, cart} = Shop.set_cart_shipping_destination(cart, branch("OLD"))
      set_block!(method, %{"services" => ["nodest", "branch"]})

      {:ok, cart} = Shop.quote_cart_shipping(reload(cart))
      {:ok, order} = Shop.convert_cart_to_order(cart, billing_data: complete_billing("US"))

      assert order.metadata["shipping_provider"]["service"] == "nodest"
      assert order.metadata["shipping_destination"]["locality"]["name"] == "Kyiv"
      assert order.metadata["shipping_destination"]["pickup_point"] == nil
    end

    test "a single-service method of the older shape works as it did" do
      method = method!()
      {:ok, method} = Shop.update_shipping_method(method, %{metadata: legacy_metadata(method)})
      cart = cart_with!(method)

      assert ShippingMethod.shipping_config(method).services == ["locker"]
      assert Shop.cart_shipping_service_key(cart) == "locker"
      assert request_service!(cart) == "locker"
      assert Shop.shipping_quote_snapshot(cart).choices == []
      assert {:error, :unknown_service} = Shop.set_cart_shipping_service(cart, "branch")
    end
  end

  describe "set_cart_shipping_service/2" do
    test "stores the choice, drops the quote and keeps the locality" do
      cart = cart_with!(method!())
      {:ok, cart} = Shop.set_cart_shipping_destination(cart, branch())
      {:ok, cart} = Shop.quote_cart_shipping(cart)
      assert Shop.shipping_quote_status(cart) == :ok

      {:ok, cart} = Shop.set_cart_shipping_service(cart, "locker")

      refute Map.has_key?(cart.metadata, "shipping_quote")
      assert Shop.cart_shipping_destination(cart) == %Destination{locality: @locality}
      assert Shop.shipping_quote_status(cart) == :needs_destination
      assert reload(cart).metadata["shipping_service"] == "locker"
    end

    test "an address survives a move between address services" do
      cart = cart_with!(method!(%{"services" => ["courier", "door"]}))
      {:ok, cart} = Shop.set_cart_shipping_destination(cart, address())

      {:ok, cart} = Shop.set_cart_shipping_service(cart, "door")

      assert Shop.cart_shipping_destination(cart) == address()
      assert Shop.shipping_quote_status(cart) == :missing
    end

    test "a typed point code survives a move between manual pickup services" do
      cart = cart_with!(method!(%{"services" => ["post_office", "post_express"]}))
      {:ok, cart} = Shop.set_cart_shipping_destination(cart, branch("01001"))

      {:ok, cart} = Shop.set_cart_shipping_service(cart, "post_express")

      assert Shop.cart_shipping_destination(cart) == branch("01001")
    end

    test "choosing the service already in effect leaves the quote alone" do
      cart = cart_with!(method!())
      {:ok, cart} = Shop.set_cart_shipping_destination(cart, branch())
      {:ok, cart} = Shop.quote_cart_shipping(cart)

      {:ok, cart} = Shop.set_cart_shipping_service(cart, "branch")

      assert Shop.shipping_quote_status(cart) == :ok
    end

    test "choosing the default stores it explicitly and keeps the quote" do
      cart = cart_with!(method!())
      {:ok, cart} = Shop.set_cart_shipping_destination(cart, branch())
      {:ok, cart} = Shop.quote_cart_shipping(cart)

      {:ok, cart} = Shop.set_cart_shipping_service(cart, "branch")

      assert reload(cart).metadata["shipping_service"] == "branch"
      assert Shop.shipping_quote_status(cart) == :ok
    end

    test "tells nobody when the service is already the one in effect" do
      cart = cart_with!(method!())
      Events.subscribe_to_session_cart(cart.session_id)
      {:ok, cart} = Shop.set_cart_shipping_service(cart, "locker")
      assert_receive {:shipping_selected, _}

      assert {:ok, same} = Shop.set_cart_shipping_service(cart, "locker")
      refute_receive {:shipping_selected, _}, 100
      assert same.metadata == cart.metadata
      assert Decimal.equal?(same.shipping_amount, cart.shipping_amount)
    end

    test "broadcasts the change" do
      cart = cart_with!(method!())
      Events.subscribe_to_session_cart(cart.session_id)

      {:ok, _cart} = Shop.set_cart_shipping_service(cart, "locker")

      assert_receive {:shipping_selected, %Cart{uuid: uuid}}
      assert uuid == cart.uuid
    end

    test "refuses a service the method does not allow or the provider does not list" do
      cart = cart_with!(method!())

      assert {:error, :unknown_service} = Shop.set_cart_shipping_service(cart, "door")
      assert {:error, :unknown_service} = Shop.set_cart_shipping_service(cart, "teleport")
      assert reload(cart).metadata["shipping_service"] == nil
    end

    test "refuses a cart without a calculated method" do
      {:ok, cart} = Shop.create_cart(session_id: "sc-#{System.unique_integer([:positive])}")
      {:ok, cart} = Shop.add_to_cart(cart, product!(), 1)

      assert {:error, :no_method} = Shop.set_cart_shipping_service(cart, "branch")

      {:ok, fixed} =
        Shop.create_shipping_method(%{"name" => "Fixed", "price" => "5.00", "active" => true})

      {:ok, cart} = Shop.set_cart_shipping(cart, fixed, "US")

      assert {:error, :not_calculated} = Shop.set_cart_shipping_service(cart, "branch")
    end

    test "refuses a cart that is not active" do
      cart = cart_with!(method!())
      {:ok, cart} = Shop.set_cart_shipping_destination(cart, branch())
      {:ok, cart} = Shop.quote_cart_shipping(cart)
      {:ok, _order} = Shop.convert_cart_to_order(cart, billing_data: complete_billing("US"))

      assert {:error, :cart_not_active} = Shop.set_cart_shipping_service(cart, "locker")
    end
  end

  describe "the price" do
    test "is asked for the service the shopper chose" do
      test_pid = self()

      StubProvider.put(%{
        services: @services,
        quote: fn request, ctx ->
          send(test_pid, {:quoted, request.service, ctx.service})
          amount = if request.service == "courier", do: "90", else: "40"
          {:ok, %Quote{amount: Decimal.new(amount), currency: ctx.currency}}
        end
      })

      cart = cart_with!(method!())
      {:ok, cart} = Shop.set_cart_shipping_destination(cart, branch())
      {:ok, cart} = Shop.quote_cart_shipping(cart)
      assert_received {:quoted, "branch", "branch"}
      assert Decimal.equal?(cart.shipping_amount, Decimal.new("40"))

      {:ok, cart} = Shop.set_cart_shipping_service(cart, "courier")
      {:ok, cart} = Shop.set_cart_shipping_destination(cart, address())
      {:ok, cart} = Shop.quote_cart_shipping(cart)

      assert_received {:quoted, "courier", "courier"}
      assert Decimal.equal?(cart.shipping_amount, Decimal.new("90"))
      assert Shop.shipping_quote_status(cart) == :ok
    end

    test "a quote for one service is never charged for another" do
      cart = cart_with!(method!(%{"services" => ["courier", "door"]}))
      {:ok, cart} = Shop.set_cart_shipping_destination(cart, address())
      {:ok, cart} = Shop.quote_cart_shipping(cart)
      assert Shop.shipping_quote_status(cart) == :ok

      # The address is kept, the request is not the same any more.
      {:ok, cart} = Shop.set_cart_shipping_service(cart, "door")

      assert Shop.cart_shipping_destination(cart) == address()
      assert Shop.shipping_quote_status(cart) == :missing
    end
  end

  describe "the snapshot" do
    test "lists the allowed services the provider offers, in its order" do
      cart = cart_with!(method!(%{"services" => ["courier", "branch"]}))

      snapshot = Shop.shipping_quote_snapshot(cart)

      assert Enum.map(snapshot.choices, & &1.key) == ["branch", "courier"]
      assert snapshot.service.key == "courier"
    end

    test "carries the service the shopper chose" do
      cart = cart_with!(method!())
      {:ok, cart} = Shop.set_cart_shipping_service(cart, "courier")

      snapshot = Shop.shipping_quote_snapshot(cart)

      assert snapshot.service.key == "courier"
      assert snapshot.service.destination == :address
      assert Enum.map(snapshot.choices, & &1.key) == ["branch", "locker", "courier"]
    end

    test "a service the provider does not list is not offered" do
      StubProvider.put(%{services: Enum.take(@services, 2)})
      cart = cart_with!(method!())

      assert Enum.map(Shop.shipping_quote_snapshot(cart).choices, & &1.key) == [
               "branch",
               "locker"
             ]
    end

    test "a method that is not calculated or not selected has no choices" do
      cart = cart_with!(method!())
      other = method!()

      assert Shop.shipping_quote_snapshot(cart, other).choices == []
      assert Shop.shipping_quote_snapshot(cart, nil).choices == []
    end

    test "a service that is gone still lists the others, so the shopper can step away" do
      cart = cart_with!(method!())
      {:ok, cart} = Shop.set_cart_shipping_service(cart, "courier")
      StubProvider.put(%{services: Enum.take(@services, 2)})

      snapshot = Shop.shipping_quote_snapshot(cart)

      assert snapshot.service == nil
      assert snapshot.service_error == :unknown_service
      assert Enum.map(snapshot.choices, & &1.key) == ["branch", "locker"]
    end

    test "a service list that cannot be had is asked of the carrier once, not again for the choices" do
      cart = cart_with!(method!())
      {:ok, cart} = Shop.set_cart_shipping_service(cart, "courier")
      StubProvider.put(%{services: @services, modes: %{services: :crash}})
      flush_stub_calls()

      snapshot = Shop.shipping_quote_snapshot(cart)

      assert {:provider_crashed, _message} = snapshot.service_error
      assert snapshot.choices == []
      assert stub_service_calls() == 1
    end

    test "a default the provider does not offer leaves the one allowed service to choose" do
      StubProvider.put(%{services: Enum.filter(@services, &(&1.key == "courier"))})
      cart = cart_with!(method!(%{"services" => ["branch", "courier"]}))

      snapshot = Shop.shipping_quote_snapshot(cart)

      assert snapshot.service == nil
      assert snapshot.service_error == :unknown_service
      assert Enum.map(snapshot.choices, & &1.key) == ["courier"]

      assert {:ok, cart} = Shop.set_cart_shipping_service(cart, "courier")

      snapshot = Shop.shipping_quote_snapshot(cart)

      assert snapshot.service.key == "courier"
      assert snapshot.service_error == nil
      assert snapshot.status != :unavailable
      assert snapshot.choices == []
      assert Shop.cart_shipping_service_key(cart) == "courier"
    end
  end

  describe "changing the method" do
    test "different defaults clear a destination saved before service choices were recorded" do
      cart = cart_with!(method!())
      {:ok, cart} = Shop.set_cart_shipping_destination(cart, branch())

      cart =
        cart
        |> Ecto.Changeset.change(metadata: CartQuote.put_service(cart.metadata, nil))
        |> Repo.update!()

      other = set_block!(method!(), %{"service" => "locker"})

      {:ok, cart} = Shop.set_cart_shipping(cart, other, "US")

      assert Shop.cart_shipping_destination(cart) == nil
      assert Shop.shipping_quote_status(cart) == :needs_destination
    end

    test "the same provider and services keeps the choice and the destination" do
      method = method!()
      cart = cart_with!(method)
      {:ok, cart} = Shop.set_cart_shipping_service(cart, "courier")
      {:ok, cart} = Shop.set_cart_shipping_destination(cart, address())

      {:ok, cart} = Shop.set_cart_shipping(cart, method!(), "US")

      assert CartQuote.service(cart.metadata) == "courier"
      assert Shop.cart_shipping_destination(cart) == address()
    end

    test "other services clear the choice and the destination" do
      cart = cart_with!(method!())
      {:ok, cart} = Shop.set_cart_shipping_service(cart, "courier")
      {:ok, cart} = Shop.set_cart_shipping_destination(cart, address())

      {:ok, cart} = Shop.set_cart_shipping(cart, method!(%{"services" => ["courier"]}), "US")

      assert CartQuote.service(cart.metadata) == nil
      assert Shop.cart_shipping_destination(cart) == nil
    end

    test "the same provider and default service but other allowed services clear them" do
      cart = cart_with!(method!(%{"services" => ["branch", "locker"]}))
      {:ok, cart} = Shop.set_cart_shipping_service(cart, "locker")
      {:ok, cart} = Shop.set_cart_shipping_destination(cart, branch())

      {:ok, cart} =
        Shop.set_cart_shipping(
          cart,
          method!(%{"services" => ["branch", "locker", "courier"]}),
          "US"
        )

      assert CartQuote.service(cart.metadata) == nil
      assert Shop.cart_shipping_destination(cart) == nil
    end

    test "clearing the shipping clears the choice" do
      cart = cart_with!(method!())
      {:ok, cart} = Shop.set_cart_shipping_service(cart, "courier")

      {:ok, _cart} = Shop.clear_cart_shipping(cart)

      assert reload(cart).metadata["shipping_service"] == nil
    end
  end

  describe "the order" do
    test "records the service the shopper chose" do
      cart = cart_with!(method!())
      {:ok, cart} = Shop.set_cart_shipping_service(cart, "courier")
      {:ok, cart} = Shop.set_cart_shipping_destination(cart, address())
      {:ok, cart} = Shop.quote_cart_shipping(cart)

      assert {:ok, order} = Shop.convert_cart_to_order(cart, billing_data: complete_billing("US"))

      assert order.metadata["shipping_provider"] == %{
               "provider" => "stub",
               "service" => "courier"
             }
    end

    test "records the default service when the shopper chose none" do
      cart = cart_with!(method!())
      {:ok, cart} = Shop.set_cart_shipping_destination(cart, branch())
      {:ok, cart} = Shop.quote_cart_shipping(cart)

      assert {:ok, order} = Shop.convert_cart_to_order(cart, billing_data: complete_billing("US"))

      assert order.metadata["shipping_provider"] == %{"provider" => "stub", "service" => "branch"}
    end
  end

  defp set_block!(method, changes) do
    block = Map.merge(method.metadata["shipping_provider"], changes)
    metadata = Map.put(method.metadata, "shipping_provider", block)
    {:ok, method} = Shop.update_shipping_method(method, %{metadata: metadata})
    method
  end

  # The block as methods were stored before the shopper could choose.
  defp legacy_metadata(method) do
    block = %{
      "provider" => "stub",
      "service" => "locker",
      "settings" => %{"sender_city" => @city}
    }

    Map.put(method.metadata, "shipping_provider", block)
  end
end
