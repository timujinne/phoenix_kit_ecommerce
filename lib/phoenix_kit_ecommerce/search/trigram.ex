defmodule PhoenixKitEcommerce.Search.Trigram do
  @moduledoc """
  Whether the `pg_trgm` extension is installed and its `%>` operator is
  usable (found on the connection's search path), which decides if search may
  fall back to typo-tolerant matching. An extension installed in a schema that
  is not on the search path is not usable: the typo query would fail on every
  misspelt search.

  The answer is cached for 60 seconds in a `:persistent_term` (one query per
  minute instead of one per search); an extension installed later is noticed
  within a minute. Only a successful check is cached: when the query fails the
  last known answer (or `false`) is returned for that call and the next call asks
  again. Without the extension search still works: it only skips the typo
  fallback (`PhoenixKitEcommerce.Search.Query`).
  """

  @cache_key {__MODULE__, :available}
  @ttl_ms 60_000

  # `to_regoperator` answers NULL, never an error, for an operator that does not
  # resolve on the search path.
  @check_sql """
  SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm')
         AND to_regoperator('%>(text, text)') IS NOT NULL
  """

  @doc "True when `pg_trgm` is installed in the database and its `%>` operator resolves."
  @spec available?() :: boolean()
  def available? do
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(@cache_key, nil) do
      {checked_at, value} when now - checked_at < @ttl_ms -> value
      stale -> refresh(now, stale)
    end
  end

  @doc false
  # Test hook: pins the cached answer for the next 60 seconds.
  @spec put_cache(boolean()) :: :ok
  def put_cache(value) when is_boolean(value) do
    :persistent_term.put(@cache_key, {System.monotonic_time(:millisecond), value})
    :ok
  end

  @doc "Forgets the cached answer."
  @spec reset_cache() :: :ok
  def reset_cache do
    :persistent_term.erase(@cache_key)
    :ok
  end

  defp refresh(now, stale) do
    case check_installed() do
      {:ok, value} ->
        :persistent_term.put(@cache_key, {now, value})
        value

      :error ->
        last_known(stale)
    end
  end

  defp last_known({_checked_at, value}), do: value
  defp last_known(nil), do: false

  defp check_installed do
    case PhoenixKit.RepoHelper.repo().query(@check_sql, []) do
      {:ok, %{rows: [[installed]]}} when is_boolean(installed) -> {:ok, installed}
      _other -> :error
    end
  rescue
    _error -> :error
  end
end
