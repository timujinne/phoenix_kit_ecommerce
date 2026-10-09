defmodule PhoenixKitEcommerce.Shipping.MethodConfig do
  @moduledoc """
  Read-only view of the provider configuration of a shipping method, kept in
  `method.metadata["shipping_provider"]`:

      %{
        "provider" => "nova_poshta",
        "service" => "warehouse",
        "settings" => %{"sender_city" => %{"id" => "...", "name" => "Poltava"}},
        "pricing" => %{"markup_percent" => "0", "markup_fixed" => "0", "round_to" => "1"}
      }

  A method without the block uses the `"fixed"` provider, which is the
  behaviour shipping methods always had.
  """

  alias PhoenixKitEcommerce.Shipping.Codec

  @metadata_key "shipping_provider"
  @fixed "fixed"

  defstruct provider: @fixed,
            service: nil,
            settings: %{},
            pricing: %{
              markup_percent: Decimal.new(0),
              markup_fixed: Decimal.new(0),
              round_to: Decimal.new(1)
            }

  @type pricing :: %{
          markup_percent: Decimal.t(),
          markup_fixed: Decimal.t(),
          round_to: Decimal.t()
        }

  @type t :: %__MODULE__{
          provider: String.t(),
          service: String.t() | nil,
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

  @doc "Reads the configuration out of a metadata map."
  @spec from_metadata(term()) :: t()
  def from_metadata(metadata) do
    block = Codec.get(metadata, :shipping_provider)

    %__MODULE__{
      provider: block |> Codec.get(:provider) |> provider_key(),
      service: block |> Codec.get(:service) |> service_key(),
      settings: block |> Codec.get(:settings) |> Codec.string_map(),
      pricing: block |> Codec.get(:pricing) |> pricing_from()
    }
  end

  @doc """
  `true` when the price comes from a provider other than `"fixed"`.

  Accepts a shipping method or a `t:t/0`.
  """
  @spec calculated?(t() | term()) :: boolean()
  def calculated?(%__MODULE__{provider: provider}), do: provider != @fixed
  def calculated?(method), do: method |> from_method() |> calculated?()

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
      round_to: positive(Codec.get(pricing, :round_to), Decimal.new(1))
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
