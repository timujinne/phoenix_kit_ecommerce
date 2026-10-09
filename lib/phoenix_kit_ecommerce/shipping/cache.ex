defmodule PhoenixKitEcommerce.Shipping.Cache do
  @moduledoc """
  Small TTL cache for carrier answers (locality and pickup point lookups,
  quotes).

  The process only owns a public ETS table and sweeps expired entries every
  ten minutes; reads and writes go straight to ETS. `fetch/3` works without
  the process running (it just calls the function every time), so tests and
  hosts that have not added `Cache` to their supervision tree are unaffected.

  TTLs default to 6 hours for lookups, 10 minutes for quotes and 30 seconds
  for the negative entries (transient errors, so a carrier that is down does
  not cost a full timeout on every keystroke). They can be changed with

      config :phoenix_kit_ecommerce, :shipping_cache_ttl,
        lookups: :timer.hours(1),
        quotes: :timer.minutes(5),
        negative: :timer.seconds(10)

  The table holds at most `config :phoenix_kit_ecommerce,
  :shipping_cache_max_entries` entries (default 5000); when it is full the
  expired entries go first, then the ones closest to expiry.
  """

  use GenServer

  @table :phoenix_kit_ecommerce_shipping_cache
  @sweep_interval :timer.minutes(10)
  @default_ttl [
    lookups: :timer.hours(6),
    quotes: :timer.minutes(10),
    negative: :timer.seconds(30)
  ]
  @default_max_entries 5_000

  @doc """
  Starts the cache process, which owns the ETS table. The process is a
  singleton: when it is already running (the module's `children/0` and a
  host's own supervision tree both listing it, a test starting it again) the
  extra start is `:ignore`d instead of failing the supervisor.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case GenServer.start_link(__MODULE__, opts, name: __MODULE__) do
      {:error, {:already_started, _pid}} -> :ignore
      other -> other
    end
  end

  @doc """
  Returns the cached value for `key`, or calls `fun` and caches its result
  for `ttl_ms` milliseconds. `{:ok, _}` results are cached; an `{:error, reason}`
  only when `:negative_ttl` is a positive number of milliseconds and
  `:cacheable_error?` (a function of the reason, default: never) accepts it.
  """
  @spec fetch(term(), term(), (-> result), keyword()) :: result when result: term()
  def fetch(key, ttl_ms, fun, opts \\ []) when is_function(fun, 0) do
    case lookup(key) do
      {:ok, value} ->
        value

      :error ->
        result = fun.()
        store(key, ttl_ms, result, opts)
        result
    end
  end

  @doc "The TTL in milliseconds for `:lookups`, `:quotes` or `:negative` entries."
  @spec ttl(:lookups | :quotes | :negative) :: non_neg_integer()
  def ttl(kind) when kind in [:lookups, :quotes, :negative] do
    configured = Application.get_env(:phoenix_kit_ecommerce, :shipping_cache_ttl, [])
    default = Keyword.fetch!(@default_ttl, kind)

    case Keyword.get(configured, kind, default) do
      ms when is_integer(ms) and ms >= 0 -> ms
      _invalid -> default
    end
  end

  @doc "Drops every cached entry."
  @spec clear() :: :ok
  def clear do
    if table?(), do: :ets.delete_all_objects(@table)
    :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    schedule_sweep()
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  @spec sweep() :: non_neg_integer()
  def sweep do
    now = now()
    :ets.select_delete(@table, [{{:_, :"$1", :_}, [{:<, :"$1", now}], [true]}])
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval)

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, expires_at, value}] -> if expires_at > now(), do: {:ok, value}, else: :error
      [] -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp store(key, ttl_ms, {:ok, _} = result, _opts) when is_integer(ttl_ms) and ttl_ms > 0,
    do: insert(key, ttl_ms, result)

  defp store(key, _ttl_ms, {:error, reason} = result, opts) do
    negative = Keyword.get(opts, :negative_ttl)
    cacheable? = Keyword.get(opts, :cacheable_error?, fn _reason -> false end)

    if is_integer(negative) and negative > 0 and cacheable?.(reason),
      do: insert(key, negative, result),
      else: false
  end

  defp store(_key, _ttl_ms, _result, _opts), do: false

  defp insert(key, ttl_ms, result) do
    make_room(key)
    :ets.insert(@table, {key, now() + ttl_ms, result})
  rescue
    ArgumentError -> false
  end

  defp make_room(key) do
    max = max_entries()

    if :ets.info(@table, :size) >= max and not :ets.member(@table, key) do
      sweep()
      if :ets.info(@table, :size) >= max, do: evict_closest_to_expiry(max)
    end
  end

  defp evict_closest_to_expiry(max) do
    @table
    |> :ets.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.take(max(div(max, 10), 1))
    |> Enum.each(fn {key, _expires_at} -> :ets.delete(@table, key) end)
  end

  defp max_entries do
    case Application.get_env(:phoenix_kit_ecommerce, :shipping_cache_max_entries) do
      max when is_integer(max) and max > 0 -> max
      _unset -> @default_max_entries
    end
  end

  defp table?, do: :ets.whereis(@table) != :undefined

  defp now, do: System.monotonic_time(:millisecond)
end
