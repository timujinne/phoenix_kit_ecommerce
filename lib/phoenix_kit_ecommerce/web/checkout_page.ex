defmodule PhoenixKitEcommerce.Web.CheckoutPage do
  @moduledoc """
  Checkout page LiveView for converting cart to order.
  Supports both logged-in users (with billing profiles) and guest checkout.

  Supports real-time cart synchronization across multiple browser tabs
  via PubSub subscription.
  """

  use PhoenixKitEcommerce.Web, :live_view

  alias PhoenixKit.Utils.CountryData
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.BillingProfile
  alias PhoenixKitBilling.PaymentOption
  alias PhoenixKitBilling.Web.Components.BillingProfileFields
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Activity
  alias PhoenixKitEcommerce.Errors
  alias PhoenixKitEcommerce.Events
  alias PhoenixKitEcommerce.ItemImage
  alias PhoenixKitEcommerce.NamePrefix
  alias PhoenixKitEcommerce.PriceDisplay
  alias PhoenixKitEcommerce.SelectedSpecs
  alias PhoenixKitEcommerce.Shipping.CartQuote
  alias PhoenixKitEcommerce.ShippingMethod
  alias PhoenixKitEcommerce.Web.Components.ShippingDestinationPicker
  alias PhoenixKitEcommerce.Web.Components.ShippingDisplay
  alias PhoenixKitEcommerce.Web.Components.ShopLayouts
  alias PhoenixKitEcommerce.Web.Helpers
  alias PhoenixKitEcommerce.Web.ShippingRequote

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

    # Before the cart is read: an update landing between a read and a later
    # subscription would never reach this page.
    if connected?(socket) do
      Events.subscribe_to_cart_of(user_uuid, session_id)
      Events.subscribe_currencies()
    end

    case Shop.find_active_cart(user_uuid: user_uuid, session_id: session_id) do
      nil ->
        {:ok, redirect_without_cart(socket, user_uuid, session)}

      cart ->
        cart = cart |> rebase_cart() |> refresh_pay_on_delivery_shipping()
        handle_cart_validation(socket, cart, user)
    end
  end

  # Same as the cart page: a shopper who only looks at a cart frozen against
  # a previous base currency must not see the old figures.
  defp rebase_cart(cart) do
    case Shop.rebase_cart(cart) do
      {:ok, rebased} -> rebased
      _ -> cart
    end
  end

  # No active cart is also what a shopper finds when this page lost its
  # process after their order was committed but before it sent them on. The
  # confirmation page does its own authorization; the session id is offered
  # only under the condition that page accepts one.
  defp redirect_without_cart(socket, user_uuid, session) do
    session_id = if session["shop_session_trusted"] == true, do: session["shop_session_id"]

    case Shop.recent_checkout_order_uuid(user_uuid: user_uuid, session_id: session_id) do
      nil ->
        redirect_to_cart(socket, gettext("Your cart is empty"))

      order_uuid ->
        push_navigate(socket,
          to: Helpers.page_path(socket.assigns, "/checkout/complete/#{order_uuid}")
        )
    end
  end

  # Same as the cart page: a method switched to pay-on-delivery after the
  # cart picked it leaves the old fee in the stored totals the summary shows.
  defp refresh_pay_on_delivery_shipping(cart) do
    case Shop.refresh_pay_on_delivery_shipping(cart) do
      {:ok, refreshed} -> refreshed
      _ -> cart
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
        if Shop.shipping_selection_position() == :checkout do
          {:ok, setup_checkout_assigns(socket, drop_shipping_selection(cart), user)}
        else
          {:ok,
           redirect_to_cart(
             socket,
             gettext(
               "The selected shipping method is no longer available for this cart - please pick another"
             )
           )}
        end

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

    if connected?(socket) do
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
    |> assign(:countries, CountryData.countries_for_select())
    |> assign(:locale, Gettext.get_locale(PhoenixKitEcommerce.Gettext))
    |> assign(:requoting, false)
    |> assign(:requote_key, nil)
    |> assign(:requote_streak, 0)
    |> assign(:checkout_shipping_methods, [])
    |> assign(:shipping_fallback, false)
    |> assign(:step, assigns.initial_step)
    |> assign(:processing, false)
    |> assign(:error_message, nil)
    |> assign(:email_exists_error, false)
    |> assign_new_billing_details(assigns.user)
    |> assign_shipping_view()
  end

  # A blank billing form: individual, nothing typed, the account email and the
  # best-guess country, and "save as a billing profile" ticked (it is only
  # ever offered to a logged-in shopper).
  defp assign_new_billing_details(socket, user) do
    socket
    |> assign(:billing_data, initial_billing_data(user, socket.assigns.cart))
    |> assign(:billing_type, "individual")
    |> assign(:billing_validate?, false)
    |> assign(:save_billing_profile, true)
    |> assign(:billing_collected?, false)
    |> assign(:save_profile_hint?, false)
    |> assign_billing_form()
  end

  # The shipping of the cart is worked out HERE, when the cart changes, and
  # handed to the render: packing, the request hash, the service list and the
  # provider's check of the destination are too much to redo on every render.
  # Only the steps that show or approve the shipping work it out; the payment
  # and billing steps carry an empty snapshot until `advance_after_billing/1`.
  defp put_cart(socket, cart) do
    socket |> assign(:cart, cart) |> assign_shipping_view()
  end

  defp assign_shipping_view(%{assigns: %{step: step}} = socket) when step in [:shipping, :review],
    do: refresh_shipping(socket)

  defp assign_shipping_view(socket) do
    socket
    |> assign(:shipping_snapshot, Shop.shipping_quote_snapshot(socket.assigns.cart, nil))
    |> assign(:shipping_presented, %{})
  end

  # Works the shipping out whatever the step: for the moments that decide on
  # it (the billing is settled, an order is placed), when the time alone can
  # change the answer (a quote ages out).
  defp refresh_shipping(socket) do
    cart = socket.assigns.cart
    snapshot = Shop.shipping_quote_snapshot(cart)

    presented =
      Map.new(socket.assigns.checkout_shipping_methods, fn method ->
        {method.uuid, presented_for(cart, snapshot, method)}
      end)

    socket
    |> assign(:shipping_snapshot, snapshot)
    |> assign(:shipping_presented, presented)
  end

  defp presented_for(cart, %{presented: %{} = presented}, %{uuid: uuid})
       when uuid == cart.shipping_method_uuid,
       do: presented

  defp presented_for(cart, _snapshot, method), do: Shop.present_shipping_method(cart, method)

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
      "country" => cart.shipping_country || Shop.default_checkout_country()
    }
  end

  # Only profile fields reach the order's snapshot, and the type changes
  # through `change_type` alone - a change event still in flight from before
  # a type click must not flip it back.
  defp merge_billing_params(socket, params) do
    fields =
      params
      |> Map.take(billing_field_names())
      |> Map.delete("type")
      |> Map.filter(fn {_field, value} -> is_binary(value) end)

    socket
    |> assign(:billing_data, Map.merge(socket.assigns.billing_data, fields))
    |> assign(:save_billing_profile, save_profile_param(params, socket))
    |> assign_billing_form()
  end

  defp proceed_with_new_billing(socket) do
    # From the first attempt on, the form shows its errors and keeps
    # re-validating as the shopper types.
    socket = socket |> assign(:billing_validate?, true) |> assign_billing_form()

    if billing_changeset(socket).valid? do
      billing_data =
        socket.assigns.billing_data
        |> clean_for_type(socket.assigns.billing_type)
        |> normalize_vat_number()

      {:noreply,
       socket
       |> assign(:billing_data, billing_data)
       |> assign(:billing_collected?, true)
       |> assign_billing_form()
       |> advance_after_billing()}
    else
      {:noreply, put_flash(socket, :error, gettext("Please fill in all required fields"))}
    end
  end

  # The billing form state is a changeset over a blank profile - the same
  # rules billing applies when it saves one - behind `to_form/2` under the
  # `billing[...]` namespace. `billing_data` stays the plain string-keyed map
  # the context takes; the form is derived from it on every change.
  defp assign_billing_form(socket, extra_errors \\ []) do
    changeset = Enum.reduce(extra_errors, billing_changeset(socket), &add_missing_error/2)

    changeset =
      if socket.assigns.billing_validate?, do: %{changeset | action: :validate}, else: changeset

    socket
    |> assign(:billing_form, to_form(changeset, as: :billing))
    |> assign(:require_billing_address, Shop.cart_requires_shipping?(socket.assigns.cart))
    |> assign(
      :subdivision_label,
      CountryData.get_subdivision_label(socket.assigns.billing_data["country"])
    )
  end

  # An error the context reported that the form's own validation did not.
  defp add_missing_error({field, {message, opts}}, changeset) do
    if Enum.any?(changeset.errors, &match?({^field, {^message, _}}, &1)) do
      changeset
    else
      Ecto.Changeset.add_error(changeset, field, message, opts)
    end
  end

  # The fields the form actually renders for the chosen type.
  @shared_billing_fields ~w(email phone country address_line1 address_line2 city state
                            postal_code)a
  defp visible_billing_fields(%{assigns: %{billing_type: "company"}}) do
    @shared_billing_fields ++
      ~w(company_name company_vat_number company_registration_number company_legal_address)a
  end

  defp visible_billing_fields(_socket),
    do: @shared_billing_fields ++ ~w(first_name middle_name last_name)a

  # The shop adds to billing's rules: the country is always needed (it drives
  # tax and shipping), and a cart that ships needs the full address. Validate
  # only the selected type; the other type's draft stays available in `data`
  # without hidden errors blocking the form.
  defp billing_changeset(socket) do
    %{billing_data: data, billing_type: type, cart: cart} = socket.assigns

    params =
      data
      |> clean_for_type(type)
      |> Map.put("type", type)
      |> Map.put("save_profile", to_string(socket.assigns.save_billing_profile))

    %BillingProfile{}
    |> BillingProfile.fields_changeset(params,
      require_email: true,
      require_address: Shop.cart_requires_shipping?(cart)
    )
    |> keep_blank_country(data["country"])
    |> Ecto.Changeset.validate_required([:country])
  end

  # `cast/3` turns a blank param into the schema default, and a billing
  # profile's country defaults to "EE" - so a shopper who has not picked a
  # country would silently get one. Keep it blank so it is reported missing.
  defp keep_blank_country(changeset, country) do
    if is_nil(country) or String.trim(country) == "" do
      Ecto.Changeset.force_change(changeset, :country, nil)
    else
      changeset
    end
  end

  defp billing_field_names, do: Enum.map(BillingProfile.form_fields(), &to_string/1)

  # An unticked checkbox still posts its hidden "false", so absence only
  # happens for a payload that does not carry the checkbox at all.
  defp save_profile_param(%{"save_profile" => value}, _socket), do: value == "true"
  defp save_profile_param(_params, socket), do: socket.assigns.save_billing_profile

  # Fields of the type that is NOT selected stay in the form state while the
  # shopper flips between the two (so nothing typed is lost), but must not
  # reach the order or the saved profile.
  @individual_only_fields ~w(first_name last_name middle_name)
  @company_only_fields ~w(company_name company_vat_number company_registration_number
                          company_legal_address)

  # Billing stores the VAT number upper-cased; the order snapshot gets the
  # same form.
  defp normalize_vat_number(%{"company_vat_number" => vat} = data) when is_binary(vat) do
    Map.put(data, "company_vat_number", vat |> String.trim() |> String.upcase())
  end

  defp normalize_vat_number(data), do: data

  defp clean_for_type(data, "company"), do: Map.drop(data, @individual_only_fields)
  defp clean_for_type(data, _individual), do: Map.drop(data, @company_only_fields)

  defp billing_incomplete_message(cart) do
    if Shop.cart_requires_shipping?(cart) do
      gettext("Please complete the billing address - a physical order needs one")
    else
      gettext("Please complete your billing details - this payment method needs them")
    end
  end

  defp redirect_to_cart(socket, message) do
    socket
    |> put_flash(:error, message)
    |> navigate_to_cart()
  end

  # The cart in the page's own language — not whatever Gettext holds, which
  # is how a checkout redirect used to land on `/en/cart` from a `/uk/` page.
  defp navigate_to_cart(socket) do
    push_navigate(socket, to: Helpers.page_path(socket.assigns, "/cart"))
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
           |> put_cart(updated_cart)
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
    # A blank form (account email and default country only) rather than a
    # copy of the selected profile: the shopper chose "new details" to type
    # something different, and a prefilled copy would be saved right back as
    # a duplicate.
    {:noreply,
     socket
     |> assign_new_billing_details(get_current_user(socket))
     |> assign(:use_new_profile, true)
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
    {:noreply, socket |> merge_billing_params(params) |> assign(:save_profile_hint?, false)}
  end

  @impl true
  def handle_event("change_type", %{"type" => type}, socket)
      when type in ["individual", "company"] do
    {:noreply,
     socket
     |> assign(:billing_type, type)
     |> assign(:billing_data, Map.put(socket.assigns.billing_data, "type", type))
     |> assign_billing_form()}
  end

  # Only the two radios send this event; anything else is ignored rather
  # than crashing the checkout.
  def handle_event("change_type", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("proceed_to_review", params, socket) do
    if socket.assigns.use_new_profile do
      # A form submit (Enter) carries the values itself; the button's click
      # does not, and relies on the change events that already merged them.
      socket =
        case params do
          %{"billing" => billing} -> merge_billing_params(socket, billing)
          _ -> socket
        end

      proceed_with_new_billing(socket)
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
      {:ok, cart} -> {:noreply, put_cart(socket, cart)}
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_event("shipping_continue", _params, socket) do
    socket = refresh_shipping(socket)
    cart = socket.assigns.cart

    # A method chosen from the list, or the fallback notice's own
    # "we'll contact you" path - anything else means the shopper has not
    # actually settled shipping yet, so the step holds. So does a calculated
    # method whose delivery place or price is not settled (the button is
    # disabled then; this is the same rule for a client that clicks anyway).
    cond do
      socket.assigns.shipping_snapshot.blocks? ->
        {:noreply, socket}

      cart.shipping_method_uuid || socket.assigns.shipping_fallback ->
        {:noreply, enter_review(socket)}

      true ->
        {:noreply, socket}
    end
  end

  # From the review: the delivery place or its price needs another look.
  @impl true
  def handle_event("back_to_shipping", _params, socket) do
    {:noreply, assign_shipping_step(socket)}
  end

  # The carrier could not be reached for the delivery options: ask again.
  @impl true
  def handle_event("recheck_shipping", _params, socket) do
    {:noreply, socket |> refresh_shipping() |> settle_shipping()}
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
  # Only from the review step: the button exists nowhere else, and every
  # earlier step is where billing and shipping get settled.
  def handle_event("confirm_order", _params, %{assigns: %{step: step}} = socket)
      when step != :review do
    {:noreply, socket}
  end

  def handle_event("confirm_order", _params, socket) do
    # A carrier-priced method is ordered at a price the carrier just gave. One
    # that aged out since the review was drawn is renewed first (the button is
    # off meanwhile); the order is placed on the next click.
    socket = refresh_shipping(socket)

    if socket.assigns.shipping_snapshot.blocks? do
      {:noreply, settle_shipping(socket)}
    else
      {:noreply, place_order(socket)}
    end
  end

  # Last, so it shadows nothing: an event this page does not know, or a
  # known one whose payload is not the shape its clause takes.
  def handle_event(event, _params, socket), do: Helpers.ignore_event(event, socket)

  defp place_order(socket) do
    socket = assign(socket, :processing, true)

    cart = socket.assigns.cart

    # Get user identifier from current scope if logged in
    user_uuid =
      case socket.assigns[:phoenix_kit_current_scope] do
        %{user: %{uuid: uuid}} -> uuid
        _ -> nil
      end

    # Only a logged-in shopper typing new details is offered (and can ask
    # for) a saved profile - the context refuses it for anyone else too.
    # Only when the form was actually filled in: a payment option that needs
    # no billing step reaches review with a blank form, and saving THAT would
    # fail and take the whole order down with it.
    save_profile? =
      socket.assigns.use_new_profile and not is_nil(user_uuid) and
        socket.assigns.save_billing_profile and socket.assigns.billing_collected?

    # Re-check ownership at the point of USE, not just at selection. The
    # selection handler guards the normal path, but `selected_profile_uuid`
    # is plain socket state and this is the event that writes it onto a
    # persisted order — the one place where being wrong costs someone their
    # address. Cheap check, last line of defence.
    if socket.assigns.use_new_profile or
         owned_profile_uuid?(socket, socket.assigns.selected_profile_uuid) do
      result = Shop.convert_cart_to_order(cart, convert_opts(socket, user_uuid, save_profile?))
      if save_profile?, do: log_billing_profile_saved(result, socket)
      handle_order_result(result, socket)
    else
      socket
      |> assign(:processing, false)
      |> assign(:selected_profile_uuid, nil)
      |> put_flash(:error, gettext("That billing profile is not available."))
    end
  end

  # Options for `convert_cart_to_order/2`.
  defp convert_opts(%{assigns: %{use_new_profile: true}} = socket, user_uuid, save_profile?) do
    # Guest or new profile - use billing_data directly
    [
      billing_data: socket.assigns.billing_data,
      user_uuid: user_uuid,
      language: socket.assigns[:current_locale]
    ] ++
      if(save_profile?, do: [save_billing_profile: true], else: [])
  end

  defp convert_opts(socket, user_uuid, _save_profile?) do
    # Logged-in user with existing profile
    [
      billing_profile_uuid: socket.assigns.selected_profile_uuid,
      user_uuid: user_uuid,
      language: socket.assigns[:current_locale]
    ]
  end

  # The profile was created inside the conversion transaction, so an order
  # that came back carrying a profile uuid means it was saved and committed.
  defp log_billing_profile_saved({:ok, %{billing_profile_uuid: profile_uuid} = order}, socket)
       when not is_nil(profile_uuid) do
    Activity.log("shop.checkout_billing_profile_saved",
      actor_uuid: Activity.actor_uuid(socket),
      actor_role: Activity.actor_role(socket),
      mode: "checkout",
      resource_type: "billing_profile",
      resource_uuid: profile_uuid,
      metadata: %{"order_uuid" => order.uuid}
    )
  end

  defp log_billing_profile_saved(_result, _socket), do: :ok

  # The single decision point for "billing is settled, what's next" - reached
  # both from the billing form (`proceed_to_review`, either path: an existing
  # profile selected or new billing data saved) and from a mount that lands
  # directly on review (`build_checkout_socket/2`, an authenticated shopper
  # whose payment option needs no billing step at all). Both must see the
  # same shipping step when one is due - a shopper who never touched the
  # billing form is not exempt from picking a shipping method.
  defp advance_after_billing(socket) do
    socket = refresh_shipping(socket)

    case next_step_after_billing(socket) do
      :shipping -> assign_shipping_step(socket)
      :review -> enter_review(socket)
    end
  end

  # `:shipping` only when there is something to decide: skipping isn't
  # unconditional (`:always` already has nothing to pick), the cart actually
  # ships something, and either
  #
  #   * selection happens at checkout (not the cart page) and no method is
  #     selected yet (a tab that already picked one, or came back from
  #     review, has nothing left to do here), or
  #   * the selected method is carrier-priced and needs the shopper: the
  #     delivery place is missing or refused, or the method cannot serve the
  #     cart - whichever page the method was picked on, the picker of this
  #     step is where that gets finished.
  #
  # A carrier-priced method whose place is known but whose price is missing or
  # out of date (a new payment option, which can change what the carrier
  # charges; a quote that aged out) needs no one: the review asks the carrier
  # itself.
  defp next_step_after_billing(socket) do
    cart = socket.assigns.cart

    if Shop.shipping_skip_mode() != :always and Shop.cart_requires_shipping?(cart) and
         (shipping_unselected_here?(cart) or
            shipping_needs_shopper?(socket.assigns.shipping_snapshot)) do
      :shipping
    else
      :review
    end
  end

  # What only the shopper can settle: a place that is missing or refused, a
  # method that cannot serve the cart. A carrier that could not be asked for
  # its options (a transient failure) is a retry, not a reason to go back.
  defp shipping_needs_shopper?(%{status: :needs_destination}), do: true

  defp shipping_needs_shopper?(%{status: :unavailable, transient?: transient?}),
    do: not transient?

  defp shipping_needs_shopper?(_snapshot), do: false

  defp shipping_unselected_here?(cart) do
    Shop.shipping_selection_position() == :checkout and is_nil(cart.shipping_method_uuid)
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
    |> assign_shipping_view()
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
        socket = put_cart(socket, cart)

        cond do
          not shipping_selection_still_valid?(cart) ->
            reject_invalid_shipping_selection(socket)

          # The delivery of a calculated method is not settled (the billing
          # country, a new payment option or the time spent here): the
          # review never approves it.
          socket.assigns.shipping_snapshot.blocks? ->
            settle_shipping(socket)

          true ->
            assign(socket, :requote_streak, 0)
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
  defp reject_invalid_shipping_selection(
         socket,
         message \\ gettext(
           "The selected shipping method is not available for your address - please pick another"
         )
       ) do
    if Shop.shipping_selection_position() == :checkout do
      socket
      |> put_cart(drop_shipping_selection(socket.assigns.cart))
      |> assign_shipping_step()
      |> put_flash(:error, message)
    else
      socket
      |> assign(:step, :shipping_invalid)
      |> put_flash(:error, message)
      |> navigate_to_cart()
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

  # A calculated method whose delivery is not settled, met on the review or
  # when the order is placed. A missing or out-of-date price is asked of the
  # carrier right here; a place the carrier refuses (or a method that cannot
  # serve the cart) needs the shopper, who gets the shipping step.
  defp settle_shipping(socket) do
    snapshot = socket.assigns.shipping_snapshot

    cond do
      snapshot.status in [:missing, :stale] -> requote_review(socket)
      shipping_needs_shopper?(snapshot) -> assign_shipping_step(socket)
      true -> socket
    end
  end

  # Asks the carrier, unless that was just done for this very state of the
  # cart (see `ShippingRequote`) or an answer is on its way.
  defp requote_review(%{assigns: %{requoting: true}} = socket), do: socket

  defp requote_review(socket) do
    %{cart: cart, locale: locale, requote_streak: streak} = socket.assigns
    status = socket.assigns.shipping_snapshot.status

    if connected?(socket) and
         ShippingRequote.due?(cart, status, socket.assigns.requote_key, streak) do
      socket
      |> assign(:requoting, true)
      |> assign(:requote_key, ShippingRequote.key(cart, status))
      |> assign(:requote_streak, streak + 1)
      |> start_async(:requote, fn -> Shop.quote_cart_shipping(cart, locale: locale) end)
    else
      socket
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
          {:ok, priced} -> put_cart(socket, priced)
          {:error, _} -> put_cart(socket, cart)
        end
      else
        put_cart(socket, cart)
      end

    socket
    |> assign(:fx_drift, Shop.cart_rate_drift(socket.assigns.cart))
    |> requote_stale_review()
  end

  # On the review a price that went stale is renewed without the shopper
  # having to do anything.
  defp requote_stale_review(%{assigns: %{step: :review}} = socket) do
    if socket.assigns.shipping_snapshot.status in [:missing, :stale] do
      requote_review(socket)
    else
      assign(socket, :requote_streak, 0)
    end
  end

  defp requote_stale_review(socket), do: socket

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
    |> push_navigate(to: Helpers.page_path(socket.assigns, "/checkout/complete/#{order.uuid}"))
  end

  # A second click on "Confirm Order" lands here: the first one already made
  # the order, so the shopper goes to it instead of reading an error. Two
  # requests racing (two tabs) get `:cart_already_converting` when the loser
  # waited on the winner's lock; the winner has committed by then.
  defp handle_order_result({:error, reason}, socket)
       when reason in [:cart_not_active, :cart_already_converting] do
    case Shop.converted_order_uuid(socket.assigns.cart.uuid) do
      nil ->
        message = Errors.message(reason)

        socket
        |> assign(:processing, false)
        |> assign(:error_message, message)
        |> put_flash(:error, message)

      order_uuid ->
        socket
        |> assign(:processing, false)
        |> push_navigate(
          to: Helpers.page_path(socket.assigns, "/checkout/complete/#{order_uuid}")
        )
    end
  end

  defp handle_order_result({:error, :cart_empty}, socket) do
    socket
    |> assign(:processing, false)
    |> navigate_to_cart()
  end

  defp handle_order_result({:error, :no_shipping_method}, socket) do
    socket
    |> assign(:processing, false)
    |> reject_invalid_shipping_selection(gettext("Please select a shipping method"))
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
    |> reject_invalid_shipping_selection()
  end

  # A carrier-priced method whose quote is missing, out of date or refused:
  # the price the shopper saw is not one the order can carry. It is renewed
  # (or, when it needs the shopper, the shipping step opens) with the cart as
  # it is now.
  defp handle_order_result({:error, :shipping_quote_required}, socket) do
    cart = Shop.get_cart(socket.assigns.cart.uuid) || socket.assigns.cart

    socket
    |> assign(:processing, false)
    |> put_cart(cart)
    |> settle_shipping()
    |> put_flash(
      :error,
      gettext("The delivery price needs to be confirmed - please check your delivery details")
    )
  end

  defp handle_order_result({:error, {:product_not_available, _uuid}}, socket) do
    socket
    |> assign(:processing, false)
    |> put_flash(:error, gettext("An item in your cart is no longer available"))
    |> navigate_to_cart()
  end

  defp handle_order_result({:error, :product_not_available}, socket) do
    socket
    |> assign(:processing, false)
    |> put_flash(:error, gettext("An item in your cart is no longer available"))
    |> navigate_to_cart()
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
    |> put_flash(:error, billing_incomplete_message(socket.assigns.cart))
  end

  defp handle_order_result({:error, reason}, socket)
       when reason in [:billing_profile_not_found, :billing_profile_not_owned] do
    socket
    |> assign(:processing, false)
    |> assign(:selected_profile_uuid, nil)
    |> assign(:step, :billing)
    |> put_flash(:error, gettext("That billing profile is not available."))
  end

  # The entered details did not make a valid profile - the whole conversion
  # rolled back, so no order exists. Back to the editable form with the
  # context's own errors on it. An error no field shows (the profile's owner,
  # its name) gets a hint next to the save box instead: unticking it places
  # the order without the profile.
  defp handle_order_result({:error, {:billing_profile_invalid, changeset}}, socket) do
    socket =
      socket
      |> assign(:processing, false)
      |> assign(:step, :billing)
      |> assign(:billing_validate?, true)
      |> assign_billing_form(changeset.errors)

    hint? =
      Enum.any?(changeset.errors, fn {field, _} ->
        field not in visible_billing_fields(socket)
      end)

    socket
    |> assign(:save_profile_hint?, hint?)
    |> put_flash(
      :error,
      gettext("The billing details could not be saved - please check the highlighted fields")
    )
  end

  defp handle_order_result({:error, :payment_option_unavailable}, socket) do
    socket
    |> assign(:processing, false)
    |> put_flash(
      :error,
      gettext("The selected payment method is no longer available - please pick another")
    )
    |> navigate_to_cart()
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
  # not a retype. The profile already exists, so saving it again is off by
  # default, and the form opens showing what is still missing.
  defp prefill_from_selected_profile(socket) do
    case Enum.find(
           socket.assigns.billing_profiles,
           &(to_string(&1.uuid) == to_string(socket.assigns.selected_profile_uuid))
         ) do
      nil ->
        socket

      profile ->
        socket
        |> assign(:billing_data, profile_form_data(profile, socket.assigns.billing_data))
        |> assign(:billing_type, profile.type || "individual")
        |> assign(:billing_validate?, true)
        |> assign(:save_billing_profile, false)
        |> assign(:billing_collected?, false)
        |> assign_billing_form()
    end
  end

  # Field-for-field copy of a saved profile into the editable form's shape.
  @profile_form_fields ~w(type first_name last_name middle_name phone company_name
                          company_vat_number company_registration_number
                          company_legal_address address_line1 address_line2 city state
                          postal_code country)a

  defp profile_form_data(profile, current) do
    base =
      Map.new(@profile_form_fields, fn field ->
        {to_string(field), Map.get(profile, field) || ""}
      end)

    # The email is the one field the customer may have typed before picking
    # a profile, so a blank profile email must not wipe it.
    Map.put(base, "email", profile.email || current["email"] || "")
  end

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

  # The picker's saves and quotes, the review's own quote: the cart as it is.
  # What this page already holds is not worked out again.
  @impl true
  def handle_info({:shipping_selected, cart}, socket) do
    if ShippingRequote.same_cart?(cart, socket.assigns.cart) do
      {:noreply, socket}
    else
      {:noreply, assign_cart_repriced(socket, cart)}
    end
  end

  # The picker says the answer may have changed without the cart (the delivery
  # options were asked for again, the carrier refused the request).
  @impl true
  def handle_info(:shipping_recheck, socket) do
    {:noreply, socket |> refresh_shipping() |> requote_stale_review()}
  end

  @impl true
  def handle_info({:payment_selected, cart}, socket) do
    # Also update selected_payment_option if it changed
    selected = Enum.find(socket.assigns.payment_options, &(&1.uuid == cart.payment_option_uuid))

    {:noreply,
     socket
     |> put_cart(cart)
     |> assign(:selected_payment_option, selected)
     |> requote_stale_review()}
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
  def handle_info(message, socket), do: Helpers.ignore_message(message, socket)

  # ============================================
  # ASYNC: THE CARRIER'S PRICE ON THE REVIEW
  # ============================================

  @impl true
  def handle_async(:requote, {:ok, {:ok, cart}}, socket) do
    {:noreply, socket |> assign(:requoting, false) |> assign_cart_repriced(cart)}
  end

  # The cart changed while the carrier was asked: read it as it is now.
  def handle_async(:requote, {:ok, {:error, :stale}}, socket) do
    socket = assign(socket, :requoting, false)

    case Shop.get_cart(socket.assigns.cart.uuid) do
      nil -> {:noreply, socket}
      cart -> {:noreply, assign_cart_repriced(socket, cart)}
    end
  end

  # What the shopper has to finish (the place was refused, the method cannot
  # serve this cart) is finished on the shipping step.
  def handle_async(:requote, {:ok, {:error, reason}}, socket)
      when reason == :needs_destination or (is_tuple(reason) and elem(reason, 0) == :unavailable) do
    socket = socket |> assign(:requoting, false) |> refresh_shipping()

    {:noreply,
     if(shipping_needs_shopper?(socket.assigns.shipping_snapshot),
       do: assign_shipping_step(socket),
       else: socket
     )}
  end

  def handle_async(:requote, _failed, socket) do
    {:noreply, assign(socket, :requoting, false)}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :shipping_blocked, shipping_blocked?(assigns))

    ~H"""
    <ShopLayouts.shop_layout {assigns}>
      <div class="p-6 max-w-6xl mx-auto">
        <div class="flex items-center justify-between mb-8">
          <h1 class="text-3xl font-bold">{gettext("Checkout")}</h1>
          <.link navigate={Helpers.page_path(assigns, "/cart")} class="btn btn-ghost btn-sm">
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
              phx-disable-with={gettext("Working…")}
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
                  current_locale={assigns[:current_locale]}
                  is_guest={@is_guest}
                  billing_profiles={@billing_profiles}
                  selected_profile_uuid={@selected_profile_uuid}
                  use_new_profile={@use_new_profile}
                  needs_profile_selection={@needs_profile_selection}
                  billing_form={@billing_form}
                  billing_type={@billing_type}
                  countries={@countries}
                  subdivision_label={@subdivision_label}
                  require_address={@require_billing_address}
                  save_profile_hint={@save_profile_hint?}
                  payment_options={@payment_options}
                />
              <% :shipping -> %>
                <.shipping_step
                  methods={@checkout_shipping_methods}
                  fallback={@shipping_fallback}
                  cart={@cart}
                  currency={@currency}
                  locale={@locale}
                  needs_billing={@needs_billing}
                  shipping_blocked={@shipping_blocked}
                  snapshot={@shipping_snapshot}
                  presented={@shipping_presented}
                />
              <% :review -> %>
                <.review_step
                  current_locale={assigns[:current_locale]}
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
                  shipping_blocked={@shipping_blocked}
                  snapshot={@shipping_snapshot}
                  requoting={@requoting}
                />
            <% end %>
          </div>

          <%!-- Order Summary Sidebar --%>
          <div class="lg:col-span-1">
            <.order_summary
              cart={@cart}
              currency={@currency}
              shipping_blocked={@shipping_blocked}
              snapshot={@shipping_snapshot}
            />
          </div>
        </div>
      </div>
    </ShopLayouts.shop_layout>
    """
  end

  # Whether a carrier-priced method still lacks its delivery place or price.
  # Only the steps that show or approve the shipping ask: the question can
  # reach the carrier's service list, which the earlier steps never need.
  defp shipping_blocked?(%{step: step, shipping_snapshot: snapshot})
       when step in [:shipping, :review],
       do: snapshot.blocks?

  defp shipping_blocked?(_assigns), do: false

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
          <%= if @use_new_profile do %>
            {gettext("Billing Information")}
          <% else %>
            {gettext("Select Billing Profile")}
          <% end %>
        </h2>

        <%= if @use_new_profile do %>
          <%!-- Guest checkout, no profiles, or "use new details" - show billing form --%>
          <button
            :if={@billing_profiles != []}
            type="button"
            id="checkout-use-saved-billing"
            phx-click="use_existing_profile"
            class="btn btn-ghost btn-sm mb-4"
          >
            <.icon name="hero-arrow-left" class="w-4 h-4" /> {gettext("Back to saved profiles")}
          </button>

          <.billing_form
            billing_form={@billing_form}
            billing_type={@billing_type}
            countries={@countries}
            subdivision_label={@subdivision_label}
            require_address={@require_address}
            show_save_profile={not @is_guest}
            save_profile_hint={@save_profile_hint}
          />
        <% else %>
          <%!-- Authenticated user with multiple profiles - show selector --%>
          <.profile_selector
            current_locale={@current_locale}
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
            <.link navigate={Helpers.page_path(assigns, "/dashboard/billing-profiles")} class="link">
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
                Helpers.page_path(
                  assigns,
                  "/dashboard/billing-profiles/#{profile.uuid}/edit"
                ) <> "?return_to=" <> Helpers.page_path(assigns, "/checkout")
              }
              class="btn btn-ghost btn-sm"
            >
              <.icon name="hero-pencil" class="w-4 h-4" />
            </.link>
          <% end %>
        </div>
      <% end %>

      <button
        type="button"
        id="checkout-use-new-billing"
        phx-click="use_new_profile"
        class="btn btn-ghost btn-sm"
      >
        <.icon name="hero-plus" class="w-4 h-4" /> {gettext("Use new details")}
      </button>
    </div>
    """
  end

  # The fields are billing's own component, so the checkout form and the
  # profile forms cannot drift. The type radios click through to
  # `change_type`; everything else is the form's `phx-change`.
  defp billing_form(assigns) do
    ~H"""
    <.form
      for={@billing_form}
      id="checkout-billing-form"
      phx-change="update_billing"
      phx-submit="proceed_to_review"
    >
      <BillingProfileFields.billing_profile_fields
        form={@billing_form}
        type={@billing_type}
        countries={@countries}
        subdivision_label={@subdivision_label}
        id_prefix="checkout-billing"
        show_options={false}
        require_email
        require_address={@require_address}
      >
        <.checkbox
          :if={@show_save_profile}
          field={@billing_form[:save_profile]}
          id="checkout-save-billing-profile"
          label={gettext("Save as a billing profile")}
        />
        <p
          :if={@show_save_profile and @save_profile_hint}
          id="checkout-save-billing-profile-hint"
          class="text-sm text-error"
        >
          {gettext(
            "This profile could not be saved. Untick \"Save as a billing profile\" to place the order without saving it."
          )}
        </p>
      </BillingProfileFields.billing_profile_fields>
    </.form>
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
              <div :for={method <- @methods} class="space-y-2">
                <label
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
                  <%!-- `method.price` is a BASE amount; the cart is in its own
                       currency, so present it through the cart's frozen rate. --%>
                  <% presented = @presented[method.uuid] %>
                  <div id={"checkout-shipping-price-#{method.uuid}"} class="font-semibold text-right">
                    <%= cond do %>
                      <% presented.pay_on_delivery? -> %>
                        <span class="badge badge-info badge-soft whitespace-nowrap">
                          {gettext("Paid on delivery")}
                        </span>
                      <% presented.free? -> %>
                        <span class="badge badge-success">{gettext("FREE")}</span>
                      <% presented.quote_status in [:needs_destination, :missing, :stale] -> %>
                        <span class="text-sm font-normal text-base-content/60">
                          {gettext("Calculated for your address")}
                        </span>
                      <% presented.quote_status == :unavailable -> %>
                        <span class="badge badge-error badge-soft whitespace-nowrap">
                          {gettext("Not available")}
                        </span>
                      <% true -> %>
                        {format_price(presented.price, @currency)}
                    <% end %>
                  </div>
                </label>

                <%!-- Where a carrier-priced method delivers, and what it charges. --%>
                <.live_component
                  :if={@cart.shipping_method_uuid == method.uuid and ShippingMethod.calculated?(method)}
                  module={ShippingDestinationPicker}
                  id={"shipping-picker-#{method.uuid}"}
                  cart={@cart}
                  method={method}
                  snapshot={@snapshot}
                  locale={@locale}
                  currency={@currency}
                />
              </div>
            </div>
            <div class="flex items-center gap-3 mt-6">
              <button
                id="checkout-shipping-continue"
                class="btn btn-primary"
                phx-click="shipping_continue"
                disabled={
                  @shipping_blocked or not Enum.any?(@methods, &(&1.uuid == @cart.shipping_method_uuid))
                }
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

    assigns =
      assigns
      |> assign(:selected_profile, selected_profile)
      |> assign(:shipping_details, review_shipping_details(assigns.cart, assigns.snapshot))

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
                <div class="font-medium">{profile_display_name(@billing_data)}</div>
                <div class="text-base-content/60">{profile_address(@billing_data)}</div>
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
            <.link navigate={Helpers.page_path(assigns, "/cart")} class="btn btn-ghost btn-sm">
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
              <div id="checkout-review-shipping-price" class="font-semibold">
                <%= cond do %>
                  <% PriceDisplay.cart_shipping_pay_on_delivery?(@cart) -> %>
                    {gettext("Paid on delivery")}
                  <% Decimal.compare(@cart.shipping_amount || Decimal.new("0"), Decimal.new("0")) == :eq -> %>
                    <span class="text-success">{gettext("FREE")}</span>
                  <% true -> %>
                    {format_price(@cart.shipping_amount, @currency)}
                <% end %>
              </div>
            </div>

            <%!-- A carrier-priced method: where it delivers, when, and the
                 notes that belong to the carrier's quote. --%>
            <div :if={@shipping_details} class="mt-3 space-y-1.5">
              <p
                :if={@shipping_details.label}
                id="checkout-review-shipping-destination"
                class="flex items-start gap-1.5 text-sm"
              >
                <.icon name="hero-map-pin" class="w-4 h-4 mt-0.5 shrink-0 text-base-content/60" />
                <span class="break-words">{@shipping_details.label}</span>
              </p>
              <ShippingDisplay.quote_details
                id="checkout-review-shipping"
                eta={@shipping_details.eta}
                cod_fee={@shipping_details.cod_fee}
                currency={@shipping_details.currency}
                fallback={@shipping_details.fallback?}
              />
              <button
                id="checkout-review-change-shipping"
                type="button"
                class="btn btn-ghost btn-xs"
                phx-click="back_to_shipping"
              >
                <.icon name="hero-pencil" class="w-3.5 h-3.5" /> {gettext("Change delivery details")}
              </button>
            </div>
          <% end %>
        </div>
      </div>

      <%!-- Order Items --%>
      <div class="card bg-base-100 shadow-lg">
        <div class="card-body">
          <div class="flex items-center justify-between mb-4">
            <h2 class="card-title">{gettext("Order Items")}</h2>
            <.link navigate={Helpers.page_path(assigns, "/cart")} class="btn btn-ghost btn-sm">
              <.icon name="hero-pencil" class="w-4 h-4 mr-1" /> {gettext("Edit Cart")}
            </.link>
          </div>

          <div class="space-y-4">
            <%= for item <- @cart.items do %>
              <% display_title = NamePrefix.strip(item.product_title) %>
              <div class="flex items-center gap-4">
                <% item_image = ItemImage.url(item) %>
                <%= if item_image do %>
                  <div class="w-16 h-16 bg-base-200 rounded-lg overflow-hidden flex-shrink-0">
                    <img
                      src={item_image}
                      alt={display_title}
                      class="w-full h-full object-cover"
                    />
                  </div>
                <% else %>
                  <div class="w-16 h-16 bg-base-200 rounded-lg flex items-center justify-center flex-shrink-0">
                    <.icon name="hero-cube" class="w-8 h-8 opacity-30" />
                  </div>
                <% end %>
                <div class="flex-1">
                  <div class="font-medium">{display_title}</div>
                  <%= if item.selected_specs && item.selected_specs != %{} do %>
                    <div class="text-xs text-base-content/60 mt-0.5">
                      <%= for {key, value} <- SelectedSpecs.labels(item) do %>
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
                    navigate={
                      Helpers.page_path(assigns, "/users/log-in") <>
                        "?return_to=" <> Helpers.page_path(assigns, "/checkout")
                    }
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

      <%!-- The delivery price went stale (the cart or the payment changed, or
           the carrier's answer aged out): it is settled on the shipping step. --%>
      <div :if={@requoting} id="checkout-review-shipping-requoting" class="alert alert-info">
        <span class="loading loading-spinner loading-sm"></span>
        <span>{gettext("Updating the delivery price...")}</span>
      </div>
      <div
        :if={@shipping_blocked and not @requoting}
        id="checkout-review-shipping-blocked"
        class="alert alert-warning"
      >
        <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
        <%= if @snapshot.transient? do %>
          <span class="flex-1">
            {gettext("Delivery options are temporarily unavailable. Please try again in a moment.")}
          </span>
          <button
            id="checkout-review-retry-shipping"
            type="button"
            class="btn btn-sm"
            phx-click="recheck_shipping"
          >
            {gettext("Try again")}
          </button>
        <% else %>
          <span class="flex-1">
            {gettext(
              "The delivery price needs to be confirmed - please check your delivery details"
            )}
          </span>
          <button
            id="checkout-review-recheck-shipping"
            type="button"
            class="btn btn-sm"
            phx-click="back_to_shipping"
          >
            {gettext("Check delivery details")}
          </button>
        <% end %>
      </div>

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
          id="checkout-confirm-order"
          phx-click="confirm_order"
          phx-disable-with={gettext("Processing...")}
          class={["btn btn-primary btn-lg"]}
          disabled={@processing or @shipping_blocked or @requoting}
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

  # What the review shows of a carrier-priced method: `nil` for an ordinary one.
  defp review_shipping_details(
         %{shipping_method: %ShippingMethod{} = method} = cart,
         %{presented: %{} = presented, entry: entry}
       ) do
    if ShippingMethod.calculated?(method) do
      estimate = presented.estimate

      %{
        label: cart |> Shop.cart_shipping_destination() |> CartQuote.destination_label(),
        eta: (estimate && estimate.eta) || (entry && entry.quote && entry.quote.eta),
        cod_fee: estimate && estimate.cod_fee,
        currency: (estimate && estimate.currency) || cart.currency,
        fallback?: presented.quote_status == :fallback
      }
    end
  end

  defp review_shipping_details(_cart, _snapshot), do: nil

  # Carrier-priced delivery that has no price yet; a pay-on-delivery method
  # charges the shop nothing either way.
  defp shipping_unsettled?(%{cart: cart, snapshot: %{blocks?: true}}) do
    not is_nil(cart.shipping_method_uuid) and
      not ShippingMethod.pay_on_delivery?(cart.shipping_method)
  end

  defp shipping_unsettled?(_assigns), do: false

  defp order_summary(assigns) do
    assigns =
      assigns
      |> assign_new(:requires_shipping, fn -> Shop.cart_requires_shipping?(assigns.cart) end)
      |> assign(:shipping_unsettled, shipping_unsettled?(assigns))

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

          <div id="checkout-summary-shipping" class="flex justify-between">
            <span class="text-base-content/70">{gettext("Shipping")}</span>
            <%= if !@requires_shipping do %>
              <span class="text-base-content/50">{gettext("Not needed")}</span>
            <% else %>
            <%= cond do %>
              <% is_nil(@cart.shipping_method_uuid) -> %>
                <span class="text-base-content/50">{gettext("Select method")}</span>
              <% @shipping_unsettled and @snapshot.status == :unavailable -> %>
                <span class="text-error">{gettext("Not available")}</span>
              <% @shipping_unsettled -> %>
                <span class="text-base-content/50">{gettext("To be calculated")}</span>
              <% PriceDisplay.cart_shipping_pay_on_delivery?(@cart) -> %>
                <span>{gettext("Paid on delivery")}</span>
              <% Decimal.compare(@cart.shipping_amount || Decimal.new("0"), Decimal.new("0")) == :eq -> %>
                <span class="text-success">{gettext("FREE")}</span>
              <% true -> %>
                <span>{format_price(@cart.shipping_amount, @currency)}</span>
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

          <div id="checkout-summary-total" class="flex justify-between text-lg font-bold">
            <span>{gettext("Total")}</span>
            <span>
              <span :if={@shipping_unsettled}>≈</span>
              {format_price(@cart.total, @currency)}
            </span>
          </div>

          <%!-- The total of a cart whose carrier-priced delivery is not settled
                carries the price of the method as a placeholder: said so. --%>
          <p
            :if={@shipping_unsettled and @snapshot.status != :unavailable}
            id="checkout-summary-total-estimate"
            class="text-xs text-base-content/60"
          >
            {gettext("The delivery cost is still to be calculated: the total will change.")}
          </p>

          <%!-- Same disclosure as the cart page, and it matters more here: this
                is the figure the shopper confirms. --%>
          <%= if PriceDisplay.any_line_on_request?(@cart.items) do %>
            <p class="text-xs text-base-content/60">
              {gettext("Items priced on request are not included in this total.")}
            </p>
          <% end %>

          <%= if @requires_shipping && PriceDisplay.cart_shipping_pay_on_delivery?(@cart) do %>
            <p id="checkout-shipping-pay-on-delivery-note" class="text-xs text-base-content/60">
              {gettext(
                "Shipping is not included in this total: you pay the carrier at their rates on delivery."
              )}
            </p>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
