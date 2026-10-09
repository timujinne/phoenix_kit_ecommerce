defmodule PhoenixKitEcommerce.Shipping.Providers.Table do
  @moduledoc """
  The built-in `"table"` provider: a price per weight band, edited by the
  shop owner.

  Settings:

    * `rates` - one band per line, `<up_to_kg> <price>`; a decimal comma is
      fine (`0,5 90`), blank lines and lines starting with `#` are ignored
    * `volumetric_divisor` - cm3 per kg; `0` (default) turns volumetric weight
      off. The billable weight of a parcel is
      `max(actual, length * width * height in cm / divisor)`
    * `eta_min_days`, `eta_max_days` - the delivery estimate shown to the customer
    * `destination` - `none` (default), `address` or `pickup_point`
      (entered manually)

  The billable weights of all parcels are summed and the sum picks the band.
  A request without parcels (a cart with nothing shippable) gets the cheapest
  band. A weight above the last band gives `{:error, :too_heavy}`.
  """

  @behaviour PhoenixKitEcommerce.Shipping.Provider

  use Gettext, backend: PhoenixKitEcommerce.Gettext

  alias PhoenixKitEcommerce.Shipping.{Codec, Context, Field, Quote, RateRequest, Service}

  @destinations %{"address" => :address, "pickup_point" => :pickup_point}
  @zero Decimal.new(0)

  @impl true
  def key, do: "table"

  @impl true
  def label, do: gettext("Rate table by weight")

  @impl true
  def services(%Context{settings: settings}) do
    destination = Map.get(@destinations, settings["destination"], :none)

    [
      %Service{
        key: "default",
        label: gettext("Delivery"),
        destination: destination,
        lookup: :manual,
        point_code_label: if(destination == :pickup_point, do: gettext("Pickup point"))
      }
    ]
  end

  @impl true
  def settings_fields do
    [
      %Field{
        key: "rates",
        label: gettext("Rates"),
        type: :textarea,
        required: true,
        help: gettext("One band per line: up to kg, price. For example: 0,5 90")
      },
      %Field{
        key: "volumetric_divisor",
        label: gettext("Volumetric divisor (cm3 per kg)"),
        type: :decimal,
        default: "0",
        help: gettext("0 turns volumetric weight off.")
      },
      %Field{key: "eta_min_days", label: gettext("Delivery from (days)"), type: :integer},
      %Field{key: "eta_max_days", label: gettext("Delivery to (days)"), type: :integer},
      %Field{
        key: "destination",
        label: gettext("Customer provides"),
        type: :select,
        options: [
          {gettext("Nothing"), "none"},
          {gettext("Address"), "address"},
          {gettext("Pickup point"), "pickup_point"}
        ],
        default: "none"
      }
    ]
  end

  @impl true
  def quote(%RateRequest{parcels: parcels}, %Context{settings: settings} = ctx) do
    divisor = settings["volumetric_divisor"] |> Codec.decimal() |> positive_or_nil()
    {actual, billable} = weights(parcels, divisor)

    case settings["rates"] |> parse_rates() do
      [] -> {:error, :no_rates}
      rates -> price(rates, actual, billable, settings, ctx)
    end
  end

  @doc """
  Parses the `rates` setting into `[{up_to_kg, price}]` sorted by weight.
  Lines that do not parse are dropped.
  """
  @spec parse_rates(term()) :: [{Decimal.t(), Decimal.t()}]
  def parse_rates(text) when is_binary(text) do
    text
    |> String.split(~r/\R/u, trim: true)
    |> Enum.map(&parse_line/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&elem(&1, 0), Decimal)
  end

  def parse_rates(_other), do: []

  defp parse_line(line) do
    line = String.trim(line)

    with false <- line == "" or String.starts_with?(line, "#"),
         [max_kg, price] <- String.split(line, ~r/\s+/u),
         %Decimal{} = max_kg <- Codec.decimal(max_kg),
         %Decimal{} = price <- Codec.decimal(price),
         :gt <- Decimal.compare(max_kg, @zero),
         false <- Decimal.compare(price, @zero) == :lt do
      {max_kg, price}
    else
      _ -> nil
    end
  end

  defp price(rates, actual, billable, settings, ctx) do
    case Enum.find(rates, fn {max_kg, _price} -> Decimal.compare(billable, max_kg) != :gt end) do
      nil ->
        {:error, :too_heavy}

      {max_kg, price} ->
        {:ok,
         %Quote{
           amount: price,
           currency: ctx.currency || currency(ctx.method),
           source: :table,
           eta: eta(settings),
           breakdown: %{
             "actual_kg" => Decimal.to_string(actual, :normal),
             "billable_kg" => Decimal.to_string(billable, :normal),
             "rate_up_to_kg" => Decimal.to_string(max_kg, :normal)
           }
         }}
    end
  end

  defp weights(parcels, divisor) do
    Enum.reduce(parcels, {@zero, @zero}, fn parcel, {actual, billable} ->
      kg = Decimal.div(parcel.weight_g || 0, 1000)

      {Decimal.add(actual, kg),
       Decimal.add(billable, Decimal.max(kg, volumetric_kg(parcel, divisor)))}
    end)
  end

  defp volumetric_kg(parcel, %Decimal{} = divisor) do
    case {parcel.length_mm, parcel.width_mm, parcel.height_mm} do
      {l, w, h} when is_integer(l) and is_integer(w) and is_integer(h) ->
        # mm3 / 1000 = cm3
        l |> Decimal.mult(w) |> Decimal.mult(h) |> Decimal.div(1000) |> Decimal.div(divisor)

      _ ->
        @zero
    end
  end

  defp volumetric_kg(_parcel, nil), do: @zero

  defp positive_or_nil(%Decimal{} = value) do
    if Decimal.compare(value, @zero) == :gt, do: value
  end

  defp positive_or_nil(nil), do: nil

  defp eta(settings) do
    min = Codec.integer(settings["eta_min_days"])
    max = Codec.integer(settings["eta_max_days"])

    if min || max, do: %{min_days: min || max, max_days: max || min, date: nil}
  end

  defp currency(%{currency: currency}), do: currency
  defp currency(_method), do: nil
end
