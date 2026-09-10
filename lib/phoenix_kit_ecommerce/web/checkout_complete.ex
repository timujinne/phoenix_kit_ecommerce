defmodule PhoenixKitEcommerce.Web.CheckoutComplete do
  @moduledoc """
  Order confirmation page after successful checkout.
  """

  use PhoenixKitEcommerce.Web, :live_view

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.NamePrefix
  alias PhoenixKitEcommerce.Policy
  alias PhoenixKitEcommerce.PriceDisplay
  alias PhoenixKitEcommerce.Web.Components.ShopLayouts
  alias PhoenixKitEcommerce.Web.Helpers

  import PhoenixKitEcommerce.Web.Helpers,
    only: [
      format_price: 2,
      profile_display_name: 1,
      profile_address: 1,
      profile_email: 1,
      get_current_user: 1
    ]

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes

  @impl true
  def mount(%{"uuid" => uuid}, session, socket) do
    # Without this the page renders English whatever the locale — see
    # Helpers.put_content_locale/1.
    _ = Helpers.put_content_locale_from(socket)
    user = get_current_user(socket)

    # Only a session id of trusted provenance may unlock an order. An id
    # adopted from a pre-signing cookie is replayable by anyone who obtained
    # it out-of-band, so it identifies a CART but proves nothing about who
    # placed an order. See `ShopSession.put_shop_session/3`.
    shop_session_id =
      if session["shop_session_trusted"] == true, do: session["shop_session_id"]

    case Billing.get_order_by_uuid(uuid) do
      nil ->
        {:ok, redirect_with_error(socket, gettext("Order not found"))}

      order ->
        handle_order_access(socket, order, user, shop_session_id)
    end
  end

  defp handle_order_access(socket, order, user, shop_session_id) do
    if has_order_access?(order, user, shop_session_id) do
      {:ok, setup_order_assigns(socket, order)}
    else
      {:ok, redirect_with_error(socket, gettext("You don't have access to this order"))}
    end
  end

  # Who may read an order confirmation — including its billing snapshot
  # (name, address, phone, email), which this page renders.
  #
  # Ownership by the logged-in user always grants access. Beyond that the
  # behaviour is an admin choice; see
  # `PhoenixKitEcommerce.Policy.order_lookup_policy/0`.
  #
  #   :strict (default) — the visitor must hold the shop session that
  #     placed the order. This is what makes a guest's own confirmation
  #     page work right after checkout without making it world-readable.
  #
  #   :link — knowing the uuid is enough, for shops that deliberately mail
  #     "view your order" links and accept the URL as the credential.
  #
  # The previous behaviour was unconditionally :link for guests, and worse
  # than it looked: `guest_user_order?` returned true for ANY order whose
  # owner had `confirmed_at: nil`, and guest checkout creates exactly such
  # users — so every guest order, and every order of a registered but
  # unconfirmed user, was readable forever by anyone with the uuid.
  defp has_order_access?(order, user, shop_session_id) do
    cond do
      not is_nil(user) and order.user_uuid == user.uuid -> true
      placed_in_session?(order, shop_session_id) -> true
      Policy.order_lookup_policy() == :link -> true
      true -> false
    end
  end

  # Orders record the shop session that placed them (see the metadata built
  # in `PhoenixKitEcommerce.build_order_attrs/*`).
  #
  # Orders placed BEFORE that was recorded fall back to the cart: they
  # carry `metadata["cart_uuid"]`, and the cart row survives conversion
  # with its `session_id`. Without this fallback, tightening order access
  # would have locked every existing guest out of their own past
  # confirmation pages on upgrade — a silent break for every deployed
  # shop, not just a theoretical one.
  #
  # The fallback costs one narrow query, and only for orders that predate
  # the change AND are being viewed by someone who is not the owner.
  defp placed_in_session?(_order, nil), do: false
  defp placed_in_session?(_order, ""), do: false

  defp placed_in_session?(%{metadata: metadata}, shop_session_id) when is_map(metadata) do
    case Map.get(metadata, "session_id") do
      stored when is_binary(stored) and stored != "" ->
        Plug.Crypto.secure_compare(stored, shop_session_id)

      _ ->
        legacy_cart_session?(metadata, shop_session_id)
    end
  end

  defp placed_in_session?(_order, _shop_session_id), do: false

  defp legacy_cart_session?(metadata, shop_session_id) do
    case Shop.cart_session_id(Map.get(metadata, "cart_uuid")) do
      stored when is_binary(stored) and stored != "" ->
        Plug.Crypto.secure_compare(stored, shop_session_id)

      _ ->
        false
    end
  end

  defp setup_order_assigns(socket, order) do
    currency = Shop.currency_for_code(order.currency)
    billing_profile = get_billing_profile(order)
    {is_guest_order, order_email} = check_guest_order(order)

    # Check if user is authenticated
    authenticated = not is_nil(socket.assigns[:phoenix_kit_current_user])

    socket
    |> assign(:page_title, gettext("Order Confirmed"))
    |> assign(:order, order)
    |> assign(:currency, currency)
    |> assign(:billing_profile, billing_profile)
    |> assign(:is_guest_order, is_guest_order)
    |> assign(:order_email, order_email)
    |> assign(:authenticated, authenticated)
  end

  # The order's own snapshot is the record of who it was billed to; the
  # live profile is a fallback for orders that predate snapshots (it is
  # editable, so preferring it made history mutable).
  defp get_billing_profile(order) do
    Helpers.order_billing_identity(order) || live_billing_profile(order)
  end

  defp live_billing_profile(%{billing_profile_uuid: nil}), do: nil
  defp live_billing_profile(%{billing_profile_uuid: uuid}), do: Billing.get_billing_profile(uuid)

  defp check_guest_order(%{user_uuid: nil} = order) do
    email = get_in(order.billing_snapshot, ["email"])
    {not is_nil(email), email}
  end

  defp check_guest_order(%{user_uuid: user_uuid}) do
    case Auth.get_user(user_uuid) do
      %{confirmed_at: nil, email: email} -> {true, email}
      _ -> {false, nil}
    end
  end

  defp redirect_with_error(socket, message) do
    socket
    |> put_flash(:error, message)
    |> push_navigate(to: Routes.path("/shop"))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <ShopLayouts.shop_layout {assigns}>
      <div class="p-6 max-w-3xl mx-auto">
        <%!-- Success Header --%>
        <div class="text-center mb-8">
          <div class="w-20 h-20 bg-success/20 rounded-full flex items-center justify-center mx-auto mb-4">
            <.icon name="hero-check-circle" class="w-12 h-12 text-success" />
          </div>
          <h1 class="text-3xl font-bold mb-2">{gettext("Order Confirmed!")}</h1>
          <p class="text-base-content/60">
            {gettext("Thank you for your order. We've received your order and will process it shortly.")}
          </p>
          <%= if @order.metadata["shipping_skipped"] do %>
            <div id="shipping-pending-notice" class="alert alert-info mt-4">
              {gettext("We will contact you to arrange shipping and confirm your order details.")}
            </div>
          <% end %>
        </div>

        <%!-- Guest Order Email Confirmation Reminder --%>
        <%= if @is_guest_order do %>
          <div class="card bg-info/10 border border-info mb-6">
            <div class="card-body">
              <div class="flex items-start gap-4">
                <.icon name="hero-envelope" class="w-8 h-8 text-info flex-shrink-0" />
                <div>
                  <h3 class="font-semibold text-lg">{gettext("Check your inbox")}</h3>
                  <p class="text-sm mt-1">
                    {gettext("We've sent a confirmation email to")}
                    <strong>{@order_email}</strong>.
                  </p>
                  <ol class="text-sm mt-3 space-y-1.5 list-decimal list-inside text-base-content/80">
                    <li>
                      {gettext("Open the email titled")}
                      <strong>{gettext("Confirm your account")}</strong>
                    </li>
                    <li>{gettext("Click the confirmation link inside")}</li>
                    <li>{gettext("Your account will be activated and you can track your order")}</li>
                  </ol>
                  <p class="text-xs text-base-content/50 mt-3">
                    {gettext("Don't see it? Check your spam or junk folder. The email may take a minute to arrive.")}
                  </p>
                </div>
              </div>
            </div>
          </div>
        <% end %>

        <%!-- Order Number --%>
        <div class="card bg-base-100 shadow-lg mb-6">
          <div class="card-body text-center">
            <div class="text-sm text-base-content/60">{gettext("Order Number")}</div>
            <div class="text-2xl font-mono font-bold">{@order.order_number}</div>
            <%= unless @is_guest_order do %>
              <%!-- Deliberately does NOT promise a confirmation email. Nothing in
                   this module sends one to a signed-in customer: the only mail
                   checkout sends is the guest ACCOUNT confirmation above. The
                   sentence that used to sit here was simply false, and a live
                   shop reported it. --%>
              <div class="text-sm text-base-content/60 mt-2">
                {gettext("You can follow this order from your account at any time.")}
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Order Details --%>
        <div class="card bg-base-100 shadow-lg mb-6">
          <div class="card-body">
            <h2 class="card-title mb-4">{gettext("Order Details")}</h2>

            <%!-- Billing Info --%>
            <%= if @billing_profile do %>
              <div class="mb-6">
                <h3 class="font-medium text-sm text-base-content/70 mb-2">{gettext("Billing Information")}</h3>
                <div class="text-sm">
                  <div class="font-medium">{profile_display_name(@billing_profile)}</div>
                  <div class="text-base-content/60">{profile_address(@billing_profile)}</div>
                  <%= if profile_email(@billing_profile) do %>
                    <div class="text-base-content/60">{profile_email(@billing_profile)}</div>
                  <% end %>
                </div>
              </div>
            <% else %>
              <%!-- Guest order - show billing snapshot --%>
              <%= if @order.billing_snapshot && map_size(@order.billing_snapshot) > 0 do %>
                <div class="mb-6">
                  <h3 class="font-medium text-sm text-base-content/70 mb-2">{gettext("Billing Information")}</h3>
                  <div class="text-sm">
                    <div class="font-medium">
                      {@order.billing_snapshot["first_name"]} {@order.billing_snapshot["last_name"]}
                    </div>
                    <div class="text-base-content/60">
                      {[
                        @order.billing_snapshot["address_line1"],
                        @order.billing_snapshot["city"],
                        @order.billing_snapshot["postal_code"],
                        @order.billing_snapshot["country"]
                      ]
                      |> Enum.filter(&(&1 && &1 != ""))
                      |> Enum.join(", ")}
                    </div>
                    <%= if @order.billing_snapshot["email"] do %>
                      <div class="text-base-content/60">{@order.billing_snapshot["email"]}</div>
                    <% end %>
                  </div>
                </div>
              <% end %>
            <% end %>

            <%!-- Items --%>
            <div class="mb-6">
              <h3 class="font-medium text-sm text-base-content/70 mb-2">{gettext("Items")}</h3>
              <div class="space-y-3">
                <%= for item <- @order.line_items || [] do %>
                  <% display_name = NamePrefix.strip(item["name"]) %>
                  <div class="flex justify-between items-center text-sm">
                    <div>
                      <span class="font-medium">{display_name}</span>
                      <%= if item["type"] != "shipping" do %>
                        <span class="text-base-content/60 ml-2">× {item["quantity"]}</span>
                      <% end %>
                    </div>
                    <%!-- The unit belongs to the UNIT price, never to the line
                          total: "€40.00 per hour" × 2 hours is a line total of
                          €80.00, and rendering that as "€80.00 per hour"
                          misstates the rate the customer agreed to. Same
                          split as the cart page. --%>
                    <% line_por = PriceDisplay.line_on_request?(item) %>
                    <div class="font-medium text-right">
                      {PriceDisplay.render(nil, @currency, :order,
                        amount: item["total"],
                        on_request: line_por
                      )}
                      <%= if !line_por and item["price_unit"] not in [nil, ""] do %>
                        <div class="text-xs font-normal text-base-content/50">
                          {gettext("%{price} each",
                            price:
                              PriceDisplay.render(nil, @currency, :order,
                                amount: item["unit_price"],
                                unit: item["price_unit"]
                              )
                          )}
                        </div>
                      <% end %>
                    </div>
                  </div>
                <% end %>
              </div>
            </div>

            <%!-- Totals --%>
            <div class="border-t pt-4 space-y-2">
              <div class="flex justify-between text-sm">
                <span class="text-base-content/70">{gettext("Subtotal")}</span>
                <span>{format_price(@order.subtotal, @currency)}</span>
              </div>

              <%= if @order.tax_amount && Decimal.compare(@order.tax_amount, Decimal.new("0")) == :gt do %>
                <div class="flex justify-between text-sm">
                  <span class="text-base-content/70">{gettext("Tax")}</span>
                  <span>{format_price(@order.tax_amount, @currency)}</span>
                </div>
              <% end %>

              <%= if @order.discount_amount && Decimal.compare(@order.discount_amount, Decimal.new("0")) == :gt do %>
                <div class="flex justify-between text-sm text-success">
                  <span>{gettext("Discount")}</span>
                  <span>-{format_price(@order.discount_amount, @currency)}</span>
                </div>
              <% end %>

              <div class="flex justify-between text-lg font-bold pt-2 border-t">
                <span>{gettext("Total")}</span>
                <span>{format_price(@order.total, @currency)}</span>
              </div>

              <%!-- The receipt for a committed order must not imply the total is
                    everything owed when an on-request line contributed 0 to it. --%>
              <%= if PriceDisplay.any_line_on_request?(@order.line_items) do %>
                <p class="text-xs text-base-content/60">
                  {gettext("Items priced on request are not included in this total.")}
                </p>
              <% end %>
            </div>
          </div>
        </div>

        <%!-- Status --%>
        <div class="card bg-base-100 shadow-lg mb-6">
          <div class="card-body">
            <div class="flex items-center justify-between">
              <div>
                <h3 class="font-medium">{gettext("Order Status")}</h3>
                <p class="text-sm text-base-content/60">{gettext("Your order is being processed")}</p>
              </div>
              <div class="badge badge-warning badge-lg capitalize">{@order.status}</div>
            </div>
          </div>
        </div>

        <%!-- Actions --%>
        <div class="flex justify-center gap-4">
          <.link navigate={Routes.path("/shop")} class="btn btn-primary">
            <.icon name="hero-shopping-bag" class="w-5 h-5 mr-2" /> {gettext("Continue Shopping")}
          </.link>
          <%= if @authenticated do %>
            <.link navigate={Routes.path("/dashboard/orders")} class="btn btn-outline">
              <.icon name="hero-clipboard-document-list" class="w-5 h-5 mr-2" /> {gettext("My Orders")}
            </.link>
          <% end %>
        </div>
      </div>
    </ShopLayouts.shop_layout>
    """
  end

  # Helpers
end
