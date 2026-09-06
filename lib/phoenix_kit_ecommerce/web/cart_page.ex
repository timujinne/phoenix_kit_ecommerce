defmodule PhoenixKitEcommerce.Web.CartPage do
  @moduledoc """
  Public cart page LiveView for E-Commerce module.

  Supports real-time cart synchronization across multiple browser tabs
  via PubSub subscription. When cart is updated in one tab, all other
  tabs receive the update automatically.
  """

  use PhoenixKitEcommerce.Web, :live_view

  alias PhoenixKit.Utils.Routes

  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Events
  alias PhoenixKitEcommerce.PriceDisplay
  alias PhoenixKitEcommerce.ShippingMethod
  alias PhoenixKitEcommerce.Translations
  alias PhoenixKitEcommerce.Vocabulary
  alias PhoenixKitEcommerce.Web.Components.ShopLayouts
  alias PhoenixKitEcommerce.Web.Helpers

  import PhoenixKitEcommerce.Web.Helpers,
    only: [format_price: 2, humanize_key: 1, get_current_user: 1]

  @impl true
  def mount(params, session, socket) do
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
    # Get session_id from session (for guest users)
    session_id = session["shop_session_id"] || generate_session_id()

    # Get current language for localized URLs
    current_language =
      (socket.assigns[:current_locale] || Translations.default_language())
      |> Helpers.put_content_locale()

    # Get current user if logged in
    user = get_current_user(socket)
    user_uuid = if user, do: user.uuid, else: nil

    # Get or create cart. Since `Cart.changeset/2` began requiring
    # `:currency`, this can FAIL: a shop whose Billing currency table has no
    # default row resolves `nil` and the changeset rejects it. That is the
    # intended loud failure, but it must not reach a shopper as a MatchError
    # crashing the page — the shop is simply not open for business yet.
    case Shop.get_or_create_cart(user_uuid: user_uuid, session_id: session_id) do
      {:ok, cart} -> mount_with_cart(socket, cart, session_id, current_language)
      {:error, _reason} -> {:ok, shop_unavailable(socket)}
    end
  end

  # The same exit the disabled-shop gate in `mount/3` takes: a flash on the
  # HOST's root, not `Routes.path("/")`.
  defp shop_unavailable(socket) do
    socket
    |> put_flash(:error, gettext("The shop is currently unavailable"))
    |> push_navigate(to: "/")
  end

  defp mount_with_cart(socket, cart, session_id, current_language) do
    # Subscribe to cart events for real-time sync across tabs
    if connected?(socket) do
      Events.subscribe_to_cart(cart)
    end

    # Shipping selection only happens on this page when it hasn't been
    # skipped entirely and the shop's configured selection position is
    # "cart" (vs. "checkout"). When it's not required here, skip fetching
    # methods and auto-selecting one - `assign_cart_state/2` mirrors this
    # same gate so a later PubSub update can't resurrect the selector.
    cart =
      if shipping_required_here?() do
        # Get available shipping methods
        shipping_methods = Shop.get_available_shipping_methods(cart)

        # Auto-select cheapest shipping method if none selected
        {:ok, cart} = Shop.auto_select_shipping_method(cart, shipping_methods)
        cart
      else
        cart
      end

    # Get default currency from Billing
    currency = Shop.currency_for_code(cart.currency)

    # Check if user is authenticated
    authenticated = not is_nil(socket.assigns[:phoenix_kit_current_user])

    socket =
      socket
      |> assign(:page_title, gettext("Shopping Cart"))
      |> assign(:session_id, session_id)
      |> assign(:currency, currency)
      |> assign(:authenticated, authenticated)
      |> assign(:current_language, current_language)
      |> assign_cart_state(cart)

    {:ok, socket}
  end

  @impl true
  def handle_event("update_quantity", %{"item_uuid" => item_uuid, "quantity" => quantity}, socket) do
    quantity = max(1, Helpers.parse_int(quantity, 1))

    update_item_quantity(socket, item_uuid, quantity)
  end

  @impl true
  def handle_event("remove_item", %{"item_uuid" => item_uuid}, socket) do
    item = Enum.find(socket.assigns.cart.items, &(&1.uuid == item_uuid))

    if item do
      case Shop.remove_from_cart(item) do
        {:ok, updated_cart} ->
          {:noreply,
           socket
           |> assign_cart_state(updated_cart)
           |> put_flash(:info, gettext("Item removed from cart"))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to remove item"))}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("select_shipping", %{"method_uuid" => method_uuid}, socket) do
    method = Enum.find(socket.assigns.shipping_methods, &(&1.uuid == method_uuid))
    cart = socket.assigns.cart

    if method do
      # Country will be set at checkout based on billing info
      case Shop.set_cart_shipping(cart, method, nil) do
        {:ok, updated_cart} ->
          {:noreply, assign(socket, :cart, updated_cart)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to set shipping method"))}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("proceed_to_checkout", _params, socket) do
    cart = socket.assigns.cart

    cond do
      cart.items == [] ->
        {:noreply, put_flash(socket, :error, gettext("Your cart is empty"))}

      is_nil(cart.shipping_method_uuid) and socket.assigns.requires_shipping and
        socket.assigns.shipping_required_here and socket.assigns.skip_mode == :off ->
        {:noreply, put_flash(socket, :error, gettext("Please select a shipping method"))}

      true ->
        {:noreply, push_navigate(socket, to: Shop.checkout_url(socket.assigns.current_language))}
    end
  end

  # One choke point for "the cart changed": refresh available methods,
  # drop a selection the cart has outgrown (or stopped needing), and keep
  # the requires-shipping flag the template gates on. Without the clearing,
  # a method that fell out of eligibility stayed selected at zero cost and
  # checkout ran into an inevitable conversion failure.
  #
  # Also the single place PubSub-driven cart updates (handle_info) run
  # through, so shipping methods are only (re)fetched here under the same
  # `shipping_required_here?/0` gate `do_mount/2` applies before its own
  # fetch+auto-select - otherwise a `:cart_updated` broadcast landing after
  # an admin flips the position to "checkout" would resurrect the cart-page
  # selector.
  defp assign_cart_state(socket, cart) do
    requires_shipping = Shop.cart_requires_shipping?(cart)
    skip_mode = Shop.shipping_skip_mode()
    position = Shop.shipping_selection_position()
    shipping_required_here = skip_mode != :always and position == :cart

    shipping_methods = load_shipping_methods(cart, requires_shipping, shipping_required_here)

    {cart, socket} =
      reconcile_shipping_selection(
        cart,
        socket,
        requires_shipping,
        shipping_required_here,
        shipping_methods
      )

    socket
    |> assign(:cart, cart)
    |> assign(:shipping_methods, shipping_methods)
    |> assign(:requires_shipping, requires_shipping)
    |> assign(:skip_mode, skip_mode)
    |> assign(:shipping_position, position)
    |> assign(:shipping_required_here, shipping_required_here)
  end

  # Available shipping methods are only fetched when shipping is both
  # needed by the cart's contents and meant to be picked on this page -
  # same gate `do_mount/2` applies before its own fetch+auto-select.
  defp load_shipping_methods(cart, requires_shipping, shipping_required_here) do
    if requires_shipping and shipping_required_here do
      Shop.get_available_shipping_methods(cart)
    else
      []
    end
  end

  # Drops a shipping selection the cart has outgrown (or stopped needing)
  # so a method that fell out of eligibility can't stay selected at zero
  # cost and run checkout into an inevitable conversion failure.
  defp reconcile_shipping_selection(
         cart,
         socket,
         requires_shipping,
         shipping_required_here,
         shipping_methods
       ) do
    cond do
      is_nil(cart.shipping_method_uuid) ->
        {cart, socket}

      not requires_shipping ->
        drop_shipping_selection(cart, socket)

      not shipping_required_here ->
        {cart, socket}

      Enum.any?(shipping_methods, &(&1.uuid == cart.shipping_method_uuid)) ->
        {cart, socket}

      true ->
        drop_shipping_selection(
          cart,
          socket,
          gettext(
            "The selected shipping method is no longer available for this cart - please pick another"
          )
        )
    end
  end

  # Clears the cart's shipping selection, optionally flashing an error
  # explaining why. Leaves cart/socket untouched if the clear fails.
  defp drop_shipping_selection(cart, socket, flash_message \\ nil) do
    case Shop.clear_cart_shipping(cart) do
      {:ok, cleared} ->
        socket = if flash_message, do: put_flash(socket, :error, flash_message), else: socket
        {cleared, socket}

      _ ->
        {cart, socket}
    end
  end

  # Shipping selection only happens on the cart page when it hasn't been
  # skipped entirely (`skip_mode != :always`) and the shop's configured
  # selection position is "cart" (vs. "checkout").
  defp shipping_required_here? do
    Shop.shipping_skip_mode() != :always and Shop.shipping_selection_position() == :cart
  end

  defp update_item_quantity(socket, item_uuid, quantity) do
    item = Enum.find(socket.assigns.cart.items, &(&1.uuid == item_uuid))

    if item do
      case Shop.update_cart_item(item, quantity) do
        {:ok, updated_cart} ->
          {:noreply, assign_cart_state(socket, updated_cart)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to update quantity"))}
      end
    else
      {:noreply, socket}
    end
  end

  # ============================================
  # PUBSUB EVENT HANDLERS
  # ============================================

  @impl true
  def handle_info({:cart_updated, cart}, socket) do
    {:noreply, assign_cart_state(socket, cart)}
  end

  @impl true
  def handle_info({:item_added, cart, _item}, socket) do
    {:noreply, assign_cart_state(socket, cart)}
  end

  @impl true
  def handle_info({:item_removed, cart, _item_id}, socket) do
    {:noreply, assign_cart_state(socket, cart)}
  end

  @impl true
  def handle_info({:quantity_updated, cart, _item}, socket) do
    {:noreply, assign_cart_state(socket, cart)}
  end

  @impl true
  def handle_info({:shipping_selected, cart}, socket) do
    {:noreply, assign(socket, :cart, cart)}
  end

  @impl true
  def handle_info({:payment_selected, cart}, socket) do
    {:noreply, assign(socket, :cart, cart)}
  end

  @impl true
  def handle_info({:cart_cleared, cart}, socket) do
    {:noreply, assign_cart_state(socket, cart)}
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
      <%!-- Page container — see shop_catalog.ex. This page and the catalog were
           the two that never had one, and relied on the module-owned layout's
           padding until that layout was removed. --%>
      <div class="p-6 max-w-7xl mx-auto">
        <%!-- Header --%>
        <header class="mb-6">
          <div class="flex items-start gap-4">
            <.link
              navigate={Shop.catalog_url(@current_language)}
              class="btn btn-ghost btn-sm"
            >
              <.icon name="hero-arrow-left" class="w-4 h-4" />
            </.link>
            <div class="flex-1 min-w-0">
              <h1 class="text-3xl font-bold text-base-content">{gettext("Shopping Cart")}</h1>
              <p class="text-base-content/70 mt-1">{gettext("Review your items before checkout")}</p>
            </div>
          </div>
        </header>

        <div class="grid grid-cols-1 lg:grid-cols-3 gap-8">
          <%!-- Cart Items --%>
          <div class="lg:col-span-2">
            <%= if @cart.items == [] do %>
              <div class="card bg-base-100 shadow-xl">
                <div class="card-body text-center py-16">
                  <.icon name="hero-shopping-cart" class="w-16 h-16 mx-auto mb-4 opacity-30" />
                  <h2 class="text-xl font-medium text-base-content/60">{gettext("Your cart is empty")}</h2>
                  <p class="text-base-content/50 mb-6">{Vocabulary.add_some_to_start()}</p>
                  <.link navigate={Shop.catalog_url(@current_language)} class="btn btn-primary">
                    {Vocabulary.browse_cta()}
                  </.link>
                </div>
              </div>
            <% else %>
              <div class="card bg-base-100 shadow-xl">
                <div class="card-body p-0">
                  <div class="overflow-x-auto">
                    <table class="table">
                      <thead>
                        <tr>
                          <th class="w-1/2">{Vocabulary.item_column()}</th>
                          <th class="text-center">{gettext("Quantity")}</th>
                          <th class="text-right">{gettext("Price")}</th>
                          <th></th>
                        </tr>
                      </thead>
                      <tbody>
                        <%= for item <- @cart.items do %>
                          <tr>
                            <td>
                              <div class="flex items-center gap-4">
                                <%= if item.product_image do %>
                                  <%= if item.product_slug do %>
                                    <.link
                                      navigate={product_item_url(item, @current_language)}
                                      class="w-16 h-16 bg-base-200 rounded-lg overflow-hidden flex-shrink-0 block"
                                    >
                                      <img
                                        src={item.product_image}
                                        alt={item.product_title}
                                        class="w-full h-full object-cover"
                                      />
                                    </.link>
                                  <% else %>
                                    <div class="w-16 h-16 bg-base-200 rounded-lg overflow-hidden flex-shrink-0">
                                      <img
                                        src={item.product_image}
                                        alt={item.product_title}
                                        class="w-full h-full object-cover"
                                      />
                                    </div>
                                  <% end %>
                                <% else %>
                                  <%= if item.product_slug do %>
                                    <.link
                                      navigate={product_item_url(item, @current_language)}
                                      class="w-16 h-16 bg-base-200 rounded-lg flex items-center justify-center flex-shrink-0 block"
                                    >
                                      <.icon name="hero-cube" class="w-8 h-8 opacity-30" />
                                    </.link>
                                  <% else %>
                                    <div class="w-16 h-16 bg-base-200 rounded-lg flex items-center justify-center flex-shrink-0">
                                      <.icon name="hero-cube" class="w-8 h-8 opacity-30" />
                                    </div>
                                  <% end %>
                                <% end %>
                                <div>
                                  <div class="font-medium">
                                    <%= if item.product_slug do %>
                                      <.link
                                        navigate={product_item_url(item, @current_language)}
                                        class="hover:text-primary transition-colors"
                                      >
                                        {item.product_title}
                                      </.link>
                                    <% else %>
                                      {item.product_title}
                                    <% end %>
                                  </div>
                                  <%= if item.product_sku do %>
                                    <div class="text-xs text-base-content/50">
                                      SKU: {item.product_sku}
                                    </div>
                                  <% end %>
                                  <%= if item.selected_specs && item.selected_specs != %{} do %>
                                    <div class="text-xs text-base-content/60 mt-1">
                                      <%= for {key, value} <- item.selected_specs do %>
                                        <span class="inline-block mr-2">
                                          <span class="font-medium">{humanize_key(key)}:</span>
                                          <span>{value}</span>
                                        </span>
                                      <% end %>
                                    </div>
                                  <% end %>
                                  <%= if item.compare_at_price && Decimal.compare(item.compare_at_price, item.unit_price) == :gt do %>
                                    <div class="text-xs">
                                      <span class="line-through text-base-content/40">
                                        {format_price(item.compare_at_price, @currency)}
                                      </span>
                                      <span class="text-success ml-1">{gettext("On sale!")}</span>
                                    </div>
                                  <% end %>
                                </div>
                              </div>
                            </td>
                            <td class="text-center">
                              <form phx-change="update_quantity" class="inline">
                                <input type="hidden" name="item_uuid" value={item.uuid} />
                                <input
                                  type="number"
                                  name="quantity"
                                  value={item.quantity}
                                  min="1"
                                  class="input input-sm w-20 text-center"
                                />
                              </form>
                            </td>
                            <td class="text-right">
                              <% line_por = PriceDisplay.line_on_request?(item) %>
                              <div class="font-semibold">
                                {PriceDisplay.render(nil, @currency, :cart,
                                  amount: item.line_total,
                                  unit: nil,
                                  on_request: line_por
                                )}
                              </div>
                              <%!-- The per-unit line is redundant once the amount
                                   is suppressed, and "Price on request each"
                                   reads as nonsense. --%>
                              <%= unless line_por do %>
                                <div class="text-xs text-base-content/50">
                                  {gettext("%{price} each",
                                    price:
                                      PriceDisplay.render(nil, @currency, :cart,
                                        amount: item.unit_price,
                                        unit: (item.metadata || %{})["price_unit"]
                                      )
                                  )}
                                </div>
                              <% end %>
                            </td>
                            <td>
                              <button
                                phx-click="remove_item"
                                phx-value-item_uuid={item.uuid}
                                class="btn btn-ghost btn-sm text-error"
                              >
                                <.icon name="hero-trash" class="w-4 h-4" />
                              </button>
                            </td>
                          </tr>
                        <% end %>
                      </tbody>
                    </table>
                  </div>
                </div>
              </div>
            <% end %>

            <%!-- Shipping Section (digital-only carts don't ship; also hidden
            when shipping selection is skipped or happens at checkout) --%>
            <%= if @cart.items != [] && @requires_shipping && @shipping_required_here do %>
              <div id="cart-shipping-methods" class="card bg-base-100 shadow-xl mt-6">
                <div class="card-body">
                  <h2 class="card-title mb-4">{gettext("Shipping Method")}</h2>

                  <%= if @shipping_methods == [] do %>
                    <div class="alert alert-warning">
                      <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
                      <span>{gettext("No shipping methods available for your selection")}</span>
                    </div>
                  <% else %>
                    <div class="space-y-3">
                      <%= for method <- @shipping_methods do %>
                        <label class={[
                          "flex items-center gap-4 p-4 border rounded-lg cursor-pointer transition-colors",
                          if(@cart.shipping_method_uuid == method.uuid,
                            do: "border-primary bg-primary/5",
                            else: "border-base-300 hover:border-primary/50"
                          )
                        ]}>
                          <input
                            type="radio"
                            name="shipping_method"
                            value={method.uuid}
                            checked={@cart.shipping_method_uuid == method.uuid}
                            phx-click="select_shipping"
                            phx-value-method_uuid={method.uuid}
                            class="radio radio-primary"
                          />
                          <div class="flex-1">
                            <div class="font-medium">{method.name}</div>
                            <%= if method.description do %>
                              <div class="text-sm text-base-content/60">{method.description}</div>
                            <% end %>
                            <%= if estimate = ShippingMethod.delivery_estimate(method) do %>
                              <div class="text-sm text-base-content/50">{estimate}</div>
                            <% end %>
                          </div>
                          <div class="text-right">
                            <%= if ShippingMethod.free_for?(method, @cart.subtotal || Decimal.new("0")) do %>
                              <span class="badge badge-success">{gettext("FREE")}</span>
                            <% else %>
                              <span class="font-semibold">
                                {format_price(method.price, @currency)}
                              </span>
                            <% end %>
                          </div>
                        </label>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>

          <%!-- Order Summary --%>
          <div class="lg:col-span-1">
            <div class="card bg-base-100 shadow-xl sticky top-6">
              <div class="card-body">
                <h2 class="card-title mb-4">{gettext("Order Summary")}</h2>

                <div class="space-y-3 text-sm">
                  <div class="flex justify-between">
                    <span class="text-base-content/70">
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

                  <%= if @cart.discount_amount && Decimal.compare(@cart.discount_amount, Decimal.new("0")) == :gt do %>
                    <div class="flex justify-between text-success">
                      <span>{gettext("Discount")}</span>
                      <span>-{format_price(@cart.discount_amount, @currency)}</span>
                    </div>
                  <% end %>

                  <%= if @cart.tax_amount && Decimal.compare(@cart.tax_amount, Decimal.new("0")) == :gt do %>
                    <div class="flex justify-between">
                      <span class="text-base-content/70">{gettext("Tax")}</span>
                      <span>{format_price(@cart.tax_amount, @currency)}</span>
                    </div>
                  <% end %>

                  <div class="divider my-2"></div>

                  <div class="flex justify-between text-lg font-bold">
                    <span>{gettext("Total")}</span>
                    <span>{format_price(@cart.total, @currency)}</span>
                  </div>

                  <%!-- An on-request line contributes 0 to every figure above, so
                        a cart holding one shows a total that is not the bill. The
                        amount stays as billing computed it; what it leaves out is
                        stated. --%>
                  <%= if PriceDisplay.any_line_on_request?(@cart.items) do %>
                    <p class="text-xs text-base-content/60">
                      {gettext(
                        "Items priced on request are not included in this total."
                      )}
                    </p>
                  <% end %>
                </div>

                <button
                  id="proceed-to-checkout"
                  phx-click="proceed_to_checkout"
                  class="btn btn-primary btn-block mt-6"
                  disabled={
                    @cart.items == [] ||
                      (is_nil(@cart.shipping_method_uuid) && @requires_shipping &&
                         @shipping_required_here && @skip_mode == :off)
                  }
                >
                  <.icon name="hero-credit-card" class="w-5 h-5 mr-2" /> {gettext("Proceed to Checkout")}
                </button>

                <%= if @cart.items != [] do %>
                  <p class="text-xs text-center text-base-content/50 mt-3">
                    {gettext("Secure checkout powered by PhoenixKit")}
                  </p>
                <% end %>
              </div>
            </div>
          </div>
        </div>
      </div>
    </ShopLayouts.shop_layout>
    """
  end

  # Private helpers

  defp generate_session_id do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp product_item_url(item, language) do
    base = DialectMapper.extract_base(language)
    Routes.path("/shop/product/#{item.product_slug}", locale: base)
  end
end
