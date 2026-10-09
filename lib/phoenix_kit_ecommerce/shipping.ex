defmodule PhoenixKitEcommerce.Shipping do
  @moduledoc """
  Entry point to shipping providers.

  Providers implement `PhoenixKitEcommerce.Shipping.Provider`. This module
  finds them, builds the `PhoenixKitEcommerce.Shipping.Context` they run in
  and calls them with a safety net: every call is cached where that makes
  sense, bounded by a timeout, wrapped in telemetry and cannot raise.

  ## Results

  Every call returns `{:ok, value}` or `{:error, reason}` where `reason` is

    * whatever the provider returned
    * `:timeout` - no answer within the timeout
    * `{:provider_crashed, message}` - the provider raised, threw or exited
    * `{:bad_return, inspected}` - the provider broke its contract
    * `:unknown_provider` - the context has no provider module
    * `:not_supported` - the provider does not implement the optional callback
    * `:unsupported_currency` - the provider declares `currencies/0` and the
      request currency is not among them

  `business_error?/1` tells the two families apart: a business error means
  "this method cannot serve this cart", everything else is transient.

  ## Configuration

      config :phoenix_kit_ecommerce,
        shipping_providers: [MyShop.Shipping.MyCarrier],
        shipping_provider_timeout: 15_000,
        shipping_packer: PhoenixKitEcommerce.Shipping.Packer.SingleBox,
        shipping_cache_ttl: [lookups: :timer.hours(6), quotes: :timer.minutes(10)]

  ## Telemetry

  `[:phoenix_kit_ecommerce, :shipping, :provider]` span with metadata
  `%{provider: key, operation: atom}`; the stop event adds `status: :ok | :error`.

  ## Isolation

  A provider call runs in its own unlinked, monitored process, so a provider
  that crashes, kills itself or links to something that dies cannot take the
  caller (a LiveView) down. The worker inherits the caller's `$callers`
  (sandbox and `Req.Test` allowances follow) and its Gettext locale: the one
  of the context, else the caller's.
  """

  require Logger

  alias PhoenixKit.Integrations
  alias PhoenixKitEcommerce.Shipping.{Address, Cache, Codec, Context, Locality, MethodConfig}
  alias PhoenixKitEcommerce.Shipping.{Parcel, PickupPoint, Quote, RateRequest, Service}
  alias PhoenixKitEcommerce.Shipping.Providers.{Fixed, Table}

  @builtin_providers [Fixed, Table]
  @telemetry_event [:phoenix_kit_ecommerce, :shipping, :provider]
  @default_timeout 15_000
  @min_query_length 2
  @context_option_keys [:provider, :settings, :service, :locale, :currency, :credentials]
  @max_query_length 64
  @business_errors [
    :too_heavy,
    :too_large,
    :service_unavailable,
    :unsupported_destination,
    :invalid_destination,
    :unsupported_currency,
    :no_rates
  ]

  @type result(value) :: {:ok, value} | {:error, term()}

  # -- registry ---------------------------------------------------------

  @doc """
  The available provider modules: the built-in `Fixed` and `Table` followed by
  `config :phoenix_kit_ecommerce, :shipping_providers`. A key is listed once
  (the first module wins) and modules that do not implement `key/0` are skipped.
  """
  @spec providers() :: [module()]
  def providers do
    configured = Application.get_env(:phoenix_kit_ecommerce, :shipping_providers, [])

    (@builtin_providers ++ configured)
    |> Enum.filter(&provider_module?/1)
    |> Enum.uniq_by(& &1.key())
  end

  @doc "Finds a provider module by its `key/0`."
  @spec provider(term()) :: {:ok, module()} | :error
  def provider(key) when is_binary(key) do
    case Enum.find(providers(), &(&1.key() == key)) do
      nil -> :error
      module -> {:ok, module}
    end
  end

  def provider(_other), do: :error

  # -- context ----------------------------------------------------------

  @doc """
  Builds the `Context` for a shipping method (or `nil`).

  Provider, service and settings come from the method's `MethodConfig` and can
  be overridden by options, for example to preview an unsaved form. The
  `provider` is `nil` when the configured key is unknown; the calls below then
  answer `{:error, :unknown_provider}`.

  Options:

    * `:provider` (key or module), `:service`, `:settings` - override the method
    * `:locale` - defaults to the process Gettext locale
    * `:currency` - defaults to the currency of the method
    * `:credentials` - use these instead of looking them up in Integrations
    * everything else is passed through as `ctx.opts` (`:timeout`, `:req_options`...)

  Credentials are only loaded when the provider implements `integration/0`:
  the connection named by `settings["integration"]`, else the first connection
  of the provider. Any failure leaves `credentials` as `nil`.
  """
  @spec context(term(), keyword()) :: Context.t()
  def context(method, opts \\ []) do
    config = MethodConfig.from_method(method)
    provider = resolve_provider(Keyword.get(opts, :provider, config.provider))
    settings = Keyword.get(opts, :settings, config.settings)

    %Context{
      method: if(is_struct(method), do: method),
      provider: provider,
      service: Keyword.get(opts, :service, config.service),
      settings: settings,
      credentials: credentials(provider, settings, opts),
      locale: Keyword.get_lazy(opts, :locale, &current_locale/0),
      currency: Keyword.get(opts, :currency) || method_currency(method),
      opts: Keyword.drop(opts, @context_option_keys)
    }
  end

  defp resolve_provider(module) when is_atom(module) and not is_nil(module) do
    if provider_module?(module), do: module
  end

  defp resolve_provider(key) do
    case provider(key) do
      {:ok, module} -> module
      :error -> nil
    end
  end

  defp provider_module?(module) when is_atom(module) and not is_nil(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :key, 0)
  end

  defp provider_module?(_other), do: false

  defp current_locale, do: Gettext.get_locale(PhoenixKitEcommerce.Gettext)

  defp method_currency(%{currency: currency}) when is_binary(currency), do: currency
  defp method_currency(_method), do: nil

  defp credentials(nil, _settings, _opts), do: nil

  defp credentials(provider, settings, opts) do
    cond do
      not function_exported?(provider, :integration, 0) -> nil
      Keyword.has_key?(opts, :credentials) -> Keyword.get(opts, :credentials)
      true -> load_credentials(provider, settings)
    end
  end

  defp load_credentials(provider, settings) do
    with uuid when is_binary(uuid) <- connection_uuid(provider, settings),
         {:ok, %{} = data} <- Integrations.get_credentials(uuid) do
      data
    else
      _ -> nil
    end
  rescue
    error ->
      Logger.warning(
        "Shipping credentials lookup failed for #{provider.key()}: " <>
          Exception.message(error)
      )

      nil
  catch
    :exit, _reason -> nil
  end

  defp connection_uuid(provider, settings) do
    case Codec.get(settings, :integration) do
      uuid when is_binary(uuid) and uuid != "" ->
        uuid

      _ ->
        case Integrations.list_connections(integration_key(provider)) do
          [%{uuid: uuid} | _] -> uuid
          [] -> nil
        end
    end
  end

  defp integration_key(provider) do
    case provider.integration() do
      %{key: key} when is_binary(key) -> key
      %{"key" => key} when is_binary(key) -> key
      _ -> provider.key()
    end
  end

  # -- provider calls ---------------------------------------------------

  @doc "The services the provider offers in this context (cached)."
  @spec services(Context.t()) :: result([Service.t()])
  def services(%Context{} = ctx) do
    call(ctx, :services, {:lookups, []}, fn -> normalize(:list, ctx.provider.services(ctx)) end)
  end

  @doc """
  Locality autocomplete. A query shorter than #{@min_query_length} characters
  answers `{:ok, []}` without calling the provider.
  """
  @spec search_localities(Context.t(), String.t()) :: result([Locality.t()])
  def search_localities(%Context{} = ctx, query) do
    query = normalize_query(query) || ""

    cond do
      String.length(query) < @min_query_length ->
        {:ok, []}

      not exports?(ctx, :search_localities, 2) ->
        unsupported(ctx)

      true ->
        call(ctx, :search_localities, {:lookups, [String.downcase(query)]}, fn ->
          normalize(:ok_list, ctx.provider.search_localities(query, ctx))
        end)
    end
  end

  @doc """
  Pickup points of `locality` for the service of the context, narrowed by
  `query` (`nil` or blank means all).

  Options: `:parcels` and `:declared_value` drop the points that cannot accept
  them (see `fits_point?/3`).
  """
  @spec list_pickup_points(Context.t(), Locality.t(), String.t() | nil, keyword()) ::
          result([PickupPoint.t()])
  def list_pickup_points(%Context{} = ctx, %Locality{} = locality, query \\ nil, opts \\ []) do
    query = normalize_query(query)

    if exports?(ctx, :list_pickup_points, 4) do
      ctx
      |> call(
        :list_pickup_points,
        {:lookups, [locality.id, query && String.downcase(query)]},
        fn ->
          normalize(:ok_list, ctx.provider.list_pickup_points(locality, ctx.service, query, ctx))
        end
      )
      |> filter_points(opts)
    else
      unsupported(ctx)
    end
  end

  @doc """
  Prices a request (cached by `request_hash/1`). A missing `service` and
  `currency` of the request are taken from the context.
  """
  @spec quote(Context.t(), RateRequest.t()) :: result(Quote.t())
  def quote(%Context{} = ctx, %RateRequest{} = request) do
    request = %{
      request
      | service: request.service || ctx.service,
        currency: request.currency || ctx.currency
    }

    if currency_supported?(ctx.provider, request.currency) do
      call(ctx, :quote, {:quotes, [request_hash(request)]}, fn ->
        normalize(:quote, ctx.provider.quote(request, ctx))
      end)
    else
      {:error, :unsupported_currency}
    end
  end

  defp currency_supported?(provider, currency) when is_binary(currency) do
    if provider_module?(provider) and function_exported?(provider, :currencies, 0),
      do: currency in provider.currencies(),
      else: true
  end

  defp currency_supported?(_provider, _currency), do: true

  defp exports?(%Context{provider: provider}, function, arity),
    do: provider_module?(provider) and function_exported?(provider, function, arity)

  defp unsupported(%Context{provider: provider}) do
    if provider_module?(provider),
      do: {:error, :not_supported},
      else: {:error, :unknown_provider}
  end

  defp normalize_query(query) when is_binary(query) do
    case query |> String.trim() |> String.slice(0, @max_query_length) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_query(_other), do: nil

  defp filter_points({:ok, points}, opts) do
    parcels = Keyword.get(opts, :parcels)
    declared = Keyword.get(opts, :declared_value)

    if is_list(parcels) or not is_nil(declared) do
      {:ok, Enum.filter(points, &fits_point?(&1, parcels || [], declared))}
    else
      {:ok, points}
    end
  end

  defp filter_points(error, _opts), do: error

  defp normalize(:list, list) when is_list(list), do: {:ok, list}
  defp normalize(:ok_list, {:ok, list} = ok) when is_list(list), do: ok

  defp normalize(:quote, {:ok, %Quote{amount: %Decimal{} = amount}} = ok) do
    if finite?(amount) and Decimal.compare(amount, 0) != :lt,
      do: ok,
      else: bad_return(ok)
  end

  defp normalize(_kind, {:error, _reason} = error), do: error
  defp normalize(_kind, other), do: bad_return(other)

  defp finite?(%Decimal{} = decimal), do: not (Decimal.nan?(decimal) or Decimal.inf?(decimal))

  defp bad_return(value), do: {:error, {:bad_return, inspect(value, limit: 5)}}

  defp call(%Context{provider: provider} = ctx, operation, cache, fun) do
    if provider_module?(provider),
      do: run_call(provider.key(), ctx, operation, cache, fun),
      else: {:error, :unknown_provider}
  end

  defp run_call(key, ctx, operation, cache, fun) do
    metadata = %{provider: key, operation: operation}

    result =
      :telemetry.span(@telemetry_event, metadata, fn ->
        result = cached(cache, key, operation, ctx, fn -> guarded(ctx, fun) end)
        {result, Map.put(metadata, :status, status(result))}
      end)

    log_error(result, key, operation)
    result
  end

  defp cached({kind, parts}, provider_key, operation, ctx, fun) do
    key = {:shipping, provider_key, operation, fingerprint(ctx), parts}

    Cache.fetch(key, Cache.ttl(kind), fun,
      negative_ttl: Cache.ttl(:negative),
      cacheable_error?: &(not business_error?(&1))
    )
  end

  defp fingerprint(%Context{} = ctx) do
    method =
      if is_map(ctx.method), do: Map.take(ctx.method, [:uuid, :price, :currency, :updated_at])

    :crypto.hash(
      :sha256,
      :erlang.term_to_binary(
        {ctx.settings, ctx.credentials, ctx.service, ctx.locale, ctx.currency, method},
        [:deterministic]
      )
    )
  end

  # An unlinked, monitored worker: whatever the provider does to itself (raise,
  # exit, kill, die through a linked process) the caller only sees a result.
  defp guarded(%Context{} = ctx, fun) do
    timeout = Keyword.get(ctx.opts, :timeout) || configured_timeout()
    parent = self()
    tag = make_ref()
    callers = [parent | Process.get(:"$callers", [])]
    locale = ctx.locale || current_locale()

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.put(:"$callers", callers)
        put_locale(locale)
        send(parent, {tag, run_safely(fun)})
      end)

    receive do
      {^tag, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, {:provider_crashed, Exception.format_exit(reason)}}
    after
      timeout ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])

        receive do
          {^tag, _late} -> :ok
        after
          0 -> :ok
        end

        {:error, :timeout}
    end
  end

  defp run_safely(fun) do
    fun.()
  rescue
    error -> {:error, {:provider_crashed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:provider_crashed, Exception.format_banner(kind, reason)}}
  end

  defp put_locale(locale) when is_binary(locale) do
    Gettext.put_locale(PhoenixKitEcommerce.Gettext, locale)
    Gettext.put_locale(locale)
  end

  defp put_locale(_locale), do: :ok

  defp configured_timeout do
    Application.get_env(:phoenix_kit_ecommerce, :shipping_provider_timeout, @default_timeout)
  end

  defp status({:ok, _value}), do: :ok
  defp status(_error), do: :error

  defp log_error({:error, reason}, key, operation) do
    message = "Shipping provider #{key} #{operation} failed: #{inspect(reason, limit: 10)}"

    if business_error?(reason), do: Logger.info(message), else: Logger.warning(message)
  end

  defp log_error(_ok, _key, _operation), do: :ok

  @doc """
  Whether an error reason means "this method cannot serve this cart"
  (`:too_heavy`, `:too_large`, `:service_unavailable`,
  `:unsupported_destination`, `:invalid_destination`, `:unsupported_currency`,
  `:no_rates`, bare or as the first element of a tuple). Anything else -
  timeout, crash, transport or HTTP trouble, provider-specific reasons - is
  transient, and callers fall back to the price of the method.
  """
  @spec business_error?(term()) :: boolean()
  def business_error?(reason) when reason in @business_errors, do: true
  def business_error?({reason, _details}) when reason in @business_errors, do: true
  def business_error?(_reason), do: false

  # -- parcels and requests --------------------------------------------

  @doc """
  Whether a pickup point accepts the parcels and the declared value. A limit
  the point does not declare, or a parcel measurement that is unknown, never
  disqualifies it.
  """
  @spec fits_point?(PickupPoint.t(), [Parcel.t()], Decimal.t() | nil) :: boolean()
  def fits_point?(%PickupPoint{limits: limits}, parcels, declared_value) when is_map(limits) do
    weight_fits?(limits[:max_weight_g], parcels) and
      dims_fit?(limits[:max_dims_mm], parcels) and
      declared_fits?(limits[:max_declared], declared_value)
  end

  def fits_point?(_point, _parcels, _declared_value), do: true

  defp weight_fits?(nil, _parcels), do: true

  defp weight_fits?(max, parcels),
    do: Enum.all?(parcels, fn parcel -> (parcel.weight_g || 0) <= max end)

  defp dims_fit?([_, _, _] = max, parcels) do
    max = Enum.sort(max, :desc)
    Enum.all?(parcels, &parcel_fits_dims?(&1, max))
  end

  defp dims_fit?(_max, _parcels), do: true

  defp parcel_fits_dims?(parcel, max) do
    case [parcel.length_mm, parcel.width_mm, parcel.height_mm] do
      [l, w, h] when is_number(l) and is_number(w) and is_number(h) ->
        [l, w, h]
        |> Enum.sort(:desc)
        |> Enum.zip(max)
        |> Enum.all?(fn {side, cap} -> side <= cap end)

      _unknown ->
        true
    end
  end

  defp declared_fits?(%Decimal{} = max, %Decimal{} = declared),
    do: Decimal.compare(declared, max) != :gt

  defp declared_fits?(_max, _declared), do: true

  @doc """
  Stable fingerprint of a request: SHA-256 of its canonical JSON (keys sorted
  recursively; service, origin, destination by id, parcels, declared value,
  COD amount, currency), the first 16 bytes as lowercase hex. Equal amounts
  hash equally whatever their Decimal scale. The format is part of the
  contract: hashes are stored with carts.
  """
  @spec request_hash(RateRequest.t()) :: String.t()
  def request_hash(%RateRequest{} = request) do
    %{
      "service" => request.service,
      "origin" => request.origin,
      "destination" => destination_ref(request.destination),
      "parcels" => request.parcels,
      "declared_value" => request.declared_value,
      "cod_amount" => request.cod_amount,
      "currency" => request.currency
    }
    |> canonical()
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> binary_part(0, 16)
    |> Base.encode16(case: :lower)
  end

  defp destination_ref(nil), do: nil

  defp destination_ref(destination) do
    %{
      "locality" => destination.locality && destination.locality.id,
      "pickup_point" => destination.pickup_point && destination.pickup_point.id,
      "address" => destination.address && Address.to_map(destination.address)
    }
  end

  defp canonical(%Decimal{} = decimal) do
    if Decimal.eq?(decimal, 0),
      do: "0",
      else: decimal |> Decimal.normalize() |> Decimal.to_string(:normal)
  end

  defp canonical(%{__struct__: _} = struct), do: struct |> Codec.dump() |> canonical()

  defp canonical(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), canonical(value)} end)
    |> Enum.sort()
    |> Jason.OrderedObject.new()
  end

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(value) when is_boolean(value) or is_nil(value), do: value
  defp canonical(value) when is_atom(value), do: Atom.to_string(value)
  defp canonical(value), do: value
end
