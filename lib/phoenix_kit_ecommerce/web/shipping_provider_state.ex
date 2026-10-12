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

  use Gettext, backend: PhoenixKitEcommerce.Gettext

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

  `provider_chosen?` is whether this post is the admin choosing another
  provider in the select (the `_target` of the change event). Then the new
  provider starts from scratch: no service (the form picks the first one it
  offers) and the default value of each of its settings; what was typed for
  the previous provider means nothing to it. The pricing (markup, rounding) is
  not the provider's, so it stays.

  Any other post is taken as it stands, provider included: it is also what
  LiveView sends to recover a form after a reconnect, when the provider, the
  service and the settings all arrive at once and none of them is a change.
  A part the post does not carry keeps its value.

  Returns `{state, :provider_chosen | :unchanged}`.
  """
  @spec apply_params(t(), term(), boolean()) :: {t(), :provider_chosen | :unchanged}
  def apply_params(state, raw, provider_chosen? \\ false)

  def apply_params(state, %{} = raw, provider_chosen?) do
    provider = posted_provider(raw, state.provider)

    cond do
      provider_chosen? and provider != state.provider ->
        {%{
           state
           | provider: provider,
             service: "",
             settings: defaults(provider),
             pricing: posted_pricing(raw, state.pricing),
             queries: %{}
         }, :provider_chosen}

      provider != state.provider ->
        base = %{state | provider: provider, settings: %{}, service: "", queries: %{}}
        {fold(base, raw), :unchanged}

      true ->
        {fold(state, raw), :unchanged}
    end
  end

  def apply_params(state, _other, _provider_chosen?), do: {state, :unchanged}

  defp fold(state, raw) do
    %{
      state
      | service: posted_service(raw, state.service),
        settings: posted_settings(raw, state),
        pricing: posted_pricing(raw, state.pricing)
    }
  end

  @doc """
  The `shipping_provider` param for `ShippingMethod.changeset/2`.

  The fixed provider has no service and no settings and no pricing, so it is
  sent bare and a plain fixed price stays a method without a block.
  """
  @spec to_param(t()) :: map()
  def to_param(%{provider: @fixed}) do
    %{"provider" => @fixed, "service" => "", "settings" => %{}, "pricing" => %{}}
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

  @doc "The label of each markup input."
  @spec pricing_label(String.t()) :: String.t()
  def pricing_label("markup_percent"), do: gettext("Markup, %")
  def pricing_label("markup_fixed"), do: gettext("Fixed markup")
  def pricing_label("round_to"), do: gettext("Round up to a multiple of")

  @doc """
  Turns the errors `MethodParams` puts on `:shipping_provider` (`{message,
  bindings}` pairs) into text for the card: `fields` maps `"service"`,
  `"setting:<key>"` and `"pricing:<key>"` to the messages shown under that
  input, `general` is what has no input of its own.
  """
  @spec errors([{String.t(), keyword()}], [Field.t()]) :: %{
          fields: %{optional(String.t()) => [String.t()]},
          general: [String.t()]
        }
  def errors(raw_errors, fields) do
    Enum.reduce(raw_errors, %{fields: %{}, general: []}, fn error, acc ->
      classify(error, fields, acc)
    end)
    |> then(fn %{fields: by_field, general: general} ->
      %{
        fields: Map.new(by_field, fn {k, v} -> {k, Enum.reverse(v)} end),
        general: Enum.reverse(general)
      }
    end)
  end

  defp classify({"service is required", _opts}, _fields, acc),
    do: put_field_error(acc, "service", gettext("Choose a service"))

  defp classify({"unknown service %{service}", opts}, _fields, acc) do
    put_field_error(
      acc,
      "service",
      gettext("The provider does not offer the service %{service}", service: opts[:service])
    )
  end

  defp classify({"required setting %{setting} is missing", opts}, fields, acc) do
    key = to_string(opts[:setting])
    label = Enum.find_value(fields, key, &(&1.key == key && &1.label))
    put_field_error(acc, "setting:" <> key, gettext("%{setting} is required", setting: label))
  end

  defp classify({message, opts}, _fields, acc)
       when message in [
              "%{field} must be a number",
              "%{field} must be at most %{max}",
              "%{field} must be 0 or greater"
            ] do
    put_field_error(acc, "pricing:#{opts[:field]}", pricing_message(message, opts))
  end

  defp classify({"unknown provider %{provider}", opts}, _fields, acc) do
    put_general_error(
      acc,
      gettext("The provider %{provider} is not installed", provider: opts[:provider])
    )
  end

  defp classify(_other, _fields, acc),
    do: put_general_error(acc, gettext("The shipping provider settings are not valid"))

  defp pricing_message("%{field} must be a number", _opts), do: gettext("Must be a number")

  defp pricing_message("%{field} must be 0 or greater", _opts),
    do: gettext("Must be 0 or greater")

  defp pricing_message("%{field} must be at most %{max}", opts),
    do: gettext("Must be at most %{max}", max: opts[:max])

  defp put_field_error(acc, key, message),
    do: %{acc | fields: Map.update(acc.fields, key, [message], &[message | &1])}

  defp put_general_error(acc, message), do: %{acc | general: [message | acc.general]}

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

  defp cast_setting(type, %{} = value, _current) when type in [:locality, :pickup_point] do
    id = value |> Map.get("id") |> Codec.string() |> trim()
    name = value |> Map.get("name") |> Codec.string() |> trim()
    if id == "" or name == "", do: :skip, else: %{"id" => id, "name" => name}
  end

  defp cast_setting(type, _other, current) when type in [:locality, :pickup_point],
    do: current || :skip

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
