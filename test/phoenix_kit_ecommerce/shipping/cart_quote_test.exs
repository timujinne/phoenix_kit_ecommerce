defmodule PhoenixKitEcommerce.Shipping.CartQuoteTest do
  @moduledoc """
  Calculated shipping on the cart: the destination, the quote, the status,
  the recalculation and what the order keeps.
  """

  # Changes the application env (provider registry) and the currency table.
  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Currency
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.{Cart, CartItem, Events}

  alias PhoenixKitEcommerce.Shipping.{
    Address,
    CartQuote,
    Destination,
    Locality,
    PickupPoint,
    Quote,
    RateRequest,
    Service
  }

  alias PhoenixKitEcommerce.Test.Shipping.StubProvider

  @city %{"id" => "c1", "name" => "Poltava"}
  @locality %Locality{id: "L1", name: "Kyiv"}

  defmodule StrictProvider do
    @moduledoc false
    @behaviour PhoenixKitEcommerce.Shipping.Provider

    alias PhoenixKitEcommerce.Shipping.{Quote, Service}

    @impl true
    def key, do: "strict"
    @impl true
    def label, do: "Strict"
    @impl true
    def services(_ctx), do: [%Service{key: "branch", label: "Branch", destination: :pickup_point}]
    @impl true
    def settings_fields, do: []
    @impl true
    def quote(_request, ctx), do: {:ok, %Quote{amount: Decimal.new(20), currency: ctx.currency}}

    @impl true
    def validate_destination(destination, _service, _ctx) do
      case destination.pickup_point do
        %{id: "bad"} -> {:error, "no such branch"}
        _ -> :ok
      end
    end
  end

  setup do
    previous = Application.get_env(:phoenix_kit_ecommerce, :shipping_providers)

    Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, [
      StubProvider,
      StrictProvider
    ])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, previous),
        else: Application.delete_env(:phoenix_kit_ecommerce, :shipping_providers)
    end)

    StubProvider.put(%{})
    :ok
  end

  defp product!(attrs \\ %{}) do
    {:ok, product} =
      Shop.create_product(
        Map.merge(
          %{
            "title" => %{"en" => "Widget #{System.unique_integer([:positive])}"},
            "price" => Decimal.new("25.00"),
            "status" => "active",
            "currency" => "USD",
            "product_type" => "physical",
            "requires_shipping" => true,
            "weight_grams" => 500
          },
          attrs
        )
      )

    product
  end

  defp cart_with!(product, quantity) do
    {:ok, cart} = Shop.create_cart(session_id: "cq-#{System.unique_integer([:positive])}")
    {:ok, cart} = Shop.add_to_cart(cart, product, quantity)
    cart
  end

  defp method!(opts \\ []) do
    provider =
      %{
        "provider" => Keyword.get(opts, :provider, "stub"),
        "service" => Keyword.get(opts, :service, "branch"),
        "settings" => %{"sender_city" => @city},
        "pricing" => %{
          "markup_percent" => Keyword.get(opts, :markup, "10"),
          "markup_fixed" => "0",
          "round_to" => "1"
        }
      }

    {:ok, method} =
      Shop.create_shipping_method(%{
        "name" => "Carrier #{System.unique_integer([:positive])}",
        "price" => Keyword.get(opts, :price, "7.00"),
        "pay_on_delivery" => Keyword.get(opts, :pay_on_delivery, false),
        "active" => true,
        "shipping_provider" => provider
      })

    method
  end

  defp legacy_method!(price \\ "5.00") do
    {:ok, method} =
      Shop.create_shipping_method(%{
        "name" => "Fixed #{System.unique_integer([:positive])}",
        "price" => price,
        "active" => true
      })

    method
  end

  defp branch(id \\ "P1"),
    do: %Destination{
      locality: @locality,
      pickup_point: %PickupPoint{id: id, name: "Branch #{id}"}
    }

  defp reload(cart), do: Shop.get_cart!(cart.uuid)

  defp ready_cart!(opts \\ []) do
    cart = cart_with!(product!(), Keyword.get(opts, :quantity, 2))
    method = Keyword.get_lazy(opts, :method, &method!/0)
    {:ok, cart} = Shop.set_cart_shipping(cart, method, "US")
    {:ok, cart} = Shop.set_cart_shipping_destination(cart, branch())
    {cart, method}
  end

  defp quote_with(amount, extra \\ []) do
    fn _request, ctx ->
      {:ok, struct(%Quote{amount: Decimal.new(amount), currency: ctx.currency}, extra)}
    end
  end

  defp stub_quote(quote) do
    StubProvider.put(%{quote: quote})
    :ok
  end

  defp ensure_payment_option(code, type) do
    attrs = %{"active" => true}

    case Billing.get_payment_option_by_code(code) do
      nil ->
        {:ok, option} =
          Billing.create_payment_option(
            Map.merge(attrs, %{"name" => code, "code" => code, "type" => type})
          )

        option

      option ->
        {:ok, option} = Billing.update_payment_option(option, attrs)
        option
    end
  end

  defp amount?(decimal, expected), do: Decimal.equal?(decimal, Decimal.new(expected))

  describe "set_cart_shipping_destination/2 and cart_shipping_destination/1" do
    test "stores the destination, reads it back and recalculates" do
      {cart, _method} = ready_cart!()

      assert %Destination{locality: %Locality{id: "L1"}, pickup_point: %PickupPoint{id: "P1"}} =
               Shop.cart_shipping_destination(cart)

      assert is_map(cart.metadata["shipping_destination"])
      assert Shop.cart_shipping_destination(reload(cart)) == Shop.cart_shipping_destination(cart)
    end

    test "takes the map form, and nil removes it" do
      {cart, _method} = ready_cart!()

      map = Destination.to_map(branch("P9"))
      assert {:ok, cart} = Shop.set_cart_shipping_destination(cart, map)
      assert Shop.cart_shipping_destination(cart).pickup_point.id == "P9"

      assert {:ok, cart} = Shop.set_cart_shipping_destination(cart, nil)
      assert Shop.cart_shipping_destination(cart) == nil
      refute Map.has_key?(cart.metadata, "shipping_destination")

      assert {:ok, cart} = Shop.set_cart_shipping_destination(cart, %Destination{})
      assert Shop.cart_shipping_destination(cart) == nil
    end

    test "drops the stored quote" do
      {cart, _method} = ready_cart!()
      {:ok, cart} = Shop.quote_cart_shipping(cart)
      assert Map.has_key?(cart.metadata, "shipping_quote")

      assert {:ok, cart} = Shop.set_cart_shipping_destination(cart, branch("P2"))
      refute Map.has_key?(cart.metadata, "shipping_quote")
      assert Shop.shipping_quote_status(cart) == :missing
    end

    test "refuses a cart that is not active" do
      {cart, _method} = ready_cart!()
      Repo.update_all(from(c in Cart, where: c.uuid == ^cart.uuid), set: [status: "abandoned"])

      assert {:error, :cart_not_active} = Shop.set_cart_shipping_destination(cart, branch("P3"))
    end

    test "tells the cart's subscribers" do
      {cart, _method} = ready_cart!()
      Events.subscribe_to_session_cart(cart.session_id)

      assert {:ok, _cart} = Shop.set_cart_shipping_destination(cart, branch("P4"))
      assert_receive {:shipping_selected, %Cart{uuid: uuid}}
      assert uuid == cart.uuid
    end
  end

  describe "build_cart_rate_request/1" do
    test "no method" do
      cart = cart_with!(product!(), 1)
      assert {:error, :no_method} = Shop.build_cart_rate_request(cart)
    end

    test "a method with a fixed price is not calculated" do
      cart = cart_with!(product!(), 1)
      {:ok, cart} = Shop.set_cart_shipping(cart, legacy_method!(), "US")

      assert {:error, :not_calculated} = Shop.build_cart_rate_request(cart)
    end

    test "nothing to ship" do
      cart = cart_with!(product!(%{"product_type" => "digital", "requires_shipping" => false}), 1)
      {:ok, cart} = Shop.set_cart_shipping(cart, method!(), "US")

      assert {:error, :not_needed} = Shop.build_cart_rate_request(cart)
    end

    test "a pickup service needs a pickup point, an address service an address" do
      cart = cart_with!(product!(), 1)
      {:ok, cart} = Shop.set_cart_shipping(cart, method!(), "US")
      assert {:error, :needs_destination} = Shop.build_cart_rate_request(cart)

      {:ok, cart} = Shop.set_cart_shipping_destination(cart, %Destination{locality: @locality})
      assert {:error, :needs_destination} = Shop.build_cart_rate_request(cart)

      {:ok, cart} = Shop.set_cart_shipping(cart, method!(service: "courier"), "US")
      {:ok, cart} = Shop.set_cart_shipping_destination(cart, branch())
      assert {:error, :needs_destination} = Shop.build_cart_rate_request(cart)

      address = %Destination{locality: @locality, address: %Address{line: "1 Main st"}}
      {:ok, cart} = Shop.set_cart_shipping_destination(cart, address)
      assert {:ok, %RateRequest{service: "courier"}} = Shop.build_cart_rate_request(cart)
    end

    test "the provider can refuse the destination" do
      cart = cart_with!(product!(), 1)
      {:ok, cart} = Shop.set_cart_shipping(cart, method!(provider: "strict"), "US")

      {:ok, cart} = Shop.set_cart_shipping_destination(cart, branch("bad"))
      assert {:error, :needs_destination} = Shop.build_cart_rate_request(cart)
      assert Shop.shipping_quote_status(cart) == :needs_destination

      {:ok, cart} = Shop.set_cart_shipping_destination(cart, branch("good"))
      assert {:ok, _request} = Shop.build_cart_rate_request(cart)
    end

    test "a service that needs no destination needs none" do
      StubProvider.put(%{services: [%Service{key: "plain", label: "Plain", destination: :none}]})
      cart = cart_with!(product!(), 1)
      {:ok, cart} = Shop.set_cart_shipping(cart, method!(service: "plain"), "US")

      assert {:ok, %RateRequest{service: "plain"}} = Shop.build_cart_rate_request(cart)
      assert Shop.shipping_quote_status(cart) == :missing
    end

    test "the request: service, origin, destination, parcels and the base value" do
      {cart, _method} = ready_cart!(quantity: 2)

      assert {:ok, request} = Shop.build_cart_rate_request(cart)
      assert request.service == "branch"
      assert request.origin == %{"sender_city" => @city}
      assert request.destination.pickup_point.id == "P1"
      assert [%{weight_g: 1000}] = request.parcels
      assert amount?(request.declared_value, "50")
      assert request.cod_amount == nil
      assert request.currency == cart.base_currency
    end

    test "the COD amount is the declared value, only for the payment option coded cod" do
      {cart, _method} = ready_cart!(quantity: 2)

      cod = ensure_payment_option("cod", "offline")
      other = ensure_payment_option("stripe", "online")

      {:ok, with_cod} = Shop.set_cart_payment_option(cart, cod)
      assert {:ok, request} = Shop.build_cart_rate_request(with_cod)
      assert amount?(request.cod_amount, "50")

      {:ok, with_other} = Shop.set_cart_payment_option(with_cod, other)
      assert {:ok, request} = Shop.build_cart_rate_request(with_other)
      assert request.cod_amount == nil
    end
  end

  describe "quote_cart_shipping/2" do
    test "an answer is stored and charged, marked up" do
      {cart, method} = ready_cart!(quantity: 2)
      stub_quote(quote_with("100", eta: %{min_days: 1, max_days: 3, date: nil}))

      assert {:ok, cart} = Shop.quote_cart_shipping(cart)

      assert Shop.shipping_quote_status(cart) == :ok
      # 100 + 10%, rounded up to a multiple of 1
      assert amount?(cart.shipping_amount, "110")
      assert amount?(cart.total, "160")
      refute amount?(cart.shipping_amount, "7")
      assert cart.shipping_method_uuid == method.uuid

      assert %{status: :ok, quote: %Quote{} = quote, reason: nil} = Shop.cart_shipping_quote(cart)
      assert amount?(quote.amount, "100")
      assert quote.eta.max_days == 3

      stored = cart.metadata["shipping_quote"]
      assert stored["status"] == "ok"
      assert stored["quote"]["source"] == "api"
      assert is_binary(stored["request_hash"]) and is_binary(stored["fetched_at"])
      assert reload(cart).metadata["shipping_quote"] == stored
      assert amount?(reload(cart).shipping_amount, "110")
    end

    test "a change of the cart makes the quote stale and the price falls back, a new quote fixes it" do
      {cart, _method} = ready_cart!(quantity: 2)
      stub_quote(quote_with("100"))
      {:ok, cart} = Shop.quote_cart_shipping(cart)
      assert amount?(cart.shipping_amount, "110")
      assert_received {:stub_called, :quote, _}

      [item] = cart.items
      {:ok, cart} = Shop.update_cart_item(item, 3)

      # No network on recalculation.
      refute_received {:stub_called, :quote, _}
      assert Shop.shipping_quote_status(cart) == :stale
      assert Shop.cart_shipping_quote(cart) == nil
      assert Shop.shipping_quote_blocks_checkout?(cart)
      assert amount?(cart.shipping_amount, "7")

      assert {:ok, cart} = Shop.quote_cart_shipping(cart)
      assert Shop.shipping_quote_status(cart) == :ok
      assert amount?(cart.shipping_amount, "110")
      refute Shop.shipping_quote_blocks_checkout?(cart)
    end

    test "the destination, the payment option and the method settings are part of the request" do
      {cart, _method} = ready_cart!()
      stub_quote(quote_with("100"))
      {:ok, cart} = Shop.quote_cart_shipping(cart)
      assert Shop.shipping_quote_status(cart) == :ok

      {:ok, with_cod} =
        Shop.set_cart_payment_option(cart, ensure_payment_option("cod", "offline"))

      assert Shop.shipping_quote_status(with_cod) == :stale

      {:ok, again} = Shop.set_cart_payment_option(with_cod, nil)
      assert Shop.shipping_quote_status(again) == :ok
    end

    test "a transient failure falls back to the price of the method" do
      {cart, _method} = ready_cart!()
      stub_quote({:error, {:http_error, 502}})

      assert {:ok, cart} = Shop.quote_cart_shipping(cart)

      assert Shop.shipping_quote_status(cart) == :fallback
      refute Shop.shipping_quote_blocks_checkout?(cart)
      assert amount?(cart.shipping_amount, "7")

      assert %{status: :fallback, quote: %Quote{source: :fallback} = quote, reason: "http_error"} =
               Shop.cart_shipping_quote(cart)

      assert amount?(quote.amount, "7")
      assert quote.currency == cart.base_currency
      assert is_binary(quote.note)
    end

    test "a crashing provider is a transient failure too" do
      {cart, _method} = ready_cart!()
      StubProvider.put(%{modes: %{quote: :crash}})

      assert {:ok, cart} = Shop.quote_cart_shipping(cart)
      assert Shop.shipping_quote_status(cart) == :fallback
    end

    test "a business error makes the method unavailable and blocks checkout" do
      {cart, _method} = ready_cart!()
      stub_quote({:error, :too_heavy})

      assert {:ok, cart} = Shop.quote_cart_shipping(cart)

      assert Shop.shipping_quote_status(cart) == :unavailable
      assert Shop.shipping_quote_blocks_checkout?(cart)

      assert %{status: :unavailable, quote: nil, reason: "too_heavy"} =
               Shop.cart_shipping_quote(cart)

      assert amount?(cart.shipping_amount, "7")

      assert {:error, :shipping_quote_required} =
               Shop.convert_cart_to_order(cart, billing_data: complete_billing("US"))

      assert reload(cart).status == "active"
    end

    test "the request errors come back" do
      cart = cart_with!(product!(), 1)
      assert {:error, :no_method} = Shop.quote_cart_shipping(cart)

      {:ok, cart} = Shop.set_cart_shipping(cart, method!(), "US")
      assert {:error, :needs_destination} = Shop.quote_cart_shipping(cart)

      {:ok, cart} = Shop.set_cart_shipping(cart, legacy_method!(), "US")
      assert {:error, :not_calculated} = Shop.quote_cart_shipping(cart)
    end

    test "a cart that changed while the carrier was answering is not written" do
      {cart, _method} = ready_cart!(quantity: 1)
      product = product!()

      StubProvider.put(%{
        quote: fn _request, ctx ->
          {:ok, _cart} = Shop.add_to_cart(cart, product, 1)
          {:ok, %Quote{amount: Decimal.new(100), currency: ctx.currency}}
        end
      })

      assert {:error, :stale} = Shop.quote_cart_shipping(cart)

      fresh = reload(cart)
      refute Map.has_key?(fresh.metadata, "shipping_quote")
      assert length(fresh.items) == 2
      assert Shop.shipping_quote_status(fresh) == :missing
      assert amount?(fresh.shipping_amount, "7")
    end

    test "a method changed while the carrier was answering is not written either" do
      {cart, _method} = ready_cart!()
      other = legacy_method!()

      StubProvider.put(%{
        quote: fn _request, ctx ->
          {:ok, _cart} = Shop.set_cart_shipping(cart, other, "US")
          {:ok, %Quote{amount: Decimal.new(100), currency: ctx.currency}}
        end
      })

      assert {:error, :stale} = Shop.quote_cart_shipping(cart)
      refute Map.has_key?(reload(cart).metadata, "shipping_quote")
    end

    test "context options and the locale reach the provider" do
      {cart, _method} = ready_cart!()
      test_pid = self()

      stub = %{
        quote: fn _request, ctx ->
          send(test_pid, {:ctx, ctx.locale, ctx.currency})
          {:ok, %Quote{amount: Decimal.new(30), currency: ctx.currency}}
        end
      }

      assert {:ok, cart} =
               Shop.quote_cart_shipping(cart, locale: "uk", context_opts: [stub: stub])

      assert_received {:ctx, "uk", currency}
      assert currency == cart.base_currency
      assert amount?(cart.shipping_amount, "33")
    end

    test "a provider that returns no currency is taken to answer in the base currency" do
      {cart, _method} = ready_cart!()
      stub_quote(fn _request, _ctx -> {:ok, %Quote{amount: Decimal.new(100), currency: nil}} end)

      assert {:ok, cart} = Shop.quote_cart_shipping(cart)
      assert Shop.cart_shipping_quote(cart).quote.currency == cart.base_currency
      assert amount?(cart.shipping_amount, "110")
    end
  end

  describe "shipping_quote_status/1" do
    test "not needed without a calculated method or without anything to ship" do
      cart = cart_with!(product!(), 1)
      assert Shop.shipping_quote_status(cart) == :not_needed
      refute Shop.shipping_quote_blocks_checkout?(cart)

      {:ok, fixed} = Shop.set_cart_shipping(cart, legacy_method!(), "US")
      assert Shop.shipping_quote_status(fixed) == :not_needed
      assert Shop.cart_shipping_quote(fixed) == nil
      refute Shop.shipping_quote_blocks_checkout?(fixed)

      digital =
        cart_with!(product!(%{"product_type" => "digital", "requires_shipping" => false}), 1)

      {:ok, digital} = Shop.set_cart_shipping(digital, method!(), "US")
      assert Shop.shipping_quote_status(digital) == :not_needed
    end

    test "needs a destination, then a quote" do
      cart = cart_with!(product!(), 1)
      {:ok, cart} = Shop.set_cart_shipping(cart, method!(), "US")

      assert Shop.shipping_quote_status(cart) == :needs_destination
      assert Shop.shipping_quote_blocks_checkout?(cart)

      {:ok, cart} = Shop.set_cart_shipping_destination(cart, branch())
      assert Shop.shipping_quote_status(cart) == :missing
      assert Shop.shipping_quote_blocks_checkout?(cart)
    end

    test "a provider that cannot list its services constrains nothing" do
      StubProvider.put(%{modes: %{services: :crash}})
      cart = cart_with!(product!(), 1)
      {:ok, cart} = Shop.set_cart_shipping(cart, method!(), "US")

      assert Shop.shipping_quote_status(cart) == :missing
    end
  end

  describe "pay on delivery with a calculated method" do
    test "the shop charges nothing, the quote is the carrier's estimate" do
      {cart, method} = ready_cart!(method: method!(pay_on_delivery: true))
      stub_quote(quote_with("100", cod_fee: Decimal.new("12")))

      assert {:ok, cart} = Shop.quote_cart_shipping(cart)

      assert Shop.shipping_quote_status(cart) == :ok
      assert amount?(cart.shipping_amount, "0")
      assert amount?(cart.total, cart.subtotal |> Decimal.to_string())

      assert %{pay_on_delivery?: true, free?: false, quote_status: :ok} =
               presented = Shop.present_shipping_method(cart, method)

      assert amount?(presented.price, "0")
      assert amount?(presented.estimate.amount, "100")
      assert amount?(presented.estimate.cod_fee, "12")
      assert presented.estimate.currency == cart.currency
    end
  end

  describe "present_shipping_method/2" do
    test "a fixed method keeps its shape and has no quote" do
      cart = cart_with!(product!(), 1)
      method = legacy_method!("5.00")

      assert %{
               price: price,
               free?: false,
               pay_on_delivery?: false,
               quote_status: :not_needed,
               estimate: nil
             } =
               Shop.present_shipping_method(cart, method)

      assert amount?(price, "5")
    end

    test "a calculated method shows its price until the quote arrives, then the real one" do
      {cart, method} = ready_cart!()

      assert %{quote_status: :missing, estimate: nil, price: price} =
               Shop.present_shipping_method(cart, method)

      assert amount?(price, "7")

      stub_quote(quote_with("100", eta: %{min_days: 2, max_days: 4, date: nil}))
      {:ok, cart} = Shop.quote_cart_shipping(cart)
      presented = Shop.present_shipping_method(cart, method)

      assert presented.quote_status == :ok
      assert amount?(presented.price, "110")
      assert amount?(presented.estimate.amount, "100")
      assert presented.estimate.eta.min_days == 2
      assert presented.estimate.source == :api
    end

    test "a calculated method that is not the selected one has no quote of its own" do
      {cart, _method} = ready_cart!()
      other = method!()

      assert %{quote_status: :missing, estimate: nil} = Shop.present_shipping_method(cart, other)
    end

    test "stale, unavailable and fallback quotes show the price of the method" do
      {cart, method} = ready_cart!()

      stub_quote({:error, :too_heavy})
      {:ok, cart} = Shop.quote_cart_shipping(cart)

      assert %{quote_status: :unavailable, estimate: nil} =
               Shop.present_shipping_method(cart, method)

      stub_quote({:error, :timeout})
      {:ok, cart} = Shop.quote_cart_shipping(cart)
      presented = Shop.present_shipping_method(cart, method)
      assert %{quote_status: :fallback, estimate: nil} = presented
      assert amount?(presented.price, "7")
    end
  end

  describe "changing the method" do
    test "the same provider and service keeps the destination and drops the quote" do
      {cart, method} = ready_cart!()
      {:ok, cart} = Shop.quote_cart_shipping(cart)
      sibling = method!(price: "9.00")

      {:ok, cart} = Shop.set_cart_shipping(cart, sibling, "US")

      assert Shop.cart_shipping_destination(cart).pickup_point.id == "P1"
      refute Map.has_key?(cart.metadata, "shipping_quote")
      assert cart.shipping_method_uuid == sibling.uuid
      assert method.uuid != sibling.uuid
      assert Shop.shipping_quote_status(cart) == :missing
    end

    test "selecting the same method again changes nothing" do
      {cart, method} = ready_cart!()
      {:ok, cart} = Shop.quote_cart_shipping(cart)

      {:ok, cart} = Shop.set_cart_shipping(cart, method, "US")

      assert Shop.shipping_quote_status(cart) == :ok
      assert Shop.cart_shipping_destination(cart)
    end

    test "another service clears both" do
      {cart, _method} = ready_cart!()
      {:ok, cart} = Shop.quote_cart_shipping(cart)

      {:ok, cart} = Shop.set_cart_shipping(cart, method!(service: "courier"), "US")

      assert Shop.cart_shipping_destination(cart) == nil
      refute CartQuote.any?(cart.metadata)
      assert Shop.shipping_quote_status(cart) == :needs_destination
    end

    test "another provider clears both" do
      {cart, _method} = ready_cart!()
      {:ok, cart} = Shop.quote_cart_shipping(cart)

      {:ok, cart} = Shop.set_cart_shipping(cart, method!(provider: "strict"), "US")

      refute CartQuote.any?(cart.metadata)
    end

    test "a method with a fixed price clears both" do
      {cart, _method} = ready_cart!()
      {:ok, cart} = Shop.quote_cart_shipping(cart)

      {:ok, cart} = Shop.set_cart_shipping(cart, legacy_method!(), "US")

      refute CartQuote.any?(cart.metadata)
      assert amount?(cart.shipping_amount, "5")
    end

    test "clearing the shipping clears both" do
      {cart, _method} = ready_cart!()
      {:ok, cart} = Shop.quote_cart_shipping(cart)

      {:ok, cart} = Shop.clear_cart_shipping(cart)

      refute CartQuote.any?(cart.metadata)
      assert reload(cart).shipping_method_uuid == nil
      refute CartQuote.any?(reload(cart).metadata)
    end

    test "other metadata of the cart survives all of it" do
      {cart, _method} = ready_cart!()

      {:ok, cart} =
        cart
        |> Cart.changeset(%{metadata: Map.put(cart.metadata, "note", "keep me")})
        |> Repo.update()

      {:ok, cart} = Shop.quote_cart_shipping(cart)
      {:ok, cart} = Shop.set_cart_shipping(cart, method!(service: "courier"), "US")

      assert reload(cart).metadata["note"] == "keep me"
    end
  end

  describe "currency" do
    setup do
      PhoenixKit.Cache.clear(:billing_currencies)
      Currency.put_request_currency(nil)
      on_exit(fn -> Currency.put_request_currency(nil) end)

      Repo.delete_all(Currency)

      {:ok, _usd} =
        Billing.create_currency(%{
          code: "USD",
          name: "Dollar",
          symbol: "$",
          is_default: true,
          exchange_rate: "1.0"
        })

      {:ok, _eur} =
        Billing.create_currency(%{
          code: "EUR",
          name: "Euro",
          symbol: "€",
          exchange_rate: "0.909091"
        })

      Currency.put_request_currency("EUR")
      :ok
    end

    defp eur_cart! do
      cart = cart_with!(product!(%{"price" => Decimal.new("110.00")}), 1)
      assert cart.currency == "EUR" and cart.base_currency == "USD"
      {:ok, cart} = Shop.set_cart_shipping(cart, method!(), "US")
      {:ok, cart} = Shop.set_cart_shipping_destination(cart, branch())
      cart
    end

    test "the request is in the base currency, the price comes back in the cart's" do
      cart = eur_cart!()
      test_pid = self()

      stub_quote(fn request, ctx ->
        send(test_pid, {:request, request})
        {:ok, %Quote{amount: Decimal.new(100), currency: ctx.currency}}
      end)

      {:ok, cart} = Shop.quote_cart_shipping(cart)

      assert_received {:request, %RateRequest{currency: "USD", declared_value: declared}}
      assert amount?(declared, "110")
      # 100 USD + 10% = 110 USD = 100.00 EUR
      assert amount?(cart.shipping_amount, "100")
      assert Shop.shipping_quote_status(cart) == :ok

      presented = Shop.present_shipping_method(cart, cart.shipping_method)
      assert amount?(presented.price, "100")
      assert amount?(presented.estimate.amount, "90.91")
      assert presented.estimate.currency == "EUR"
    end

    test "a quote in the cart's own currency is used as it is" do
      cart = eur_cart!()
      stub_quote(fn _request, _ctx -> {:ok, %Quote{amount: Decimal.new(50), currency: "EUR"}} end)

      {:ok, cart} = Shop.quote_cart_shipping(cart)

      assert amount?(cart.shipping_amount, "55")
    end

    test "a quote in a currency the cart cannot convert from costs the price of the method" do
      cart = eur_cart!()
      stub_quote(fn _request, _ctx -> {:ok, %Quote{amount: Decimal.new(50), currency: "GBP"}} end)

      {:ok, cart} = Shop.quote_cart_shipping(cart)

      assert Shop.shipping_quote_status(cart) == :ok
      # 7 USD
      assert amount?(cart.shipping_amount, "6.36")
      presented = Shop.present_shipping_method(cart, cart.shipping_method)
      assert amount?(presented.price, "6.36")
      assert presented.estimate.currency == "GBP"
      assert amount?(presented.estimate.amount, "50")
    end
  end

  describe "the order" do
    defp order_from!(cart),
      do: Shop.convert_cart_to_order(cart, billing_data: complete_billing("US"))

    test "keeps the provider, destination, quote and parcels, and the line the eta and the place" do
      {cart, method} = ready_cart!(quantity: 2)

      destination = %Destination{
        locality: @locality,
        pickup_point: %PickupPoint{id: "P1", name: "Branch No. 5"}
      }

      {:ok, cart} = Shop.set_cart_shipping_destination(cart, destination)
      stub_quote(quote_with("100", eta: %{min_days: 1, max_days: 3, date: nil}))
      {:ok, cart} = Shop.quote_cart_shipping(cart)

      assert {:ok, order} = order_from!(cart)

      assert order.metadata["shipping_method_uuid"] == method.uuid
      assert order.metadata["shipping_provider"] == %{"provider" => "stub", "service" => "branch"}
      assert order.metadata["shipping_destination"]["pickup_point"]["id"] == "P1"
      assert order.metadata["shipping_destination"]["locality"]["name"] == "Kyiv"
      assert order.metadata["shipping_quote"]["status"] == "ok"
      assert order.metadata["shipping_quote"]["quote"]["amount"] == "100"

      assert order.metadata["shipping_quote"]["request_hash"] ==
               cart.metadata["shipping_quote"]["request_hash"]

      assert [%{"weight_g" => 1000}] = order.metadata["shipping_parcels"]

      line = Enum.find(order.line_items, &(&1["type"] == "shipping"))
      assert line["eta"] == %{"min_days" => 1, "max_days" => 3, "date" => nil}
      assert line["destination_label"] == "Kyiv, Branch No. 5"
      assert amount?(Decimal.new(line["total"]), "110")
      assert amount?(order.total, "160")
      assert reload(cart).status == "converted"
    end

    test "a fallback quote converts and is recorded as such" do
      {cart, _method} = ready_cart!()
      stub_quote({:error, :timeout})
      {:ok, cart} = Shop.quote_cart_shipping(cart)

      assert {:ok, order} = order_from!(cart)

      assert order.metadata["shipping_quote"]["status"] == "fallback"
      line = Enum.find(order.line_items, &(&1["type"] == "shipping"))
      assert line["eta"] == nil
      assert amount?(Decimal.new(line["total"]), "7")
    end

    test "a missing, stale or unavailable quote refuses the order" do
      {cart, _method} = ready_cart!()
      assert {:error, :shipping_quote_required} = order_from!(cart)

      {:ok, cart} = Shop.quote_cart_shipping(cart)
      {:ok, cart} = Shop.update_cart_item(hd(cart.items), 5)
      assert Shop.shipping_quote_status(cart) == :stale
      assert {:error, :shipping_quote_required} = order_from!(cart)

      {:ok, cart} = Shop.set_cart_shipping_destination(cart, nil)
      assert {:error, :shipping_quote_required} = order_from!(cart)

      assert reload(cart).status == "active"
      assert Repo.aggregate(CartItem, :count) > 0
    end

    test "an ordinary method's order has none of it" do
      cart = cart_with!(product!(), 1)
      {:ok, cart} = Shop.set_cart_shipping(cart, legacy_method!(), "US")

      assert {:ok, order} = order_from!(cart)

      for key <- ~w(shipping_provider shipping_destination shipping_quote shipping_parcels) do
        refute Map.has_key?(order.metadata, key)
      end

      line = Enum.find(order.line_items, &(&1["type"] == "shipping"))
      refute Map.has_key?(line, "eta")
      refute Map.has_key?(line, "destination_label")
    end

    test "a digital-only order does not carry the shipping data" do
      cart = cart_with!(product!(%{"product_type" => "digital", "requires_shipping" => false}), 1)
      {:ok, cart} = Shop.set_cart_shipping(cart, method!(), "US")

      assert {:ok, order} = order_from!(cart)

      refute Map.has_key?(order.metadata, "shipping_provider")
      refute Enum.any?(order.line_items, &(&1["type"] == "shipping"))
    end
  end

  describe "destination_label" do
    test "locality with a pickup point's name or number, or an address" do
      label = &CartQuote.destination_label/1

      assert label.(nil) == nil
      assert label.(%Destination{}) == nil
      assert label.(%Destination{locality: %Locality{name: "Lviv"}}) == "Lviv"

      assert label.(%Destination{
               locality: %Locality{name: "Lviv"},
               pickup_point: %PickupPoint{number: "12"}
             }) == "Lviv, №12"

      assert label.(%Destination{
               locality: %Locality{name: "Lviv"},
               address: %Address{street: "Main", house: "1", apartment: "2"}
             }) == "Lviv, Main 1 2"

      assert label.(%Destination{address: %Address{line: "Free text 5"}}) == "Free text 5"
    end
  end
end
