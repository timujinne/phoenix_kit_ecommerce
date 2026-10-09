defmodule PhoenixKitEcommerce.Shipping.MethodParams do
  @moduledoc """
  Turns the `shipping_provider` param of the shipping method form into the
  block stored under `PhoenixKitEcommerce.Shipping.MethodConfig.metadata_key/0`
  and validates it. Used by `PhoenixKitEcommerce.ShippingMethod.changeset/2`.

  The param (string or atom keys):

      %{
        "provider" => "nova_poshta",
        "service" => "warehouse",
        "settings" => %{"sender_city" => %{"id" => "c1", "name" => "Poltava"}},
        "pricing" => %{"markup_percent" => "10", "markup_fixed" => "0", "round_to" => "5"}
      }

  Validation uses the provider registry only: no network, no database. The
  services come from `PhoenixKitEcommerce.Shipping.services/1` with empty
  credentials; a provider whose `services/1` fails is accepted as is, because
  an outage of the carrier must not stop the admin from saving a method.
  """

  alias PhoenixKitEcommerce.Shipping
  alias PhoenixKitEcommerce.Shipping.{Codec, Field}

  @fixed "fixed"
  @pricing_keys [:markup_percent, :markup_fixed, :round_to]

  @doc """
  Normalises and validates the param.

    * `{:ok, block}` - the map to store
    * `{:ok, nil}` - the block is to be removed: no provider, or `"fixed"`
      without settings (the behaviour of a method without the block)
    * `{:error, messages}` - what is wrong, as plain strings
  """
  @spec build(term()) :: {:ok, map() | nil} | {:error, [String.t()]}
  def build(param) do
    provider = param |> Codec.get(:provider) |> Codec.string() |> trim()
    service = param |> Codec.get(:service) |> Codec.string() |> trim()
    settings = param |> Codec.get(:settings) |> Codec.string_map() |> drop_blank()
    pricing = Codec.get(param, :pricing)

    if provider in ["", @fixed] and settings == %{} do
      {:ok, nil}
    else
      validate(provider_key(provider), service, settings, pricing)
    end
  end

  defp provider_key(""), do: @fixed
  defp provider_key(key), do: key

  defp validate(key, service, settings, pricing) do
    case find_provider(key) do
      {:ok, module} ->
        {pricing_block, pricing_errors} = pricing_block(pricing)

        case pricing_errors ++
               settings_errors(module, settings) ++ service_errors(module, service, settings) do
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
      :error -> {:error, ["unknown provider #{inspect(key)}"]}
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

  defp service_errors(module, service, settings) do
    ctx =
      Shipping.context(nil,
        provider: module,
        settings: settings,
        service: nilify(service),
        credentials: nil
      )

    case Shipping.services(ctx) do
      {:ok, []} -> []
      {:ok, services} -> check_service(services, service)
      {:error, _reason} -> []
    end
  end

  defp check_service(services, "") do
    if Enum.any?(services), do: ["service is required"], else: []
  end

  defp check_service(services, service) do
    if Enum.any?(services, &(&1.key == service)),
      do: [],
      else: ["unknown service #{inspect(service)}"]
  end

  # -- settings ----------------------------------------------------------

  defp settings_errors(module, settings) do
    for %Field{required: true} = field <- fields(module),
        not present?(field.type, Map.get(settings, field.key)) do
      "required setting #{field.key} is missing"
    end
  end

  defp fields(module) do
    List.wrap(module.settings_fields())
  rescue
    _error -> []
  end

  defp present?(:locality, %{} = value) do
    filled?(Codec.get(value, :id)) and filled?(Codec.get(value, :name))
  end

  defp present?(:locality, _other), do: false
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

  defp canonical(decimal), do: decimal |> Decimal.normalize() |> Decimal.to_string(:normal)

  defp checked_pricing(nil, key), do: {:error, "#{key} must be a number"}

  defp checked_pricing(decimal, :round_to) do
    if Decimal.compare(decimal, 0) == :gt,
      do: {:ok, decimal},
      else: {:error, "round_to must be greater than 0"}
  end

  defp checked_pricing(decimal, key) do
    if Decimal.compare(decimal, 0) == :lt,
      do: {:error, "#{key} must be 0 or greater"},
      else: {:ok, decimal}
  end

  defp trim(nil), do: ""
  defp trim(value), do: String.trim(value)

  defp nilify(""), do: nil
  defp nilify(value), do: value
end
