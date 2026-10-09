defmodule PhoenixKitEcommerce.Web.ShippingProviderState do
  @moduledoc false
  # The "Shipping cost calculation" card of the shipping method form, as data.
  #
  # The card's inputs are posted under
  # `shipping_method[shipping_provider][provider|service|settings|pricing]`.
  # What the admin sees cannot be read back from the changeset: the block only
  # reaches `metadata` when it is valid, and a half-filled one never is. So the
  # form keeps its own state, `t:t/0`, built from the stored method and
  # updated from every posted form, and turns it into the
  # `shipping_provider` param (`to_param/1`) that `ShippingMethod.changeset/2`
  # validates and stores.

  alias PhoenixKitEcommerce.Shipping
  alias PhoenixKitEcommerce.Shipping.{Codec, Field}
  alias PhoenixKitEcommerce.ShippingMethod

  @fixed "fixed"
  @pricing_keys ~w(markup_percent markup_fixed round_to)

  @type t :: %{
          provider: String.t(),
          service: String.t(),
          settings: %{optional(String.t()) => term()},
          pricing: %{optional(String.t()) => String.t()},
          queries: %{optional(String.t()) => String.t()}
        }

  @doc "The key of the built-in provider whose price is the price of the method."
  @spec fixed() :: String.t()
  def fixed, do: @fixed

  @doc "The pricing keys the card has inputs for."
  @spec pricing_keys() :: [String.t()]
  def pricing_keys, do: @pricing_keys

  @doc "The state of a stored method (or of a new one: the fixed provider)."
  @spec from_method(term()) :: t()
  def from_method(method) do
    config = ShippingMethod.shipping_config(method)

    %{
      provider: config.provider,
      service: config.service || "",
      settings: config.settings,
      pricing: stored_pricing(method),
      queries: %{}
    }
  end

  @doc """
  Folds the posted `shipping_provider` param into the state.

  Choosing another provider starts it from scratch: no service (the form picks
  the first one it offers) and the default value of each of its settings; what
  was typed for the previous provider means nothing to the new one. Otherwise
  the posted service, settings and pricing replace the old ones; a part the
  post does not carry keeps its value.

  Returns `{state, :provider_changed | :unchanged}`.
  """
  @spec apply_params(t(), term()) :: {t(), :provider_changed | :unchanged}
  def apply_params(state, %{} = raw) do
    provider = posted_provider(raw, state.provider)

    if provider == state.provider do
      {%{
         state
         | service: posted_service(raw, state.service),
           settings: posted_settings(raw, state),
           pricing: posted_pricing(raw, state.pricing)
       }, :unchanged}
    else
      {%{
         state
         | provider: provider,
           service: "",
           settings: defaults(provider),
           pricing: posted_pricing(raw, state.pricing),
           queries: %{}
       }, :provider_changed}
    end
  end

  def apply_params(state, _other), do: {state, :unchanged}

  @doc """
  The `shipping_provider` param for `ShippingMethod.changeset/2`.

  The fixed provider has one service, `default`, which the form does not ask
  for: it is sent only when the provider needs it (the customer gives an
  address), so that a plain fixed price stays a method without a block.
  Pricing is not a thing of the fixed provider.
  """
  @spec to_param(t()) :: map()
  def to_param(%{provider: @fixed} = state) do
    destination = state.settings["destination"]

    %{
      "provider" => @fixed,
      "service" => if(destination == "address", do: "default", else: ""),
      "settings" => Map.take(state.settings, ["destination"]),
      "pricing" => %{}
    }
  end

  def to_param(state) do
    %{
      "provider" => state.provider,
      "service" => state.service,
      "settings" => state.settings,
      "pricing" => state.pricing
    }
  end

  @doc "The settings fields of a provider (by key); none for an unknown one."
  @spec fields(String.t()) :: [Field.t()]
  def fields(key) do
    case Shipping.provider(key) do
      {:ok, module} -> List.wrap(module.settings_fields())
      :error -> []
    end
  rescue
    _error -> []
  end

  @doc "The value each setting of the provider starts with."
  @spec defaults(String.t()) :: map()
  def defaults(key) do
    for %Field{default: default} = field <- fields(key), not is_nil(default), into: %{} do
      {field.key, default}
    end
  end

  @doc "The value a field shows: the one in the state, else its default."
  @spec field_value(t(), Field.t()) :: term()
  def field_value(state, %Field{} = field) do
    case Map.fetch(state.settings, field.key) do
      {:ok, value} -> value
      :error -> field.default
    end
  end

  # -- reading the post ---------------------------------------------------

  defp posted_provider(raw, current) do
    case raw |> Map.get("provider") |> Codec.string() |> trim() do
      "" -> current
      provider -> provider
    end
  end

  defp posted_service(raw, current) do
    case Map.fetch(raw, "service") do
      {:ok, value} -> value |> Codec.string() |> trim()
      :error -> current
    end
  end

  defp posted_settings(raw, state) do
    posted = raw |> Map.get("settings") |> Codec.string_map()

    Enum.reduce(fields(state.provider), state.settings, fn %Field{key: key} = field, acc ->
      case Map.fetch(posted, key) do
        {:ok, value} -> put_setting(acc, key, cast_setting(field.type, value, acc[key]))
        :error -> acc
      end
    end)
  end

  defp put_setting(settings, key, :skip), do: Map.delete(settings, key)
  defp put_setting(settings, key, value), do: Map.put(settings, key, value)

  defp cast_setting(:boolean, value, _current), do: value in [true, "true", "on", "1"]

  defp cast_setting(:locality, %{} = value, _current) do
    id = value |> Map.get("id") |> Codec.string() |> trim()
    name = value |> Map.get("name") |> Codec.string() |> trim()
    if id == "" or name == "", do: :skip, else: %{"id" => id, "name" => name}
  end

  defp cast_setting(:locality, _other, current), do: current || :skip
  defp cast_setting(_type, value, _current), do: Codec.string(value) || ""

  defp posted_pricing(raw, current) do
    posted = raw |> Map.get("pricing") |> Codec.string_map()

    Enum.reduce(@pricing_keys, current, fn key, acc ->
      case Map.fetch(posted, key) do
        {:ok, value} -> Map.put(acc, key, Codec.string(value) || "")
        :error -> acc
      end
    end)
  end

  # The values as stored, so an untouched default does not appear as an
  # explicit "0" the admin never typed.
  defp stored_pricing(method) do
    block = Codec.get(method_metadata(method), :shipping_provider)
    stored = block |> Codec.get(:pricing) |> Codec.string_map()

    Map.new(@pricing_keys, fn key -> {key, Codec.string(Map.get(stored, key)) || ""} end)
  end

  defp method_metadata(%{metadata: metadata}), do: metadata
  defp method_metadata(_other), do: nil

  defp trim(nil), do: ""
  defp trim(value), do: String.trim(value)
end
