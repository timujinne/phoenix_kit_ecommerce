defmodule PhoenixKitEcommerce.Web.Components.ShippingDestinationPicker do
  @moduledoc """
  Where a calculated shipping method delivers, and what the carrier charges
  for it: the picker of the cart page and of the checkout shipping step.

  A LiveComponent although this module's convention is to avoid them: the
  picker owns state of its own (the search text, the lists the carrier
  answered, the quote in flight) and several `start_async` jobs, and it lives
  in two different LiveViews. Keeping that here is cheaper than duplicating it
  in both.

  ## Assigns

    * `id` - the DOM id, `"shipping-picker-<method uuid>"`
    * `cart` - the cart (with items); the picker keeps its own copy as the
      buyer's choices change it
    * `method` - the selected, calculated `PhoenixKitEcommerce.ShippingMethod`
    * `locale` - the locale the carrier's texts are asked in
    * `currency` - the cart currency struct, for the amounts

  ## What it shows

  What the service of the method asks for (`Service.destination`, `lookup`):

    * `:pickup_point` with `:search` - a city search, then the points of the
      city with a filter
    * `:pickup_point` with `:manual` - the city and the code of the point typed
      in (`PickupPoint.manual/1`)
    * `:address` - the street, house and apartment, after a city search or
      with the city typed in
    * `:none` - nothing to ask, the price is requested straight away

  A complete destination is shown as a summary with a "Change" button, and
  the quote under it: the price, the delivery time, the cash-on-delivery fee
  and the note on an estimated price (the carrier did not answer), or why the
  method cannot serve this cart.

  A quote is requested by itself while the cart's quote is `:missing` or
  `:stale` (once per change of the cart, at most three times in a row), so a
  new payment option or quantity re-prices the delivery without a click.

  ## Messages to the parent

  Whenever the cart changes, `{:shipping_cart_updated, cart}` is sent to the
  parent LiveView, which assigns the cart so that the totals render again.
  """

  use PhoenixKitEcommerce.Web, :live_component

  import PhoenixKitEcommerce.Web.Helpers, only: [format_price: 2]

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Shipping

  alias PhoenixKitEcommerce.Shipping.{
    Address,
    CartQuote,
    Destination,
    Locality,
    PickupPoint
  }

  alias PhoenixKitEcommerce.Web.Components.ShippingDisplay
  alias PhoenixKitEcommerce.Web.ShippingRequote

  @max_localities 15
  @max_points 50

  @editor_state [
    editor_seeded?: false,
    locality: nil,
    locality_query: "",
    localities: [],
    localities_state: :idle,
    localities_error: nil,
    points: [],
    points_state: :idle,
    points_truncated?: false,
    points_error: nil,
    point_query: "",
    form: %{},
    form_errors: %{},
    save_error: nil
  ]

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(@editor_state)
     |> assign(
       service_key: nil,
       service: nil,
       service_error: nil,
       editing: nil,
       quote_state: :idle,
       auto_key: nil,
       auto_streak: 0
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(Map.take(assigns, [:id, :cart, :method, :locale, :currency]))
      |> ensure_service()
      |> refresh()
      |> maybe_auto_quote()

    {:ok, socket}
  end

  # -- service ----------------------------------------------------------

  # The service is looked up once per method (and again when its settings
  # change): `Shipping.services/1` is cached, but not free.
  defp ensure_service(socket) do
    %{method: method, locale: locale} = socket.assigns
    key = :erlang.phash2({method.uuid, method.metadata})

    if socket.assigns.service_key == key do
      socket
    else
      {service, error} = load_service(method, locale)

      socket
      |> assign(@editor_state)
      |> assign(
        service_key: key,
        service: service,
        service_error: error,
        editing: nil,
        quote_state: :idle,
        auto_key: nil,
        auto_streak: 0
      )
    end
  end

  defp load_service(method, locale) do
    ctx = Shipping.context(method, locale: locale)

    case Shipping.services(ctx) do
      {:ok, []} ->
        {%Shipping.Service{key: ctx.service, destination: :none}, nil}

      {:ok, services} ->
        case Enum.find(services, &(&1.key == ctx.service)) do
          nil -> {nil, :unknown_service}
          service -> {service, nil}
        end

      {:error, reason} ->
        {nil, reason}
    end
  end

  # -- state derived from the cart --------------------------------------

  defp refresh(%{assigns: %{service: nil}} = socket), do: socket

  defp refresh(socket) do
    %{cart: cart, method: method, service: service} = socket.assigns

    destination = Shop.cart_shipping_destination(cart)
    presented = Shop.present_shipping_method(cart, method)
    entry = Shop.cart_shipping_quote(cart)
    complete? = not CartQuote.incomplete?(service.destination, destination)
    rejected? = complete? and presented.quote_status == :needs_destination

    socket
    |> assign(
      destination: destination,
      destination_label: CartQuote.destination_label(destination),
      complete?: complete?,
      rejected?: rejected?,
      presented: presented,
      status: presented.quote_status,
      entry: entry,
      editing: editing?(socket.assigns.editing, complete?, rejected?)
    )
    |> assign_quote_details(presented, entry)
    |> sync_editor()
  end

  # An incomplete (or refused) destination can only be edited; otherwise it is
  # edited when the buyer asked to.
  defp editing?(_editing, complete?, rejected?) when not complete? or rejected?, do: true
  defp editing?(nil, _complete?, _rejected?), do: false
  defp editing?(editing, _complete?, _rejected?), do: editing

  defp assign_quote_details(socket, presented, entry) do
    estimate = presented.estimate
    stored = entry && entry.quote

    assign(socket,
      eta: (estimate && estimate.eta) || (stored && stored.eta),
      cod_fee: estimate && estimate.cod_fee,
      cod_currency: (estimate && estimate.currency) || socket.assigns.cart.currency
    )
  end

  defp sync_editor(%{assigns: %{editing: true}} = socket) do
    socket |> seed_editor() |> maybe_load_points()
  end

  defp sync_editor(socket), do: socket

  defp seed_editor(%{assigns: %{editor_seeded?: true}} = socket), do: socket

  defp seed_editor(socket) do
    %{service: service, destination: destination} = socket.assigns

    locality =
      with %Shipping.Service{lookup: :search} <- service,
           %Destination{locality: %Locality{id: id} = locality} when is_binary(id) <- destination do
        locality
      else
        _ -> nil
      end

    assign(socket,
      editor_seeded?: true,
      locality: locality,
      form: form_from(service, destination)
    )
  end

  defp form_from(%Shipping.Service{destination: :pickup_point}, destination) do
    %{
      "locality" => destination |> locality_of() |> field(:name),
      "point" => destination |> point_of() |> field(:id)
    }
  end

  defp form_from(%Shipping.Service{destination: :address, lookup: lookup}, destination) do
    locality = locality_of(destination)
    address = address_of(destination)

    %{
      "locality" => field(locality, :name),
      "postcode" => postcode_of(address, locality, lookup),
      "street" => field(address, :street),
      "house" => field(address, :house),
      "apartment" => field(address, :apartment)
    }
  end

  defp form_from(_service, _destination), do: %{}

  defp postcode_of(address, locality, lookup) do
    [field(address, :postcode), if(lookup == :search, do: field(locality, :postcode))]
    |> Enum.find("", &(is_binary(&1) and &1 != ""))
  end

  defp locality_of(%Destination{locality: locality}), do: locality
  defp locality_of(_destination), do: nil
  defp point_of(%Destination{pickup_point: point}), do: point
  defp point_of(_destination), do: nil
  defp address_of(%Destination{address: address}), do: address
  defp address_of(_destination), do: nil

  defp field(nil, _key), do: ""
  defp field(struct, key), do: Map.get(struct, key) || ""

  defp maybe_load_points(%{assigns: assigns} = socket) do
    if match?(%Shipping.Service{destination: :pickup_point, lookup: :search}, assigns.service) and
         assigns.locality != nil and assigns.points_state == :idle and connected?(socket) do
      load_points(socket)
    else
      socket
    end
  end

  # -- quote ------------------------------------------------------------

  # A quote is asked for once per state of the cart (see `ShippingRequote`).
  defp maybe_auto_quote(socket) do
    assigns = socket.assigns

    cond do
      not connected?(socket) or is_nil(assigns.service) or assigns.quote_state == :loading ->
        socket

      assigns.status not in [:missing, :stale] ->
        assign(socket, auto_streak: 0)

      assigns.method.uuid != assigns.cart.shipping_method_uuid ->
        socket

      not ShippingRequote.due?(
        assigns.cart,
        assigns.status,
        assigns.auto_key,
        assigns.auto_streak
      ) ->
        socket

      true ->
        socket |> assign(auto_streak: assigns.auto_streak + 1) |> start_quote()
    end
  end

  defp start_quote(socket) do
    %{cart: cart, locale: locale} = socket.assigns

    socket
    |> assign(
      quote_state: :loading,
      auto_key: ShippingRequote.key(cart, socket.assigns.status)
    )
    |> start_async(:quote, fn -> Shop.quote_cart_shipping(cart, locale: locale) end)
  end

  defp maybe_start_quote(socket) do
    if socket.assigns.status in [:missing, :stale], do: start_quote(socket), else: socket
  end

  defp notify(socket, cart) do
    send(self(), {:shipping_cart_updated, cart})
    socket
  end

  # -- async ------------------------------------------------------------

  @impl true
  def handle_async(:quote, {:ok, {:ok, cart}}, socket) do
    {:noreply, socket |> assign(cart: cart, quote_state: :idle) |> refresh() |> notify(cart)}
  end

  # The cart changed while the carrier was asked: read it again, and let the
  # next quote (automatic if the cart really differs) answer for it.
  def handle_async(:quote, {:ok, {:error, :stale}}, socket) do
    socket =
      case Shop.get_cart(socket.assigns.cart.uuid) do
        nil -> socket
        cart -> socket |> assign(cart: cart) |> notify(cart)
      end

    {:noreply, socket |> assign(quote_state: :idle) |> refresh() |> maybe_auto_quote()}
  end

  # The state of the cart tells these (the destination is refused, the method
  # cannot serve it); the status is read again.
  def handle_async(:quote, {:ok, {:error, reason}}, socket)
      when reason == :needs_destination or (is_tuple(reason) and elem(reason, 0) == :unavailable) do
    {:noreply, socket |> assign(quote_state: :idle) |> refresh()}
  end

  def handle_async(:quote, _failed, socket) do
    {:noreply, assign(socket, quote_state: :error)}
  end

  def handle_async(:localities, {:ok, {:ok, localities}}, socket) do
    localities = localities |> Enum.filter(&locality_with_id?/1) |> Enum.take(@max_localities)

    {:noreply,
     assign(socket, localities: localities, localities_state: :done, localities_error: nil)}
  end

  def handle_async(:localities, {:ok, {:error, reason}}, socket) do
    {:noreply, assign(socket, localities_state: :error, localities_error: lookup_error(reason))}
  end

  def handle_async(:localities, {:exit, {:shutdown, :cancel}}, socket), do: {:noreply, socket}

  def handle_async(:localities, {:exit, _reason}, socket) do
    {:noreply, assign(socket, localities_state: :error, localities_error: lookup_error(nil))}
  end

  def handle_async(:points, {:ok, {:ok, points}}, socket) do
    points = Enum.filter(points, &point_with_id?/1)

    {:noreply,
     assign(socket,
       points: Enum.take(points, @max_points),
       points_truncated?: length(points) > @max_points,
       points_state: :done,
       points_error: nil
     )}
  end

  def handle_async(:points, {:ok, {:error, reason}}, socket) do
    {:noreply, assign(socket, points_state: :error, points_error: lookup_error(reason))}
  end

  def handle_async(:points, {:exit, {:shutdown, :cancel}}, socket), do: {:noreply, socket}

  def handle_async(:points, {:exit, _reason}, socket) do
    {:noreply, assign(socket, points_state: :error, points_error: lookup_error(nil))}
  end

  defp locality_with_id?(%Locality{id: id}), do: is_binary(id) and id != ""
  defp locality_with_id?(_other), do: false
  defp point_with_id?(%PickupPoint{id: id}), do: is_binary(id) and id != ""
  defp point_with_id?(_other), do: false

  defp lookup_error(:timeout),
    do: gettext("The carrier did not answer in time. Please try again.")

  defp lookup_error(_reason),
    do: gettext("The list could not be loaded right now. Please try again.")

  defp load_points(socket) do
    %{method: method, locale: locale, locality: locality, point_query: query, cart: cart} =
      socket.assigns

    parcels = Shop.cart_parcels(cart)
    declared_value = Shop.cart_declared_value(cart)

    socket
    |> assign(points_state: :loading, points_error: nil)
    |> start_async(:points, fn ->
      method
      |> Shipping.context(locale: locale)
      |> Shipping.list_pickup_points(locality, query,
        parcels: parcels,
        declared_value: declared_value
      )
    end)
  end

  # -- events -----------------------------------------------------------

  @impl true
  def handle_event("locality_search", %{"q" => text}, socket) do
    query = String.trim(text)
    socket = assign(socket, locality_query: text)

    if String.length(query) < 2 do
      {:noreply,
       socket
       |> cancel_async(:localities)
       |> assign(localities: [], localities_state: :idle, localities_error: nil)}
    else
      %{method: method, locale: locale} = socket.assigns

      {:noreply,
       socket
       |> assign(localities_state: :loading, localities_error: nil)
       |> start_async(:localities, fn ->
         method |> Shipping.context(locale: locale) |> Shipping.search_localities(query)
       end)}
    end
  end

  def handle_event("pick_locality", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.localities, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      locality ->
        case Shop.set_cart_shipping_destination(socket.assigns.cart, %Destination{
               locality: locality
             }) do
          {:ok, cart} ->
            {:noreply,
             socket
             |> assign(
               cart: cart,
               locality: locality,
               localities: [],
               localities_state: :idle,
               locality_query: "",
               points: [],
               points_state: :idle,
               point_query: "",
               form: put_postcode(socket.assigns.form, locality),
               save_error: nil
             )
             |> refresh()
             |> notify(cart)}

          {:error, reason} ->
            {:noreply, assign(socket, save_error: save_error(reason))}
        end
    end
  end

  def handle_event("change_locality", _params, socket) do
    {:noreply,
     socket
     |> cancel_async(:points)
     |> assign(
       locality: nil,
       points: [],
       points_state: :idle,
       point_query: "",
       locality_query: "",
       save_error: nil
     )}
  end

  def handle_event("filter_points", %{"q" => text}, socket) do
    {:noreply, socket |> assign(point_query: text) |> load_points()}
  end

  def handle_event("retry_points", _params, socket), do: {:noreply, load_points(socket)}

  def handle_event("pick_point", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.points, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      point ->
        save_complete(socket, %Destination{locality: socket.assigns.locality, pickup_point: point})
    end
  end

  def handle_event("manual_change", %{"manual" => params}, socket) do
    {:noreply, assign(socket, form: params)}
  end

  def handle_event("apply_manual", %{"manual" => params}, socket) do
    locality = text(params, "locality")
    code = text(params, "point")

    errors =
      %{}
      |> require_text(:locality, locality, gettext("Please enter the city"))
      |> validate_point_code(socket.assigns.service, code)

    if errors == %{} do
      save_complete(socket, %Destination{
        locality: %Locality{name: locality},
        pickup_point: PickupPoint.manual(code)
      })
    else
      {:noreply, assign(socket, form: params, form_errors: errors)}
    end
  end

  def handle_event("address_change", %{"address" => params}, socket) do
    {:noreply, assign(socket, form: params)}
  end

  def handle_event("apply_address", %{"address" => params}, socket) do
    service = socket.assigns.service
    manual? = service.lookup == :manual

    errors =
      %{}
      |> require_text(:street, text(params, "street"), gettext("Please enter the street"))
      |> require_text(:house, text(params, "house"), gettext("Please enter the house number"))
      |> require_if(
        manual?,
        :locality,
        text(params, "locality"),
        gettext("Please enter the city")
      )
      |> require_if(
        manual?,
        :postcode,
        text(params, "postcode"),
        gettext("Please enter the postcode")
      )

    if errors == %{} do
      save_complete(socket, %Destination{
        locality: address_locality(socket.assigns.locality, params, manual?),
        address: %Address{
          postcode: blank_to_nil(text(params, "postcode")),
          street: text(params, "street"),
          house: text(params, "house"),
          apartment: blank_to_nil(text(params, "apartment"))
        }
      })
    else
      {:noreply, assign(socket, form: params, form_errors: errors)}
    end
  end

  def handle_event("change", _params, socket) do
    {:noreply, socket |> assign(editing: true) |> refresh()}
  end

  def handle_event("cancel_change", _params, socket) do
    {:noreply, socket |> stop_editing() |> refresh()}
  end

  def handle_event("requote", _params, socket) do
    {:noreply, start_quote(socket)}
  end

  def handle_event("reload_service", _params, socket) do
    {:noreply,
     socket
     |> assign(service_key: nil)
     |> ensure_service()
     |> refresh()
     |> maybe_auto_quote()}
  end

  # The destination is complete: store it, close the editor, ask the carrier.
  defp save_complete(socket, %Destination{} = destination) do
    case Shop.set_cart_shipping_destination(socket.assigns.cart, destination) do
      {:ok, cart} ->
        {:noreply,
         socket
         |> assign(cart: cart)
         |> stop_editing()
         |> refresh()
         |> notify(cart)
         |> maybe_start_quote()}

      {:error, reason} ->
        {:noreply, assign(socket, save_error: save_error(reason))}
    end
  end

  defp stop_editing(socket) do
    socket |> cancel_async(:points) |> assign(@editor_state) |> assign(editing: false)
  end

  defp put_postcode(form, %Locality{postcode: postcode}) when is_binary(postcode) do
    if Map.get(form, "postcode") in [nil, ""], do: Map.put(form, "postcode", postcode), else: form
  end

  defp put_postcode(form, _locality), do: form

  defp address_locality(locality, _params, false), do: locality

  defp address_locality(_locality, params, true) do
    %Locality{name: text(params, "locality"), postcode: blank_to_nil(text(params, "postcode"))}
  end

  defp text(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) -> String.trim(value)
      _other -> ""
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp require_text(errors, key, "", message), do: Map.put(errors, key, message)
  defp require_text(errors, _key, _value, _message), do: errors

  defp require_if(errors, true, key, value, message),
    do: require_text(errors, key, value, message)

  defp require_if(errors, false, _key, _value, _message), do: errors

  defp validate_point_code(errors, service, code) do
    cond do
      code == "" ->
        Map.put(errors, :point, gettext("Please enter the code of the delivery point"))

      point_code_mismatch?(service.point_code_format, code) ->
        Map.put(errors, :point, gettext("This code does not look right. Please check it."))

      true ->
        errors
    end
  end

  # The format is a regex the HTML `pattern` carries too; one that does not
  # compile is the provider's slip and does not stop the buyer.
  defp point_code_mismatch?(format, code) when is_binary(format) and format != "" do
    case Regex.compile("^(?:" <> format <> ")$") do
      {:ok, regex} -> not Regex.match?(regex, code)
      {:error, _reason} -> false
    end
  end

  defp point_code_mismatch?(_format, _code), do: false

  defp save_error(:invalid_destination),
    do: gettext("These delivery details are too long or not valid. Please shorten them.")

  defp save_error(_reason),
    do: gettext("The delivery details could not be saved. Please try again.")

  # -- render -----------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class="rounded-box border border-base-300 bg-base-200/40 p-4 space-y-4 text-sm"
    >
      <%= if @service_error do %>
        <.service_error reason={@service_error} myself={@myself} />
      <% else %>
        <.destination_summary
          :if={@service.destination != :none and not @editing}
          label={@destination_label}
          myself={@myself}
        />

        <div
          :if={@service.destination != :none and @editing}
          id="shipping-editor"
          class="space-y-3"
        >
          <p :if={@rejected?} id="shipping-destination-rejected" class="text-error">
            <.icon name="hero-exclamation-circle" class="w-4 h-4 inline" />
            {gettext("The carrier does not accept this delivery place. Please choose another one.")}
          </p>

          <.locality_search
            :if={@service.lookup == :search and is_nil(@locality)}
            query={@locality_query}
            localities={@localities}
            state={@localities_state}
            error={@localities_error}
            myself={@myself}
          />

          <.chosen_locality
            :if={@service.lookup == :search and not is_nil(@locality)}
            locality={@locality}
            myself={@myself}
          />

          <.points_picker
            :if={
              @service.destination == :pickup_point and @service.lookup == :search and
                not is_nil(@locality)
            }
            query={@point_query}
            points={@points}
            state={@points_state}
            truncated={@points_truncated?}
            error={@points_error}
            myself={@myself}
          />

          <.manual_form
            :if={@service.destination == :pickup_point and @service.lookup == :manual}
            service={@service}
            form={@form}
            errors={@form_errors}
            myself={@myself}
          />

          <.address_form
            :if={
              @service.destination == :address and
                (@service.lookup == :manual or not is_nil(@locality))
            }
            manual={@service.lookup == :manual}
            form={@form}
            errors={@form_errors}
            myself={@myself}
          />

          <p :if={@save_error} id="shipping-save-error" class="text-error">{@save_error}</p>

          <button
            :if={@complete? and not @rejected?}
            id="shipping-cancel-change"
            type="button"
            class="btn btn-ghost btn-xs"
            phx-click="cancel_change"
            phx-target={@myself}
          >
            {gettext("Cancel")}
          </button>
        </div>

        <.quote_area
          :if={@quote_state != :idle or @status in [:ok, :fallback, :unavailable, :missing, :stale]}
          quote_state={@quote_state}
          status={@status}
          entry={@entry}
          presented={@presented}
          currency={@currency}
          eta={@eta}
          cod_fee={@cod_fee}
          cod_currency={@cod_currency}
          myself={@myself}
        />
      <% end %>
    </div>
    """
  end

  attr :reason, :any, required: true
  attr :myself, :any, required: true

  defp service_error(assigns) do
    ~H"""
    <div id="shipping-service-error" class="space-y-2">
      <%= if @reason in [:unknown_provider, :unknown_service] do %>
        <p id="shipping-quote-unavailable" class="text-error">
          {ShippingDisplay.unavailable_text(Atom.to_string(@reason))}
        </p>
      <% else %>
        <p class="text-error">
          {gettext("The delivery options could not be loaded right now. Please try again.")}
        </p>
        <button
          id="shipping-service-retry"
          type="button"
          class="btn btn-outline btn-sm"
          phx-click="reload_service"
          phx-target={@myself}
        >
          {gettext("Try again")}
        </button>
      <% end %>
    </div>
    """
  end

  attr :label, :string, default: nil
  attr :myself, :any, required: true

  defp destination_summary(assigns) do
    ~H"""
    <div id="shipping-destination-summary" class="flex items-start justify-between gap-3">
      <div class="min-w-0">
        <div class="text-xs text-base-content/60">{gettext("Deliver to")}</div>
        <div class="font-medium break-words">{@label}</div>
      </div>
      <button
        id="shipping-change"
        type="button"
        class="btn btn-ghost btn-xs shrink-0"
        phx-click="change"
        phx-target={@myself}
      >
        <.icon name="hero-pencil" class="w-3.5 h-3.5" /> {gettext("Change")}
      </button>
    </div>
    """
  end

  attr :query, :string, required: true
  attr :localities, :list, required: true
  attr :state, :atom, required: true
  attr :error, :string, default: nil
  attr :myself, :any, required: true

  defp locality_search(assigns) do
    ~H"""
    <div class="space-y-2">
      <form
        id="shipping-locality-form"
        phx-change="locality_search"
        phx-submit="locality_search"
        phx-target={@myself}
      >
        <fieldset class="fieldset">
          <legend class="fieldset-legend">{gettext("City")}</legend>
          <input
            id="shipping-locality-input"
            type="text"
            name="q"
            value={@query}
            class="input w-full"
            placeholder={gettext("Start typing the name of your city")}
            autocomplete="off"
            phx-debounce="300"
          />
        </fieldset>
      </form>

      <div id="shipping-locality-results" class="space-y-1" aria-live="polite">
        <p :if={@state == :loading} class="flex items-center gap-2 text-base-content/60">
          <span class="loading loading-spinner loading-xs"></span> {gettext("Searching...")}
        </p>
        <p :if={@error} class="text-error">{@error}</p>
        <p :if={@state == :done and @localities == []} class="text-base-content/60">
          {gettext("Nothing found. Check the spelling and try again.")}
        </p>
        <ul
          :if={@localities != []}
          class="menu menu-sm w-full rounded-box border border-base-300 bg-base-100 p-1"
        >
          <li :for={locality <- @localities}>
            <button
              id={"shipping-locality-option-#{dom_id(locality.id)}"}
              type="button"
              phx-click="pick_locality"
              phx-value-id={locality.id}
              phx-target={@myself}
            >
              <span class="font-medium">{locality.name}</span>
              <span :if={locality.region} class="text-xs text-base-content/60">
                {locality.region}
              </span>
            </button>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  attr :locality, :any, required: true
  attr :myself, :any, required: true

  defp chosen_locality(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-3">
      <div id="shipping-locality-selected" class="min-w-0">
        <span class="font-medium">{@locality.name}</span>
        <span :if={@locality.region} class="text-xs text-base-content/60">{@locality.region}</span>
      </div>
      <button
        id="shipping-locality-change"
        type="button"
        class="btn btn-ghost btn-xs shrink-0"
        phx-click="change_locality"
        phx-target={@myself}
      >
        {gettext("Change city")}
      </button>
    </div>
    """
  end

  attr :query, :string, required: true
  attr :points, :list, required: true
  attr :state, :atom, required: true
  attr :truncated, :boolean, required: true
  attr :error, :string, default: nil
  attr :myself, :any, required: true

  defp points_picker(assigns) do
    ~H"""
    <div class="space-y-2">
      <form
        id="shipping-points-form"
        phx-change="filter_points"
        phx-submit="filter_points"
        phx-target={@myself}
      >
        <fieldset class="fieldset">
          <legend class="fieldset-legend">{gettext("Delivery point")}</legend>
          <input
            id="shipping-point-filter"
            type="text"
            name="q"
            value={@query}
            class="input w-full"
            placeholder={gettext("Search by number, name or address")}
            autocomplete="off"
            phx-debounce="300"
          />
        </fieldset>
      </form>

      <div id="shipping-points" class="space-y-1" aria-live="polite">
        <p :if={@state == :loading} class="flex items-center gap-2 text-base-content/60">
          <span class="loading loading-spinner loading-xs"></span> {gettext("Loading the list...")}
        </p>
        <div :if={@error} class="flex items-center gap-3">
          <p class="text-error">{@error}</p>
          <button
            id="shipping-points-retry"
            type="button"
            class="btn btn-outline btn-xs"
            phx-click="retry_points"
            phx-target={@myself}
          >
            {gettext("Try again")}
          </button>
        </div>
        <p :if={@state == :done and @points == []} class="text-base-content/60">
          {gettext("No delivery points found for this search.")}
        </p>
        <div
          :if={@points != []}
          class="max-h-72 overflow-y-auto rounded-box border border-base-300 bg-base-100 divide-y divide-base-200"
        >
          <button
            :for={point <- @points}
            id={"shipping-point-#{dom_id(point.id)}"}
            type="button"
            class="flex w-full items-start gap-3 p-3 text-left transition-colors hover:bg-base-200"
            phx-click="pick_point"
            phx-value-id={point.id}
            phx-target={@myself}
          >
            <.icon
              name={point_icon(point.kind)}
              class="w-5 h-5 mt-0.5 shrink-0 text-base-content/60"
            />
            <span class="min-w-0">
              <span class="block font-medium">{point_title(point)}</span>
              <span :if={point.address} class="block text-xs text-base-content/60">
                {point.address}
              </span>
            </span>
          </button>
        </div>
        <p :if={@truncated} class="text-xs text-base-content/60">
          {gettext("Only the first %{count} points are shown. Narrow the search to see others.",
            count: max_points()
          )}
        </p>
      </div>
    </div>
    """
  end

  attr :service, :any, required: true
  attr :form, :map, required: true
  attr :errors, :map, required: true
  attr :myself, :any, required: true

  defp manual_form(assigns) do
    ~H"""
    <form
      id="shipping-manual-form"
      class="space-y-3"
      phx-change="manual_change"
      phx-submit="apply_manual"
      phx-target={@myself}
    >
      <fieldset class="fieldset">
        <legend class="fieldset-legend">{gettext("City")}</legend>
        <input
          id="shipping-manual-locality"
          type="text"
          name="manual[locality]"
          value={@form["locality"]}
          class={["input w-full", @errors[:locality] && "input-error"]}
          required
        />
        <p :if={@errors[:locality]} class="fieldset-label text-error">{@errors[:locality]}</p>
      </fieldset>

      <fieldset class="fieldset">
        <legend class="fieldset-legend">
          {@service.point_code_label || gettext("Delivery point")}
        </legend>
        <input
          id="shipping-manual-point"
          type="text"
          name="manual[point]"
          value={@form["point"]}
          class={["input w-full", @errors[:point] && "input-error"]}
          pattern={@service.point_code_format}
          required
        />
        <p :if={@errors[:point]} class="fieldset-label text-error">{@errors[:point]}</p>
      </fieldset>

      <button id="shipping-manual-apply" type="submit" class="btn btn-primary btn-sm">
        {gettext("Apply")}
      </button>
    </form>
    """
  end

  attr :manual, :boolean, required: true
  attr :form, :map, required: true
  attr :errors, :map, required: true
  attr :myself, :any, required: true

  defp address_form(assigns) do
    ~H"""
    <form
      id="shipping-address-form"
      class="space-y-3"
      phx-change="address_change"
      phx-submit="apply_address"
      phx-target={@myself}
    >
      <fieldset :if={@manual} class="fieldset">
        <legend class="fieldset-legend">{gettext("City")}</legend>
        <input
          id="shipping-address-locality"
          type="text"
          name="address[locality]"
          value={@form["locality"]}
          class={["input w-full", @errors[:locality] && "input-error"]}
          required
        />
        <p :if={@errors[:locality]} class="fieldset-label text-error">{@errors[:locality]}</p>
      </fieldset>

      <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
        <fieldset class="fieldset sm:col-span-3">
          <legend class="fieldset-legend">{gettext("Street")}</legend>
          <input
            id="shipping-address-street"
            type="text"
            name="address[street]"
            value={@form["street"]}
            class={["input w-full", @errors[:street] && "input-error"]}
            required
          />
          <p :if={@errors[:street]} class="fieldset-label text-error">{@errors[:street]}</p>
        </fieldset>

        <fieldset class="fieldset">
          <legend class="fieldset-legend">{gettext("House")}</legend>
          <input
            id="shipping-address-house"
            type="text"
            name="address[house]"
            value={@form["house"]}
            class={["input w-full", @errors[:house] && "input-error"]}
            required
          />
          <p :if={@errors[:house]} class="fieldset-label text-error">{@errors[:house]}</p>
        </fieldset>

        <fieldset class="fieldset">
          <legend class="fieldset-legend">{gettext("Apartment")}</legend>
          <input
            id="shipping-address-apartment"
            type="text"
            name="address[apartment]"
            value={@form["apartment"]}
            class="input w-full"
          />
        </fieldset>

        <fieldset class="fieldset">
          <legend class="fieldset-legend">{gettext("Postcode")}</legend>
          <input
            id="shipping-address-postcode"
            type="text"
            name="address[postcode]"
            value={@form["postcode"]}
            class={["input w-full", @errors[:postcode] && "input-error"]}
            required={@manual}
          />
          <p :if={@errors[:postcode]} class="fieldset-label text-error">{@errors[:postcode]}</p>
        </fieldset>
      </div>

      <button id="shipping-address-apply" type="submit" class="btn btn-primary btn-sm">
        {gettext("Apply")}
      </button>
    </form>
    """
  end

  attr :quote_state, :atom, required: true
  attr :status, :atom, required: true
  attr :entry, :any, default: nil
  attr :presented, :map, required: true
  attr :currency, :any, default: nil
  attr :eta, :any, default: nil
  attr :cod_fee, :any, default: nil
  attr :cod_currency, :any, default: nil
  attr :myself, :any, required: true

  defp quote_area(assigns) do
    ~H"""
    <div id="shipping-quote" class="space-y-1.5 border-t border-base-300 pt-3" aria-live="polite">
      <%= cond do %>
        <% @quote_state == :loading -> %>
          <p id="shipping-quote-loading" class="flex items-center gap-2 text-base-content/60">
            <span class="loading loading-spinner loading-xs"></span>
            {gettext("Calculating the delivery price...")}
          </p>
        <% @quote_state == :error -> %>
          <div id="shipping-quote-error" class="flex items-center gap-3">
            <p class="text-error">
              {gettext("The delivery price could not be calculated. Please try again.")}
            </p>
            <.recalculate_button myself={@myself} />
          </div>
        <% @status == :unavailable -> %>
          <p id="shipping-quote-unavailable" class="text-error">
            <.icon name="hero-exclamation-circle" class="w-4 h-4 inline" />
            {ShippingDisplay.unavailable_text(@entry && @entry.reason)}
          </p>
        <% @status in [:ok, :fallback] -> %>
          <div class="flex items-baseline justify-between gap-3">
            <span class="text-base-content/70">{gettext("Delivery")}</span>
            <span id="shipping-quote-price" class="font-semibold text-right">
              <%= cond do %>
                <% @presented.pay_on_delivery? and @presented.estimate -> %>
                  {gettext("Paid to the carrier on delivery ≈ %{amount}",
                    amount: format_price(@presented.estimate.amount, @cod_currency)
                  )}
                <% @presented.pay_on_delivery? -> %>
                  {gettext("Paid on delivery")}
                <% @presented.free? -> %>
                  <span class="badge badge-success">{gettext("FREE")}</span>
                <% true -> %>
                  {format_price(@presented.price, @currency)}
              <% end %>
            </span>
          </div>
          <ShippingDisplay.quote_details
            id="shipping-quote"
            eta={@eta}
            cod_fee={@cod_fee}
            currency={@cod_currency}
            fallback={@status == :fallback}
          />
          <.recalculate_button :if={@status == :fallback} myself={@myself} />
        <% @status in [:missing, :stale] -> %>
          <.recalculate_button myself={@myself} />
        <% true -> %>
      <% end %>
    </div>
    """
  end

  attr :myself, :any, required: true

  defp recalculate_button(assigns) do
    ~H"""
    <button
      id="shipping-quote-retry"
      type="button"
      class="btn btn-outline btn-xs"
      phx-click="requote"
      phx-target={@myself}
    >
      <.icon name="hero-arrow-path" class="w-3.5 h-3.5" /> {gettext("Calculate the delivery price")}
    </button>
    """
  end

  defp max_points, do: @max_points

  defp point_icon(:branch), do: "hero-building-storefront"
  defp point_icon(:locker), do: "hero-archive-box"
  defp point_icon(:cargo), do: "hero-truck"
  defp point_icon(_kind), do: "hero-map-pin"

  # The name says it all when it carries the number (a carrier's "Branch no.
  # 12: ..."); otherwise the number leads.
  defp point_title(%PickupPoint{name: name, number: number}) do
    cond do
      blank?(name) and blank?(number) -> ""
      blank?(name) -> "№" <> number
      blank?(number) or String.contains?(name, number) -> name
      true -> "№" <> number <> ", " <> name
    end
  end

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

  defp dom_id(id), do: String.replace(id, ~r/[^A-Za-z0-9_-]/, "_")
end
