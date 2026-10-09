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

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, previous),
        else: Application.delete_env(:phoenix_kit_ecommerce, :shipping_providers)
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

      picker = "#shipping-picker-#{method.uuid}"
      assert has_element?(view, picker)
      assert has_element?(view, "#shipping-locality-input")
      refute has_element?(view, "#shipping-quote")

      # Typing in the city input searches the carrier (debounced in the browser).
      view |> form("#shipping-locality-form", %{"q" => "Pol"}) |> render_change()
      render_async(view)

      assert has_element?(view, "#shipping-locality-results #shipping-locality-option-L1")

      view |> element("#shipping-locality-option-L1") |> render_click()
      render_async(view)

      # The city is on the cart, the points of the city are listed.
      assert %Destination{locality: %Locality{id: "L1"}} =
               cart |> reload() |> Shop.cart_shipping_destination()

      assert has_element?(view, "#shipping-locality-selected", "Poltava")
      assert has_element?(view, "#shipping-points #shipping-point-P1")
      assert has_element?(view, "#shipping-points #shipping-point-P2")

      # The filter narrows the list.
      view |> form("#shipping-points-form", %{"q" => "locker"}) |> render_change()
      render_async(view)

      refute has_element?(view, "#shipping-point-P1")
      assert has_element?(view, "#shipping-point-P2")

      view |> element("#shipping-point-P2") |> render_click()
      render_async(view)

      assert has_element?(view, "#shipping-destination-summary", "Poltava")
      assert has_element?(view, "#shipping-destination-summary", "Locker 2")
      refute has_element?(view, "#shipping-editor")

      assert has_element?(view, "#shipping-quote-price", "100")
      assert has_element?(view, "#shipping-quote-eta")
      assert has_element?(view, "#shipping-quote-cod-fee", "20")
      refute has_element?(view, "#shipping-quote-fallback")
      refute has_element?(view, "#shipping-quote-unavailable")

      # The page totals followed the quote (the parent heard of the change).
      assert has_element?(view, "#cart-summary-shipping", "100")

      cart = reload(cart)
      assert Shop.shipping_quote_status(cart) == :ok
      assert %PickupPoint{id: "P2"} = Shop.cart_shipping_destination(cart).pickup_point
    end

    test "points that cannot take the parcel of the cart are not offered", %{conn: conn} do
      {conn, cart, _method} = cart_session(conn)
      {:ok, view, _html} = live(conn, "/cart")

      view |> form("#shipping-locality-form", %{"q" => "Pol"}) |> render_change()
      render_async(view)
      view |> element("#shipping-locality-option-L1") |> render_click()
      render_async(view)

      assert_received {:stub_called, :list_pickup_points, [%Locality{id: "L1"}, _service, nil]}
      assert Decimal.equal?(Shop.cart_declared_value(cart), Decimal.new("25"))

      # The cart weighs 500 g; the third point takes 100 g.
      assert has_element?(view, "#shipping-point-P1")
      refute has_element?(view, "#shipping-point-P3")
    end

    test "the change button reopens the editor on the same city", %{conn: conn} do
      {conn, _cart, _method} = cart_session(conn, destination: branch("P1"))
      {:ok, view, _html} = live(conn, "/cart")
      render_async(view)

      assert has_element?(view, "#shipping-destination-summary", "Branch 1")
      refute has_element?(view, "#shipping-editor")

      view |> element("#shipping-change") |> render_click()
      render_async(view)

      assert has_element?(view, "#shipping-editor")
      assert has_element?(view, "#shipping-locality-selected", "Poltava")
      assert has_element?(view, "#shipping-point-P2")

      # Cancelling keeps what the cart has.
      view |> element("#shipping-cancel-change") |> render_click()
      assert has_element?(view, "#shipping-destination-summary", "Branch 1")
    end

    test "a failing city search is an inline message, not a crash", %{conn: conn} do
      stub!(%{localities: {:error, :timeout}})
      {conn, _cart, _method} = cart_session(conn)
      {:ok, view, _html} = live(conn, "/cart")

      view |> form("#shipping-locality-form", %{"q" => "Pol"}) |> render_change()
      render_async(view)

      assert has_element?(view, "#shipping-locality-results p.text-error")
      refute has_element?(view, "[id^='shipping-locality-option-']")
      assert has_element?(view, "#shipping-locality-input")
    end

    test "failing points are an inline message with a retry", %{conn: conn} do
      stub!(%{points: {:error, {:http, 500}}})
      {conn, _cart, _method} = cart_session(conn, destination: %Destination{locality: @poltava})
      {:ok, view, _html} = live(conn, "/cart")
      render_async(view)

      assert has_element?(view, "#shipping-points p.text-error")
      assert has_element?(view, "#shipping-points-retry")

      stub!()
      view |> element("#shipping-points-retry") |> render_click()
      render_async(view)

      assert has_element?(view, "#shipping-point-P1")
    end
  end

  describe "cart page: typed in" do
    test "a pickup point by its code: checks the format, then quotes", %{conn: conn} do
      stub!(%{services: [manual_branch()]})
      {conn, cart, _method} = cart_session(conn)
      {:ok, view, _html} = live(conn, "/cart")

      assert has_element?(view, "#shipping-manual-form")
      assert has_element?(view, "#shipping-manual-point[pattern='[0-9]{5}']")
      refute has_element?(view, "#shipping-locality-input")

      view
      |> form("#shipping-manual-form", %{"manual" => %{"locality" => "Poltava", "point" => "12"}})
      |> render_submit()

      assert has_element?(view, "#shipping-manual-form")
      assert has_element?(view, "#shipping-manual-form p.text-error")
      refute has_element?(view, "#shipping-quote")

      view
      |> form("#shipping-manual-form", %{
        "manual" => %{"locality" => "Poltava", "point" => "36000"}
      })
      |> render_submit()

      render_async(view)

      refute has_element?(view, "#shipping-manual-form")
      assert has_element?(view, "#shipping-destination-summary", "Poltava")
      assert has_element?(view, "#shipping-quote-price", "100")

      destination = cart |> reload() |> Shop.cart_shipping_destination()
      assert %Locality{name: "Poltava", id: nil} = destination.locality
      assert %PickupPoint{id: "36000", extra: %{"manual" => "true"}} = destination.pickup_point
    end

    test "an address after a city search", %{conn: conn} do
      stub!(%{services: [courier(:search)]})
      {conn, cart, _method} = cart_session(conn, service: "courier")
      {:ok, view, _html} = live(conn, "/cart")

      refute has_element?(view, "#shipping-address-form")

      view |> form("#shipping-locality-form", %{"q" => "Pol"}) |> render_change()
      render_async(view)
      view |> element("#shipping-locality-option-L1") |> render_click()

      assert has_element?(view, "#shipping-address-form")
      refute has_element?(view, "#shipping-address-locality")

      # A street and a house are what an address needs.
      view
      |> form("#shipping-address-form", %{"address" => %{"street" => "", "house" => ""}})
      |> render_submit()

      assert has_element?(view, "#shipping-address-form p.text-error")

      view
      |> form("#shipping-address-form", %{
        "address" => %{
          "street" => "Soborna",
          "house" => "7",
          "apartment" => "12",
          "postcode" => "36000"
        }
      })
      |> render_submit()

      render_async(view)

      assert has_element?(view, "#shipping-destination-summary", "Soborna 7 12")
      assert has_element?(view, "#shipping-quote-price", "100")

      destination = cart |> reload() |> Shop.cart_shipping_destination()
      assert destination.locality.id == "L1"

      assert %{street: "Soborna", house: "7", apartment: "12", postcode: "36000"} =
               destination.address
    end

    test "an address typed in whole needs the city and the postcode", %{conn: conn} do
      stub!(%{services: [courier(:manual)]})
      {conn, _cart, _method} = cart_session(conn, service: "courier")
      {:ok, view, _html} = live(conn, "/cart")

      assert has_element?(view, "#shipping-address-locality")
      refute has_element?(view, "#shipping-locality-input")

      view
      |> form("#shipping-address-form", %{
        "address" => %{"street" => "Soborna", "house" => "7", "locality" => "", "postcode" => ""}
      })
      |> render_submit()

      assert has_element?(view, "#shipping-address-form p.text-error")
      refute has_element?(view, "#shipping-quote")

      view
      |> form("#shipping-address-form", %{
        "address" => %{
          "street" => "Soborna",
          "house" => "7",
          "locality" => "Poltava",
          "postcode" => "36000"
        }
      })
      |> render_submit()

      render_async(view)

      assert has_element?(view, "#shipping-destination-summary", "Poltava")
      assert has_element?(view, "#shipping-quote-price", "100")
    end

    test "a point the carrier refuses sends the shopper back to the editor", %{conn: conn} do
      Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, [
        StubProvider,
        RejectingProvider
      ])

      {conn, cart, _method} = cart_session(conn, provider: "rejecting")
      {:ok, view, _html} = live(conn, "/cart")

      view
      |> form("#shipping-manual-form", %{
        "manual" => %{"locality" => "Poltava", "point" => "00000"}
      })
      |> render_submit()

      render_async(view)

      assert has_element?(view, "#shipping-destination-rejected")
      assert has_element?(view, "#shipping-manual-form")
      refute has_element?(view, "#shipping-quote-price")
      assert Shop.shipping_quote_status(reload(cart)) == :needs_destination

      view
      |> form("#shipping-manual-form", %{
        "manual" => %{"locality" => "Poltava", "point" => "36000"}
      })
      |> render_submit()

      render_async(view)

      refute has_element?(view, "#shipping-destination-rejected")
      assert has_element?(view, "#shipping-quote-price", "20")
    end

    test "a service that asks for nothing is quoted straight away", %{conn: conn} do
      stub!(%{services: [%Service{key: "plain", label: "Plain", destination: :none}]})
      {conn, cart, _method} = cart_session(conn, service: "plain")
      {:ok, view, _html} = live(conn, "/cart")
      render_async(view)

      refute has_element?(view, "#shipping-editor")
      refute has_element?(view, "#shipping-destination-summary")
      assert has_element?(view, "#shipping-quote-price", "100")
      assert Shop.shipping_quote_status(reload(cart)) == :ok
    end
  end

  describe "the quote" do
    test "an answer that cannot be had falls back to the price of the method, flagged",
         %{conn: conn} do
      stub!(%{quote: {:error, :timeout}})
      {conn, cart, _method} = cart_session(conn, destination: branch("P1"))
      {:ok, view, _html} = live(conn, "/cart")
      render_async(view)

      assert has_element?(view, "#shipping-quote-fallback")
      assert has_element?(view, "#shipping-quote-price", "7.00")
      refute has_element?(view, "#shipping-quote-unavailable")
      assert Shop.shipping_quote_status(reload(cart)) == :fallback
    end

    test "a carrier that refuses the cart makes the method unavailable, with the reason",
         %{conn: conn} do
      stub!(%{quote: {:error, :too_heavy}})
      {conn, cart, _method} = cart_session(conn, destination: branch("P1"))
      {:ok, view, _html} = live(conn, "/cart")
      render_async(view)

      assert has_element?(view, "#shipping-quote-unavailable")
      refute has_element?(view, "#shipping-quote-price")
      assert Shop.shipping_quote_status(reload(cart)) == :unavailable
    end

    test "a provider that is no longer configured is not available for this order",
         %{conn: conn} do
      {conn, _cart, _method} = cart_session(conn, destination: branch("P1"))
      Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, [])

      {:ok, view, _html} = live(conn, "/cart")

      assert has_element?(view, "#shipping-service-error #shipping-quote-unavailable")
      refute has_element?(view, "#shipping-editor")
    end

    test "a pay-on-delivery method shows the estimate the buyer pays the carrier",
         %{conn: conn} do
      {conn, _cart, _method} =
        cart_session(conn, destination: branch("P1"), pay_on_delivery: true)

      {:ok, view, _html} = live(conn, "/cart")
      render_async(view)

      price = view |> element("#shipping-quote-price") |> render()
      assert price =~ "100"
      assert price =~ "carrier"
      assert has_element?(view, "#shipping-quote-cod-fee", "20")
    end

    test "a quote that is out of date is asked for again, once", %{conn: conn} do
      {conn, cart, _method} = cart_session(conn, destination: branch("P1"))
      {:ok, view, _html} = live(conn, "/cart")
      render_async(view)

      assert_received {:stub_called, :quote, _}
      refute_received {:stub_called, :quote, _}

      # A bigger order is a different request: the old quote is stale.
      [item] = reload(cart).items
      {:ok, _cart} = Shop.update_cart_item(item, 3)
      _ = render(view)
      render_async(view)

      assert_received {:stub_called, :quote, [request]}
      assert Decimal.equal?(request.declared_value, Decimal.new("75"))
      assert has_element?(view, "#shipping-quote-price", "100")
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
        render_async(view)
        _ = render(view)
      end

      assert Shop.shipping_quote_status(reload(cart)) == :stale
      assert has_element?(view, "#shipping-quote-retry")
      assert quote_calls() <= 3
    end

    test "the cart's status can always be renewed by hand", %{conn: conn} do
      stub!(%{quote: {:error, :timeout}})
      {conn, _cart, _method} = cart_session(conn, destination: branch("P1"))
      {:ok, view, _html} = live(conn, "/cart")
      render_async(view)

      assert has_element?(view, "#shipping-quote-fallback")
      flush_quote_calls()

      stub!()
      view |> element("#shipping-quote-retry") |> render_click()
      render_async(view)

      assert quote_calls() == 1
      refute has_element?(view, "#shipping-quote-fallback")
      assert has_element?(view, "#shipping-quote-price", "100")
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
      |> form("#shipping-manual-form", %{
        "manual" => %{"locality" => "Poltava", "point" => "36000"}
      })
      |> render_submit()

      render_async(view)

      assert has_element?(view, "#shipping-quote-price", "100")
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
      |> form("#shipping-manual-form", %{
        "manual" => %{"locality" => "Poltava", "point" => "36000"}
      })
      |> render_submit()

      render_async(view)

      assert has_element?(view, "#shipping-quote-unavailable")
      assert has_element?(view, "#checkout-shipping-continue[disabled]")

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
      |> form("#shipping-manual-form", %{
        "manual" => %{"locality" => "Poltava", "point" => "36000"}
      })
      |> render_submit()

      render_async(view)
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
      render_async(view)

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
      render_async(view)

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
      render_async(view)

      assert reload(cart).status == "active"
      assert Shop.shipping_quote_status(reload(cart)) == :ok
      assert has_element?(view, "#checkout-confirm-order:not([disabled])")

      # The next click places the order.
      view |> element("#checkout-confirm-order") |> render_click()
      {path, _flash} = assert_redirect(view)
      assert path =~ "/checkout/complete/"
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
      render_async(view)

      assert Shop.shipping_quote_status(reload(cart)) == :unavailable
      assert has_element?(view, "#checkout-confirm-order[disabled]")
      assert has_element?(view, "#checkout-review-shipping-blocked")

      view |> element("#checkout-review-recheck-shipping") |> render_click()

      assert has_element?(view, "#checkout-shipping-step")
      assert has_element?(view, "#shipping-quote-unavailable")
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
