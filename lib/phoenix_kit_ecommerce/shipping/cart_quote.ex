defmodule PhoenixKitEcommerce.Shipping.CartQuote do
  @moduledoc """
  What a cart remembers about calculated shipping, kept in `cart.metadata`:

    * `"shipping_destination"` - `Destination.to_map/1`
    * `"shipping_quote"` - the last answer of the carrier for the cart as it
      was when asked:

          %{
            "request_hash" => "...",
            "status" => "ok" | "fallback" | "unavailable",
            "quote" => Quote.to_map/1 | nil,
            "reason" => "too_heavy" | nil,
            "fetched_at" => "2026-10-09T10:00:00Z"
          }

      `request_hash` is `PhoenixKitEcommerce.Shipping.request_hash/1` of the
      request the answer belongs to; a quote whose hash differs from the
      current request is stale and is never charged.

  Pure helpers (no database, no network) over the metadata map. The cart
  functions that use them are in `PhoenixKitEcommerce`.
  """

  use Gettext, backend: PhoenixKitEcommerce.Gettext

  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKitEcommerce.Shipping
  alias PhoenixKitEcommerce.Shipping.{Address, Codec, Destination, Locality, PickupPoint, Quote}

  @destination_key "shipping_destination"
  @quote_key "shipping_quote"
  @statuses [:ok, :fallback, :unavailable]

  @type status :: :ok | :fallback | :unavailable

  @type stored :: %{
          request_hash: String.t() | nil,
          status: status(),
          quote: Quote.t() | nil,
          reason: String.t() | nil,
          fetched_at: DateTime.t() | nil
        }

  @doc "The metadata key of the destination."
  @spec destination_key() :: String.t()
  def destination_key, do: @destination_key

  @doc "The metadata key of the stored quote."
  @spec quote_key() :: String.t()
  def quote_key, do: @quote_key

  @doc "The destination kept in the metadata, or `nil`."
  @spec destination(term()) :: Destination.t() | nil
  def destination(metadata) do
    case Codec.get(metadata, :shipping_destination) do
      stored when is_map(stored) -> Destination.from_map(stored)
      _ -> nil
    end
  end

  @doc """
  Stores the destination (`nil`, or a destination with nothing in it, removes
  it).
  """
  @spec put_destination(map(), Destination.t() | nil) :: map()
  def put_destination(metadata, destination) do
    if empty_destination?(destination),
      do: Map.delete(metadata, @destination_key),
      else: Map.put(metadata, @destination_key, Destination.to_map(destination))
  end

  @doc "Removes the stored quote."
  @spec drop_quote(map()) :: map()
  def drop_quote(metadata), do: Map.delete(metadata, @quote_key)

  @doc "Removes the stored destination and quote."
  @spec drop_all(map()) :: map()
  def drop_all(metadata), do: metadata |> drop_quote() |> Map.delete(@destination_key)

  @doc "Whether the metadata holds a destination or a quote."
  @spec any?(map()) :: boolean()
  def any?(metadata),
    do: Map.has_key?(metadata, @destination_key) or Map.has_key?(metadata, @quote_key)

  @doc "The stored quote entry, or `nil` when there is none (or it is unreadable)."
  @spec stored(term()) :: stored() | nil
  def stored(metadata) do
    entry = Codec.get(metadata, :shipping_quote)

    case entry |> Codec.get(:status) |> Codec.atom(@statuses) do
      nil ->
        nil

      status ->
        %{
          request_hash: entry |> Codec.get(:request_hash) |> Codec.string(),
          status: status,
          quote: entry |> Codec.get(:quote) |> Quote.from_map(),
          reason: entry |> Codec.get(:reason) |> Codec.string(),
          fetched_at: entry |> Codec.get(:fetched_at) |> Codec.datetime()
        }
    end
  end

  @doc """
  The entry to store for the answer of the carrier to a request.

    * `{:ok, quote}` - `"ok"` (`"fallback"` if the provider itself says so)
    * a business error (see `PhoenixKitEcommerce.Shipping.business_error?/1`) -
      `"unavailable"`, no quote
    * any other error - `"fallback"`: a quote at the price of the method
  """
  @spec entry(String.t(), {:ok, Quote.t()} | {:error, term()}, map(), String.t() | nil) :: map()
  def entry(request_hash, {:ok, %Quote{} = quote}, _method, currency) do
    quote = %{quote | currency: quote.currency || currency}
    status = if quote.source == :fallback, do: "fallback", else: "ok"
    build_entry(request_hash, status, quote, nil)
  end

  def entry(request_hash, {:error, reason}, method, currency) do
    if Shipping.business_error?(reason) do
      build_entry(request_hash, "unavailable", nil, error_reason(reason))
    else
      build_entry(
        request_hash,
        "fallback",
        fallback_quote(method, currency),
        error_reason(reason)
      )
    end
  end

  defp build_entry(request_hash, status, quote, reason) do
    %{
      "request_hash" => request_hash,
      "status" => status,
      "quote" => quote && Quote.to_map(quote),
      "reason" => reason,
      "fetched_at" => DateTime.to_iso8601(UtilsDate.utc_now())
    }
  end

  defp fallback_quote(method, currency) do
    %Quote{
      amount: method_price(method),
      currency: currency,
      source: :fallback,
      note: gettext("The carrier rate is unavailable at the moment, the standard price applies.")
    }
  end

  defp method_price(%{price: %Decimal{} = price}), do: price
  defp method_price(_method), do: Decimal.new(0)

  @doc "A short machine-readable form of an error reason."
  @spec error_reason(term()) :: String.t()
  def error_reason(reason) when is_atom(reason) and not is_nil(reason), do: Atom.to_string(reason)

  def error_reason({reason, _details}) when is_atom(reason) and not is_nil(reason),
    do: Atom.to_string(reason)

  def error_reason(_reason), do: "error"

  @doc "Whether a destination holds nothing."
  @spec empty_destination?(Destination.t() | nil) :: boolean()
  def empty_destination?(nil), do: true

  def empty_destination?(%Destination{} = destination),
    do:
      is_nil(destination.locality) and is_nil(destination.pickup_point) and
        is_nil(destination.address)

  @doc """
  Whether the destination lacks what a service with this kind of destination
  needs: a pickup point, or an address.
  """
  @spec incomplete?(Shipping.Service.destination(), Destination.t() | nil) :: boolean()
  def incomplete?(:pickup_point, %Destination{pickup_point: %PickupPoint{}}), do: false
  def incomplete?(:address, %Destination{address: %Address{}}), do: false
  def incomplete?(kind, _destination) when kind in [:pickup_point, :address], do: true
  def incomplete?(_kind, _destination), do: false

  @doc """
  A short human description of where the parcel goes: the locality followed by
  the pickup point or the address. `nil` when there is nothing to say.
  """
  @spec destination_label(Destination.t() | nil) :: String.t() | nil
  def destination_label(nil), do: nil

  def destination_label(%Destination{} = destination) do
    [
      locality_name(destination.locality),
      point_name(destination.pickup_point),
      address_line(destination.address)
    ]
    |> Enum.reject(&blank?/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, ", ")
    end
  end

  defp locality_name(%Locality{name: name}), do: name
  defp locality_name(_other), do: nil

  defp point_name(%PickupPoint{name: name, number: number}) do
    cond do
      not blank?(name) -> name
      not blank?(number) -> "№" <> number
      true -> nil
    end
  end

  defp point_name(_other), do: nil

  defp address_line(%Address{line: line} = address) do
    if blank?(line) do
      [address.street, address.house, address.apartment]
      |> Enum.reject(&blank?/1)
      |> Enum.join(" ")
    else
      line
    end
  end

  defp address_line(_other), do: nil

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""
end
