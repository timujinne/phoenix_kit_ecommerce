defmodule PhoenixKitEcommerce.Shipping.Providers.Fixed do
  @moduledoc """
  The built-in `"fixed"` provider: the price is the price of the shipping
  method, exactly as shipping methods have always worked.

  The only setting is `destination`: `none` (default) or `address`. It offers
  a single service, `default`, and never searches anything.
  """

  @behaviour PhoenixKitEcommerce.Shipping.Provider

  use Gettext, backend: PhoenixKitEcommerce.Gettext

  alias PhoenixKitEcommerce.Shipping.{Context, Field, Quote, RateRequest, Service}

  @impl true
  def key, do: "fixed"

  @impl true
  def label, do: gettext("Fixed price")

  @impl true
  def services(%Context{settings: settings}) do
    destination = if settings["destination"] == "address", do: :address, else: :none
    [%Service{key: "default", label: gettext("Delivery"), destination: destination}]
  end

  @impl true
  def settings_fields do
    [
      %Field{
        key: "destination",
        label: gettext("Customer provides"),
        type: :select,
        options: [{gettext("Nothing"), "none"}, {gettext("Address"), "address"}],
        default: "none"
      }
    ]
  end

  @impl true
  def quote(%RateRequest{}, %Context{method: %{price: %Decimal{} = price} = method} = ctx) do
    {:ok,
     %Quote{
       amount: price,
       currency: ctx.currency || method.currency,
       source: :fixed,
       eta: eta(method)
     }}
  end

  def quote(%RateRequest{}, %Context{}), do: {:error, :no_method}

  defp eta(%{estimated_days_min: nil, estimated_days_max: nil}), do: nil

  defp eta(%{estimated_days_min: min, estimated_days_max: max}),
    do: %{min_days: min, max_days: max, date: nil}

  defp eta(_method), do: nil
end
