defmodule PhoenixKitEcommerce.Web.ShippingRequote do
  @moduledoc """
  When a LiveView may ask the carrier for the price of the cart's shipping by
  itself.

  A quote is asked for while the cart's quote is `:missing` or `:stale`. It is
  asked once per state of the cart: `key/2` says which state a request was
  made for, and the same state is not asked again (a carrier that fails keeps
  the cart `:stale` or `:missing`, and re-rendering must not call it in a
  loop; a failed answer is stored as a fallback quote that ages out only after
  a couple of minutes). A run of requests that never settles the cart stops
  after `max_streak/0` however the cart reads, which covers a carrier whose
  quotes are expired on arrival.
  """

  alias PhoenixKitEcommerce.Shipping.{CartQuote, Destination}

  @max_streak 3

  @doc "How many automatic requests in a row a cart that never settles gets."
  @spec max_streak() :: pos_integer()
  def max_streak, do: @max_streak

  @doc "Identifies the state of the cart a quote request is made for."
  @spec key(map(), atom()) :: tuple()
  def key(cart, status) do
    stored = CartQuote.stored(cart.metadata)
    destination = CartQuote.destination(cart.metadata)

    {cart.shipping_method_uuid, destination && Destination.to_map(destination), status,
     cart.payment_option_uuid, items_signature(cart), stored && stored.fetched_at}
  end

  @doc """
  Whether a request is due: the quote is `:missing` or `:stale`, this state of
  the cart was not asked for last, and the run of requests is not too long.
  """
  @spec due?(map(), atom(), term(), non_neg_integer()) :: boolean()
  def due?(cart, status, last_key, streak) do
    status in [:missing, :stale] and streak < @max_streak and key(cart, status) != last_key
  end

  @doc """
  Whether two carts are the same row at the same moment: the cart a page holds
  against one that arrives by broadcast. What a page already holds is not
  worked out again.
  """
  @spec same_cart?(map(), map()) :: boolean()
  def same_cart?(%{uuid: uuid} = a, %{uuid: uuid} = b) do
    [:updated_at, :metadata, :total, :shipping_method_uuid, :payment_option_uuid, :items_count]
    |> Enum.all?(&(Map.get(a, &1) == Map.get(b, &1)))
  end

  def same_cart?(_a, _b), do: false

  defp items_signature(%{items: items}) when is_list(items),
    do: Enum.map(items, &{&1.uuid, &1.quantity})

  defp items_signature(_cart), do: nil
end
