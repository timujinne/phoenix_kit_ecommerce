defmodule PhoenixKitEcommerce.Web.ShippingPickerTest do
  @moduledoc """
  The shipping destination picker and everything around it: the cart page and
  the checkout with a carrier-priced method, the quote it shows, the checkout
  review and the confirmation page.

  Providers are the `StubProvider`, registered through the application env
  (restored on exit), so this file does not run async.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Cart
  alias PhoenixKitEcommerce.Shipping.{Destination, Locality, PickupPoint, Quote, Service}
  alias PhoenixKitEcommerce.Test.Repo
  alias PhoenixKitEcommerce.Test.Shipping.StubProvider
  alias PhoenixKitEcommerce.Web.Components.ShippingDestinationPicker

  defmodule RejectingProvider do
    @moduledoc false
    @behaviour PhoenixKitEcommerce.Shipping.Provider

    alias PhoenixKitEcommerce.Shipping.{Quote, Service}

    @impl true
    def key, do: "rejecting"
    @impl true
    def label, do: "Rejecting"
    @impl true
    def services(_ctx) do
      [%Service{key: "branch", label: "Branch", destination: :pickup_point, lookup: :manual}]
    end

    @impl true
    def settings_fields, do: []
    @impl true
    def quote(_request, ctx), do: {:ok, %Quote{amount: Decimal.new(20), currency: ctx.currency}}

    @impl true
    def validate_destination(%{pickup_point: %{id: "00000"}}, _service, _ctx),
      do: {:error, "no such branch"}

    def validate_destination(_destination, _service, _ctx), do: :ok
  end

  @poltava %Locality{id: "L1", name: "Poltava", region: "Poltava region"}
  @kyiv %Locality{id: "L2", name: "Kyiv", region: "Kyiv region"}

  setup do
    previous = Application.get_env(:phoenix_kit_ecommerce, :shipping_providers)
    Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, [StubProvider])
    # No pause between two lookups unless a test is about it.
    Application.put_env(:phoenix_kit_ecommerce, :shipping_lookup_interval, 0)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, previous),
        else: Application.delete_env(:phoenix_kit_ecommerce, :shipping_providers)

      Application.delete_env(:phoenix_kit_ecommerce, :shipping_lookup_interval)
    end)

    PhoenixKit.Settings.update_setting_with_module(
      "shop_shipping_selection_position",
      "cart",
      "shop"
    )

    stub!()
    :ok
  end

  # -- the cart page ----------------------------------------------------

  describe "cart page: a pickup point found by search" do
    test "search the city, pick it, find a point, pick it: the quote is shown", %{conn: conn} do
      {conn, cart, method} = cart_session(conn)

      {:ok, view, _html} = live(conn, "/cart")

      assert has_element?(view, "#shipping-picker-#{method.uuid}")
      assert has_element?(view, ps("locality-input"))
      refute has_element?(view, ps("quote"))

      # Typing in the city input searches the carrier (debounced in the browser).
      view |> form(ps("locality-form"), %{"q" => "Pol"}) |> render_change()
      settle(view)

      assert has_element?(view, "#{ps("locality-results")} #{ps("locality-option-L1")}")

      view |> element(ps("locality-option-L1")) |> render_click()
      settle(view)

      # The city is on the cart, the points of the city are listed.
      assert %Destination{locality: %Locality{id: "L1"}} =
               cart |> reload() |> Shop.cart_shipping_destination()

      assert has_element?(view, ps("locality-selected"), "Poltava")
      assert has_element?(view, "#{ps("points")} #{ps("point-P1")}")
      assert has_element?(view, "#{ps("points")} #{ps("point-P2")}")

      # The filter narrows the list.
      view |> form(ps("points-form"), %{"q" => "locker"}) |> render_change()
      settle(view)

      refute has_element?(view, ps("point-P1"))
      assert has_element?(view, ps("point-P2"))

      view |> element(ps("point-P2")) |> render_click()
      settle(view)

      assert has_element?(view, ps("destination-summary"), "Poltava")
      assert has_element?(view, ps("destination-summary"), "Locker 2")
      refute has_element?(view, ps("editor"))

      assert has_element?(view, ps("quote-price"), "100")
      assert has_element?(view, ps("quote-eta"))
      assert has_element?(view, ps("quote-cod-fee"), "20")
      refute has_element?(view, ps("quote-fallback"))
      refute has_element?(view, ps("quote-unavailable"))

      # The page totals followed the quote (the parent heard of the change).
      assert has_element?(view, "#cart-summary-shipping", "100")

      cart = reload(cart)
      assert Shop.shipping_quote_status(cart) == :ok
      assert %PickupPoint{id: "P2"} = Shop.cart_shipping_destination(cart).pickup_point
    end

    test "points that cannot take the parcel of the cart are not offered", %{conn: conn} do
      {conn, cart, _method} = cart_session(conn)
      {:ok, view, _html} = live(conn, "/cart")

      view |> form(ps("locality-form"), %{"q" => "Pol"}) |> render_change()
      settle(view)
      view |> element(ps("locality-option-L1")) |> render_click()
      settle(view)

      assert_received {:stub_called, :list_pickup_points, [%Locality{id: "L1"}, _service, nil]}
      assert Decimal.equal?(Shop.cart_declared_value(cart), Decimal.new("25"))

      # The cart weighs 500 g; the third point takes 100 g.
      assert has_element?(view, ps("point-P1"))
      refute has_element?(view, ps("point-P3"))
    end

    test "a chosen point that stops taking the parcel sends the shopper back to the list",
         %{conn: conn} do
      limited = %Destination{
        locality: @poltava,
        pickup_point: %PickupPoint{
          id: "P2",
          number: "2",
          name: "Locker 2",
          kind: :locker,
          limits: %{max_weight_g: 1_200, max_dims_mm: nil, max_declared: nil}
        }
      }

      {conn, cart, _method} = cart_session(conn, destination: limited)
      {:ok, view, _html} = live(conn, "/cart")
      settle(view)

      assert has_element?(view, ps("destination-summary"), "Locker 2")
      assert has_element?(view, ps("quote-price"), "100")
      refute has_element?(view, ps("point-limits"))

      # Three pieces weigh 1500 g, the locker takes 1200 g.
      [item] = reload(cart).items
      {:ok, _cart} = Shop.update_cart_item(item, 3)
      settle(view)

      assert Shop.shipping_quote_status(reload(cart)) == :needs_destination
      assert has_element?(view, ps("point-limits"))
      refute has_element?(view, ps("destination-rejected"))
      refute has_element?(view, ps("quote-price"))
      assert has_element?(view, ps("editor"))
      assert has_element?(view, ps("locality-selected"), "Poltava")
      assert has_element?(view, "#{ps("points")} #{ps("point-P1")}")

      view |> element(ps("point-P1")) |> render_click()
      settle(view)

      refute has_element?(view, ps("point-limits"))
      assert has_element?(view, ps("destination-summary"), "Branch 1")
      assert has_element?(view, ps("quote-price"), "100")
      assert Shop.shipping_quote_status(reload(cart)) == :ok
    end

    test "the change button reopens the editor on the same city", %{conn: conn} do
      {conn, _cart, _method} = cart_session(conn, destination: branch("P1"))
      {:ok, view, _html} = live(conn, "/cart")
      settle(view)

      assert has_element?(view, ps("destination-summary"), "Branch 1")
      refute has_element?(view, ps("editor"))

      view |> element(ps("change")) |> render_click()
      settle(view)

      assert has_element?(view, ps("editor"))
      assert has_element?(view, ps("locality-selected"), "Poltava")
      assert has_element?(view, ps("point-P2"))

      # Cancelling keeps what the cart has.
      view |> element(ps("cancel-change")) |> render_click()
      assert has_element?(view, ps("destination-summary"), "Branch 1")
    end

    test "a failing city search is an inline message, not a crash", %{conn: conn} do
      stub!(%{localities: {:error, :timeout}})
      {conn, _cart, _method} = cart_session(conn)
      {:ok, view, _html} = live(conn, "/cart")

      view |> form(ps("locality-form"), %{"q" => "Pol"}) |> render_change()
      settle(view)

      assert has_element?(view, "#{ps("locality-results")} p.text-error")
      refute has_element?(view, "[id*='-locality-option-']")
      assert has_element?(view, ps("locality-input"))
    end

    test "a rate limited city search says the service is busy", %{conn: conn} do
      stub!(%{localities: {:error, :rate_limited}})
      {conn, _cart, _method} = cart_session(conn)
      {:ok, view, _html} = live(conn, "/cart")

      view |> form(ps("locality-form"), %{"q" => "Pol"}) |> render_change()
      settle(view)

      assert has_element?(view, "#{ps("locality-results")} p.text-error", "busy")
      assert has_element?(view, ps("locality-input"))
    end

    test "failing points are an inline message with a retry", %{conn: conn} do
      stub!(%{points: {:error, {:http, 500}}})
      {conn, _cart, _method} = cart_session(conn, destination: %Destination{locality: @poltava})
      {:ok, view, _html} = live(conn, "/cart")
      settle(view)

      assert has_element?(view, "#{ps("points")} p.text-error")
      assert has_element?(view, ps("points-retry"))

      stub!()
      view |> element(ps("points-retry")) |> render_click()
      settle(view)

      assert has_element?(view, ps("point-P1"))
    end
  end

  describe "cart page: typed in" do
    test "a pickup point by its code: checks the format, then quotes", %{conn: conn} do
      stub!(%{services: [manual_branch()]})
      {conn, cart, _method} = cart_session(conn)
      {:ok, view, _html} = live(conn, "/cart")

      assert has_element?(view, ps("manual-form"))
      assert has_element?(view, "#{ps("manual-point")}[pattern='[0-9]{5}']")
      refute has_element?(view, ps("locality-input"))

      view
      |> form(ps("manual-form"), %{"manual" => %{"locality" => "Poltava", "point" => "12"}})
      |> render_submit()

      assert has_element?(view, ps("manual-form"))
      assert has_element?(view, "#{ps("manual-form")} p.text-error")
      refute has_element?(view, ps("quote"))

      view
      |> form(ps("manual-form"), %{
        "manual" => %{"locality" => "Poltava", "point" => "36000"}
      })
      |> render_submit()

      settle(view)

      refute has_element?(view, ps("manual-form"))
      assert has_element?(view, ps("destination-summary"), "Poltava")
      assert has_element?(view, ps("quote-price"), "100")

      destination = cart |> reload() |> Shop.cart_shipping_destination()
      assert %Locality{name: "Poltava", id: nil} = destination.locality
      assert %PickupPoint{id: "36000", extra: %{"manual" => "true"}} = destination.pickup_point
    end

    test "an address after a city search", %{conn: conn} do
      stub!(%{services: [courier(:search)]})
      {conn, cart, _method} = cart_session(conn, service: "courier")
      {:ok, view, _html} = live(conn, "/cart")

      refute has_element?(view, ps("address-form"))

      view |> form(ps("locality-form"), %{"q" => "Pol"}) |> render_change()
      settle(view)
      view |> element(ps("locality-option-L1")) |> render_click()

      assert has_element?(view, ps("address-form"))
      refute has_element?(view, ps("address-locality"))

      # A street and a house are what an address needs.
      view
      |> form(ps("address-form"), %{"address" => %{"street" => "", "house" => ""}})
      |> render_submit()

      assert has_element?(view, "#{ps("address-form")} p.text-error")

      view
      |> form(ps("address-form"), %{
        "address" => %{
          "street" => "Soborna",
          "house" => "7",
          "apartment" => "12",
          "postcode" => "36000"
        }
      })
      |> render_submit()

      settle(view)

      assert has_element?(view, ps("destination-summary"), "Soborna 7 12")
      assert has_element?(view, ps("quote-price"), "100")

      destination = cart |> reload() |> Shop.cart_shipping_destination()
      assert destination.locality.id == "L1"

      assert %{street: "Soborna", house: "7", apartment: "12", postcode: "36000"} =
               destination.address
    end

    test "an address typed in whole needs the city and the postcode", %{conn: conn} do
      stub!(%{services: [courier(:manual)]})
      {conn, _cart, _method} = cart_session(conn, service: "courier")
      {:ok, view, _html} = live(conn, "/cart")

      assert has_element?(view, ps("address-locality"))
      refute has_element?(view, ps("locality-input"))

      view
      |> form(ps("address-form"), %{
        "address" => %{"street" => "Soborna", "house" => "7", "locality" => "", "postcode" => ""}
      })
      |> render_submit()

      assert has_element?(view, "#{ps("address-form")} p.text-error")
      refute has_element?(view, ps("quote"))

      view
      |> form(ps("address-form"), %{
        "address" => %{
          "street" => "Soborna",
          "house" => "7",
          "locality" => "Poltava",
          "postcode" => "36000"
        }
      })
      |> render_submit()

      settle(view)

      assert has_element?(view, ps("destination-summary"), "Poltava")
      assert has_element?(view, ps("quote-price"), "100")
    end

    test "a point the carrier refuses sends the shopper back to the editor", %{conn: conn} do
      Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, [
        StubProvider,
        RejectingProvider
      ])

      {conn, cart, _method} = cart_session(conn, provider: "rejecting")
      {:ok, view, _html} = live(conn, "/cart")

      view
      |> form(ps("manual-form"), %{
        "manual" => %{"locality" => "Poltava", "point" => "00000"}
      })
      |> render_submit()

      settle(view)

      assert has_element?(view, ps("destination-rejected"))
      assert has_element?(view, ps("manual-form"))
      refute has_element?(view, ps("quote-price"))
      assert Shop.shipping_quote_status(reload(cart)) == :needs_destination

      view
      |> form(ps("manual-form"), %{
        "manual" => %{"locality" => "Poltava", "point" => "36000"}
      })
      |> render_submit()

      settle(view)

      refute has_element?(view, ps("destination-rejected"))
      assert has_element?(view, ps("quote-price"), "20")
    end

    test "a service that asks for nothing is quoted straight away", %{conn: conn} do
      stub!(%{services: [%Service{key: "plain", label: "Plain", destination: :none}]})
      {conn, cart, _method} = cart_session(conn, service: "plain")
      {:ok, view, _html} = live(conn, "/cart")
      settle(view)

      refute has_element?(view, ps("editor"))
      refute has_element?(view, ps("destination-summary"))
      assert has_element?(view, ps("quote-price"), "100")
      assert Shop.shipping_quote_status(reload(cart)) == :ok
    end
  end

  describe "the quote" do
    test "an answer that cannot be had falls back to the price of the method, flagged",
         %{conn: conn} do
      stub!(%{quote: {:error, :timeout}})
      {conn, cart, _method} = cart_session(conn, destination: branch("P1"))
      {:ok, view, _html} = live(conn, "/cart")
      settle(view)

      assert has_element?(view, ps("quote-fallback"))
      assert has_element?(view, ps("quote-price"), "7.00")
      refute has_element?(view, ps("quote-unavailable"))
      assert Shop.shipping_quote_status(reload(cart)) == :fallback
    end

    test "a carrier that refuses the cart makes the method unavailable, with the reason",
         %{conn: conn} do
      stub!(%{quote: {:error, :too_heavy}})
      {conn, cart, _method} = cart_session(conn, destination: branch("P1"))
      {:ok, view, _html} = live(conn, "/cart")
      settle(view)

      assert has_element?(view, ps("quote-unavailable"))
      refute has_element?(view, ps("quote-price"))
      assert Shop.shipping_quote_status(reload(cart)) == :unavailable
    end

    test "a provider that is no longer configured is not available for this order",
         %{conn: conn} do
      {conn, _cart, _method} = cart_session(conn, destination: branch("P1"))
      Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, [])

      {:ok, view, _html} = live(conn, "/cart")

      assert has_element?(view, "#{ps("service-error")} #{ps("quote-unavailable")}")
      refute has_element?(view, ps("editor"))
    end

    test "a pay-on-delivery method shows the estimate the buyer pays the carrier",
         %{conn: conn} do
      {conn, _cart, _method} =
        cart_session(conn, destination: branch("P1"), pay_on_delivery: true)

      {:ok, view, _html} = live(conn, "/cart")
      settle(view)

      assert has_element?(view, ps("quote-price"), "100")
      assert has_element?(view, ps("quote-price"), "carrier")
      assert has_element?(view, ps("quote-cod-fee"), "20")
    end

    test "a quote that is out of date is asked for again, once", %{conn: conn} do
      {conn, cart, _method} = cart_session(conn, destination: branch("P1"))
      {:ok, view, _html} = live(conn, "/cart")
      settle(view)

      assert_received {:stub_called, :quote, _}
      refute_received {:stub_called, :quote, _}

      # A bigger order is a different request: the old quote is stale.
      [item] = reload(cart).items
      {:ok, _cart} = Shop.update_cart_item(item, 3)
      _ = render(view)
      settle(view)

      assert_received {:stub_called, :quote, [request]}
      assert Decimal.equal?(request.declared_value, Decimal.new("75"))
      assert has_element?(view, ps("quote-price"), "100")
      assert Shop.shipping_quote_status(reload(cart)) == :ok

      # And not a third time.
      _ = render(view)
      refute_received {:stub_called, :quote, _}
    end

    test "a carrier whose quotes are expired on arrival is not called in a loop",
         %{conn: conn} do
      expired = fn _request, ctx ->
        {:ok,
         %Quote{
           amount: Decimal.new(100),
           currency: ctx.currency,
           expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
         }}
      end

      stub!(%{quote: expired})
      {conn, cart, _method} = cart_session(conn, destination: branch("P1"))
      {:ok, view, _html} = live(conn, "/cart")

      for _round <- 1..5 do
        settle(view)
        _ = render(view)
      end

      assert Shop.shipping_quote_status(reload(cart)) == :stale
      assert has_element?(view, ps("quote-retry"))
      assert quote_calls() <= 3
    end

    test "the cart's status can always be renewed by hand", %{conn: conn} do
      stub!(%{quote: {:error, :timeout}})
      {conn, _cart, _method} = cart_session(conn, destination: branch("P1"))
      {:ok, view, _html} = live(conn, "/cart")
      settle(view)

      assert has_element?(view, ps("quote-fallback"))
      flush_quote_calls()

      stub!()
      view |> element(ps("quote-retry")) |> render_click()
      settle(view)

      assert quote_calls() == 1
      refute has_element?(view, ps("quote-fallback"))
      assert has_element?(view, ps("quote-price"), "100")
    end
  end

  describe "the carrier is not for a client to spam" do
    test "searches are coalesced: one in flight, the latest text wins", %{conn: conn} do
      Application.put_env(:phoenix_kit_ecommerce, :shipping_lookup_interval, 200)
      stub!(%{localities: gated_localities(self())})
      {conn, _cart, _method} = cart_session(conn)
      {:ok, view, _html} = live(conn, "/cart")

      search = fn text ->
        view |> form(ps("locality-form"), %{"q" => text}) |> render_change()
      end

      search.("Po")
      assert_receive {:locality_search, worker, "Po"}

      # While that one is out, more is typed: nothing else is asked yet.
      search.("Pol")
      search.("Polt")
      search.("Polta")
      refute_receive {:locality_search, _worker, _query}, 50

      send(worker, :answer)

      # What followed is asked once, for the last text.
      assert_receive {:locality_search, worker, "Polta"}, 1000
      send(worker, :answer)
      refute_receive {:locality_search, _worker, _query}, 300

      settle(view)
      assert has_element?(view, ps("locality-option-L1"))
    end

    test "a short text asks nothing and drops what was asked", %{conn: conn} do
      stub!(%{localities: gated_localities(self())})
      {conn, _cart, _method} = cart_session(conn)
      {:ok, view, _html} = live(conn, "/cart")

      view |> form(ps("locality-form"), %{"q" => "Pol"}) |> render_change()
      assert_receive {:locality_search, worker, "Pol"}

      view |> form(ps("locality-form"), %{"q" => "P"}) |> render_change()
      send(worker, :answer)
      settle(view)

      refute has_element?(view, "[id*='-locality-option-']")
      refute_receive {:locality_search, _worker, _query}, 100
    end

    test "a late answer to an earlier search does not undo the city that was picked",
         %{conn: conn} do
      stub!(%{localities: gated_localities(self())})
      {conn, cart, _method} = cart_session(conn)
      {:ok, view, _html} = live(conn, "/cart")

      view |> form(ps("locality-form"), %{"q" => "Pol"}) |> render_change()
      assert_receive {:locality_search, first, "Pol"}
      send(first, :answer)
      settle(view)

      # A second search is on its way when the city is picked from the first.
      view |> form(ps("locality-form"), %{"q" => "Polt"}) |> render_change()
      assert_receive {:locality_search, second, "Polt"}
      view |> element(ps("locality-option-L1")) |> render_click()
      send(second, :answer)
      settle(view)

      assert has_element?(view, ps("locality-selected"), "Poltava")
      refute has_element?(view, "[id*='-locality-option-']")
      refute has_element?(view, ps("locality-input"))
      assert Shop.cart_shipping_destination(reload(cart)).locality.id == "L1"
    end

    test "the filter is throttled the same way", %{conn: conn} do
      Application.put_env(:phoenix_kit_ecommerce, :shipping_lookup_interval, 200)
      {conn, _cart, _method} = cart_session(conn, destination: %Destination{locality: @poltava})
      {:ok, view, _html} = live(conn, "/cart")
      settle(view)
      flush_calls(:list_pickup_points)

      for text <- ["l", "lo", "loc", "lock"] do
        view |> form(ps("points-form"), %{"q" => text}) |> render_change()
      end

      assert_receive {:stub_called, :list_pickup_points, [_locality, _service, "lock"]}, 1000
      settle(view)
      assert count_calls(:list_pickup_points) <= 2
    end

    test "the quote is not asked by hand while it is asked, nor when it is settled" do
      handle = fn quote_state, status ->
        socket =
          socket_with(%{
            quote_state: quote_state,
            snapshot: %{status: status},
            cart: %Cart{},
            locale: "en",
            auto_key: nil
          })

        {:noreply, socket} = ShippingDestinationPicker.handle_event("requote", %{}, socket)
        socket.assigns.quote_state
      end

      # Asked for: a stale or estimated price, nothing in flight.
      assert handle.(:idle, :stale) == :loading
      assert handle.(:idle, :missing) == :loading
      assert handle.(:idle, :fallback) == :loading
      assert handle.(:error, :stale) == :loading

      # Not asked for: in flight, or settled.
      assert handle.(:loading, :stale) == :loading
      assert handle.(:idle, :ok) == :idle
      assert handle.(:idle, :unavailable) == :idle
      assert handle.(:idle, :needs_destination) == :idle
    end

    test "a filter without a city asks nothing" do
      lookups = %{
        localities: %{at: nil, pending: false, timer: false},
        points: %{at: nil, pending: false, timer: false}
      }

      for event <- ["filter_points", "retry_points"],
          assigns <- [
            %{editing: true, locality: nil},
            %{editing: false, locality: %Locality{id: "L1", name: "Poltava"}}
          ] do
        socket =
          socket_with(
            Map.merge(assigns, %{lookups: lookups, points_state: :idle, point_query: ""})
          )

        {:noreply, socket} =
          ShippingDestinationPicker.handle_event(event, %{"q" => "any"}, socket)

        assert socket.assigns.lookups.points.at == nil
        assert socket.assigns.points_state == :idle
      end
    end

    test "events of a shape nobody sends are ignored", %{conn: conn} do
      {conn, cart, _method} = cart_session(conn)
      {:ok, view, _html} = live(conn, "/cart")

      for q <- [%{"a" => ["b"]}, 42, nil] do
        view |> element(ps("locality-form")) |> render_change(%{"q" => q})
      end

      assert has_element?(view, ps("locality-input"))
      assert Shop.cart_shipping_destination(reload(cart)) == nil

      # The rest of it never comes from a browser: the handlers take it in stride.
      socket =
        socket_with(%{
          service: %Service{key: "branch", destination: :pickup_point, lookup: :manual},
          localities: [],
          points: [],
          lookups: %{
            localities: %{at: nil, pending: false, timer: false},
            points: %{at: nil, pending: false, timer: false}
          }
        })

      for {event, params} <- [
            {"locality_search", %{"q" => %{"x" => 1}}},
            {"locality_search", %{}},
            {"pick_locality", %{"id" => %{"x" => 1}}},
            {"pick_point", %{}},
            {"manual_change", %{"manual" => "oops"}},
            {"apply_manual", %{"manual" => [1]}},
            {"address_change", %{"address" => 5}},
            {"apply_address", %{"address" => [1, 2]}},
            {"no_such_event", %{"a" => 1}}
          ] do
        assert {:noreply, %Phoenix.LiveView.Socket{}} =
                 ShippingDestinationPicker.handle_event(event, params, socket)
      end
    end
  end

  describe "what a client types is capped" do
    test "the inputs say so", %{conn: conn} do
      {conn, _cart, _method} = cart_session(conn)
      {:ok, view, _html} = live(conn, "/cart")
      assert has_element?(view, ps("locality-input") <> "[maxlength='64']")

      stub!(%{services: [manual_branch()]})
      {conn, _cart, _method} = cart_session(build_conn())
      {:ok, view, _html} = live(conn, "/cart")
      assert has_element?(view, ps("manual-point") <> "[maxlength='64']")
      assert has_element?(view, ps("manual-locality") <> "[maxlength='255']")

      stub!(%{services: [courier(:manual)]})
      {conn, _cart, _method} = cart_session(build_conn(), service: "courier")
      {:ok, view, _html} = live(conn, "/cart")

      for field <- ~w(locality street house apartment postcode) do
        assert has_element?(view, ps("address-#{field}") <> "[maxlength='255']")
      end
    end

    test "a long search text reaches the carrier cut", %{conn: conn} do
      {conn, _cart, _method} = cart_session(conn)
      {:ok, view, _html} = live(conn, "/cart")

      view |> form(ps("locality-form"), %{"q" => String.duplicate("x", 500)}) |> render_change()
      settle(view)

      assert_received {:stub_called, :search_localities, [query]}
      assert String.length(query) == 64
    end

    test "a code over the cap is refused, not cut and not matched", %{conn: conn} do
      # No format to match: only the length stands between the code and the cart.
      stub!(%{
        services: [%Service{key: "branch", destination: :pickup_point, lookup: :manual}]
      })

      {conn, cart, _method} = cart_session(conn)
      {:ok, view, _html} = live(conn, "/cart")

      view
      |> form(ps("manual-form"), %{
        "manual" => %{"locality" => "Poltava", "point" => String.duplicate("9", 5000)}
      })
      |> render_submit()

      assert has_element?(view, ps("manual-form") <> " p.text-error")
      assert Shop.cart_shipping_destination(reload(cart)) == nil
    end

    test "the fields of a form are only its own, each cut", %{conn: conn} do
      stub!(%{services: [manual_branch()]})
      {conn, _cart, _method} = cart_session(conn)
      {:ok, view, _html} = live(conn, "/cart")

      view
      |> element(ps("manual-form"))
      |> render_change(%{
        "manual" => %{"locality" => String.duplicate("a", 600), "point" => "123", "evil" => "x"}
      })

      assert has_element?(
               view,
               ps("manual-locality") <> "[value='#{String.duplicate("a", 255)}']"
             )

      assert has_element?(view, ps("manual-point") <> "[value='123']")
      refute render(view) =~ "evil"
    end
  end

  describe "typed values and the page around the picker" do
    test "survive the page rendering again", %{conn: conn} do
      stub!(%{services: [manual_branch()]})
      {conn, cart, _method} = cart_session(conn)
      {:ok, view, _html} = live(conn, "/cart")

      view
      |> form(ps("manual-form"), %{"manual" => %{"locality" => "Pol", "point" => "123"}})
      |> render_change()

      # The cart changes elsewhere: the page renders again, the picker updates.
      [item] = reload(cart).items
      {:ok, _cart} = Shop.update_cart_item(item, 2)
      settle(view)

      assert has_element?(view, ps("manual-locality") <> "[value='Pol']")
      assert has_element?(view, ps("manual-point") <> "[value='123']")
    end

    test "a locality search keeps its text when the page renders again", %{conn: conn} do
      {conn, cart, _method} = cart_session(conn)
      {:ok, view, _html} = live(conn, "/cart")

      view |> form(ps("locality-form"), %{"q" => "Pol"}) |> render_change()
      settle(view)

      [item] = reload(cart).items
      {:ok, _cart} = Shop.update_cart_item(item, 2)
      settle(view)

      assert has_element?(view, ps("locality-input") <> "[value='Pol']")
      assert has_element?(view, ps("locality-option-L1"))
    end

    test "changing the method while the lookups are out does not trouble the page",
         %{conn: conn} do
      stub!(%{localities: gated_localities(self())})
      {conn, cart, first} = cart_session(conn)
      second = method!([])
      {:ok, view, _html} = live(conn, "/cart")

      view |> form(ps("locality-form"), %{"q" => "Pol"}) |> render_change()
      assert_receive {:locality_search, worker, "Pol"}

      view
      |> element("#cart-shipping-methods input[phx-value-method_uuid='#{second.uuid}']")
      |> render_click()

      send(worker, :answer)
      settle(view)

      assert reload(cart).shipping_method_uuid == second.uuid
      assert has_element?(view, "#shipping-picker-#{second.uuid}")
      refute has_element?(view, "#shipping-picker-#{first.uuid}")
      refute has_element?(view, "[id*='-locality-option-']")
    end
  end

  describe "services that cannot be listed" do
    test "a failure that may pass is a retry, not a refusal", %{conn: conn} do
      {conn, cart, _method} = cart_session(conn, destination: branch("P1"), quoted: true)
      stub!(%{modes: %{services: :crash}})
      {:ok, view, _html} = live(conn, "/cart")

      assert has_element?(view, ps("service-error"))
      assert has_element?(view, ps("service-retry"))
      refute has_element?(view, ps("quote-unavailable"))

      # The carrier is back: the retry brings the picker back too.
      stub!()
      view |> element(ps("service-retry")) |> render_click()
      settle(view)

      refute has_element?(view, ps("service-error"))
      assert has_element?(view, ps("destination-summary"), "Branch 1")
      assert Shop.shipping_quote_status(reload(cart)) in [:ok, :stale, :missing]
    end

    test "the review stays on the review and offers the retry", %{conn: conn} do
      {conn, cart, _method} = cart_session(conn, destination: branch("P1"), quoted: true)
      {:ok, view, _html} = live(conn, "/checkout")
      view |> fill_billing_form(country: "US") |> render_change()
      view |> element("button[phx-click='proceed_to_review']") |> render_click()
      assert has_element?(view, "#checkout-confirm-order:not([disabled])")

      # The quote ages out while the carrier cannot list its services.
      stub!(%{modes: %{services: :crash}})
      age_quote!(cart, 31)
      send(view.pid, {:shipping_selected, reload(cart)})
      settle(view)

      refute has_element?(view, "#checkout-shipping-step")
      assert has_element?(view, "#checkout-review-shipping-blocked")
      assert has_element?(view, "#checkout-review-retry-shipping")
      assert has_element?(view, "#checkout-confirm-order[disabled]")

      stub!()
      view |> element("#checkout-review-retry-shipping") |> render_click()
      settle(view)

      assert has_element?(view, "#checkout-confirm-order:not([disabled])")
      assert Shop.shipping_quote_status(reload(cart)) == :ok
    end
  end

  describe "the total while the delivery is not settled" do
    test "the cart page says it is an estimate", %{conn: conn} do
      {conn, _cart, _method} = cart_session(conn, destination: branch("P1"))
      stub!(%{quote: gated_quote(self())})
      {:ok, view, _html} = live(conn, "/cart")

      assert_receive {:quote_waiting, worker}
      assert has_element?(view, "#cart-summary-shipping", "To be calculated")
      assert has_element?(view, "#cart-summary-total-estimate")

      send(worker, :answer)
      settle(view)

      refute has_element?(view, "#cart-summary-total-estimate")
      assert has_element?(view, "#cart-summary-shipping", "100")
    end

    test "a method the carrier refuses reads not available", %{conn: conn} do
      stub!(%{quote: {:error, :too_heavy}})
      {conn, _cart, _method} = cart_session(conn, destination: branch("P1"))
      {:ok, view, _html} = live(conn, "/cart")
      settle(view)

      assert has_element?(view, "#cart-summary-shipping", "Not available")
      refute has_element?(view, "#cart-summary-total-estimate")
    end

    test "a free method that fell back to its price does not claim an estimate",
         %{conn: conn} do
      stub!(%{quote: {:error, :timeout}})
      {conn, cart, method} = cart_session(conn, destination: branch("P1"))

      {:ok, _method} =
        Shop.update_shipping_method(method, %{"free_above_amount" => "10"})

      {:ok, view, _html} = live(conn, "/cart")
      settle(view)

      assert Shop.shipping_quote_status(reload(cart)) == :fallback
      assert has_element?(view, ps("quote-price"), "FREE")
      refute has_element?(view, ps("quote-fallback"))
    end
  end

  # -- the checkout -----------------------------------------------------

  describe "checkout" do
    test "the shipping step has the picker; continue waits for a settled price",
         %{conn: conn} do
      stub!(%{services: [manual_branch()]})
      {conn, _cart, method} = cart_session(conn)
      {:ok, view, _html} = live(conn, "/checkout")

      to_shipping_step(view)

      assert has_element?(view, "#checkout-shipping-step #shipping-picker-#{method.uuid}")
      assert has_element?(view, "#checkout-shipping-continue[disabled]")
      assert has_element?(view, "#checkout-summary-shipping", "To be calculated")

      view
      |> form(ps("manual-form"), %{
        "manual" => %{"locality" => "Poltava", "point" => "36000"}
      })
      |> render_submit()

      settle(view)

      assert has_element?(view, ps("quote-price"), "100")
      refute has_element?(view, "#checkout-shipping-continue[disabled]")
      assert has_element?(view, "#checkout-summary-shipping", "100")

      view |> element("#checkout-shipping-continue") |> render_click()

      # The review shows where it goes, when, and the carrier's fee.
      assert has_element?(view, "#checkout-review-shipping-destination", "Poltava")
      assert has_element?(view, "#checkout-review-shipping-eta")
      assert has_element?(view, "#checkout-review-shipping-cod-fee", "20")
      assert has_element?(view, "#checkout-confirm-order:not([disabled])")
      refute has_element?(view, "#checkout-review-shipping-blocked")
    end

    test "a method the carrier cannot serve keeps the shopper on the step", %{conn: conn} do
      stub!(%{services: [manual_branch()], quote: {:error, :too_heavy}})
      {conn, cart, _method} = cart_session(conn)
      {:ok, view, _html} = live(conn, "/checkout")

      to_shipping_step(view)

      view
      |> form(ps("manual-form"), %{
        "manual" => %{"locality" => "Poltava", "point" => "36000"}
      })
      |> render_submit()

      settle(view)

      assert has_element?(view, ps("quote-unavailable"))
      assert has_element?(view, "#checkout-shipping-continue[disabled]")
      assert has_element?(view, "#checkout-summary-shipping", "Not available")
      refute has_element?(view, "#checkout-summary-total-estimate")

      # Even a click that was not offered moves nothing.
      render_click(view, "shipping_continue", %{})
      assert has_element?(view, "#checkout-shipping-step")
      refute has_element?(view, "#checkout-confirm-order")
      assert Shop.shipping_quote_status(reload(cart)) == :unavailable
    end

    test "a method picked on the cart page without a place is finished at checkout",
         %{conn: conn} do
      stub!(%{services: [manual_branch()]})
      {conn, _cart, method} = cart_session(conn)
      {:ok, view, _html} = live(conn, "/checkout")

      view |> fill_billing_form(country: "US") |> render_change()
      view |> element("button[phx-click='proceed_to_review']") |> render_click()

      # Not the review: the cart has no place to deliver to.
      assert has_element?(view, "#checkout-shipping-step")
      assert has_element?(view, "#shipping-picker-#{method.uuid}")
      refute has_element?(view, "#checkout-confirm-order")
    end

    test "the order is placed at the quoted price and the confirmation shows where it goes",
         %{conn: conn} do
      stub!(%{services: [manual_branch()]})
      {conn, cart, _method} = cart_session(conn)
      {:ok, view, _html} = live(conn, "/checkout")

      to_shipping_step(view)

      view
      |> form(ps("manual-form"), %{
        "manual" => %{"locality" => "Poltava", "point" => "36000"}
      })
      |> render_submit()

      settle(view)
      view |> element("#checkout-shipping-continue") |> render_click()
      view |> element("#checkout-confirm-order") |> render_click()

      {path, _flash} = assert_redirect(view)
      assert path =~ "/checkout/complete/"

      order_uuid = path |> String.split("/") |> List.last()
      {:ok, complete, _html} = live(conn, "/checkout/complete/#{order_uuid}")

      assert has_element?(complete, "#order-shipping-destination", "Poltava")
      assert has_element?(complete, "#order-shipping-eta")
      assert has_element?(complete, "#order-shipping-cod-fee", "20")
      refute has_element?(complete, "#order-shipping-fallback")

      order = Billing.get_order_by_uuid(order_uuid)
      assert order.metadata["shipping_provider"] == %{"provider" => "stub", "service" => "branch"}
      assert reload(cart).status == "converted"
    end

    test "a price that went stale on the review is renewed without a click", %{conn: conn} do
      {conn, cart, _method} = cart_session(conn, destination: branch("P1"), quoted: true)
      {:ok, view, _html} = live(conn, "/checkout")

      view |> fill_billing_form(country: "US") |> render_change()
      view |> element("button[phx-click='proceed_to_review']") |> render_click()

      # The cart is settled: straight to the review.
      assert has_element?(view, "#checkout-confirm-order:not([disabled])")
      stub!(%{quote: gated_quote(self())})

      # Time passes: the carrier's answer ages out.
      age_quote!(cart, 31)
      send(view.pid, {:shipping_selected, reload(cart)})
      _ = :sys.get_state(view.pid)

      # The carrier is asked, and nothing can be confirmed until it answers.
      assert_receive {:quote_waiting, worker}
      assert has_element?(view, "#checkout-review-shipping-requoting")
      assert has_element?(view, "#checkout-confirm-order[disabled]")

      send(worker, :answer)
      settle(view)

      assert quote_calls() == 1
      refute has_element?(view, "#checkout-review-shipping-requoting")
      refute has_element?(view, "#checkout-review-shipping-blocked")
      assert has_element?(view, "#checkout-confirm-order:not([disabled])")
      assert Shop.shipping_quote_status(reload(cart)) == :ok
    end

    test "a new payment option renews the price, which depends on cash on delivery",
         %{conn: conn} do
      stripe = ensure_payment_option("stripe", requires_billing_profile: false)
      {conn, cart, _method} = cart_session(conn, destination: branch("P1"), quoted: true)
      {:ok, view, _html} = live(conn, "/checkout")

      view |> fill_billing_form(country: "US") |> render_change()
      view |> element("button[phx-click='proceed_to_review']") |> render_click()
      assert has_element?(view, "#checkout-confirm-order:not([disabled])")
      flush_quote_calls()

      # Back to the payment step, an option that is not cash on delivery.
      view |> element("button[phx-click='back_to_payment']") |> render_click()
      view |> element("input[phx-value-option_uuid='#{stripe.uuid}']") |> render_click()
      view |> element("button[phx-click='proceed_to_billing']") |> render_click()

      assert Shop.shipping_quote_status(reload(cart)) == :stale

      stub!(%{quote: gated_quote(self())})
      view |> element("button[phx-click='proceed_to_review']") |> render_click()

      # Not the shipping step: the place is known, only the price is renewed.
      refute has_element?(view, "#checkout-shipping-step")
      assert_receive {:quote_waiting, worker}
      assert has_element?(view, "#checkout-review-shipping-requoting")
      assert has_element?(view, "#checkout-confirm-order[disabled]")

      send(worker, :answer)
      settle(view)

      assert_received {:stub_called, :quote, [request]}
      assert request.cod_amount == nil
      assert Shop.shipping_quote_status(reload(cart)) == :ok
      assert has_element?(view, "#checkout-confirm-order:not([disabled])")
    end

    test "confirming a price that went stale renews it first and orders nothing",
         %{conn: conn} do
      {conn, cart, _method} = cart_session(conn, destination: branch("P1"), quoted: true)
      {:ok, view, _html} = live(conn, "/checkout")

      view |> fill_billing_form(country: "US") |> render_change()
      view |> element("button[phx-click='proceed_to_review']") |> render_click()
      assert has_element?(view, "#checkout-confirm-order:not([disabled])")
      stub!(%{quote: gated_quote(self())})

      # The page does not know yet: the click arrives for a stale cart.
      age_quote!(cart, 31)
      render_click(view, "confirm_order", %{})

      assert_receive {:quote_waiting, worker}
      assert has_element?(view, "#checkout-confirm-order[disabled]")
      assert reload(cart).status == "active"

      send(worker, :answer)
      settle(view)

      assert reload(cart).status == "active"
      assert Shop.shipping_quote_status(reload(cart)) == :ok
      assert has_element?(view, "#checkout-confirm-order:not([disabled])")

      # The next click places the order.
      view |> element("#checkout-confirm-order") |> render_click()
      {path, _flash} = assert_redirect(view)
      assert path =~ "/checkout/complete/"
    end

    test "a carrier whose quotes are expired on arrival is asked at most three times",
         %{conn: conn} do
      {conn, cart, _method} = cart_session(conn, destination: branch("P1"), quoted: true)
      {:ok, view, _html} = live(conn, "/checkout")
      view |> fill_billing_form(country: "US") |> render_change()
      view |> element("button[phx-click='proceed_to_review']") |> render_click()
      assert has_element?(view, "#checkout-confirm-order:not([disabled])")

      expired = fn _request, ctx ->
        {:ok,
         %Quote{
           amount: Decimal.new(100),
           currency: ctx.currency,
           expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
         }}
      end

      stub!(%{quote: expired})
      age_quote!(cart, 31)
      send(view.pid, {:shipping_selected, reload(cart)})

      for _round <- 1..6 do
        settle(view)
        send(view.pid, {:shipping_selected, reload(cart)})
      end

      settle(view)

      assert quote_calls() <= 3
      assert has_element?(view, "#checkout-review-shipping-blocked")
      assert has_element?(view, "#checkout-confirm-order[disabled]")
      refute has_element?(view, "#checkout-review-shipping-requoting")
    end

    test "an estimated price that aged out is renewed on the review as well", %{conn: conn} do
      stub!(%{quote: {:error, :timeout}})
      {conn, cart, _method} = cart_session(conn, destination: branch("P1"), quoted: true)
      assert Shop.shipping_quote_status(reload(cart)) == :fallback

      {:ok, view, _html} = live(conn, "/checkout")
      view |> fill_billing_form(country: "US") |> render_change()
      view |> element("button[phx-click='proceed_to_review']") |> render_click()

      # An estimate does not stop the order...
      assert has_element?(view, "#checkout-confirm-order:not([disabled])")
      assert has_element?(view, "#checkout-review-shipping-fallback")

      # ...until two minutes pass: then the carrier is asked again.
      stub!()
      age_quote!(cart, 3)
      send(view.pid, {:shipping_selected, reload(cart)})
      settle(view)

      assert quote_calls() == 1
      assert Shop.shipping_quote_status(reload(cart)) == :ok
      refute has_element?(view, "#checkout-review-shipping-fallback")
      assert has_element?(view, "#checkout-confirm-order:not([disabled])")
    end

    test "a place the carrier turns down sends the review back to the shipping step",
         %{conn: conn} do
      {conn, cart, _method} = cart_session(conn, destination: branch("P1"), quoted: true)
      {:ok, view, _html} = live(conn, "/checkout")

      view |> fill_billing_form(country: "US") |> render_change()
      view |> element("button[phx-click='proceed_to_review']") |> render_click()

      # The method can no longer serve this cart (the carrier's word).
      stub!(%{quote: {:error, :too_heavy}})
      age_quote!(cart, 31)
      send(view.pid, {:shipping_selected, reload(cart)})
      settle(view)

      assert Shop.shipping_quote_status(reload(cart)) == :unavailable
      assert has_element?(view, "#checkout-confirm-order[disabled]")
      assert has_element?(view, "#checkout-review-shipping-blocked")

      view |> element("#checkout-review-recheck-shipping") |> render_click()

      assert has_element?(view, "#checkout-shipping-step")
      assert has_element?(view, ps("quote-unavailable"))
      assert has_element?(view, "#checkout-shipping-continue[disabled]")
    end
  end

  # -- the order pages --------------------------------------------------

  describe "order confirmation" do
    test "shows where the parcel goes, the delivery time and the carrier's fee", %{conn: conn} do
      {conn, cart, _method} = cart_session(conn, destination: branch("P1"))
      {:ok, cart} = Shop.quote_cart_shipping(cart)

      {:ok, order} =
        Shop.convert_cart_to_order(cart, billing_data: complete_billing("US", "picker-complete"))

      {:ok, view, _html} = live(conn, "/checkout/complete/#{order.uuid}")

      assert has_element?(view, "#order-line-shipping #order-shipping-destination", "Poltava")
      assert has_element?(view, "#order-line-shipping #order-shipping-destination", "Branch 1")
      assert has_element?(view, "#order-shipping-eta")
      assert has_element?(view, "#order-shipping-cod-fee", "20")
    end

    test "an estimated price is marked as such", %{conn: conn} do
      stub!(%{quote: {:error, :timeout}})
      {conn, cart, _method} = cart_session(conn, destination: branch("P1"))
      {:ok, cart} = Shop.quote_cart_shipping(cart)

      {:ok, order} =
        Shop.convert_cart_to_order(cart, billing_data: complete_billing("US", "picker-fallback"))

      {:ok, view, _html} = live(conn, "/checkout/complete/#{order.uuid}")

      assert has_element?(view, "#order-shipping-fallback")
    end

    test "an ordinary method's line carries no carrier details", %{conn: conn} do
      session_id = "picker-plain-#{System.unique_integer([:positive])}"

      {:ok, method} =
        Shop.create_shipping_method(%{
          "name" => "Plain #{System.unique_integer([:positive])}",
          "price" => "5.00",
          "active" => true
        })

      {:ok, cart} = Shop.create_cart(session_id: session_id)
      {:ok, cart} = Shop.add_to_cart(cart, physical_product!(), 1)
      {:ok, cart} = Shop.set_cart_shipping(cart, method, "US")

      {:ok, order} =
        Shop.convert_cart_to_order(cart, billing_data: complete_billing("US", "picker-plain"))

      conn =
        Plug.Test.init_test_session(conn, %{
          "shop_session_id" => session_id,
          "shop_session_trusted" => true
        })

      {:ok, view, _html} = live(conn, "/checkout/complete/#{order.uuid}")

      assert has_element?(view, "#order-line-shipping")
      refute has_element?(view, "#order-shipping-details")
    end
  end

  # -- helpers ----------------------------------------------------------

  defp stub!(overrides \\ %{}) do
    flush_quote_calls()

    StubProvider.put(
      Map.merge(
        %{
          notify: self(),
          localities: fn _query -> {:ok, [@poltava, @kyiv]} end,
          points: &points/3,
          quote: &quote_of/2
        },
        overrides
      )
    )
  end

  # A component socket that is not mounted: for the handlers that need no page.
  defp socket_with(assigns) do
    %Phoenix.LiveView.Socket{assigns: Map.merge(%{__changed__: %{}}, assigns)}
  end

  # A city search that waits for the test.
  defp gated_localities(test) do
    fn query ->
      send(test, {:locality_search, self(), query})

      receive do
        :answer -> {:ok, [@poltava, @kyiv]}
      end
    end
  end

  defp current_cart(view), do: :sys.get_state(view.pid).socket.assigns.cart
  defp reload_cart_of(view), do: reload(current_cart(view))

  defp count_calls(operation, count \\ 0) do
    receive do
      {:stub_called, ^operation, _args} -> count_calls(operation, count + 1)
    after
      0 -> count
    end
  end

  defp flush_calls(operation) do
    count_calls(operation)
    :ok
  end

  defp points(_locality, _service, query) do
    all = [
      %PickupPoint{
        id: "P1",
        number: "1",
        name: "Branch 1",
        address: "Soborna 1",
        kind: :branch
      },
      %PickupPoint{
        id: "P2",
        number: "2",
        name: "Locker 2",
        address: "Soborna 2",
        kind: :locker
      },
      %PickupPoint{
        id: "P3",
        number: "3",
        name: "Tiny 3",
        address: "Soborna 3",
        kind: :locker,
        limits: %{max_weight_g: 100, max_dims_mm: nil, max_declared: nil}
      }
    ]

    {:ok,
     Enum.filter(all, fn point ->
       is_nil(query) or
         String.contains?(
           String.downcase(point.name <> " " <> point.address),
           String.downcase(query)
         )
     end)}
  end

  defp quote_of(_request, ctx) do
    {:ok,
     %Quote{
       amount: Decimal.new(100),
       currency: ctx.currency,
       cod_fee: Decimal.new(20),
       eta: %{min_days: 1, max_days: 2, date: nil},
       source: :api
     }}
  end

  # A quote that waits for the test: the worker announces itself and answers
  # when told to.
  defp gated_quote(test) do
    fn request, ctx ->
      send(test, {:quote_waiting, self()})

      receive do
        :answer -> quote_of(request, ctx)
      end
    end
  end

  defp manual_branch do
    %Service{
      key: "branch",
      label: "To a branch",
      destination: :pickup_point,
      lookup: :manual,
      point_code_label: "Branch index",
      point_code_format: "[0-9]{5}"
    }
  end

  defp courier(lookup),
    do: %Service{key: "courier", label: "Courier", destination: :address, lookup: lookup}

  defp branch(id),
    do: %Destination{
      locality: @poltava,
      pickup_point: %PickupPoint{id: id, name: "Branch #{id |> String.trim_leading("P")}"}
    }

  # A guest session whose cart holds a shippable item and the stub method
  # (no markup, so the price shown is the carrier's); optionally the place.
  defp cart_session(conn, opts \\ []) do
    method = method!(opts)
    session_id = "picker-#{System.unique_integer([:positive])}"

    {:ok, cart} = Shop.create_cart(session_id: session_id)
    {:ok, cart} = Shop.add_to_cart(cart, physical_product!(), 1)
    {:ok, cart} = Shop.set_cart_shipping(cart, method, "US")

    # Cash on delivery is the one option a fresh database has active: the
    # checkout would pick it by itself, and the quote depends on it.
    {:ok, cart} = Shop.set_cart_payment_option(cart, ensure_payment_option("cod"))

    cart =
      case Keyword.get(opts, :destination) do
        nil ->
          cart

        destination ->
          {:ok, cart} = Shop.set_cart_shipping_destination(cart, destination)
          cart
      end

    cart =
      if opts[:quoted] do
        {:ok, cart} = Shop.quote_cart_shipping(cart)
        flush_quote_calls()
        cart
      else
        cart
      end

    session = %{"shop_session_id" => session_id, "shop_session_trusted" => true}
    Process.put(:picker_id, "shipping-picker-#{method.uuid}")
    {Plug.Test.init_test_session(conn, session), cart, method}
  end

  defp method!(opts) do
    {:ok, method} =
      Shop.create_shipping_method(%{
        "name" => "Carrier #{System.unique_integer([:positive])}",
        "price" => "7.00",
        "pay_on_delivery" => Keyword.get(opts, :pay_on_delivery, false),
        "active" => true,
        "shipping_provider" => %{
          "provider" => Keyword.get(opts, :provider, "stub"),
          "service" => Keyword.get(opts, :service, "branch"),
          "settings" => %{"sender_city" => %{"id" => "c1", "name" => "Poltava"}},
          "pricing" => %{"markup_percent" => "0", "markup_fixed" => "0", "round_to" => "1"}
        }
      })

    method
  end

  defp physical_product! do
    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Picker Widget #{System.unique_integer([:positive])}"},
        "price" => Decimal.new("25.00"),
        "status" => "active",
        "currency" => "USD",
        "product_type" => "physical",
        "requires_shipping" => true,
        "weight_grams" => 500
      })

    product
  end

  defp reload(cart), do: Shop.get_cart!(cart.uuid)

  # The selector of an element inside the picker of the last `cart_session`.
  defp ps(suffix), do: "##{Process.get(:picker_id)}-#{suffix}"

  # The view has caught up with everything in flight: the events the picker
  # raised, the broadcasts they caused, the carrier's answers.
  defp settle(view) do
    for _round <- 1..2 do
      _ = :sys.get_state(view.pid)
      render_async(view)
    end

    :ok
  end

  # Billing filled, on to the shipping step (the cart has no place yet).
  defp to_shipping_step(view) do
    view |> fill_billing_form(country: "US") |> render_change()
    view |> element("button[phx-click='proceed_to_review']") |> render_click()
    assert has_element?(view, "#checkout-shipping-step")
  end

  # The stored quote was fetched `minutes` ago.
  defp age_quote!(cart, minutes) do
    cart = reload(cart)
    fetched = DateTime.utc_now() |> DateTime.add(-minutes * 60, :second) |> DateTime.to_iso8601()
    entry = Map.put(cart.metadata["shipping_quote"], "fetched_at", fetched)

    cart
    |> Cart.changeset(%{metadata: Map.put(cart.metadata, "shipping_quote", entry)})
    |> Repo.update!()
  end

  defp quote_calls(count \\ 0) do
    receive do
      {:stub_called, :quote, _args} -> quote_calls(count + 1)
    after
      0 -> count
    end
  end

  defp flush_quote_calls do
    quote_calls()
    :ok
  end

  defp ensure_payment_option(code, attrs \\ []) do
    attrs = attrs |> Keyword.put(:active, true) |> Map.new(fn {k, v} -> {to_string(k), v} end)

    case Billing.get_payment_option_by_code(code) do
      nil ->
        {:ok, option} =
          Billing.create_payment_option(
            Map.merge(attrs, %{"name" => code, "code" => code, "type" => "offline"})
          )

        option

      option ->
        {:ok, option} = Billing.update_payment_option(option, attrs)
        option
    end
  end
end
