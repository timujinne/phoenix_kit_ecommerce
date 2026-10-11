defmodule PhoenixKitEcommerce.Shipping.Field do
  @moduledoc """
  Description of one provider setting, used to render the shipping method
  admin form and to validate its input.

    * `key` - the key under `settings` in the method configuration
    * `type` - `:string | :integer | :decimal | :boolean | :select | :textarea |
      :locality` (`:locality` is an autocomplete over `search_localities/2`)
    * `options` - `[{label, value}]`, for `:select`
    * `required`, `default`, `help` - as the names say
  """

  alias PhoenixKitEcommerce.Shipping.Codec

  @types [:string, :integer, :decimal, :boolean, :select, :textarea, :locality]

  defstruct key: nil,
            label: nil,
            type: :string,
            options: [],
            required: false,
            default: nil,
            help: nil

  @type type :: :string | :integer | :decimal | :boolean | :select | :textarea | :locality

  @type t :: %__MODULE__{
          key: String.t() | nil,
          label: String.t() | nil,
          type: type(),
          options: [{String.t(), term()}],
          required: boolean(),
          default: term(),
          help: String.t() | nil
        }

  @doc "Serialises the field into a JSON-safe map (options become `[label, value]` pairs)."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = field), do: Codec.encode(field)

  @doc "Builds a field from a map with string or atom keys; garbage becomes `nil`."
  @spec from_map(term()) :: t() | nil
  def from_map(%__MODULE__{} = field), do: field

  def from_map(map) when is_map(map) do
    %__MODULE__{
      key: map |> Codec.get(:key) |> Codec.string(),
      label: map |> Codec.get(:label) |> Codec.string(),
      type: map |> Codec.get(:type) |> Codec.atom(@types) || :string,
      options: map |> Codec.get(:options) |> Codec.list(&option/1),
      required: Codec.get(map, :required) == true,
      default: Codec.get(map, :default),
      help: map |> Codec.get(:help) |> Codec.string()
    }
  end

  def from_map(_other), do: nil

  defp option({label, value}), do: {Codec.string(label), value}
  defp option([label, value]), do: {Codec.string(label), value}

  defp option(%{} = map) do
    case {Codec.get(map, :label), Codec.get(map, :value)} do
      {nil, nil} -> nil
      {label, value} -> {Codec.string(label), value}
    end
  end

  defp option(_other), do: nil
end
