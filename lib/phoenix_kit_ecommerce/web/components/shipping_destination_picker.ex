defmodule PhoenixKitEcommerce.Web.Components.ShippingDestinationPicker do
  @moduledoc """
  Where a calculated shipping method delivers, and what the carrier charges
  for it: the picker of the cart page and of the checkout shipping step.

  A LiveComponent because the picker owns state of its own (the search text,
  the lists the carrier answered, the quote in flight) and several
  `start_async` jobs, and it lives in two different LiveViews: keeping that
  here is cheaper than duplicating it in both.

  ## Assigns

    * `id` - the DOM id, `"shipping-picker-<method uuid>"`; the ids inside the
      picker are derived from it (`"<id>-locality-input"`...)
    * `cart` - the cart (with items)
    * `snapshot` - `PhoenixKitEcommerce.shipping_quote_snapshot/2` of the cart
      and the method. The parent works it out when the cart changes; the picker
      never recomputes it, since the work (packing, hashing, the service list,
      the provider's check of the destination) is too much for a render
    * `method` - the selected, calculated `PhoenixKitEcommerce.ShippingMethod`
    * `locale` - the locale the carrier's texts are asked in
    * `currency` - the cart currency struct, for the amounts

  The picker does not keep a cart of its own: what it saves goes to the
  database, the shipping broadcast reaches the parent, and the parent passes
  the new cart and snapshot down.

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

  ## Quotes and the carrier

  A quote is requested by itself while the cart's quote is `:missing` or
  `:stale` (see `PhoenixKitEcommerce.Web.ShippingRequote`: once per state of
  the cart, at most three times in a row). Every other call to the carrier is
  the shopper's, and bounded for a client that is not a browser: one search
  or filter request in flight at a time, at least
  `config :phoenix_kit_ecommerce, :shipping_lookup_interval` milliseconds
  (default 400) between two, the latest text wins; texts and form fields are
  capped; events of an unexpected shape are ignored.

  ## Messages to the parent

  `:shipping_recheck` asks the parent to work the snapshot out again when the
  cart did not change but the answer may have (the service list was retried,
  the carrier refused the request).
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
  @query_length 64
  @field_length 255
  @code_length 64
  @default_interval 400
  @address_fields ~w(locality postcode street house apartment)
  @manual_fields ~w(locality point)

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
    save_error: nil,
    lookups: %{
      localities: %{at: nil, pending: false, timer: false},
      points: %{at: nil, pending: false, timer: false}
    }
  ]

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(@editor_state)
     |> assign(
       service_key: nil,
       service: nil,
       editing: nil,
       quote_state: :idle,
       auto_key: nil,
       auto_streak: 0
     )}
  end

  @impl true
  def update(%{action: {:flush, kind}}, socket) do
    socket = put_lookup(socket, kind, timer: false)
    {:ok, if(lookup_wanted?(socket, kind), do: request_lookup(socket, kind), else: socket)}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(Map.take(assigns, [:id, :cart, :method, :snapshot, :locale, :currency]))
      |> ensure_method()
      |> refresh()
      |> maybe_auto_quote()

    {:ok, socket}
  end

  # A new method (or new settings of it) is a new picker: whatever was typed
  # or looked up belongs to the old one.
  defp ensure_method(socket) do
    %{method: method} = socket.assigns
    key = :erlang.phash2({method.uuid, method.metadata})

    if socket.assigns.service_key == key do
      socket
    else
      socket
      |> cancel_lookups()
      |> assign(@editor_state)
      |> assign(service_key: key, editing: nil, quote_state: :idle, auto_key: nil, auto_streak: 0)
    end
  end

  defp cancel_lookups(socket) do
    socket |> cancel_async(:localities) |> cancel_async(:points)
  end

  # -- state derived from the snapshot ----------------------------------

  defp refresh(socket) do
    %{cart: cart, snapshot: snapshot} = socket.assigns

    case snapshot.service do
      nil -> assign(socket, service: nil)
      service -> refresh_with(socket, cart, snapshot, service)
    end
  end

  defp refresh_with(socket, cart, snapshot, service) do
    destination = Shop.cart_shipping_destination(cart)
    complete? = not CartQuote.incomplete?(service.destination, destination)
    rejected? = complete? and snapshot.status == :needs_destination

    socket
    |> assign(
      service: service,
      destination: destination,
      destination_label: CartQuote.destination_label(destination),
      complete?: complete?,
      rejected?: rejected?,
      point_limits?: rejected? and snapshot.reason == "point_limits",
      editing: editing?(socket.assigns.editing, complete?, rejected?)
    )
    |> assign_quote_details(snapshot)
    |> sync_editor()
  end

  # An incomplete (or refused) destination can only be edited; otherwise it is
  # edited when the buyer asked to.
  defp editing?(_editing, complete?, rejected?) when not complete? or rejected?, do: true
  defp editing?(nil, _complete?, _rejected?), do: false
  defp editing?(editing, _complete?, _rejected?), do: editing

  defp assign_quote_details(socket, snapshot) do
    estimate = snapshot.presented && snapshot.presented.estimate
    stored = snapshot.entry && snapshot.entry.quote

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
      request_lookup(socket, :points)
    else
      socket
    end
  end

  # -- the carrier: lookups ---------------------------------------------

  # One lookup of a kind in flight at a time, at least `lookup_interval/0`
  # apart; what is asked while one runs (or too soon) is coalesced into one
  # request for the latest text.
  defp request_lookup(socket, kind) do
    lookup = socket.assigns.lookups[kind]
    wait = lookup_wait(lookup.at)

    cond do
      lookup_state(socket, kind) == :loading -> put_lookup(socket, kind, pending: true)
      lookup.timer -> socket
      wait > 0 -> schedule_flush(socket, kind, wait)
      true -> run_lookup(socket, kind)
    end
  end

  defp lookup_wait(nil), do: 0

  defp lookup_wait(at) do
    max(lookup_interval() - (System.monotonic_time(:millisecond) - at), 0)
  end

  defp lookup_interval do
    Application.get_env(:phoenix_kit_ecommerce, :shipping_lookup_interval, @default_interval)
  end

  defp schedule_flush(socket, kind, wait) do
    send_update_after(__MODULE__, [id: socket.assigns.id, action: {:flush, kind}], wait)
    put_lookup(socket, kind, timer: true)
  end

  defp put_lookup(socket, kind, changes) do
    lookups = Map.update!(socket.assigns.lookups, kind, &Map.merge(&1, Map.new(changes)))
    assign(socket, lookups: lookups)
  end

  defp lookup_state(socket, :localities), do: socket.assigns.localities_state
  defp lookup_state(socket, :points), do: socket.assigns.points_state

  defp lookup_wanted?(socket, :localities) do
    assigns = socket.assigns
    assigns.editing == true and is_nil(assigns.locality) and query_long_enough?(assigns)
  end

  defp lookup_wanted?(socket, :points) do
    assigns = socket.assigns
    assigns.editing == true and not is_nil(assigns.locality)
  end

  defp query_long_enough?(assigns), do: String.length(String.trim(assigns.locality_query)) >= 2

  defp run_lookup(socket, :localities) do
    %{method: method, locale: locale, locality_query: text} = socket.assigns
    query = String.trim(text)

    socket
    |> put_lookup(:localities, at: System.monotonic_time(:millisecond), pending: false)
    |> assign(localities_state: :loading, localities_error: nil)
    |> start_async(:localities, fn ->
      method |> Shipping.context(locale: locale) |> Shipping.search_localities(query)
    end)
  end

  # The packing and the declared value are read in the task: they take the
  # database, and a filter box types often.
  defp run_lookup(socket, :points) do
    %{method: method, locale: locale, locality: locality, point_query: query, cart: cart} =
      socket.assigns

    socket
    |> put_lookup(:points, at: System.monotonic_time(:millisecond), pending: false)
    |> assign(points_state: :loading, points_error: nil)
    |> start_async(:points, fn ->
      method
      |> Shipping.context(locale: locale)
      |> Shipping.list_pickup_points(locality, query,
        parcels: Shop.cart_parcels(cart),
        declared_value: Shop.cart_declared_value(cart)
      )
    end)
  end

  # What came back while another, newer request was waiting is asked again.
  defp after_lookup(socket, kind) do
    if socket.assigns.lookups[kind].pending do
      socket |> put_lookup(kind, pending: false) |> request_lookup(kind)
    else
      socket
    end
  end

  # -- quote ------------------------------------------------------------

  # A quote is asked for once per state of the cart (see `ShippingRequote`).
  defp maybe_auto_quote(socket) do
    assigns = socket.assigns

    cond do
      not connected?(socket) or is_nil(assigns.service) or quote_busy?(assigns) ->
        socket

      assigns.snapshot.status not in [:missing, :stale] ->
        assign(socket, auto_streak: 0)

      assigns.method.uuid != assigns.cart.shipping_method_uuid ->
        socket

      not ShippingRequote.due?(
        assigns.cart,
        assigns.snapshot.status,
        assigns.auto_key,
        assigns.auto_streak
      ) ->
        socket

      true ->
        socket |> assign(auto_streak: assigns.auto_streak + 1) |> start_quote()
    end
  end

  defp quote_busy?(assigns), do: assigns.quote_state == :loading

  defp start_quote(socket) do
    %{cart: cart, locale: locale, snapshot: snapshot} = socket.assigns

    socket
    |> assign(
      quote_state: :loading,
      auto_key: ShippingRequote.key(cart, snapshot.status)
    )
    |> start_async(:quote, fn -> Shop.quote_cart_shipping(cart, locale: locale) end)
  end

  defp recheck(socket) do
    send(self(), :shipping_recheck)
    socket
  end

  # -- async ------------------------------------------------------------

  @impl true
  # The carrier answered and the cart now carries it. The broadcast that said
  # so left the quoting process before its result did, so the parent has
  # already taken the cart and passed it down.
  def handle_async(:quote, {:ok, {:ok, _cart}}, socket) do
    {:noreply, assign(socket, quote_state: :idle)}
  end

  # The cart changed while the carrier was asked: whoever changed it told the
  # parent, which passes the cart down; ask again for what it is now.
  def handle_async(:quote, {:ok, {:error, :stale}}, socket) do
    {:noreply, socket |> assign(quote_state: :idle) |> maybe_auto_quote()}
  end

  # The state of the cart tells these (the destination is refused, the method
  # cannot serve it): the parent works the snapshot out again.
  def handle_async(:quote, {:ok, {:error, reason}}, socket)
      when reason == :needs_destination or (is_tuple(reason) and elem(reason, 0) == :unavailable) do
    {:noreply, socket |> assign(quote_state: :idle) |> recheck()}
  end

  def handle_async(:quote, _failed, socket) do
    {:noreply, assign(socket, quote_state: :error)}
  end

  def handle_async(:localities, {:exit, {:shutdown, :cancel}}, socket), do: {:noreply, socket}

  # An answer that comes after the city was picked is not wanted.
  def handle_async(:localities, _result, %{assigns: %{locality: %Locality{}}} = socket),
    do: {:noreply, socket}

  def handle_async(:localities, {:ok, {:ok, localities}}, socket) do
    localities = localities |> Enum.filter(&locality_with_id?/1) |> Enum.take(@max_localities)

    {:noreply,
     socket
     |> assign(localities: localities, localities_state: :done, localities_error: nil)
     |> after_lookup(:localities)}
  end

  def handle_async(:localities, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(localities_state: :error, localities_error: lookup_error(reason))
     |> after_lookup(:localities)}
  end

  def handle_async(:localities, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(localities_state: :error, localities_error: lookup_error(nil))
     |> after_lookup(:localities)}
  end

  def handle_async(:points, {:exit, {:shutdown, :cancel}}, socket), do: {:noreply, socket}

  def handle_async(:points, {:ok, {:ok, points}}, socket) do
    points = Enum.filter(points, &point_with_id?/1)

    {:noreply,
     socket
     |> assign(
       points: Enum.take(points, @max_points),
       points_truncated?: length(points) > @max_points,
       points_state: :done,
       points_error: nil
     )
     |> after_lookup(:points)}
  end

  def handle_async(:points, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(points_state: :error, points_error: lookup_error(reason))
     |> after_lookup(:points)}
  end

  def handle_async(:points, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(points_state: :error, points_error: lookup_error(nil))
     |> after_lookup(:points)}
  end

  defp locality_with_id?(%Locality{id: id}), do: is_binary(id) and id != ""
  defp locality_with_id?(_other), do: false
  defp point_with_id?(%PickupPoint{id: id}), do: is_binary(id) and id != ""
  defp point_with_id?(_other), do: false

  defp lookup_error(:timeout),
    do: gettext("The carrier did not answer in time. Please try again.")

  defp lookup_error(_reason),
    do: gettext("The list could not be loaded right now. Please try again.")

  # -- events -----------------------------------------------------------

  @impl true
  def handle_event("locality_search", params, socket) do
    text = params |> query_param() |> String.slice(0, @query_length)
    socket = assign(socket, locality_query: text)

    if String.length(String.trim(text)) < 2 do
      {:noreply,
       socket
       |> cancel_async(:localities)
       |> put_lookup(:localities, pending: false)
       |> assign(localities: [], localities_state: :idle, localities_error: nil)}
    else
      {:noreply,
       if(lookup_wanted?(socket, :localities),
         do: request_lookup(socket, :localities),
         else: socket
       )}
    end
  end

  def handle_event("pick_locality", %{"id" => id}, socket) when is_binary(id) do
    case Enum.find(socket.assigns.localities, &(&1.id == id)) do
      nil -> {:noreply, socket}
      locality -> pick_locality(socket, locality)
    end
  end

  def handle_event("change_locality", _params, socket) do
    {:noreply,
     socket
     |> cancel_lookups()
     |> assign(
       locality: nil,
       localities: [],
       localities_state: :idle,
       points: [],
       points_state: :idle,
       point_query: "",
       locality_query: "",
       save_error: nil
     )
     |> put_lookup(:localities, pending: false)
     |> put_lookup(:points, pending: false)}
  end

  def handle_event("filter_points", params, socket) do
    text = params |> query_param() |> String.slice(0, @query_length)
    socket = assign(socket, point_query: text)

    {:noreply,
     if(lookup_wanted?(socket, :points), do: request_lookup(socket, :points), else: socket)}
  end

  def handle_event("retry_points", _params, socket) do
    {:noreply,
     if(lookup_wanted?(socket, :points), do: request_lookup(socket, :points), else: socket)}
  end

  def handle_event("pick_point", %{"id" => id}, socket) when is_binary(id) do
    case Enum.find(socket.assigns.points, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      point ->
        save_complete(socket, %Destination{locality: socket.assigns.locality, pickup_point: point})
    end
  end

  def handle_event("manual_change", %{"manual" => params}, socket) when is_map(params) do
    {:noreply, assign(socket, form: whitelist(params, @manual_fields))}
  end

  def handle_event("apply_manual", %{"manual" => params}, socket) when is_map(params) do
    locality = text(params, "locality")
    code = text(params, "point", @code_length + 1)

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
      {:noreply, assign(socket, form: whitelist(params, @manual_fields), form_errors: errors)}
    end
  end

  def handle_event("address_change", %{"address" => params}, socket) when is_map(params) do
    {:noreply, assign(socket, form: whitelist(params, @address_fields))}
  end

  def handle_event("apply_address", %{"address" => params}, socket) when is_map(params) do
    manual? = socket.assigns.service.lookup == :manual

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
      {:noreply, assign(socket, form: whitelist(params, @address_fields), form_errors: errors)}
    end
  end

  def handle_event("change", _params, socket) do
    {:noreply, socket |> assign(editing: true) |> refresh()}
  end

  def handle_event("cancel_change", _params, socket) do
    {:noreply, socket |> stop_editing() |> refresh()}
  end

  # The carrier is asked again by hand only when the answer is worth asking
  # for again, and never while it is being asked.
  def handle_event("requote", _params, socket) do
    assigns = socket.assigns

    if not quote_busy?(assigns) and assigns.snapshot.status in [:missing, :stale, :fallback] do
      {:noreply, start_quote(socket)}
    else
      {:noreply, socket}
    end
  end

  # The list of services could not be had: ask again (the parent does).
  def handle_event("recheck", _params, socket), do: {:noreply, recheck(socket)}

  # Whatever else a client sends is not for the picker.
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp pick_locality(socket, locality) do
    case Shop.set_cart_shipping_destination(socket.assigns.cart, %Destination{locality: locality}) do
      {:ok, _cart} ->
        {:noreply,
         socket
         |> cancel_lookups()
         |> assign(
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
         |> put_lookup(:localities, pending: false)
         |> put_lookup(:points, pending: false)
         |> maybe_load_points()}

      {:error, reason} ->
        {:noreply, assign(socket, save_error: save_error(reason))}
    end
  end

  # The destination is complete: store it and close the editor. The quote
  # starts when the parent passes the new cart down (`maybe_auto_quote/1`).
  defp save_complete(socket, %Destination{} = destination) do
    case Shop.set_cart_shipping_destination(socket.assigns.cart, destination) do
      {:ok, _cart} -> {:noreply, stop_editing(socket)}
      {:error, reason} -> {:noreply, assign(socket, save_error: save_error(reason))}
    end
  end

  defp stop_editing(socket) do
    socket |> cancel_lookups() |> assign(@editor_state) |> assign(editing: false)
  end

  defp put_postcode(form, %Locality{postcode: postcode}) when is_binary(postcode) do
    if Map.get(form, "postcode") in [nil, ""], do: Map.put(form, "postcode", postcode), else: form
  end

  defp put_postcode(form, _locality), do: form

  defp address_locality(locality, _params, false), do: locality

  defp address_locality(_locality, params, true) do
    %Locality{name: text(params, "locality"), postcode: blank_to_nil(text(params, "postcode"))}
  end

  defp query_param(%{"q" => text}) when is_binary(text), do: text
  defp query_param(_params), do: ""

  # A trimmed, capped text; anything but a string is empty.
  defp text(params, key, length \\ @field_length) do
    case Map.get(params, key) do
      value when is_binary(value) -> value |> String.slice(0, length) |> String.trim()
      _other -> ""
    end
  end

  # Only the fields of the form, each capped: what comes back into the inputs.
  defp whitelist(params, fields) do
    Map.new(fields, fn field ->
      value =
        case Map.get(params, field) do
          text when is_binary(text) -> String.slice(text, 0, @field_length)
          _other -> ""
        end

      {field, value}
    end)
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

      String.length(code) > @code_length ->
        Map.put(errors, :point, gettext("This code is too long. Please check it."))

      point_code_mismatch?(service.point_code_format, code) ->
        Map.put(errors, :point, gettext("This code does not look right. Please check it."))

      true ->
        errors
    end
  end

  # The format is a regex the HTML `pattern` carries too; one that does not
  # compile is the provider's slip and does not stop the buyer. A code over the
  # cap was refused before it gets here (never cut: a cut code is another code).
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
    <div id={@id} class="rounded-box border border-base-300 bg-base-200/40 p-4 space-y-4 text-sm">
      <%= cond do %>
        <% @snapshot.service_error -> %>
          <.service_error
            pid={@id}
            reason={@snapshot.service_error}
            transient={@snapshot.transient?}
            myself={@myself}
          />
        <% is_nil(@service) -> %>
        <% true -> %>
          <.destination_summary
            :if={@service.destination != :none and not @editing}
            pid={@id}
            label={@destination_label}
            myself={@myself}
          />

          <div
            :if={@service.destination != :none and @editing}
            id={"#{@id}-editor"}
            class="space-y-3"
          >
            <p
              :if={@rejected? and not @point_limits?}
              id={"#{@id}-destination-rejected"}
              class="text-error"
            >
              <.icon name="hero-exclamation-circle" class="w-4 h-4 inline" />
              {gettext(
                "The carrier does not accept this delivery place. Please choose another one."
              )}
            </p>
            <p :if={@point_limits?} id={"#{@id}-point-limits"} class="text-error">
              <.icon name="hero-exclamation-circle" class="w-4 h-4 inline" />
              {gettext(
                "The chosen point can't take this parcel (weight/size/value). Please choose another one."
              )}
            </p>

            <.locality_search
              :if={@service.lookup == :search and is_nil(@locality)}
              pid={@id}
              query={@locality_query}
              localities={@localities}
              state={@localities_state}
              error={@localities_error}
              myself={@myself}
            />

            <.chosen_locality
              :if={@service.lookup == :search and not is_nil(@locality)}
              pid={@id}
              locality={@locality}
              myself={@myself}
            />

            <.points_picker
              :if={
                @service.destination == :pickup_point and @service.lookup == :search and
                  not is_nil(@locality)
              }
              pid={@id}
              query={@point_query}
              points={@points}
              state={@points_state}
              truncated={@points_truncated?}
              error={@points_error}
              myself={@myself}
            />

            <.manual_form
              :if={@service.destination == :pickup_point and @service.lookup == :manual}
              pid={@id}
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
              pid={@id}
              manual={@service.lookup == :manual}
              form={@form}
              errors={@form_errors}
              myself={@myself}
            />

            <p :if={@save_error} id={"#{@id}-save-error"} class="text-error">{@save_error}</p>

            <button
              :if={@complete? and not @rejected?}
              id={"#{@id}-cancel-change"}
              type="button"
              class="btn btn-ghost btn-xs"
              phx-click="cancel_change"
              phx-target={@myself}
            >
              {gettext("Cancel")}
            </button>
          </div>

          <.quote_area
            :if={
              @quote_state != :idle or
                @snapshot.status in [:ok, :fallback, :unavailable, :missing, :stale]
            }
            pid={@id}
            quote_state={@quote_state}
            status={@snapshot.status}
            entry={@snapshot.entry}
            presented={@snapshot.presented}
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

  attr :pid, :string, required: true
  attr :reason, :any, required: true
  attr :transient, :boolean, required: true
  attr :myself, :any, required: true

  defp service_error(assigns) do
    ~H"""
    <div id={"#{@pid}-service-error"} class="space-y-2">
      <%= if @transient do %>
        <p class="text-error">
          {gettext("Delivery options are temporarily unavailable. Please try again in a moment.")}
        </p>
        <button
          id={"#{@pid}-service-retry"}
          type="button"
          class="btn btn-outline btn-sm"
          phx-click="recheck"
          phx-target={@myself}
        >
          <.icon name="hero-arrow-path" class="w-3.5 h-3.5" /> {gettext("Try again")}
        </button>
      <% else %>
        <p id={"#{@pid}-quote-unavailable"} class="text-error">
          {ShippingDisplay.unavailable_text(Atom.to_string(@reason))}
        </p>
      <% end %>
    </div>
    """
  end

  attr :pid, :string, required: true
  attr :label, :string, default: nil
  attr :myself, :any, required: true

  defp destination_summary(assigns) do
    ~H"""
    <div id={"#{@pid}-destination-summary"} class="flex items-start justify-between gap-3">
      <div class="min-w-0">
        <div class="text-xs text-base-content/60">{gettext("Deliver to")}</div>
        <div class="font-medium break-words">{@label}</div>
      </div>
      <button
        id={"#{@pid}-change"}
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

  attr :pid, :string, required: true
  attr :query, :string, required: true
  attr :localities, :list, required: true
  attr :state, :atom, required: true
  attr :error, :string, default: nil
  attr :myself, :any, required: true

  defp locality_search(assigns) do
    ~H"""
    <div class="space-y-2">
      <form
        id={"#{@pid}-locality-form"}
        phx-change="locality_search"
        phx-submit="locality_search"
        phx-target={@myself}
      >
        <fieldset class="fieldset">
          <legend class="fieldset-legend">{gettext("City")}</legend>
          <input
            id={"#{@pid}-locality-input"}
            type="text"
            name="q"
            value={@query}
            class="input w-full"
            placeholder={gettext("Start typing the name of your city")}
            autocomplete="off"
            maxlength="64"
            phx-debounce="300"
          />
        </fieldset>
      </form>

      <div id={"#{@pid}-locality-results"} class="space-y-1" aria-live="polite">
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
              id={"#{@pid}-locality-option-#{dom_id(locality.id)}"}
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

  attr :pid, :string, required: true
  attr :locality, :any, required: true
  attr :myself, :any, required: true

  defp chosen_locality(assigns) do
    ~H"""
    <div class="flex items-center justify-between gap-3">
      <div id={"#{@pid}-locality-selected"} class="min-w-0">
        <span class="font-medium">{@locality.name}</span>
        <span :if={@locality.region} class="text-xs text-base-content/60">{@locality.region}</span>
      </div>
      <button
        id={"#{@pid}-locality-change"}
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

  attr :pid, :string, required: true
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
        id={"#{@pid}-points-form"}
        phx-change="filter_points"
        phx-submit="filter_points"
        phx-target={@myself}
      >
        <fieldset class="fieldset">
          <legend class="fieldset-legend">{gettext("Delivery point")}</legend>
          <input
            id={"#{@pid}-point-filter"}
            type="text"
            name="q"
            value={@query}
            class="input w-full"
            placeholder={gettext("Search by number, name or address")}
            autocomplete="off"
            maxlength="64"
            phx-debounce="300"
          />
        </fieldset>
      </form>

      <div id={"#{@pid}-points"} class="space-y-1" aria-live="polite">
        <p :if={@state == :loading} class="flex items-center gap-2 text-base-content/60">
          <span class="loading loading-spinner loading-xs"></span> {gettext("Loading the list...")}
        </p>
        <div :if={@error} class="flex items-center gap-3">
          <p class="text-error">{@error}</p>
          <button
            id={"#{@pid}-points-retry"}
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
            id={"#{@pid}-point-#{dom_id(point.id)}"}
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

  attr :pid, :string, required: true
  attr :service, :any, required: true
  attr :form, :map, required: true
  attr :errors, :map, required: true
  attr :myself, :any, required: true

  defp manual_form(assigns) do
    ~H"""
    <form
      id={"#{@pid}-manual-form"}
      class="space-y-3"
      phx-change="manual_change"
      phx-submit="apply_manual"
      phx-target={@myself}
    >
      <fieldset class="fieldset">
        <legend class="fieldset-legend">{gettext("City")}</legend>
        <input
          id={"#{@pid}-manual-locality"}
          type="text"
          name="manual[locality]"
          value={@form["locality"]}
          class={["input w-full", @errors[:locality] && "input-error"]}
          maxlength="255"
          required
        />
        <p :if={@errors[:locality]} class="fieldset-label text-error">{@errors[:locality]}</p>
      </fieldset>

      <fieldset class="fieldset">
        <legend class="fieldset-legend">
          {@service.point_code_label || gettext("Delivery point")}
        </legend>
        <input
          id={"#{@pid}-manual-point"}
          type="text"
          name="manual[point]"
          value={@form["point"]}
          class={["input w-full", @errors[:point] && "input-error"]}
          pattern={@service.point_code_format}
          maxlength="64"
          required
        />
        <p :if={@errors[:point]} class="fieldset-label text-error">{@errors[:point]}</p>
      </fieldset>

      <button id={"#{@pid}-manual-apply"} type="submit" class="btn btn-primary btn-sm">
        {gettext("Apply")}
      </button>
    </form>
    """
  end

  attr :pid, :string, required: true
  attr :manual, :boolean, required: true
  attr :form, :map, required: true
  attr :errors, :map, required: true
  attr :myself, :any, required: true

  defp address_form(assigns) do
    ~H"""
    <form
      id={"#{@pid}-address-form"}
      class="space-y-3"
      phx-change="address_change"
      phx-submit="apply_address"
      phx-target={@myself}
    >
      <fieldset :if={@manual} class="fieldset">
        <legend class="fieldset-legend">{gettext("City")}</legend>
        <input
          id={"#{@pid}-address-locality"}
          type="text"
          name="address[locality]"
          value={@form["locality"]}
          class={["input w-full", @errors[:locality] && "input-error"]}
          maxlength="255"
          required
        />
        <p :if={@errors[:locality]} class="fieldset-label text-error">{@errors[:locality]}</p>
      </fieldset>

      <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
        <fieldset class="fieldset sm:col-span-3">
          <legend class="fieldset-legend">{gettext("Street")}</legend>
          <input
            id={"#{@pid}-address-street"}
            type="text"
            name="address[street]"
            value={@form["street"]}
            class={["input w-full", @errors[:street] && "input-error"]}
            maxlength="255"
            required
          />
          <p :if={@errors[:street]} class="fieldset-label text-error">{@errors[:street]}</p>
        </fieldset>

        <fieldset class="fieldset">
          <legend class="fieldset-legend">{gettext("House")}</legend>
          <input
            id={"#{@pid}-address-house"}
            type="text"
            name="address[house]"
            value={@form["house"]}
            class={["input w-full", @errors[:house] && "input-error"]}
            maxlength="255"
            required
          />
          <p :if={@errors[:house]} class="fieldset-label text-error">{@errors[:house]}</p>
        </fieldset>

        <fieldset class="fieldset">
          <legend class="fieldset-legend">{gettext("Apartment")}</legend>
          <input
            id={"#{@pid}-address-apartment"}
            type="text"
            name="address[apartment]"
            value={@form["apartment"]}
            class="input w-full"
            maxlength="255"
          />
        </fieldset>

        <fieldset class="fieldset">
          <legend class="fieldset-legend">{gettext("Postcode")}</legend>
          <input
            id={"#{@pid}-address-postcode"}
            type="text"
            name="address[postcode]"
            value={@form["postcode"]}
            class={["input w-full", @errors[:postcode] && "input-error"]}
            maxlength="255"
            required={@manual}
          />
          <p :if={@errors[:postcode]} class="fieldset-label text-error">{@errors[:postcode]}</p>
        </fieldset>
      </div>

      <button id={"#{@pid}-address-apply"} type="submit" class="btn btn-primary btn-sm">
        {gettext("Apply")}
      </button>
    </form>
    """
  end

  attr :pid, :string, required: true
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
    <div id={"#{@pid}-quote"} class="space-y-1.5 border-t border-base-300 pt-3" aria-live="polite">
      <%= cond do %>
        <% @quote_state == :loading -> %>
          <p id={"#{@pid}-quote-loading"} class="flex items-center gap-2 text-base-content/60">
            <span class="loading loading-spinner loading-xs"></span>
            {gettext("Calculating the delivery price...")}
          </p>
        <% @quote_state == :error -> %>
          <div id={"#{@pid}-quote-error"} class="flex items-center gap-3">
            <p class="text-error">
              {gettext("The delivery price could not be calculated. Please try again.")}
            </p>
            <.recalculate_button pid={@pid} myself={@myself} />
          </div>
        <% @status == :unavailable -> %>
          <p id={"#{@pid}-quote-unavailable"} class="text-error">
            <.icon name="hero-exclamation-circle" class="w-4 h-4 inline" />
            {ShippingDisplay.unavailable_text(@entry && @entry.reason)}
          </p>
        <% @status in [:ok, :fallback] -> %>
          <div class="flex items-baseline justify-between gap-3">
            <span class="text-base-content/70">{gettext("Delivery")}</span>
            <span id={"#{@pid}-quote-price"} class="font-semibold text-right">
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
            id={"#{@pid}-quote"}
            eta={@eta}
            cod_fee={@cod_fee}
            currency={@cod_currency}
            fallback={@status == :fallback and not @presented.free?}
          />
          <.recalculate_button :if={@status == :fallback} pid={@pid} myself={@myself} />
        <% @status in [:missing, :stale] -> %>
          <.recalculate_button pid={@pid} myself={@myself} />
        <% true -> %>
      <% end %>
    </div>
    """
  end

  attr :pid, :string, required: true
  attr :myself, :any, required: true

  defp recalculate_button(assigns) do
    ~H"""
    <button
      id={"#{@pid}-quote-retry"}
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
