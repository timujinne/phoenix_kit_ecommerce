defmodule PhoenixKitEcommerce.Web.CheckoutShippingStepTest do
  @moduledoc """
  The checkout-time shipping step (`shop_shipping_selection_position: "checkout"`):
  it only appears after billing, filters methods by the billing country just
  captured, and honors `shop_shipping_skip_mode` the same way the conversion
  context does (`PhoenixKitEcommerce.ConvertSkipShippingTest` covers that side).
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitEcommerce, as: Shop

  test "position=checkout: shipping step appears after billing with country-filtered methods",
       %{conn: conn} do
    PhoenixKit.Settings.update_setting_with_module(
      "shop_shipping_selection_position",
      "checkout",
      "shop"
    )

    # Covers "EE" only - the billing form below uses that country, so the
    # step must offer it.
    method = shipping_method(countries: ["EE"])
    conn = setup_shippable_cart_session(conn)

    {:ok, view, _html} = live(conn, "/checkout")

    view |> fill_billing_form(country: "EE") |> render_change()
    html = view |> element("button[phx-click='proceed_to_review']") |> render_click()

    assert html =~ "id=\"checkout-shipping-step\""
    assert has_element?(view, "#checkout-shipping-method-#{method.uuid}")
    refute has_element?(view, "#checkout-shipping-fallback-notice")
    refute has_element?(view, "#checkout-shipping-blocked")

    view
    |> element("#checkout-shipping-method-#{method.uuid} input[type='radio']")
    |> render_click()

    html = view |> element("#checkout-shipping-continue") |> render_click()

    # Reached review, and the chosen method shows up on it.
    assert has_element?(view, "button[phx-click='confirm_order']")
    assert html =~ method.name
  end

  test "fallback + uncovered country shows contact notice and proceeds to review",
       %{conn: conn} do
    PhoenixKit.Settings.update_setting_with_module(
      "shop_shipping_selection_position",
      "checkout",
      "shop"
    )

    PhoenixKit.Settings.update_setting_with_module("shop_shipping_skip_mode", "fallback", "shop")

    # Covers "US" only - the billing form below uses "EE", which nothing serves.
    _method = shipping_method(countries: ["US"])
    conn = setup_shippable_cart_session(conn)

    {:ok, view, _html} = live(conn, "/checkout")

    view |> fill_billing_form(country: "EE") |> render_change()
    view |> element("button[phx-click='proceed_to_review']") |> render_click()

    assert has_element?(view, "#checkout-shipping-fallback-notice")
    refute has_element?(view, "#checkout-shipping-blocked")

    view |> element("#checkout-shipping-continue") |> render_click()

    assert has_element?(view, "button[phx-click='confirm_order']")
  end

  # Regression for the 4th checkout entry path: an authenticated shopper
  # whose payment option needs no billing profile (`requires_billing_profile:
  # false`) reaches review through `proceed_to_billing`'s else-branch, not
  # through `advance_after_billing/1` like the other three paths (mount,
  # and both `proceed_to_review` branches). With position=checkout and a
  # shippable cart, that branch used to skip the shipping step entirely.
  test "authenticated + billing-less payment option: proceed_to_billing still honors the shipping step",
       %{conn: conn} do
    PhoenixKit.Settings.update_setting_with_module(
      "shop_shipping_selection_position",
      "checkout",
      "shop"
    )

    method = shipping_method(countries: ["EE"])
    conn = conn |> setup_shippable_cart_session() |> put_test_scope(fake_scope())

    # Two active options so mount stops on :payment (needs_payment_selection)
    # instead of auto-selecting a lone one - the payment step's own continue
    # button is what exercises `proceed_to_billing`. `code` is a fixed
    # enum (PhoenixKitBilling.PaymentOption.codes/0) and core seeds a row
    # per code, so activate the seeded ones rather than inserting - a
    # fresh insert of an already-taken code violates its unique index.
    _cod = ensure_payment_option("cod", "offline", requires_billing_profile: true)

    no_billing_option =
      ensure_payment_option("stripe", "online",
        provider: "stripe",
        requires_billing_profile: false
      )

    {:ok, view, _html} = live(conn, "/checkout")

    assert has_element?(view, "button[phx-click='proceed_to_billing']")

    view
    |> element("input[phx-value-option_uuid='#{no_billing_option.uuid}']")
    |> render_click()

    html = view |> element("button[phx-click='proceed_to_billing']") |> render_click()

    assert html =~ "id=\"checkout-shipping-step\""
    assert has_element?(view, "#checkout-shipping-method-#{method.uuid}")
    refute has_element?(view, "button[phx-click='confirm_order']")
  end

  # Regression for the exact line `build_checkout_socket/2`'s own comment
  # calls out: mount can land directly on :review (an authenticated shopper
  # with a payment option that needs no billing profile, and no billing
  # profile prompt pending) - the same "billing is settled" moment
  # `advance_after_billing/1` reaches from every other entry path. With
  # position=checkout and a shippable cart, the shipping step must still
  # appear on that path, reached with ZERO clicks (mount alone), not just
  # via the button-click paths the tests above cover.
  test "mount alone (billing-less payment option, authenticated) lands on the shipping step",
       %{conn: conn} do
    PhoenixKit.Settings.update_setting_with_module(
      "shop_shipping_selection_position",
      "checkout",
      "shop"
    )

    method = shipping_method(countries: ["EE"])
    conn = conn |> setup_shippable_cart_session() |> put_test_scope(fake_scope())

    # Core seeds "cod" active by default - deactivate it so the only active
    # option is the billing-less one below. With exactly one active option,
    # `maybe_auto_select_payment/2` auto-selects it, and since
    # `payment_option_needs_billing?/3` is false for it, mount's
    # `determine_initial_step/5` computes :review directly - no clicks.
    case Billing.get_payment_option_by_code("cod") do
      nil -> :ok
      cod -> {:ok, _} = Billing.update_payment_option(cod, %{"active" => false})
    end

    _stripe =
      ensure_payment_option("stripe", "online",
        provider: "stripe",
        requires_billing_profile: false
      )

    {:ok, view, html} = live(conn, "/checkout")

    assert html =~ "id=\"checkout-shipping-step\""
    assert has_element?(view, "#checkout-shipping-method-#{method.uuid}")
    refute has_element?(view, "button[phx-click='confirm_order']")
  end

  test "off + uncovered country blocks at shipping step", %{conn: conn} do
    PhoenixKit.Settings.update_setting_with_module(
      "shop_shipping_selection_position",
      "checkout",
      "shop"
    )

    # skip_mode stays at the "off" default - nothing may skip.
    _method = shipping_method(countries: ["US"])
    conn = setup_shippable_cart_session(conn)

    {:ok, view, _html} = live(conn, "/checkout")

    view |> fill_billing_form(country: "EE") |> render_change()
    view |> element("button[phx-click='proceed_to_review']") |> render_click()

    assert has_element?(view, "#checkout-shipping-blocked")
    refute has_element?(view, "#checkout-shipping-continue")
    refute has_element?(view, "button[phx-click='confirm_order']")

    # Belt and suspenders: even a crafted "shipping_continue" event (no
    # matching DOM affordance exists to fire it) must not move the step.
    render_click(view, "shipping_continue", %{})
    refute has_element?(view, "button[phx-click='confirm_order']")
    assert has_element?(view, "#checkout-shipping-blocked")
  end

  # Regression for a closed loop with no way out. With position=checkout the
  # cart page renders NO shipping section, so `enter_review/1`'s "please pick
  # another" bounce to `/cart` stranded the shopper: nothing there to change,
  # and "Proceed to Checkout" walked back into the same rejection in
  # `mount/3`. Reachable by editing billing to a country the already-chosen
  # method does not serve. The step that owns the choice has to reclaim it.
  test "editing billing to a country the chosen method does not serve returns to the shipping step",
       %{conn: conn} do
    PhoenixKit.Settings.update_setting_with_module(
      "shop_shipping_selection_position",
      "checkout",
      "shop"
    )

    ee_method = shipping_method(countries: ["EE"])
    us_method = shipping_method(countries: ["US"])
    conn = setup_shippable_cart_session(conn)

    {:ok, view, _html} = live(conn, "/checkout")

    view |> fill_billing_form(country: "EE") |> render_change()
    view |> element("button[phx-click='proceed_to_review']") |> render_click()

    view
    |> element("#checkout-shipping-method-#{ee_method.uuid} input[type='radio']")
    |> render_click()

    view |> element("#checkout-shipping-continue") |> render_click()
    assert has_element?(view, "button[phx-click='confirm_order']")

    # Back to billing, now shipping somewhere the EE-only method cannot go.
    # The review step carries two `back_to_billing` buttons (the billing
    # card's pencil and the footer arrow), so the bare event selector is
    # ambiguous. Target the id rather than the label: the label is a
    # gettext string, and this suite is not pinned to an English locale.
    view |> element("#checkout-review-change-billing") |> render_click()
    view |> fill_billing_form(country: "US") |> render_change()
    html = view |> element("button[phx-click='proceed_to_review']") |> render_click()

    # Back on the step that owns the choice - NOT redirected to a cart page
    # that has no shipping section - with the stale selection dropped and the
    # methods that actually serve the new country offered.
    assert html =~ "id=\"checkout-shipping-step\""
    assert has_element?(view, "#checkout-shipping-method-#{us_method.uuid}")
    refute has_element?(view, "#checkout-shipping-method-#{ee_method.uuid}")
    refute has_element?(view, "button[phx-click='confirm_order']")

    # And the shopper can finish from here.
    view
    |> element("#checkout-shipping-method-#{us_method.uuid} input[type='radio']")
    |> render_click()

    view |> element("#checkout-shipping-continue") |> render_click()
    assert has_element?(view, "button[phx-click='confirm_order']")
  end

  # The blocked state offers no Continue by design; without a way back the
  # shopper cannot reach the one thing that would fix it - their address.
  test "blocked shipping step still offers a way back to billing", %{conn: conn} do
    PhoenixKit.Settings.update_setting_with_module(
      "shop_shipping_selection_position",
      "checkout",
      "shop"
    )

    _method = shipping_method(countries: ["US"])
    conn = setup_shippable_cart_session(conn)

    {:ok, view, _html} = live(conn, "/checkout")

    view |> fill_billing_form(country: "EE") |> render_change()
    view |> element("button[phx-click='proceed_to_review']") |> render_click()

    assert has_element?(view, "#checkout-shipping-blocked")
    assert has_element?(view, "#checkout-shipping-back")

    view |> element("#checkout-shipping-back") |> render_click()
    assert has_element?(view, "#checkout-billing-form")
  end

  test "an unavailable selection on mount can be replaced inside checkout", %{conn: conn} do
    PhoenixKit.Settings.update_setting_with_module(
      "shop_shipping_selection_position",
      "checkout",
      "shop"
    )

    old_method = shipping_method(countries: ["EE"])
    replacement = shipping_method(countries: ["EE"])
    conn = setup_shippable_cart_session(conn)
    cart = Shop.find_active_cart(session_id: get_session(conn, "shop_session_id"))
    {:ok, cart} = Shop.set_cart_shipping(cart, old_method, "EE")
    {:ok, _} = Shop.update_shipping_method(old_method, %{"active" => false})

    {:ok, view, _html} = live(conn, "/checkout")
    assert is_nil(Shop.get_cart!(cart.uuid).shipping_method_uuid)

    view |> fill_billing_form(country: "EE") |> render_change()
    view |> element("button[phx-click='proceed_to_review']") |> render_click()

    assert has_element?(view, "#checkout-shipping-method-#{replacement.uuid}")
    refute has_element?(view, "#checkout-shipping-method-#{old_method.uuid}")
  end

  for change <- [:disabled, :cleared] do
    test "a shipping selection #{change} after review returns to the checkout picker on confirm",
         %{
           conn: conn
         } do
      PhoenixKit.Settings.update_setting_with_module(
        "shop_shipping_selection_position",
        "checkout",
        "shop"
      )

      old_method = shipping_method(countries: ["EE"])
      replacement = shipping_method(countries: ["EE"])
      conn = setup_shippable_cart_session(conn)

      {:ok, view, _html} = live(conn, "/checkout")
      view |> fill_billing_form(country: "EE") |> render_change()
      view |> element("button[phx-click='proceed_to_review']") |> render_click()

      view
      |> element("#checkout-shipping-method-#{old_method.uuid} input[type='radio']")
      |> render_click()

      view |> element("#checkout-shipping-continue") |> render_click()

      case unquote(change) do
        :disabled ->
          {:ok, _} = Shop.update_shipping_method(old_method, %{"active" => false})

        :cleared ->
          cart = Shop.find_active_cart(session_id: get_session(conn, "shop_session_id"))
          {:ok, _} = Shop.clear_cart_shipping(cart)
      end

      view |> element("button[phx-click='confirm_order']") |> render_click()

      assert has_element?(view, "#checkout-shipping-method-#{replacement.uuid}")

      if unquote(change) == :disabled do
        refute has_element?(view, "#checkout-shipping-method-#{old_method.uuid}")
      end

      refute has_element?(view, "#checkout-shipping-continue:not([disabled])")

      view
      |> element("#checkout-shipping-method-#{replacement.uuid} input[type='radio']")
      |> render_click()

      view |> element("#checkout-shipping-continue") |> render_click()
      view |> element("button[phx-click='confirm_order']") |> render_click()
      assert_redirect(view)
    end
  end

  # Core migrations seed one row per `PaymentOption.codes/0` entry
  # (inactive, default `requires_billing_profile`), so `code` is never
  # free to insert fresh - fetch the seeded row and flip it to what this
  # test needs instead.
  defp ensure_payment_option(code, type, attrs) do
    attrs =
      attrs
      |> Keyword.put(:active, true)
      |> Map.new(fn {k, v} -> {to_string(k), v} end)

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

  defp shipping_method(attrs) do
    # The name drives the slug, and the slug is unique — a test that needs two
    # methods (e.g. one per country) hit "has already been taken" on the second.
    unique = System.unique_integer([:positive])

    {:ok, method} =
      Shop.create_shipping_method(%{
        "name" => "Standard #{unique}",
        "price" => Decimal.new("5.00"),
        "active" => true,
        "countries" => Keyword.fetch!(attrs, :countries)
      })

    method
  end

  # A guest session with one physical (shippable) item in its cart - the
  # same pattern `CartPageShippingModesTest` and `CheckoutSignalTest` use.
  defp setup_shippable_cart_session(conn) do
    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Shipping Step Widget"},
        "price" => Decimal.new("25.00"),
        "status" => "active",
        "currency" => "USD",
        "product_type" => "physical",
        "requires_shipping" => true,
        "weight_grams" => 500
      })

    session_id = "checkout-shipping-step-#{System.unique_integer([:positive])}"

    {:ok, cart} = Shop.create_cart(session_id: session_id)
    {:ok, _cart} = Shop.add_to_cart(cart, product, 1)

    Plug.Test.init_test_session(conn, %{"shop_session_id" => session_id})
  end
end
