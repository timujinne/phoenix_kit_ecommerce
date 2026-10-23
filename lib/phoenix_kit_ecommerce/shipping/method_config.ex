defmodule PhoenixKitEcommerce.Shipping.MethodConfig do
  @moduledoc """
  Read-only view of the provider configuration of a shipping method, kept in
  `method.metadata["shipping_provider"]`:

      %{
        "provider" => "acme_post",
        "service" => "warehouse",
        "services" => ["warehouse", "locker"],
        "settings" => %{"sender_city" => %{"id" => "...", "name" => "Springfield"}},
        "pricing" => %{"markup_percent" => "0", "markup_fixed" => "0", "round_to" => "5"}
      }

  `"services"` are the services the buyer may choose from, in the order the
  provider lists them; `"service"` is the default one (the first allowed one
  unless a stored default is among them). A block with a `"service"` and no
  `"services"` (how methods were stored before the buyer could choose) is
  read as a list of that one service, so it behaves as it always did.

  A method without the block uses the `"fixed"` provider, which is the
  behaviour shipping methods always had. `round_to` is `nil` (no rounding)
  unless a positive step is stored.
  """

  alias PhoenixKitEcommerce.Shipping.Codec

  @metadata_key "shipping_provider"
  @fixed "fixed"

  defstruct provider: @fixed,
            service: nil,
            services: [],
            settings: %{},
            pricing: %{
              markup_percent: Decimal.new(0),
              markup_fixed: Decimal.new(0),
              round_to: nil
            }

  @type pricing :: %{
          markup_percent: Decimal.t(),
          markup_fixed: Decimal.t(),
          round_to: Decimal.t() | nil
        }

  @type t :: %__MODULE__{
          provider: String.t(),
          service: String.t() | nil,
          services: [String.t()],
          settings: map(),
          pricing: pricing()
        }

  @doc "The metadata key the configuration lives under."
  @spec metadata_key() :: String.t()
  def metadata_key, do: @metadata_key

  @doc "Reads the configuration of a shipping method (any map or struct with `metadata`)."
  @spec from_method(term()) :: t()
  def from_method(%{metadata: metadata}), do: from_metadata(metadata)
  def from_method(_other), do: from_metadata(nil)

  @doc """
  Reads the configuration out of a metadata map. A `"fixed"` block (an older
  one could ask the customer for an address) is read as no block at all.
  """
  @spec from_metadata(term()) :: t()
  def from_metadata(metadata) do
    block = Codec.get(metadata, :shipping_provider)

    case block |> Codec.get(:provider) |> provider_key() do
      @fixed ->
        %__MODULE__{}

      provider ->
        stored = block |> Codec.get(:service) |> service_key()
        services = block |> Codec.get(:services) |> allowed_services(stored)

        %__MODULE__{
          provider: provider,
          service: default_service(stored, services),
          services: services,
          settings: block |> Codec.get(:settings) |> Codec.string_map(),
          pricing: block |> Codec.get(:pricing) |> pricing_from()
        }
    end
  end

  @doc """
  `true` when the price comes from a provider other than `"fixed"`.

  Accepts a shipping method or a `t:t/0`.
  """
  @spec calculated?(t() | term()) :: boolean()
  def calculated?(%__MODULE__{provider: provider}), do: provider != @fixed
  def calculated?(method), do: method |> from_method() |> calculated?()

  @doc """
  Cleans a list of service keys: trimmed, no blanks or duplicates, in the
  given order. Anything that is not a list is an empty list.
  """
  @spec normalize_services(term()) :: [String.t()]
  def normalize_services(list) when is_list(list) do
    list
    |> Enum.map(&service_key/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def normalize_services(_other), do: []

  defp allowed_services(list, stored) do
    case normalize_services(list) do
      [] -> normalize_services([stored])
      services -> services
    end
  end

  defp default_service(stored, services),
    do: if(stored in services, do: stored, else: List.first(services))

  defp provider_key(value) do
    case value |> Codec.string() |> trim() do
      "" -> @fixed
      key -> key
    end
  end

  defp service_key(value) do
    case value |> Codec.string() |> trim() do
      "" -> nil
      key -> key
    end
  end

  defp trim(nil), do: ""
  defp trim(value), do: String.trim(value)

  defp pricing_from(pricing) do
    %{
      markup_percent: non_negative(Codec.get(pricing, :markup_percent), Decimal.new(0)),
      markup_fixed: non_negative(Codec.get(pricing, :markup_fixed), Decimal.new(0)),
      round_to: positive(Codec.get(pricing, :round_to), nil)
    }
  end

  defp non_negative(value, default) do
    case Codec.decimal(value) do
      nil -> default
      decimal -> if Decimal.compare(decimal, 0) == :lt, do: default, else: decimal
    end
  end

  defp positive(value, default) do
    case Codec.decimal(value) do
      nil -> default
      decimal -> if Decimal.compare(decimal, 0) == :gt, do: decimal, else: default
    end
  end
end
