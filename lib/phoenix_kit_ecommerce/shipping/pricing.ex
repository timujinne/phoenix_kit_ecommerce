defmodule PhoenixKitEcommerce.Shipping.Pricing do
  @moduledoc """
  Turns a provider quote into the amount the shop charges.

  The result is in the currency of the quote. The cash-on-delivery fee
  (`quote.cod_fee`) is not part of it: the recipient pays it to the carrier,
  so it is displayed on its own line. A pay-on-delivery method charges the
  shop nothing; the quote is then only the carrier's estimate, see
  `carrier_estimate/1`.
  """

  alias PhoenixKitEcommerce.Shipping.{MethodConfig, Quote}
  alias PhoenixKitEcommerce.ShippingMethod

  @zero Decimal.new(0)

  @doc """
  The final shipping amount.

    1. a pay-on-delivery method (`ShippingMethod.pay_on_delivery?/1`) is 0
    2. at or above the method `free_above_amount` of `base_subtotal` it is 0
    3. a `:fallback` quote (the carrier could not be reached) costs the
       `method.price`
    4. otherwise `amount * (1 + markup_percent / 100) + markup_fixed`, rounded
       up to a multiple of `round_to` (no rounding when it is unset)
  """
  @spec final_amount(MethodConfig.t(), Quote.t(), map(), Decimal.t()) :: Decimal.t()
  def final_amount(%MethodConfig{} = config, %Quote{} = rate, method, base_subtotal) do
    cond do
      ShippingMethod.pay_on_delivery?(method) -> @zero
      free?(method, base_subtotal) -> @zero
      rate.source == :fallback -> method.price
      true -> marked_up(config, rate.amount)
    end
  end

  @doc """
  What the carrier itself would charge, for display next to a pay-on-delivery
  method: the raw quote amount, its currency and the cash-on-delivery fee.
  """
  @spec carrier_estimate(Quote.t()) :: %{
          amount: Decimal.t() | nil,
          currency: String.t() | nil,
          cod_fee: Decimal.t() | nil
        }
  def carrier_estimate(%Quote{} = quote) do
    %{amount: quote.amount, currency: quote.currency, cod_fee: quote.cod_fee}
  end

  defp free?(%{free_above_amount: %Decimal{} = threshold}, %Decimal{} = subtotal) do
    Decimal.compare(subtotal, threshold) != :lt
  end

  defp free?(_method, _subtotal), do: false

  defp marked_up(%MethodConfig{pricing: pricing}, %Decimal{} = amount) do
    factor = pricing.markup_percent |> Decimal.div(100) |> Decimal.add(1)

    amount
    |> Decimal.mult(factor)
    |> Decimal.add(pricing.markup_fixed)
    |> Decimal.max(@zero)
    |> round_up(pricing.round_to)
  end

  # No step: only a markup percentage can add digits (4.35 × 1.075 =
  # 4.67625); settle on cents like the amount columns do, so the in-memory
  # cart agrees with the stored one.
  defp round_up(amount, nil), do: Decimal.round(amount, 2, :half_up)

  defp round_up(amount, step) do
    amount
    |> Decimal.div(step)
    |> Decimal.round(0, :ceiling)
    |> Decimal.mult(step)
  end
end
