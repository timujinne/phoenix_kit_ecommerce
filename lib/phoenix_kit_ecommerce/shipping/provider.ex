defmodule PhoenixKitEcommerce.Shipping.Provider do
  @moduledoc """
  Contract for a shipping provider (a carrier adapter or a built-in price rule).

  A provider is a plain module. It is registered in the host config and then
  shows up in the shipping method admin form:

      config :phoenix_kit_ecommerce,
        shipping_providers: [MyShop.Shipping.MyCarrier]

  Call the providers through `PhoenixKitEcommerce.Shipping` rather than
  directly: the facade adds caching, a timeout, telemetry and turns
  exceptions into `{:error, {:provider_crashed, message}}`.

  ## Required callbacks

    * `key/0` - unique, stable identifier stored on shipping methods
    * `label/0` - human readable name
    * `services/1` - the `PhoenixKitEcommerce.Shipping.Service` list. It takes
      the context because the answer may depend on credentials: a carrier
      without an API key might only support manual pickup point entry
      (`lookup: :manual`). The shop owner ticks which of the services a
      shipping method offers and the shopper chooses among those at checkout,
      so `quote/2` and the lookups must work for every service listed
      (`RateRequest.service` and `Context.service` name the one chosen)
    * `settings_fields/0` - `PhoenixKitEcommerce.Shipping.Field` list for the
      admin form; values arrive in `ctx.settings` with string keys
    * `quote/2` - price a `PhoenixKitEcommerce.Shipping.RateRequest`

  ## Optional callbacks

    * `search_localities/2` - autocomplete over cities for the query string
    * `list_pickup_points/4` - `(locality, service_key, query, ctx)`; the
      query narrows the list (a big city can have thousands of points), `nil`
      means no narrowing
    * `validate_destination/3` - extra checks of what the customer entered.
      `:ok`, or `{:error, message}` with an explanation for the customer
      (called through `PhoenixKitEcommerce.Shipping.validate_destination/3`)
    * `integration/0` - describes the provider for PhoenixKit Integrations:
      a map with `key`, `name`, `auth_type: :api_key`, `setup_fields` and
      `capabilities: [:shipping]`. The secret field must be called `api_key`
      or core will not encrypt it. When present, the facade loads the
      connection and passes it as `ctx.credentials` (`nil` if there is none)

    * `currencies/0` - ISO 4217 codes the provider prices in. When exported,
      `Shipping.quote/2` answers `{:error, :unsupported_currency}` for any
      other `RateRequest.currency` without calling the provider

    * `countries/0` - ISO 3166-1 alpha-2 codes of the destination countries the
      provider delivers to. Absent or `[]` means any. When the context (or the
      request) names another country, the `Shipping` facade answers
      `{:error, :unsupported_destination}` without calling the provider, and
      the shop shows the method as unavailable. A `Service` narrows this
      further with `Service.countries`. `Shipping.providers_for_country/1`
      lists the providers that serve a country

  `create_shipment/2`, `cancel_shipment/2`, `track/2` and `label/2` are
  reserved for waybills, tracking and printing. Nothing calls them yet.

  ## Rules for adapters

    * **Pure `services/1` and `validate_destination/3`.** No network, no
      database, no file access: only the context and the arguments. Core calls
      them from render paths, under the cart row lock and with a 2 second
      timeout; anything slow belongs in `quote/2` or the lookups. They get a
      context without credentials where core does not need them.

    * **Settings.** `RateRequest.origin` is filled by core from `ctx.settings`
      (the provider settings of the method), which stays the single source of
      truth; adapters read `ctx.settings`.
    * **Country.** `ctx.country` and `RateRequest.country` are the destination
      country; they are `nil` while the shopper has not given one, and then
      nothing is refused. `search_localities/2` and `list_pickup_points/4`
      should search that country only, and a provider that serves several sets
      `Locality.country`. A restriction of the carrier that depends on the
      country (no cash on delivery to Poland, say) is a business error:
      `{:error, :unsupported_destination}` or `{:error, :service_unavailable}`.
    * **Money.** `RateRequest.declared_value` and `cod_amount` are in
      `RateRequest.currency`; `Quote.amount` must be a non-negative `Decimal`
      or the answer is rejected as `{:bad_return, _}`.
    * **Credentials.** Work with `ctx.credentials == nil` whenever the carrier
      allows it (a keyless mode). Error reasons must never contain secrets:
      they are logged and may be stored.
    * **Manual pickup points.** For `lookup: :manual` the UI builds the point
      with `PhoenixKitEcommerce.Shipping.PickupPoint.manual/1`; read
      `pickup_point.id` (the code the customer typed).
    * **`extra` maps** of localities, points and addresses are provider-private;
      their values are strings once a JSON round-trip has happened (carts and
      orders), so keep references as strings.

  ## Errors

  Return `{:error, reason}`. These reasons are *business errors*:
  `:too_heavy`, `:too_large`, `:service_unavailable`, `:unsupported_destination`,
  `:invalid_destination`, `:unsupported_currency`, `:no_rates` (also as
  `{reason, details}`). They mean "this method cannot serve this cart", and
  the shop shows the method as unavailable. Every other reason (timeout,
  crash, transport, HTTP, provider-specific tuples) is transient: the shop
  falls back to the price of the method and the facade caches the failure
  briefly. `PhoenixKitEcommerce.Shipping.business_error?/1` makes the
  distinction.

  ## Example

      defmodule MyShop.Shipping.MyCarrier do
        @behaviour PhoenixKitEcommerce.Shipping.Provider

        alias PhoenixKitEcommerce.Shipping.{Context, Quote, RateRequest, Service}

        @impl true
        def key, do: "my_carrier"

        @impl true
        def label, do: "My carrier"

        @impl true
        def services(%Context{}) do
          [%Service{key: "home", label: "Courier", destination: :address}]
        end

        @impl true
        def settings_fields, do: []

        @impl true
        def quote(%RateRequest{parcels: parcels}, %Context{currency: currency}) do
          grams = parcels |> Enum.map(& &1.weight_g) |> Enum.sum()

          {:ok,
           %Quote{
             amount: Decimal.new(50 + div(grams, 1000) * 10),
             currency: currency,
             source: :api
           }}
        end
      end
  """

  alias PhoenixKitEcommerce.Shipping.{
    Context,
    Destination,
    Field,
    Locality,
    PickupPoint,
    Quote,
    RateRequest,
    Service
  }

  @callback key() :: String.t()
  @callback label() :: String.t()
  @callback services(Context.t()) :: [Service.t()]
  @callback settings_fields() :: [Field.t()]
  @callback quote(RateRequest.t(), Context.t()) :: {:ok, Quote.t()} | {:error, term()}
  @callback search_localities(String.t(), Context.t()) ::
              {:ok, [Locality.t()]} | {:error, term()}
  @callback list_pickup_points(Locality.t(), String.t(), String.t() | nil, Context.t()) ::
              {:ok, [PickupPoint.t()]} | {:error, term()}
  @callback validate_destination(Destination.t(), Service.t(), Context.t()) ::
              :ok | {:error, String.t()}
  @callback integration() :: map() | nil
  @callback currencies() :: [String.t()]
  @callback countries() :: [String.t()]

  # Reserved for the next stage (waybills, tracking, printing); not called yet.
  @callback create_shipment(map(), Context.t()) :: {:ok, map()} | {:error, term()}
  @callback cancel_shipment(map(), Context.t()) :: :ok | {:error, term()}
  @callback track(String.t(), Context.t()) :: {:ok, map()} | {:error, term()}
  @callback label(map(), Context.t()) :: {:ok, binary()} | {:error, term()}

  @optional_callbacks search_localities: 2,
                      list_pickup_points: 4,
                      validate_destination: 3,
                      integration: 0,
                      currencies: 0,
                      countries: 0,
                      create_shipment: 2,
                      cancel_shipment: 2,
                      track: 2,
                      label: 2
end
