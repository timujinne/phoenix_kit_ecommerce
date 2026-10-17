defmodule PhoenixKitEcommerce.API.Signals do
  @moduledoc """
  The notification an assistant-built cart sends the shop's operators,
  coalesced and capped so that free cart tokens cannot flood their Telegram.

  `cart_changed/2` is called once per write call, after the transaction has
  committed. It sends nothing unless an operator turned on
  `shop_notify_cart_first_item` or `shop_notify_cart_item`; then it spends one
  slot of the per-cart hourly cap and one of the global hourly cap
  (`API.CartSettings`) and delivers one message through
  `Notifications.assistant_cart_updated/3`.

  A signal dropped by the **global** cap is counted, and the next message that
  goes out says "+N more assistant carts"; one dropped by the per-cart cap is
  silent. The counters are Hammer ETS buckets (per node, like every other rate
  limit of the API). Nothing here raises: a signal must never fail a write.
  """

  require Logger

  alias PhoenixKit.Users.RateLimiter.Backend
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.API.CartSettings
  alias PhoenixKitEcommerce.Notifications

  @hour 3_600_000
  @day 86_400_000
  @global_key "shop_api:signal:global"
  @dropped_key "shop_api:signal:dropped"
  @reported_key "shop_api:signal:reported"
  @cart_key_prefix "shop_api:signal:cart:"
  @first_flag "first_item_notified"

  @doc """
  Sends (or drops) the one message of a write. `lines` is a list of
  `%{title: String.t(), quantity: pos_integer()}` for the lines the write
  created or changed.
  """
  @spec cart_changed(map(), [map()]) :: :ok
  def cart_changed(cart, lines) when is_list(lines) do
    want_first? =
      Shop.notify_event?(:cart_first_item) and
        not Map.has_key?(cart.metadata || %{}, @first_flag)

    want_every? = Shop.notify_event?(:cart_item)

    if lines != [] and (want_first? or want_every?) do
      emit(cart, lines, want_first?, want_every?)
    else
      :ok
    end
  rescue
    # Only the exception module is logged: its message can embed request data.
    error ->
      Logger.warning("[Shop] assistant cart signal failed: #{inspect(error.__struct__)}")
      :ok
  catch
    :exit, _reason -> :ok
  end

  defp emit(cart, lines, want_first?, want_every?) do
    case take_budget(cart) do
      :ok ->
        # The first-item flag is claimed only now that a slot was granted, so a
        # dropped signal never uses up the cart's one first-item message.
        first? = want_first? and Shop.claim_cart_flag(cart, @first_flag)

        if first? or want_every? do
          Notifications.assistant_cart_updated(cart, lines,
            first?: first?,
            more_carts: take_dropped()
          )
        else
          :ok
        end

      {:dropped, :global} ->
        Backend.inc(@dropped_key, @day)
        :ok

      # A per-cart drop and a switched-off cap are silent: neither is counted.
      {:dropped, _silent} ->
        :ok
    end
  end

  # A global cap of 0 switches the messages off: nothing is spent or counted, so
  # the note after a later raise does not name writes made while they were off.
  defp take_budget(cart) do
    case CartSettings.signal_global_per_hour() do
      0 -> {:dropped, :off}
      global_limit -> take_budget(cart, global_limit)
    end
  end

  defp take_budget(cart, global_limit) do
    case Backend.hit(
           @cart_key_prefix <> cart.uuid,
           @hour,
           CartSettings.signal_per_cart_per_hour()
         ) do
      {:deny, _retry_ms} ->
        {:dropped, :cart}

      {:allow, _count} ->
        case Backend.hit(@global_key, @hour, global_limit) do
          {:allow, _count} -> :ok
          {:deny, _retry_ms} -> {:dropped, :global}
        end
    end
  end

  # Dropped signals are counted by two counters that only grow (Hammer takes
  # positive increments only): `dropped` with every drop, `reported` with every
  # drop a message has named. Both live in the same one-day window, so they roll
  # over together.
  defp take_dropped do
    pending = Backend.get(@dropped_key, @day) - Backend.get(@reported_key, @day)

    if pending > 0 do
      Backend.inc(@reported_key, @day, pending)
      pending
    else
      0
    end
  end
end
