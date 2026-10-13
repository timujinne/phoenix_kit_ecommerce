defmodule PhoenixKitEcommerce.Shipping.RateLimit do
  @moduledoc """
  A token bucket per provider for the lookups a shopper's typing causes
  (locality search, pickup point list), so that many shoppers together cannot
  drown a carrier's API.

  `config :phoenix_kit_ecommerce, :shipping_lookup_rate` is the calls per
  second one provider may get from the whole node (default 20); a burst of up
  to that many is let through at once. The bucket lives in an ETS table owned
  by `PhoenixKitEcommerce.Shipping.Cache`; without that process running
  nothing is limited, like nothing is cached.

  Only calls that really reach the provider count: answers from the cache do
  not.
  """

  @table :phoenix_kit_ecommerce_shipping_rate_limit
  @default_rate 20
  @retries 5

  @doc false
  @spec create_table() :: :ets.table()
  def create_table do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
  end

  @doc """
  Takes one token of the provider's bucket: `:ok`, or `:rate_limited` when the
  bucket is empty.
  """
  @spec take(String.t()) :: :ok | :rate_limited
  def take(provider_key) do
    take(provider_key, rate(), now())
  rescue
    ArgumentError -> :ok
  end

  @doc "The calls per second one provider may get."
  @spec rate() :: pos_integer()
  def rate do
    case Application.get_env(:phoenix_kit_ecommerce, :shipping_lookup_rate) do
      rate when is_integer(rate) and rate > 0 -> rate
      _unset -> @default_rate
    end
  end

  @doc "Empties every bucket (they start full again)."
  @spec reset() :: :ok
  def reset do
    if :ets.whereis(@table) != :undefined, do: :ets.delete_all_objects(@table)
    :ok
  end

  # Tokens are counted in thousandths, so that integer arithmetic refills them
  # exactly: `elapsed_ms * rate` thousandths since the last take.
  defp take(key, rate, now, attempt \\ 0)

  defp take(_key, _rate, _now, @retries), do: :rate_limited

  defp take(key, rate, now, attempt) do
    capacity = rate * 1_000

    case :ets.lookup(@table, key) do
      [] ->
        if :ets.insert_new(@table, {key, capacity - 1_000, now}),
          do: :ok,
          else: take(key, rate, now, attempt + 1)

      [{^key, tokens, at}] ->
        available = min(capacity, tokens + max(now - at, 0) * rate)

        if available < 1_000,
          do: :rate_limited,
          else: swap(key, tokens, at, available - 1_000, now, rate, attempt)
    end
  end

  # An atomic compare-and-set: concurrent takers cannot both spend one token.
  defp swap(key, tokens, at, left, now, rate, attempt) do
    matched =
      :ets.select_replace(@table, [
        {{key, tokens, at}, [], [{{key, left, now}}]}
      ])

    if matched == 1, do: :ok, else: take(key, rate, now, attempt + 1)
  end

  defp now, do: System.monotonic_time(:millisecond)
end
