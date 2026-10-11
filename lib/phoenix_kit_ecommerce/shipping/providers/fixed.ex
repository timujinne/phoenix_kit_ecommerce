defmodule PhoenixKitEcommerce.Shipping.Providers.Fixed do
  @moduledoc """
  The built-in `"fixed"` provider: the price is the price of the shipping
  method, exactly as shipping methods have always worked.

  It has no settings, offers a single service, `default`, and never asks the
  customer for a destination or searches anything: it is the not-calculated
  path of a shipping method.
  """

  @behaviour PhoenixKitEcommerce.Shipping.Provider

  use Gettext, backend: PhoenixKitEcommerce.Gettext

  alias PhoenixKitEcommerce.Shipping.{Context, Quote, RateRequest, Service}

  @impl true
  def key, do: "fixed"

  @impl true
  def label, do: gettext("Fixed price")

  @impl true
  def services(%Context{}) do
    [%Service{key: "default", label: gettext("Delivery"), destination: :none}]
  end

  @impl true
  def settings_fields, do: []

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
