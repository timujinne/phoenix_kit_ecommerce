defmodule PhoenixKitEcommerce.Web.CheckoutPage do
  @moduledoc """
  Checkout page LiveView for converting cart to order.
  Supports both logged-in users (with billing profiles) and guest checkout.

  Supports real-time cart synchronization across multiple browser tabs
  via PubSub subscription.
  """

  use PhoenixKitEcommerce.Web, :live_view

  alias PhoenixKit.Utils.CountryData
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.PaymentOption
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Errors
  alias PhoenixKitEcommerce.Events
  alias PhoenixKitEcommerce.PriceDisplay
  alias PhoenixKitEcommerce.Web.Components.ShopLayouts
  alias PhoenixKitEcommerce.Web.Helpers

  import PhoenixKitEcommerce.Web.Helpers,
    only: [
      format_price: 2,
      humanize_key: 1,
      profile_display_name: 1,
      profile_address: 1,
      get_current_user: 1
    ]

  @impl true
  def mount(params, session, socket) do
    # Point the module Gettext at a locale its catalogues contain — see
    # Helpers.put_content_locale/1. Without it this page renders English
    # while its siblings translate.
    _ = Helpers.put_content_locale_from(socket)
    # The storefront of a DISABLED shop must not be browsable or purchasable;
    # only the order-confirmation page stays reachable (it is a receipt for an
    # already-placed order, not shopping). Admin pages are unaffected - that is
    # where the module gets re-enabled.
    if Shop.enabled?() do
      do_mount(params, session, socket)
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("The shop is currently unavailable"))
       # The HOST's root, not Routes.path("/") - that prepends the
       # PhoenixKit prefix ("/phoenix_kit/"), which no route serves.
       |> push_navigate(to: "/")}
    end
  end

  defp do_mount(_params, session, socket) do
    user = get_current_user(socket)
    session_id = session["shop_session_id"]
    user_uuid = if user, do: user.uuid

    case Shop.find_active_cart(user_uuid: user_uuid, session_id: session_id) do
      nil ->
        {:ok, redirect_to_cart(socket, gettext("Your cart is empty"))}

      cart ->
        handle_cart_validation(socket, cart, user)
    end
  end

  defp handle_cart_validation(socket, cart, user) do
    requires_shipping = Shop.cart_requires_shipping?(cart)

    cond do
      Enum.empty?(cart.items) ->
        {:ok, redirect_to_cart(socket, gettext("Your cart is empty"))}

      missing_shipping_method_blocks_checkout?(cart, requires_shipping) ->
        {:ok, redirect_to_cart(socket, gettext("Please select a shipping method"))}

      selected_shipping_method_outgrown?(cart, requires_shipping) ->
        {:ok,
         redirect_to_cart(
           socket,
           gettext(
             "The selected shipping method is no longer available for this cart - please pick another"
           )
         )}

      true ->
        {:ok, setup_checkout_assigns(socket, cart, user)}
    end
  end

  # Only bounce back to the cart page when shipping was meant to be picked
  # THERE. With `position: :checkout` the shipping step handles it after
  # billing; with any skip mode other than `:off` a missing method is not
  # necessarily fatal either way - `next_step_after_billing/1` and the
  # context's `shipping_skippable?/1` make that call once the checkout
  # country is known.
  defp missing_shipping_method_blocks_checkout?(cart, requires_shipping) do
    is_nil(cart.shipping_method_uuid) and requires_shipping and
      Shop.shipping_selection_position() == :cart and Shop.shipping_skip_mode() == :off
  end

  # A selection the cart has outgrown must not reach review priced at zero -
  # it converts to a guaranteed conversion failure.
  defp selected_shipping_method_outgrown?(cart, requires_shipping) do
    requires_shipping and not is_nil(cart.shipping_method_uuid) and
      not Enum.any?(
        Shop.get_available_shipping_methods(cart),
        &(&1.uuid == cart.shipping_method_uuid)
      )
  end

  defp setup_checkout_assigns(socket, cart, user) do
    is_guest = is_nil(user)
    authenticated = not is_nil(socket.assigns[:phoenix_kit_current_user])

    # Subscribe to cart events for real-time sync across tabs
    if connected?(socket) do
      Events.subscribe_to_cart(cart)
      Events.subscribe_currencies()
      PhoenixKitEcommerce.Notifications.checkout_started(cart)
    end

    # Load and auto-select payment option
    payment_options = Billing.list_active_payment_options()

    {cart, selected_payment_option, needs_payment_selection} =
      prepare_payment_options(cart, payment_options)

    # Load billing profiles
    billing_profiles = load_billing_profiles(user)
    {selected_profile, needs_profile_selection} = select_billing_profile(billing_profiles)

    # Determine if billing is needed and initial step
    needs_billing =
      payment_option_needs_billing?(selected_payment_option, is_guest, billing_profiles)

    initial_step =
      determine_initial_step(
        needs_payment_selection,
        needs_billing,
        is_guest,
        billing_profiles,
        needs_profile_selection
      )

    build_checkout_socket(socket, %{
      cart: cart,
      is_guest: is_guest,
      authenticated: authenticated,
      payment_options: payment_options,
      selected_payment_option: selected_payment_option,
      needs_payment_selection: needs_payment_selection,
      billing_profiles: billing_profiles,
      selected_profile: selected_profile,
      needs_profile_selection: needs_profile_selection,
      needs_billing: needs_billing,
      initial_step: initial_step,
      user: user
    })
  end

  defp prepare_payment_options(cart, payment_options) do
    {selected, needs_selection} = select_payment_option(payment_options, cart)
    cart = maybe_auto_select_payment(cart, payment_options)
    {cart, selected, needs_selection}
  end

  defp maybe_auto_select_payment(cart, payment_options) do
    if length(payment_options) == 1 and is_nil(cart.payment_option_uuid) do
      case Shop.set_cart_payment_option(cart, hd(payment_options)) do
        {:ok, updated_cart} -> updated_cart
        _ -> cart
      end
    else
      cart
    end
  end

  defp determine_initial_step(needs_payment, needs_billing, is_guest, profiles, needs_profile) do
    cond do
      needs_payment -> :payment
      needs_billing and (is_guest or profiles == []) -> :billing
      needs_billing and needs_profile -> :billing
      true -> :review
    end
  end

  defp build_checkout_socket(socket, assigns) do
    socket = do_build_checkout_socket(socket, assigns)

    # Mount can land directly on :review (an authenticated shopper with a
    # saved profile and a payment option that needs no billing details) -
    # the same "billing is settled" moment `proceed_to_review` reaches from
    # the billing form, so it runs through the same step decision (which
    # also prices the cart).
    if socket.assigns.step == :review, do: advance_after_billing(socket), else: socket
  end

  defp do_build_checkout_socket(socket, assigns) do
    socket
    |> assign(:page_title, gettext("Checkout"))
    |> assign(:cart, assigns.cart)
    |> assign(:currency, Shop.currency_for_code(assigns.cart.currency))
    |> assign(:fx_drift, Shop.cart_rate_drift(assigns.cart))
    |> assign(:is_guest, assigns.is_guest)
    |> assign(:authenticated, assigns.authenticated)
    |> assign(:payment_options, assigns.payment_options)
    |> assign(:selected_payment_option, assigns.selected_payment_option)
    |> assign(:needs_payment_selection, assigns.needs_payment_selection)
    |> assign(:billing_profiles, assigns.billing_profiles)
    |> assign(
      :selected_profile_uuid,
      if(assigns.selected_profile, do: assigns.selected_profile.uuid)
    )
    |> assign(:use_new_profile, assigns.is_guest or assigns.billing_profiles == [])
    |> assign(:needs_profile_selection, assigns.needs_profile_selection)
    |> assign(:needs_billing, assigns.needs_billing)
    |> assign(:billing_data, initial_billing_data(assigns.user, assigns.cart))
    |> assign(:countries, CountryData.list_countries())
    |> assign(:checkout_shipping_methods, [])
    |> assign(:shipping_fallback, false)
    |> assign(:step, assigns.initial_step)
    |> assign(:processing, false)
    |> assign(:error_message, nil)
    |> assign(:email_exists_error, false)
    |> assign(:form_errors, %{})
  end

  # Select payment option with smart defaults
  defp select_payment_option([], _cart), do: {nil, false}

  defp select_payment_option(options, cart) do
    # Check if cart already has a payment option selected
    selected =
      if cart.payment_option_uuid do
        Enum.find(options, &(&1.uuid == cart.payment_option_uuid))
      end

    cond do
      # Cart has valid selected option
      selected -> {selected, false}
      # Only one option available
      length(options) == 1 -> {hd(options), false}
      # Multiple options - user must choose
      true -> {hd(options), true}
    end
  end

  # Check if billing info is needed for the payment option
  defp payment_option_needs_billing?(nil, _is_guest, _profiles), do: true

  defp payment_option_needs_billing?(
         %{requires_billing_profile: true},
         _is_guest,
         _profiles
       ),
       do: true

  defp payment_option_needs_billing?(
         %{requires_billing_profile: false},
         true,
         _profiles
       ),
       do: true

  defp payment_option_needs_billing?(
         %{requires_billing_profile: false},
         false,
         _profiles
       ),
       do: false

  # Select billing profile with smart defaults
  defp select_billing_profile([]), do: {nil, false}

  defp select_billing_profile(profiles) do
    default = Enum.find(profiles, & &1.is_default)

    cond do
      # Has default profile - use it
      default -> {default, false}
      # Only one profile - auto-select it
      length(profiles) == 1 -> {hd(profiles), false}
      # Multiple profiles without default - select first, show prompt
      true -> {hd(profiles), true}
    end
  end

  defp load_billing_profiles(nil), do: []
  defp load_billing_profiles(user), do: Billing.list_user_billing_profiles(user.uuid)

  defp initial_billing_data(user, cart) do
    %{
      "type" => "individual",
      "first_name" => "",
      "last_name" => "",
      "email" => if(user, do: user.email, else: ""),
      "phone" => "",
      "address_line1" => "",
      "city" => "",
      "postal_code" => "",
      "country" => cart.shipping_country || "EE"
    }
  end

  defp profile_to_billing_data(profile, cart) do
    profile
    |> profile_base_data()
    |> Map.put("country", profile.country || cart.shipping_country || "EE")
  end

  defp profile_base_data(profile) do
    %{
      "type" => profile.type || "individual",
      "first_name" => profile.first_name || "",
      "last_name" => profile.last_name || "",
      "email" => profile.email || "",
      "phone" => profile.phone || "",
      "address_line1" => profile.address_line1 || "",
      "city" => profile.city || "",
      "postal_code" => profile.postal_code || ""
    }
  end

  defp redirect_to_cart(socket, message) do
    socket
    |> put_flash(:error, message)
    |> push_navigate(to: Routes.path("/cart"))
  end

  @impl true
  def handle_event("select_payment_option", %{"option_uuid" => option_uuid}, socket) do
    option = Enum.find(socket.assigns.payment_options, &(&1.uuid == option_uuid))

    if option do
      case Shop.set_cart_payment_option(socket.assigns.cart, option) do
        {:ok, updated_cart} ->
          # Update needs_billing based on new payment option
          needs_billing =
            payment_option_needs_billing?(
              option,
              socket.assigns.is_guest,
              socket.assigns.billing_profiles
            )

          {:noreply,
           socket
           |> assign(:cart, updated_cart)
           |> assign(:selected_payment_option, option)
           |> assign(:needs_billing, needs_billing)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to set payment option"))}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("proceed_to_billing", _params, socket) do
    if socket.assigns.needs_billing do
      {:noreply, assign(socket, :step, :billing)}
    else
      # advance_after_billing/1, not a bare step assign: it is the single
      # decision point for "billing is settled, what's next" - a shippable
      # cart with position=checkout still needs the :shipping step (or its
      # fallback notice) before review, and it is also the only path that
      # prices the cart with the billing country, so a review that skips it
      # shows a tax-free total the conversion then charges tax on.
      {:noreply, advance_after_billing(socket)}
    end
  end

  @impl true
  def handle_event("back_to_payment", _params, socket) do
    {:noreply, assign(socket, :step, :payment)}
  end

  @impl true
  def handle_event("select_profile", %{"profile_uuid" => profile_uuid}, socket) do
    # Only a profile that belongs to THIS user may be selected. `@billing_profiles`
    # is already scoped by `load_billing_profiles/1` (Billing.list_user_billing_profiles
    # for the current user), so membership in that list is the ownership check.
    #
    # Without it, the uuid went from the client straight onto the order, and
    # `maybe_set_billing_snapshot` copied the referenced profile's name, address,
    # phone and email onto the attacker's order — where the confirmation page
    # renders them back. Any known profile uuid was a PII read.
    #
    # Note the sibling handler `use_new_profile` already did this correctly with
    # `Enum.find(socket.assigns.billing_profiles, ...)`; this one just never got
    # the same treatment.
    if owned_profile_uuid?(socket, profile_uuid) do
      {:noreply,
       socket
       |> assign(:selected_profile_uuid, profile_uuid)
       |> assign(:use_new_profile, false)}
    else
      {:noreply, put_flash(socket, :error, gettext("That billing profile is not available."))}
    end
  end

  @impl true
  def handle_event("use_new_profile", _params, socket) do
    # Pre-fill form from selected profile if available
    billing_data =
      case Enum.find(
             socket.assigns.billing_profiles,
             &(to_string(&1.uuid) == to_string(socket.assigns.selected_profile_uuid))
           ) do
        nil -> socket.assigns.billing_data
        profile -> profile_to_billing_data(profile, socket.assigns.cart)
      end

    {:noreply,
     socket
     |> assign(:use_new_profile, true)
     |> assign(:billing_data, billing_data)
     |> assign(:selected_profile_uuid, nil)}
  end

  @impl true
  def handle_event("use_existing_profile", _params, socket) do
    default_profile = Enum.find(socket.assigns.billing_profiles, & &1.is_default)
    first_profile = List.first(socket.assigns.billing_profiles)
    profile = default_profile || first_profile

    {:noreply,
     socket
     |> assign(:use_new_profile, false)
     |> assign(:selected_profile_uuid, if(profile, do: profile.uuid))}
  end

  @impl true
  def handle_event("update_billing", %{"billing" => params}, socket) do
    billing_data = Map.merge(socket.assigns.billing_data, params)
    {:noreply, assign(socket, :billing_data, billing_data)}
  end

  @impl true
  def handle_event("proceed_to_review", _params, socket) do
    if socket.assigns.use_new_profile do
      # Validate billing data
      errors = validate_billing_data(socket.assigns.billing_data)

      if Enum.empty?(errors) do
        {:noreply, socket |> advance_after_billing() |> assign(:form_errors, %{})}
      else
        {:noreply,
         socket
         |> assign(:form_errors, errors)
         |> put_flash(:error, gettext("Please fill in all required fields"))}
      end
    else
      if is_nil(socket.assigns.selected_profile_uuid) do
        {:noreply, put_flash(socket, :error, gettext("Please select a billing profile"))}
      else
        {:noreply, advance_after_billing(socket)}
      end
    end
  end

  @impl true
  def handle_event("back_to_billing", _params, socket) do
    {:noreply, assign(socket, :step, :billing)}
  end

  @impl true
  def handle_event("select_checkout_shipping", %{"method_uuid" => uuid}, socket) do
    method = Enum.find(socket.assigns.checkout_shipping_methods, &(&1.uuid == uuid))

    case method &&
           Shop.set_cart_shipping(
             socket.assigns.cart,
             method,
             socket.assigns.cart.shipping_country
           ) do
      {:ok, cart} -> {:noreply, assign(socket, :cart, cart)}
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("shipping_continue", _params, socket) do
    cart = socket.assigns.cart

    # A method chosen from the list, or the fallback notice's own
    # "we'll contact you" path - anything else means the shopper has not
    # actually settled shipping yet, so the step holds.
    if cart.shipping_method_uuid || socket.assigns.shipping_fallback do
      {:noreply, enter_review(socket)}
    else
      {:noreply, socket}
    end
  end

  # §4.4: the shopper's own EXPLICIT choice to accept the current rate -
  # the ONE path that ever changes a non-empty cart's `exchange_rate`.
  @impl true
  def handle_event("refresh_cart_rate", _params, socket) do
    case Shop.refresh_cart_rate(socket.assigns.cart) do
      {:ok, cart} ->
        {:noreply,
         socket
         |> assign_cart_repriced(cart)
         |> put_flash(:info, gettext("Your cart has been repriced at the current exchange rate"))}

      {:error, _reason} ->
        {:noreply,
         put_flash(socket, :error, gettext("The cart could not be repriced — please try again"))}
    end
  end

  @impl true
  def handle_event("confirm_order", _params, socket) do
    socket = assign(socket, :processing, true)

    cart = socket.assigns.cart

    # Get user identifier from current scope if logged in
    user_uuid =
      case socket.assigns[:phoenix_kit_current_scope] do
        %{user: %{uuid: uuid}} -> uuid
        _ -> nil
      end

    # Build options for convert_cart_to_order
    opts =
      if socket.assigns.use_new_profile do
        # Guest or new profile - use billing_data directly
        [billing_data: socket.assigns.billing_data, user_uuid: user_uuid]
      else
        # Logged-in user with existing profile
        [billing_profile_uuid: socket.assigns.selected_profile_uuid, user_uuid: user_uuid]
      end

    # Re-check ownership at the point of USE, not just at selection. The
    # selection handler guards the normal path, but `selected_profile_uuid`
    # is plain socket state and this is the event that writes it onto a
    # persisted order — the one place where being wrong costs someone their
    # address. Cheap check, last line of defence.
    if socket.assigns.use_new_profile or
         owned_profile_uuid?(socket, socket.assigns.selected_profile_uuid) do
      result = Shop.convert_cart_to_order(cart, opts)
      {:noreply, handle_order_result(result, socket)}
    else
      {:noreply,
       socket
       |> assign(:processing, false)
       |> assign(:selected_profile_uuid, nil)
       |> put_flash(:error, gettext("That billing profile is not available."))}
    end
  end

  # The single decision point for "billing is settled, what's next" - reached
  # both from the billing form (`proceed_to_review`, either path: an existing
  # profile selected or new billing data saved) and from a mount that lands
  # directly on review (`build_checkout_socket/2`, an authenticated shopper
  # whose payment option needs no billing step at all). Both must see the
  # same shipping step when one is due - a shopper who never touched the
  # billing form is not exempt from picking a shipping method.
  defp advance_after_billing(socket) do
    case next_step_after_billing(socket) do
      :shipping -> assign_shipping_step(socket)
      :review -> enter_review(socket)
    end
  end

  # `:shipping` only when there is something to decide: selection happens at
  # checkout (not the cart page), skipping isn't unconditional (`:always`
  # already has nothing to pick), the cart actually ships something, and no
  # method is selected yet (a tab that already picked one, or came back from
  # review, has nothing left to do here).
  defp next_step_after_billing(socket) do
    cart = socket.assigns.cart

    if Shop.shipping_selection_position() == :checkout and
         Shop.shipping_skip_mode() != :always and
         Shop.cart_requires_shipping?(cart) and
         is_nil(cart.shipping_method_uuid) do
      :shipping
    else
      :review
    end
  end

  # The billing identity just captured, read back as a plain country code -
  # the shipping step needs it to filter methods and to persist onto the
  # cart via `Shop.set_cart_shipping_country/2` BEFORE it fetches them.
  defp billing_country(socket) do
    if socket.assigns.use_new_profile do
      socket.assigns.billing_data["country"]
    else
      case Enum.find(
             socket.assigns.billing_profiles,
             &(to_string(&1.uuid) == to_string(socket.assigns.selected_profile_uuid))
           ) do
        %{country: country} -> country
        _ -> nil
      end
    end
  end

  defp assign_shipping_step(socket) do
    cart = apply_billing_country(socket.assigns.cart, billing_country(socket))
    methods = Shop.get_available_shipping_methods(cart)

    socket
    |> assign(:cart, cart)
    |> assign(:checkout_shipping_methods, methods)
    |> assign(:shipping_fallback, methods == [] and Shop.shipping_skip_mode() == :fallback)
    |> assign(:step, :shipping)
  end

  # A blank country must never overwrite one the cart already carries: the
  # billing-less payment option reaches this step with no profile and no
  # form data, and writing nil there would clear a country the cart was
  # already scoped to and quietly widen the method list back to the
  # country-blind one this step exists to avoid.
  defp apply_billing_country(cart, country) when is_binary(country) and country != "" do
    case Shop.set_cart_shipping_country(cart, country) do
      {:ok, updated} -> updated
      {:error, _} -> cart
    end
  end

  defp apply_billing_country(cart, _country), do: cart

  # Entering review must show the amount that will actually be charged.
  #
  # The cart carries no shipping country until checkout supplies one, and
  # tax is zero without it — so simply flipping to `:review` showed a
  # pre-tax total while `convert_cart_to_order/2` went on to apply the
  # country and charge tax. The customer approved one number and was billed
  # another.
  #
  # `preview_checkout_totals/2` runs the same country resolution and
  # recalculation the conversion does, so the review figure and the charge
  # are produced by one code path.
  defp enter_review(socket) do
    socket = assign(socket, :step, :review)

    case Shop.preview_checkout_totals(socket.assigns.cart, checkout_opts(socket)) do
      {:ok, cart} ->
        # The billing country just entered the calculation - a method that
        # served the country-less cart may not serve THIS address, and its
        # ineligible price is zero, so review would show an underpriced
        # total that conversion then rejects. Catch it here, at the moment
        # the number is first shown.
        if shipping_selection_still_valid?(cart) do
          assign(socket, :cart, cart)
        else
          socket
          |> assign(:cart, cart)
          |> reject_invalid_shipping_selection()
        end

      # Never block review on a pricing refresh; conversion recalculates
      # under its own lock regardless, and a stale display is a smaller
      # failure than a dead checkout.
      {:error, _} ->
        socket
    end
  end

  # "Pick another" has to point at a page that HAS a picker.
  #
  # With `position: :cart` that is the cart page, and bouncing there is
  # right. With `position: :checkout` the cart page deliberately renders no
  # shipping section at all (see `CartPage.shipping_required_here?/0`), so
  # the redirect used to strand the shopper: the cart offered nothing to
  # change, and "Proceed to Checkout" walked straight back into the same
  # rejection in `mount/3` (`selected_shipping_method_outgrown?/2`) — a
  # closed loop with no way out. Reachable by editing billing back to a
  # country the chosen method does not serve.
  #
  # So for `:checkout` we drop the now-ineligible selection and re-enter the
  # step that owns the choice, with the methods for the country the shopper
  # actually just entered.
  defp reject_invalid_shipping_selection(socket) do
    message =
      gettext(
        "The selected shipping method is not available for your address - please pick another"
      )

    if Shop.shipping_selection_position() == :checkout do
      socket
      |> assign(:cart, drop_shipping_selection(socket.assigns.cart))
      |> assign_shipping_step()
      |> put_flash(:error, message)
    else
      socket
      |> assign(:step, :shipping_invalid)
      |> put_flash(:error, message)
      |> push_navigate(to: Routes.path("/cart"))
    end
  end

  # Clearing must not be able to leave the ineligible method in place —
  # `assign_shipping_step/1` would then render an unchecked list with
  # Continue still enabled, and Continue leads straight back here.
  defp drop_shipping_selection(cart) do
    case Shop.clear_cart_shipping(cart) do
      {:ok, cleared} -> cleared
      _ -> %{cart | shipping_method_uuid: nil, shipping_amount: nil}
    end
  end

  # A cart change broadcast from another tab lands here. Blindly assigning
  # it into an open REVIEW showed a total that had lost the billing country
  # (the cart page's select_shipping deliberately clears it), so the
  # customer approved a tax-free figure that conversion then taxed. On the
  # review step, re-price through the same path that produced the figure in
  # the first place.
  defp assign_cart_repriced(socket, cart) do
    socket =
      if socket.assigns[:step] == :review do
        case Shop.preview_checkout_totals(cart, checkout_opts(socket)) do
          {:ok, priced} -> assign(socket, :cart, priced)
          {:error, _} -> assign(socket, :cart, cart)
        end
      else
        assign(socket, :cart, cart)
      end

    assign(socket, :fx_drift, Shop.cart_rate_drift(socket.assigns.cart))
  end

  defp shipping_selection_still_valid?(cart) do
    cond do
      not Shop.cart_requires_shipping?(cart) ->
        true

      not is_nil(cart.shipping_method_uuid) ->
        Enum.any?(
          Shop.get_available_shipping_methods(cart),
          &(&1.uuid == cart.shipping_method_uuid)
        )

      # No method selected: only valid here if the shop allows converting
      # without one (`:always`, or `:fallback` with nothing covering this
      # country) - the same call `convert_cart_to_order/2` makes via
      # `shipping_skippable?/1`, so review cannot approve a total the
      # conversion then refuses.
      true ->
        Shop.shipping_skippable?(cart) != false
    end
  end

  # The billing identity for this checkout, in the shape both
  # `preview_checkout_totals/2` and `convert_cart_to_order/2` expect.
  defp checkout_opts(socket) do
    if socket.assigns.use_new_profile do
      [billing_data: socket.assigns.billing_data]
    else
      [billing_profile_uuid: socket.assigns.selected_profile_uuid]
    end
  end

  # Membership in `@billing_profiles` IS the ownership check — that list is
  # built by `load_billing_profiles/1` from
  # `Billing.list_user_billing_profiles(user.uuid)`, so it only ever holds
  # the current user's profiles.
  defp owned_profile_uuid?(_socket, nil), do: false

  defp owned_profile_uuid?(socket, profile_uuid) do
    Enum.any?(
      socket.assigns.billing_profiles,
      &(to_string(&1.uuid) == to_string(profile_uuid))
    )
  end

  defp handle_order_result({:ok, order}, socket) do
    socket
    |> assign(:processing, false)
    |> push_navigate(to: Routes.path("/checkout/complete/#{order.uuid}"))
  end

  defp handle_order_result({:error, :cart_not_active}, socket) do
    message = Errors.message(:cart_not_active)

    socket
    |> assign(:processing, false)
    |> assign(:error_message, message)
    |> put_flash(:error, message)
  end

  defp handle_order_result({:error, :cart_empty}, socket) do
    socket
    |> assign(:processing, false)
    |> push_navigate(to: Routes.path("/cart"))
  end

  defp handle_order_result({:error, :no_shipping_method}, socket) do
    socket
    |> assign(:processing, false)
    |> put_flash(:error, gettext("Please select a shipping method"))
    |> push_navigate(to: Routes.path("/cart"))
  end

  defp handle_order_result({:error, :email_already_registered}, socket) do
    socket
    |> assign(:processing, false)
    |> assign(:email_exists_error, true)
    |> assign(:error_message, nil)
  end

  # The selected method stopped serving this cart (usually the billing
  # country ruled it out). Send the shopper back to pick another instead of
  # a dead generic failure.
  defp handle_order_result({:error, :shipping_method_unavailable}, socket) do
    socket
    |> assign(:processing, false)
    |> put_flash(
      :error,
      gettext(
        "The selected shipping method is not available for your address - please pick another"
      )
    )
    |> push_navigate(to: Routes.path("/cart"))
  end

  defp handle_order_result({:error, {:product_not_available, _uuid}}, socket) do
    socket
    |> assign(:processing, false)
    |> put_flash(:error, gettext("An item in your cart is no longer available"))
    |> push_navigate(to: Routes.path("/cart"))
  end

  defp handle_order_result({:error, :product_not_available}, socket) do
    socket
    |> assign(:processing, false)
    |> put_flash(:error, gettext("An item in your cart is no longer available"))
    |> push_navigate(to: Routes.path("/cart"))
  end

  # The billing details are missing deliverable-address fields — this is
  # the context refusing what the review step's own validation would have
  # caught, so return the customer to an EDITABLE billing form instead of
  # failing generically. A saved profile that fails here (billing never
  # required profiles to carry an address) is prefilled into the form for
  # completion.
  defp handle_order_result({:error, {:billing_incomplete, _missing}}, socket) do
    socket = assign(socket, :processing, false)

    socket =
      if socket.assigns.use_new_profile do
        socket
      else
        prefill_from_selected_profile(socket)
      end

    socket
    |> assign(:step, :billing)
    |> assign(:use_new_profile, true)
    |> put_flash(
      :error,
      gettext("Please complete the billing address - a physical order needs one")
    )
  end

  defp handle_order_result({:error, :billing_profile_not_found}, socket) do
    socket
    |> assign(:processing, false)
    |> assign(:selected_profile_uuid, nil)
    |> assign(:step, :billing)
    |> put_flash(:error, gettext("That billing profile is not available."))
  end

  defp handle_order_result({:error, :payment_option_unavailable}, socket) do
    socket
    |> assign(:processing, false)
    |> put_flash(
      :error,
      gettext("The selected payment method is no longer available - please pick another")
    )
    |> push_navigate(to: Routes.path("/cart"))
  end

  defp handle_order_result({:error, :shop_disabled}, socket) do
    socket
    |> assign(:processing, false)
    |> put_flash(:error, gettext("The shop is currently unavailable"))
    |> push_navigate(to: "/")
  end

  defp handle_order_result({:error, _reason}, socket) do
    socket
    |> assign(:processing, false)
    |> assign(:error_message, gettext("Failed to create order. Please try again."))
    |> put_flash(:error, gettext("Failed to create order"))
  end

  # Seed the editable billing form from the profile the customer had
  # selected, so completing an address-less saved profile is a fill-in,
  # not a retype.
  defp prefill_from_selected_profile(socket) do
    case Enum.find(
           socket.assigns.billing_profiles,
           &(to_string(&1.uuid) == to_string(socket.assigns.selected_profile_uuid))
         ) do
      nil ->
        socket

      profile ->
        assign(socket, :billing_data, profile_form_data(profile, socket.assigns.billing_data))
    end
  end

  # Field-for-field copy of a saved profile into the editable form's shape.
  @profile_form_fields ~w(first_name last_name phone company_name address_line1
                          address_line2 city state postal_code country)a

  defp profile_form_data(profile, current) do
    base =
      Map.new(@profile_form_fields, fn field ->
        {to_string(field), Map.get(profile, field) || ""}
      end)

    # The email is the one field the customer may have typed before picking
    # a profile, so a blank profile email must not wipe it.
    Map.put(base, "email", profile.email || current["email"] || "")
  end

  defp validate_billing_data(data) do
    errors = %{}

    errors =
      if blank?(data["first_name"]),
        do: Map.put(errors, :first_name, "is required"),
        else: errors

    errors =
      if blank?(data["last_name"]),
        do: Map.put(errors, :last_name, "is required"),
        else: errors

    errors =
      if blank?(data["email"]),
        do: Map.put(errors, :email, "is required"),
        else: errors

    errors =
      if blank?(data["address_line1"]),
        do: Map.put(errors, :address_line1, "is required"),
        else: errors

    errors =
      if blank?(data["city"]), do: Map.put(errors, :city, "is required"), else: errors

    errors =
      if blank?(data["country"]),
        do: Map.put(errors, :country, "is required"),
        else: errors

    errors
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(str) when is_binary(str), do: String.trim(str) == ""
  defp blank?(_), do: false

  # ============================================
  # PUBSUB EVENT HANDLERS
  # ============================================

  @impl true
  def handle_info({:cart_updated, cart}, socket) do
    {:noreply, assign_cart_repriced(socket, cart)}
  end

  @impl true
  def handle_info({:item_added, cart, _item}, socket) do
    {:noreply, assign_cart_repriced(socket, cart)}
  end

  @impl true
  def handle_info({:item_removed, cart, _item_id}, socket) do
    # If cart becomes empty, redirect to cart page
    if Enum.empty?(cart.items) do
      {:noreply, redirect_to_cart(socket, gettext("Your cart is empty"))}
    else
      {:noreply, assign_cart_repriced(socket, cart)}
    end
  end

  @impl true
  def handle_info({:quantity_updated, cart, _item}, socket) do
    {:noreply, assign_cart_repriced(socket, cart)}
  end

  @impl true
  def handle_info({:shipping_selected, cart}, socket) do
    {:noreply, assign_cart_repriced(socket, cart)}
  end

  @impl true
  def handle_info({:payment_selected, cart}, socket) do
    # Also update selected_payment_option if it changed
    selected = Enum.find(socket.assigns.payment_options, &(&1.uuid == cart.payment_option_uuid))

    {:noreply,
     socket
     |> assign(:cart, cart)
     |> assign(:selected_payment_option, selected)}
  end

  @impl true
  def handle_info({:cart_cleared, _cart}, socket) do
    # Cart was cleared, redirect to cart page
    {:noreply, redirect_to_cart(socket, gettext("Your cart is empty"))}
  end

  # §4.4: a currency-table change may open (or close) the drift gap
  # between this cart's frozen rate and the live one. The cart itself is
  # NEVER touched here — only the notice is recomputed.
  @impl true
  def handle_info({:currencies_changed, _code}, socket) do
    {:noreply, assign(socket, :fx_drift, Shop.cart_rate_drift(socket.assigns.cart))}
  end

  # Catch-all: an unrecognised message must not take the LiveView down.
  #
  # Every clause above matches a specific broadcast shape, so ANY message
  # outside that set — a new event added to `Events`, a late reply, a
  # library-sent message — crashed the mounted view. `Events` already
  # publishes some events to two topics, and this module subscribes to
  # more than one, so adding a single new event shape would have started
  # crashing live sessions with no change here at all.
  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <ShopLayouts.shop_layout {assigns}>
      <div class="p-6 max-w-6xl mx-auto">
        <div class="flex items-center justify-between mb-8">
          <h1 class="text-3xl font-bold">{gettext("Checkout")}</h1>
          <.link navigate={Routes.path("/cart")} class="btn btn-ghost btn-sm">
            <.icon name="hero-arrow-left" class="w-4 h-4" />
          </.link>
        </div>

        <%!-- Steps Indicator --%>
        <div class="steps w-full mb-8">
          <%= if length(@payment_options) > 1 do %>
            <div class={["step", @step in [:payment, :billing, :shipping, :review] && "step-primary"]}>
              {gettext("Payment")}
            </div>
          <% end %>
          <%= if @needs_billing do %>
            <div class={["step", @step in [:billing, :shipping, :review] && "step-primary"]}>
              {gettext("Billing")}
            </div>
          <% end %>
          <%!-- Only a checkout-position shop ever reaches :shipping; without
               this chip the whole indicator went blank on that step. --%>
          <div :if={@step == :shipping} class="step step-primary">
            {gettext("Shipping")}
          </div>
          <div class={["step", @step == :review && "step-primary"]}>
            {gettext("Review & Confirm")}
          </div>
        </div>

        <%!-- §4.4: the frozen rate drifted past fx_rate_drift_alert_pct.
             Prices stay as shown; only the button reprices. --%>
        <%= if @fx_drift do %>
          <div id="checkout-fx-drift" class="alert alert-warning mb-6">
            <.icon name="hero-arrow-trending-up" class="w-5 h-5" />
            <div class="flex-1">
              <div class="font-semibold">
                {gettext("The exchange rate has changed since you started this cart")}
              </div>
              <div class="text-sm">
                {gettext(
                  "Your cart is priced at rate %{frozen}; the current rate is %{current} (%{pct}% apart). Your prices stay as shown unless you reprice.",
                  frozen: Decimal.to_string(@fx_drift.frozen, :normal),
                  current: Decimal.to_string(@fx_drift.current, :normal),
                  pct: Decimal.to_string(@fx_drift.pct, :normal)
                )}
              </div>
            </div>
            <button
              type="button"
              id="checkout-fx-drift-reprice"
              class="btn btn-sm btn-outline"
              phx-click="refresh_cart_rate"
            >
              {gettext("Reprice at the current rate")}
            </button>
          </div>
        <% end %>

        <%!-- Guest Checkout Info --%>
        <%= if @is_guest do %>
          <div class="alert alert-info mb-6">
            <.icon name="hero-envelope" class="w-5 h-5" />
            <div>
              <div class="font-semibold">{gettext("Checking out as a guest")}</div>
              <div class="text-sm">
                {gettext(
                  "After placing your order, we'll send a confirmation email to verify your address. Check your inbox and click the link to activate your account and track your order."
                )}
              </div>
            </div>
          </div>
        <% end %>

        <div class="grid grid-cols-1 lg:grid-cols-3 gap-8">
          <%!-- Main Content --%>
          <div class="lg:col-span-2">
            <%= case @step do %>
              <% :payment -> %>
                <.payment_step
                  payment_options={@payment_options}
                  selected_payment_option={@selected_payment_option}
                  needs_billing={@needs_billing}
                />
              <% :billing -> %>
                <.billing_step
                  is_guest={@is_guest}
                  billing_profiles={@billing_profiles}
                  selected_profile_uuid={@selected_profile_uuid}
                  use_new_profile={@use_new_profile}
                  needs_profile_selection={@needs_profile_selection}
                  billing_data={@billing_data}
                  form_errors={@form_errors}
                  countries={@countries}
                  payment_options={@payment_options}
                />
              <% :shipping -> %>
                <.shipping_step
                  methods={@checkout_shipping_methods}
                  fallback={@shipping_fallback}
                  cart={@cart}
                  currency={@currency}
                  needs_billing={@needs_billing}
                />
              <% :review -> %>
                <.review_step
                  cart={@cart}
                  is_guest={@is_guest}
                  billing_profiles={@billing_profiles}
                  selected_profile_uuid={@selected_profile_uuid}
                  use_new_profile={@use_new_profile}
                  billing_data={@billing_data}
                  currency={@currency}
                  processing={@processing}
                  error_message={@error_message}
                  email_exists_error={@email_exists_error}
                  selected_payment_option={@selected_payment_option}
                  needs_billing={@needs_billing}
                  payment_options={@payment_options}
                />
            <% end %>
          </div>

          <%!-- Order Summary Sidebar --%>
          <div class="lg:col-span-1">
            <.order_summary cart={@cart} currency={@currency} />
          </div>
        </div>
      </div>
    </ShopLayouts.shop_layout>
    """
  end

  # Components

  defp payment_step(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-lg">
      <div class="card-body">
        <h2 class="card-title mb-4">{gettext("Select Payment Method")}</h2>

        <div class="space-y-3">
          <%= for option <- @payment_options do %>
            <label class={[
              "flex items-center gap-4 p-4 border rounded-lg cursor-pointer transition-colors",
              if(@selected_payment_option && @selected_payment_option.uuid == option.uuid,
                do: "border-primary bg-primary/5",
                else: "border-base-300 hover:border-primary/50"
              )
            ]}>
              <input
                type="radio"
                name="payment_option"
                value={option.uuid}
                checked={@selected_payment_option && @selected_payment_option.uuid == option.uuid}
                phx-click="select_payment_option"
                phx-value-option_uuid={option.uuid}
                class="radio radio-primary"
              />
              <.icon name={PaymentOption.icon_name(option)} class="w-6 h-6 text-base-content/70" />
              <div class="flex-1">
                <div class="font-medium">{option.name}</div>
                <%= if option.description do %>
                  <div class="text-sm text-base-content/60">{option.description}</div>
                <% end %>
              </div>
            </label>
          <% end %>
        </div>

        <div class="card-actions justify-end mt-6">
          <button phx-click="proceed_to_billing" class="btn btn-primary">
            <%= if @needs_billing do %>
              {gettext("Continue to Billing")}
              <.icon name="hero-arrow-right" class="w-4 h-4 ml-2" />
            <% else %>
              {gettext("Continue to Review")}
              <.icon name="hero-arrow-right" class="w-4 h-4 ml-2" />
            <% end %>
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp billing_step(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-lg">
      <div class="card-body">
        <h2 class="card-title mb-4">
          <%= if @is_guest or @billing_profiles == [] do %>
            {gettext("Billing Information")}
          <% else %>
            {gettext("Select Billing Profile")}
          <% end %>
        </h2>

        <%= if @use_new_profile do %>
          <%!-- Guest checkout or no profiles - show billing form --%>
          <.billing_form
            billing_data={@billing_data}
            form_errors={@form_errors}
            countries={@countries}
          />
        <% else %>
          <%!-- Authenticated user with multiple profiles - show selector --%>
          <.profile_selector
            billing_profiles={@billing_profiles}
            selected_profile_uuid={@selected_profile_uuid}
            needs_profile_selection={@needs_profile_selection}
          />
        <% end %>

        <div class="card-actions justify-between mt-6">
          <%= if length(@payment_options) > 1 do %>
            <button phx-click="back_to_payment" class="btn btn-ghost">
              <.icon name="hero-arrow-left" class="w-4 h-4" />
            </button>
          <% else %>
            <div></div>
          <% end %>
          <button phx-click="proceed_to_review" class="btn btn-primary">
            {gettext("Continue to Review")}
            <.icon name="hero-arrow-right" class="w-4 h-4 ml-2" />
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp profile_selector(assigns) do
    ~H"""
    <div class="space-y-3">
      <%!-- Show info alert when multiple profiles exist without a default --%>
      <%= if @needs_profile_selection do %>
        <div class="alert alert-info mb-4">
          <.icon name="hero-information-circle" class="w-5 h-5" />
          <span>
            {gettext("You have multiple billing profiles. Please select one or")}
            <.link navigate={Routes.path("/dashboard/billing-profiles")} class="link">
              {gettext("set a default in your account settings")}
            </.link>.
          </span>
        </div>
      <% end %>

      <%= for profile <- @billing_profiles do %>
        <div class={[
          "flex items-start gap-4 p-4 border rounded-lg transition-colors",
          if(to_string(@selected_profile_uuid) == to_string(profile.uuid),
            do: "border-primary bg-primary/5",
            else: "border-base-300 hover:border-primary/50"
          )
        ]}>
          <label class="flex items-start gap-4 flex-1 cursor-pointer">
            <input
              type="radio"
              name="profile"
              value={profile.uuid}
              checked={to_string(@selected_profile_uuid) == to_string(profile.uuid)}
              phx-click="select_profile"
              phx-value-profile_uuid={profile.uuid}
              class="radio radio-primary mt-1"
            />
            <div class="flex-1">
              <div class="font-medium flex items-center gap-2">
                {profile_display_name(profile)}
                <%= if profile.is_default do %>
                  <span class="badge badge-primary badge-sm">{gettext("Default")}</span>
                <% end %>
              </div>
              <div class="text-sm text-base-content/60 mt-1">
                {profile_address(profile)}
              </div>
              <%= if profile.email do %>
                <div class="text-sm text-base-content/60">
                  {profile.email}
                </div>
              <% end %>
            </div>
          </label>
          <%!-- Edit button for selected profile --%>
          <%= if to_string(@selected_profile_uuid) == to_string(profile.uuid) do %>
            <.link
              navigate={
                Routes.path("/dashboard/billing-profiles/#{profile.uuid}/edit?return_to=/checkout")
              }
              class="btn btn-ghost btn-sm"
            >
              <.icon name="hero-pencil" class="w-4 h-4" />
            </.link>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp billing_form(assigns) do
    ~H"""
    <form id="checkout-billing-form" phx-change="update_billing" class="space-y-4">
      <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
        <fieldset class="fieldset">
          <legend class="fieldset-legend">{gettext("First Name *")}</legend>
          <input
            type="text"
            name="billing[first_name]"
            value={@billing_data["first_name"]}
            class={["input", @form_errors[:first_name] && "input-error"]}
            required
          />
          <%= if @form_errors[:first_name] do %>
            <p class="fieldset-label text-error">{@form_errors[:first_name]}</p>
          <% end %>
        </fieldset>

        <fieldset class="fieldset">
          <legend class="fieldset-legend">{gettext("Last Name *")}</legend>
          <input
            type="text"
            name="billing[last_name]"
            value={@billing_data["last_name"]}
            class={["input", @form_errors[:last_name] && "input-error"]}
            required
          />
          <%= if @form_errors[:last_name] do %>
            <p class="fieldset-label text-error">{@form_errors[:last_name]}</p>
          <% end %>
        </fieldset>
      </div>

      <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
        <fieldset class="fieldset">
          <legend class="fieldset-legend">{gettext("Email *")}</legend>
          <input
            type="email"
            name="billing[email]"
            value={@billing_data["email"]}
            class={["input", @form_errors[:email] && "input-error"]}
            required
          />
          <%= if @form_errors[:email] do %>
            <p class="fieldset-label text-error">{@form_errors[:email]}</p>
          <% end %>
        </fieldset>

        <fieldset class="fieldset">
          <legend class="fieldset-legend">{gettext("Phone")}</legend>
          <input
            type="tel"
            name="billing[phone]"
            value={@billing_data["phone"]}
            class="input"
          />
        </fieldset>
      </div>

      <fieldset class="fieldset">
        <legend class="fieldset-legend">{gettext("Address *")}</legend>
        <input
          type="text"
          name="billing[address_line1]"
          value={@billing_data["address_line1"]}
          class={["input", @form_errors[:address_line1] && "input-error"]}
          placeholder={gettext("Street address")}
          required
        />
        <%= if @form_errors[:address_line1] do %>
          <p class="fieldset-label text-error">{@form_errors[:address_line1]}</p>
        <% end %>
      </fieldset>

      <div class="grid grid-cols-1 md:grid-cols-3 gap-4">
        <fieldset class="fieldset">
          <legend class="fieldset-legend">{gettext("City *")}</legend>
          <input
            type="text"
            name="billing[city]"
            value={@billing_data["city"]}
            class={["input", @form_errors[:city] && "input-error"]}
            required
          />
          <%= if @form_errors[:city] do %>
            <p class="fieldset-label text-error">{@form_errors[:city]}</p>
          <% end %>
        </fieldset>

        <fieldset class="fieldset">
          <legend class="fieldset-legend">{gettext("Postal Code")}</legend>
          <input
            type="text"
            name="billing[postal_code]"
            value={@billing_data["postal_code"]}
            class="input"
          />
        </fieldset>

        <fieldset class="fieldset">
          <legend class="fieldset-legend">{gettext("Country *")}</legend>
          <select
            name="billing[country]"
            class={["select", @form_errors[:country] && "select-error"]}
            required
          >
            <option value="">{gettext("Select country...")}</option>
            <%= for country <- @countries do %>
              <option value={country.alpha2} selected={@billing_data["country"] == country.alpha2}>
                {country.name}
              </option>
            <% end %>
          </select>
          <%= if @form_errors[:country] do %>
            <p class="fieldset-label text-error">{@form_errors[:country]}</p>
          <% end %>
        </fieldset>
      </div>
    </form>
    """
  end

  # `position: :checkout` shipping step, reached (only) from
  # `assign_shipping_step/1` after billing. Three mutually exclusive states:
  # methods to choose from, the fallback "we'll contact you" notice
  # (`:fallback` mode with none covering this country), or a hard block
  # (nothing covers it and the shop does not allow skipping).
  defp shipping_step(assigns) do
    ~H"""
    <div id="checkout-shipping-step" class="card bg-base-100 shadow-lg">
      <div class="card-body">
        <h2 class="card-title mb-4">{gettext("Shipping")}</h2>

        <%= cond do %>
          <% @methods != [] -> %>
            <div class="space-y-3">
              <label
                :for={method <- @methods}
                id={"checkout-shipping-method-#{method.uuid}"}
                class={[
                  "flex items-center gap-4 p-4 border rounded-lg cursor-pointer transition-colors",
                  if(@cart.shipping_method_uuid == method.uuid,
                    do: "border-primary bg-primary/5",
                    else: "border-base-300 hover:border-primary/50"
                  )
                ]}
              >
                <input
                  type="radio"
                  name="checkout_shipping"
                  class="radio radio-primary"
                  checked={@cart.shipping_method_uuid == method.uuid}
                  phx-click="select_checkout_shipping"
                  phx-value-method_uuid={method.uuid}
                />
                <div class="flex-1">
                  <div class="font-medium">{method.name}</div>
                  <%= if method.description do %>
                    <div class="text-sm text-base-content/60">{method.description}</div>
                  <% end %>
                </div>
                <div class="font-semibold">{format_price(method.price, @currency)}</div>
              </label>
            </div>
            <div class="flex items-center gap-3 mt-6">
              <button
                id="checkout-shipping-continue"
                class="btn btn-primary"
                phx-click="shipping_continue"
                disabled={not Enum.any?(@methods, &(&1.uuid == @cart.shipping_method_uuid))}
              >
                {gettext("Continue")} <.icon name="hero-arrow-right" class="w-4 h-4 ml-2" />
              </button>
              <.shipping_back_button needs_billing={@needs_billing} />
            </div>
          <% @fallback -> %>
            <div id="checkout-shipping-fallback-notice" class="alert alert-info">
              <.icon name="hero-information-circle" class="w-5 h-5" />
              <span>
                {gettext(
                  "Shipping to your country will be arranged individually - we will contact you to confirm delivery and details after you place the order."
                )}
              </span>
            </div>
            <div class="flex items-center gap-3 mt-6">
              <button id="checkout-shipping-continue" class="btn btn-primary" phx-click="shipping_continue">
                {gettext("Continue")} <.icon name="hero-arrow-right" class="w-4 h-4 ml-2" />
              </button>
              <.shipping_back_button needs_billing={@needs_billing} />
            </div>
          <% true -> %>
            <div id="checkout-shipping-blocked" class="alert alert-warning">
              <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
              <span>{gettext("No shipping methods are available for your country.")}</span>
            </div>
            <div class="mt-6">
              <.shipping_back_button needs_billing={@needs_billing} />
            </div>
        <% end %>
      </div>
    </div>
    """
  end

  # The blocked state has no Continue by design — the shop does not deliver
  # there — so without a way back the shopper is stranded on a step whose
  # only remedy (a different address) lives on the previous one. The cart
  # link in the page header is not that remedy: under `position: :checkout`
  # the cart page renders no shipping section at all.
  defp shipping_back_button(assigns) do
    ~H"""
    <button
      :if={@needs_billing}
      id="checkout-shipping-back"
      phx-click="back_to_billing"
      class="btn btn-ghost"
    >
      <.icon name="hero-arrow-left" class="w-4 h-4 mr-2" /> {gettext("Back")}
    </button>
    """
  end

  defp review_step(assigns) do
    selected_profile =
      if assigns.use_new_profile do
        nil
      else
        Enum.find(
          assigns.billing_profiles,
          &(to_string(&1.uuid) == to_string(assigns.selected_profile_uuid))
        )
      end

    assigns = assign(assigns, :selected_profile, selected_profile)

    ~H"""
    <div class="space-y-6">
      <%!-- Payment Method --%>
      <div class="card bg-base-100 shadow-lg">
        <div class="card-body">
          <div class="flex items-center justify-between mb-4">
            <h2 class="card-title">{gettext("Payment Method")}</h2>
            <%= if length(@payment_options) > 1 do %>
              <button phx-click="back_to_payment" class="btn btn-ghost btn-sm">
                <.icon name="hero-pencil" class="w-4 h-4 mr-1" /> {gettext("Change")}
              </button>
            <% end %>
          </div>

          <%= if @selected_payment_option do %>
            <div class="flex items-center gap-3">
              <.icon
                name={PaymentOption.icon_name(@selected_payment_option)}
                class="w-6 h-6 text-base-content/70"
              />
              <div>
                <div class="font-medium">{@selected_payment_option.name}</div>
                <%= if @selected_payment_option.description do %>
                  <div class="text-sm text-base-content/60">
                    {@selected_payment_option.description}
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      </div>

      <%!-- Billing Info (only if billing is needed) --%>
      <%= if @needs_billing do %>
        <div class="card bg-base-100 shadow-lg">
          <div class="card-body">
            <div class="flex items-center justify-between mb-4">
              <h2 class="card-title">{gettext("Billing Information")}</h2>
              <button
                id="checkout-review-change-billing"
                phx-click="back_to_billing"
                class="btn btn-ghost btn-sm"
              >
                <.icon name="hero-pencil" class="w-4 h-4 mr-1" /> {gettext("Change")}
              </button>
            </div>

            <div class="text-sm">
              <%= if @use_new_profile do %>
                <div class="font-medium">
                  {@billing_data["first_name"]} {@billing_data["last_name"]}
                </div>
                <div class="text-base-content/60">
                  {[
                    @billing_data["address_line1"],
                    @billing_data["city"],
                    @billing_data["postal_code"],
                    @billing_data["country"]
                  ]
                  |> Enum.filter(&(&1 && &1 != ""))
                  |> Enum.join(", ")}
                </div>
                <div class="text-base-content/60">{@billing_data["email"]}</div>
                <%= if @billing_data["phone"] && @billing_data["phone"] != "" do %>
                  <div class="text-base-content/60">{@billing_data["phone"]}</div>
                <% end %>
              <% else %>
                <%= if @selected_profile do %>
                  <div class="font-medium">{profile_display_name(@selected_profile)}</div>
                  <div class="text-base-content/60">{profile_address(@selected_profile)}</div>
                  <%= if @selected_profile.email do %>
                    <div class="text-base-content/60">{@selected_profile.email}</div>
                  <% end %>
                  <%= if @selected_profile.phone do %>
                    <div class="text-base-content/60">{@selected_profile.phone}</div>
                  <% end %>
                <% end %>
              <% end %>
            </div>
          </div>
        </div>
      <% end %>

      <%!-- Shipping Info --%>
      <div class="card bg-base-100 shadow-lg">
        <div class="card-body">
          <div class="flex items-center justify-between mb-4">
            <h2 class="card-title">{gettext("Shipping Method")}</h2>
            <.link navigate={Routes.path("/cart")} class="btn btn-ghost btn-sm">
              <.icon name="hero-pencil" class="w-4 h-4 mr-1" /> {gettext("Change")}
            </.link>
          </div>

          <%= if @cart.shipping_method do %>
            <div class="flex justify-between items-center">
              <div>
                <div class="font-medium">{@cart.shipping_method.name}</div>
                <%= if @cart.shipping_method.description do %>
                  <div class="text-sm text-base-content/60">{@cart.shipping_method.description}</div>
                <% end %>
              </div>
              <div class="font-semibold">
                <%= if Decimal.compare(@cart.shipping_amount || Decimal.new("0"), Decimal.new("0")) == :eq do %>
                  <span class="text-success">{gettext("FREE")}</span>
                <% else %>
                  {format_price(@cart.shipping_amount, @currency)}
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      </div>

      <%!-- Order Items --%>
      <div class="card bg-base-100 shadow-lg">
        <div class="card-body">
          <div class="flex items-center justify-between mb-4">
            <h2 class="card-title">{gettext("Order Items")}</h2>
            <.link navigate={Routes.path("/cart")} class="btn btn-ghost btn-sm">
              <.icon name="hero-pencil" class="w-4 h-4 mr-1" /> {gettext("Edit Cart")}
            </.link>
          </div>

          <div class="space-y-4">
            <%= for item <- @cart.items do %>
              <div class="flex items-center gap-4">
                <%= if item.product_image do %>
                  <div class="w-16 h-16 bg-base-200 rounded-lg overflow-hidden flex-shrink-0">
                    <img
                      src={item.product_image}
                      alt={item.product_title}
                      class="w-full h-full object-cover"
                    />
                  </div>
                <% else %>
                  <div class="w-16 h-16 bg-base-200 rounded-lg flex items-center justify-center flex-shrink-0">
                    <.icon name="hero-cube" class="w-8 h-8 opacity-30" />
                  </div>
                <% end %>
                <div class="flex-1">
                  <div class="font-medium">{item.product_title}</div>
                  <%= if item.selected_specs && item.selected_specs != %{} do %>
                    <div class="text-xs text-base-content/60 mt-0.5">
                      <%= for {key, value} <- item.selected_specs do %>
                        <span class="inline-block mr-2">
                          <span class="font-medium">{humanize_key(key)}:</span>
                          <span>{value}</span>
                        </span>
                      <% end %>
                    </div>
                  <% end %>
                  <%!-- An on-request line carries no amount — its stored
                        unit_price is 0 — so formatting it prints "1 × 0.00" and
                        "0.00" on the LAST page before the order is placed. The
                        cart and confirmation pages route through PriceDisplay
                        for exactly this reason; the page between them did not,
                        which is the page where the customer commits. --%>
                  <% line_por = PriceDisplay.line_on_request?(item) %>
                  <div class="text-sm text-base-content/60">
                    <%= if line_por do %>
                      {gettext("Qty: %{count}", count: item.quantity)}
                    <% else %>
                      {gettext("Qty: %{count} × %{price}",
                        count: item.quantity,
                        price:
                          PriceDisplay.render(nil, @currency, :cart,
                            amount: item.unit_price,
                            unit: (item.metadata || %{})["price_unit"]
                          )
                      )}
                    <% end %>
                  </div>
                </div>
                <div class="font-semibold">
                  {PriceDisplay.render(nil, @currency, :cart,
                    amount: item.line_total,
                    unit: nil,
                    on_request: line_por
                  )}
                </div>
              </div>
            <% end %>
          </div>
        </div>
      </div>

      <%!-- Email Already Registered --%>
      <%= if @email_exists_error do %>
        <div class="card bg-warning/10 border border-warning">
          <div class="card-body">
            <div class="flex items-start gap-4">
              <.icon name="hero-user-circle" class="w-8 h-8 text-warning flex-shrink-0" />
              <div>
                <h3 class="font-semibold text-lg">{gettext("Account already exists")}</h3>
                <p class="text-sm mt-1">
                  {gettext(
                    "An account with this email is already registered. Please log in to complete your order."
                  )}
                </p>
                <div class="mt-3">
                  <.link
                    navigate={Routes.path("/users/log-in") <> "?return_to=" <> Routes.path("/checkout")}
                    class="btn btn-primary btn-sm"
                  >
                    <.icon name="hero-arrow-right-on-rectangle" class="w-4 h-4 mr-1" />
                    {gettext("Log in to continue")}
                  </.link>
                </div>
              </div>
            </div>
          </div>
        </div>
      <% end %>

      <%!-- Error Message --%>
      <%= if @error_message do %>
        <div class="alert alert-error">
          <.icon name="hero-exclamation-circle" class="w-5 h-5" />
          <span>{@error_message}</span>
        </div>
      <% end %>

      <%!-- Confirm Button --%>
      <div class="flex justify-between items-center">
        <%= cond do %>
          <% @needs_billing -> %>
            <button phx-click="back_to_billing" class="btn btn-ghost">
              <.icon name="hero-arrow-left" class="w-4 h-4" />
            </button>
          <% length(@payment_options) > 1 -> %>
            <button phx-click="back_to_payment" class="btn btn-ghost">
              <.icon name="hero-arrow-left" class="w-4 h-4" />
            </button>
          <% true -> %>
            <div></div>
        <% end %>
        <button
          phx-click="confirm_order"
          class={["btn btn-primary btn-lg"]}
          disabled={@processing}
        >
          <%= if @processing do %>
            <span class="loading loading-spinner loading-sm"></span> {gettext("Processing...")}
          <% else %>
            <.icon name="hero-check" class="w-5 h-5 mr-2" /> {gettext("Confirm Order")}
          <% end %>
        </button>
      </div>
    </div>
    """
  end

  defp order_summary(assigns) do
    assigns =
      assign_new(assigns, :requires_shipping, fn -> Shop.cart_requires_shipping?(assigns.cart) end)

    ~H"""
    <div class="card bg-base-100 shadow-lg sticky top-6">
      <div class="card-body">
        <h2 class="card-title mb-4">{gettext("Order Summary")}</h2>

        <div class="space-y-3 text-sm">
          <div class="flex justify-between">
            <span class="text-base-content/70">
              <%!-- One literal per plural form: the count is inside the label, and
                    Russian needs three forms for it. --%>
              {ngettext("Subtotal (%{count} item)", "Subtotal (%{count} items)",
                @cart.items_count || 0,
                count: @cart.items_count || 0
              )}
            </span>
            <span>{format_price(@cart.subtotal, @currency)}</span>
          </div>

          <div class="flex justify-between">
            <span class="text-base-content/70">{gettext("Shipping")}</span>
            <%= if !@requires_shipping do %>
              <span class="text-base-content/50">{gettext("Not needed")}</span>
            <% else %>
            <%= if is_nil(@cart.shipping_method_uuid) do %>
              <span class="text-base-content/50">{gettext("Select method")}</span>
            <% else %>
              <%= if Decimal.compare(@cart.shipping_amount || Decimal.new("0"), Decimal.new("0")) == :eq do %>
                <span class="text-success">{gettext("FREE")}</span>
              <% else %>
                <span>{format_price(@cart.shipping_amount, @currency)}</span>
              <% end %>
            <% end %>
            <% end %>
          </div>

          <%= if @cart.tax_amount && Decimal.compare(@cart.tax_amount, Decimal.new("0")) == :gt do %>
            <div class="flex justify-between">
              <span class="text-base-content/70">{gettext("Tax")}</span>
              <span>{format_price(@cart.tax_amount, @currency)}</span>
            </div>
          <% end %>

          <%= if @cart.discount_amount && Decimal.compare(@cart.discount_amount, Decimal.new("0")) == :gt do %>
            <div class="flex justify-between text-success">
              <span>{gettext("Discount")}</span>
              <span>-{format_price(@cart.discount_amount, @currency)}</span>
            </div>
          <% end %>

          <div class="divider my-2"></div>

          <div class="flex justify-between text-lg font-bold">
            <span>{gettext("Total")}</span>
            <span>{format_price(@cart.total, @currency)}</span>
          </div>

          <%!-- Same disclosure as the cart page, and it matters more here: this
                is the figure the shopper confirms. --%>
          <%= if PriceDisplay.any_line_on_request?(@cart.items) do %>
            <p class="text-xs text-base-content/60">
              {gettext("Items priced on request are not included in this total.")}
            </p>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
