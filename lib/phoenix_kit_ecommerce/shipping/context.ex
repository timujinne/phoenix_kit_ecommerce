defmodule PhoenixKitEcommerce.Shipping.Context do
  @moduledoc """
  Everything a provider callback needs besides its own arguments.

    * `method` - the `PhoenixKitEcommerce.ShippingMethod`, or `nil`
    * `provider` - the provider module, or `nil` when the configured key is unknown
    * `service` - the selected service key
    * `settings` - the provider settings of the method (string keys)
    * `credentials` - the Integrations data of the provider, or `nil`
    * `locale` / `currency` - the shopper locale and the currency of the order
    * `opts` - pass-through options (for example `:req_options` in tests)

  `to_map/1` is deliberately lossy: credentials, the method struct and `opts`
  never leave the process, so a serialised context is safe to log. For the
  same reason `inspect/1` hides `credentials`. `from_map/1` only resolves a
  provider that is registered in `PhoenixKitEcommerce.Shipping.providers/0`.
  """

  alias PhoenixKitEcommerce.Shipping
  alias PhoenixKitEcommerce.Shipping.Codec

  @derive {Inspect, except: [:credentials]}
  defstruct method: nil,
            provider: nil,
            service: nil,
            settings: %{},
            credentials: nil,
            locale: nil,
            currency: nil,
            opts: []

  @type t :: %__MODULE__{
          method: PhoenixKitEcommerce.ShippingMethod.t() | nil,
          provider: module() | nil,
          service: String.t() | nil,
          settings: map(),
          credentials: map() | nil,
          locale: String.t() | nil,
          currency: String.t() | nil,
          opts: keyword()
        }

  @doc "Serialises the context without credentials, method and opts."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = context) do
    %{
      "method_uuid" => method_uuid(context.method),
      "provider" => provider_name(context.provider),
      "service" => context.service,
      "settings" => Codec.dump(context.settings),
      "locale" => context.locale,
      "currency" => context.currency
    }
  end

  @doc "Builds a context from `to_map/1` output; the omitted fields stay empty."
  @spec from_map(term()) :: t() | nil
  def from_map(%__MODULE__{} = context), do: context

  def from_map(map) when is_map(map) do
    %__MODULE__{
      provider: map |> Codec.get(:provider) |> registered_provider(),
      service: map |> Codec.get(:service) |> Codec.string(),
      settings: map |> Codec.get(:settings) |> Codec.string_map(),
      locale: map |> Codec.get(:locale) |> Codec.string(),
      currency: map |> Codec.get(:currency) |> Codec.string()
    }
  end

  def from_map(_other), do: nil

  defp method_uuid(%{uuid: uuid}), do: uuid
  defp method_uuid(_other), do: nil

  defp provider_name(nil), do: nil
  defp provider_name(module) when is_atom(module), do: Atom.to_string(module)

  defp registered_provider(value) when is_binary(value) do
    Enum.find(Shipping.providers(), &(Atom.to_string(&1) == value or &1.key() == value))
  end

  defp registered_provider(value) when is_atom(value) and not is_nil(value) do
    if value in Shipping.providers(), do: value
  end

  defp registered_provider(_other), do: nil
end
