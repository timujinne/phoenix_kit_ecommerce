defmodule PhoenixKitEcommerce.Shipping.MethodParams do
  @moduledoc """
  Turns the `shipping_provider` param of the shipping method form into the
  block stored under `PhoenixKitEcommerce.Shipping.MethodConfig.metadata_key/0`
  and validates it. Used by `PhoenixKitEcommerce.ShippingMethod.changeset/2`.

  The param (string or atom keys):

      %{
        "provider" => "acme_post",
        "service" => "warehouse",
        "settings" => %{"sender_city" => %{"id" => "c1", "name" => "Springfield"}},
        "pricing" => %{"markup_percent" => "10", "markup_fixed" => "0", "round_to" => "5"}
      }

  `round_to` is the rounding step of the price: empty or `0` means no
  rounding, a positive number rounds up to a multiple of it.

  Validation uses the provider registry only: no database, no credentials and
  nothing but a short (2 s) call to the provider's `services/1`:

    * a provider whose `services/1` fails is accepted as is, because an outage
      of the carrier must not stop the admin from saving a method
    * so is one that lists no services at all
    * a service the credential-less list does not know is accepted when the
      provider has an `integration/0`, since its credentials may unlock more
      services than we can see here
  """

  require Logger

  alias PhoenixKitEcommerce.Shipping
  alias PhoenixKitEcommerce.Shipping.{Codec, Field}

  @fixed "fixed"
  @pricing_keys [:markup_percent, :markup_fixed, :round_to]
  @max_pricing 1_000_000
  @services_timeout 2_000

  @type message :: {String.t(), keyword()}

  @doc """
  Normalises and validates the param.

  Option `check_service: false` skips the one check that calls the provider
  (that the service is offered), for interactive validation: a slow carrier
  must not slow down every keystroke of a form. The shape of the service, the
  settings and the pricing are still checked.

    * `{:ok, block}` - the map to store
    * `{:ok, nil}` - the block is to be removed: no provider, or `"fixed"`
      (it has no service and no settings: the behaviour of a method without
      the block)
    * `{:error, messages}` - what is wrong, as `{message, bindings}` pairs for
      `Ecto.Changeset.add_error/4` (user text only ever travels in the
      bindings); a param that is not a map is an error too

  `"fixed"` is always a method without the block, whatever else the param
  carries.
  """
  @spec build(term(), keyword()) :: {:ok, map() | nil} | {:error, [message()]}
  def build(param, opts \\ [])

  def build(param, opts) when is_map(param) do
    provider = param |> Codec.get(:provider) |> Codec.string() |> trim()
    service = param |> Codec.get(:service) |> Codec.string() |> trim()
    settings = param |> Codec.get(:settings) |> Codec.string_map() |> drop_blank()
    pricing = Codec.get(param, :pricing)

    if provider in ["", @fixed] do
      {:ok, nil}
    else
      validate(provider, service, settings, pricing, opts)
    end
  end

  def build(_param, _opts), do: {:error, [{"must be a map", []}]}

  defp validate(key, service, settings, pricing, opts) do
    case find_provider(key) do
      {:ok, module} ->
        {pricing_block, pricing_errors} = pricing_block(pricing)

        case pricing_errors ++
               settings_errors(module, settings) ++
               service_errors(module, service, settings, opts) do
          [] -> {:ok, block(key, service, settings, pricing_block)}
          errors -> {:error, errors}
        end

      {:error, _messages} = error ->
        error
    end
  end

  defp find_provider(key) do
    case Shipping.provider(key) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, [{"unknown provider %{provider}", [provider: key]}]}
    end
  end

  defp block(key, service, settings, pricing) do
    %{"provider" => key, "settings" => settings}
    |> put_present("service", service)
    |> put_present("pricing", pricing)
  end

  defp put_present(map, _key, value) when value in [nil, "", %{}], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # -- service -----------------------------------------------------------

  defp service_errors(module, service, settings, opts) do
    if Keyword.get(opts, :check_service, true),
      do: check_service_offered(module, service, settings),
      else: []
  end

  defp check_service_offered(module, service, settings) do
    ctx =
      Shipping.context(nil,
        provider: module,
        settings: settings,
        service: nilify(service),
        credentials: nil,
        timeout: @services_timeout
      )

    case Shipping.services(ctx) do
      {:ok, []} -> []
      {:ok, services} -> check_service(module, services, service)
      {:error, _reason} -> []
    end
  end

  defp check_service(_module, _services, "") do
    [{"service is required", []}]
  end

  defp check_service(module, services, service) do
    cond do
      Enum.any?(services, &(&1.key == service)) ->
        []

      function_exported?(module, :integration, 0) ->
        Logger.debug(
          "Shipping method service #{inspect(service)} is not offered to #{module.key()} " <>
            "without credentials; accepted"
        )

        []

      true ->
        [{"unknown service %{service}", [service: service]}]
    end
  end

  # -- settings ----------------------------------------------------------

  defp settings_errors(module, settings) do
    for %Field{required: true} = field <- fields(module),
        not present?(field.type, Map.get(settings, field.key)) do
      {"required setting %{setting} is missing", [setting: field.key]}
    end
  end

  defp fields(module) do
    List.wrap(module.settings_fields())
  rescue
    _error -> []
  end

  defp present?(type, %{} = value) when type in [:locality, :pickup_point] do
    filled?(Codec.get(value, :id)) and filled?(Codec.get(value, :name))
  end

  defp present?(type, _other) when type in [:locality, :pickup_point], do: false
  defp present?(:boolean, value), do: is_boolean(value) or value in ["true", "false"]
  defp present?(_type, value), do: filled?(value)

  defp filled?(nil), do: false
  defp filled?(value) when is_binary(value), do: String.trim(value) != ""
  defp filled?(value) when is_map(value) or is_list(value), do: Enum.any?(value)
  defp filled?(_value), do: true

  # A blank input is "not filled in": `nil`, "", an empty map or an empty list.
  defp drop_blank(settings) do
    settings |> Enum.reject(fn {_key, value} -> blank?(value) end) |> Map.new()
  end

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(value), do: value in [nil, %{}, []]

  # -- pricing -----------------------------------------------------------

  defp pricing_block(pricing) do
    Enum.reduce(@pricing_keys, {%{}, []}, fn key, {block, errors} ->
      case pricing_value(Codec.get(pricing, key), key) do
        :blank ->
          {block, errors}

        {:ok, decimal} ->
          {Map.put(block, Atom.to_string(key), canonical(decimal)), errors}

        {:error, message} ->
          {block, errors ++ [message]}
      end
    end)
  end

  defp pricing_value(value, key) do
    if is_nil(value) or (is_binary(value) and String.trim(value) == ""),
      do: :blank,
      else: value |> Codec.decimal() |> checked_pricing(key)
  end

  defp canonical(decimal) do
    if Decimal.eq?(decimal, 0),
      do: "0",
      else: decimal |> Decimal.normalize() |> Decimal.to_string(:normal)
  end

  defp checked_pricing(nil, key), do: {:error, {"%{field} must be a number", [field: key]}}

  defp checked_pricing(decimal, key) do
    cond do
      Decimal.compare(decimal, @max_pricing) == :gt ->
        {:error, {"%{field} must be at most %{max}", [field: key, max: @max_pricing]}}

      Decimal.compare(decimal, 0) == :lt ->
        {:error, {"%{field} must be 0 or greater", [field: key]}}

      true ->
        {:ok, decimal}
    end
  end

  defp trim(nil), do: ""
  defp trim(value), do: String.trim(value)

  defp nilify(""), do: nil
  defp nilify(value), do: value
end
