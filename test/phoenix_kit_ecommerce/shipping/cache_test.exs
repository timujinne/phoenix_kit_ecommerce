defmodule PhoenixKitEcommerce.Shipping.CacheTest do
  # Owns a named process and a named ETS table, so not async.
  use ExUnit.Case, async: false

  alias PhoenixKitEcommerce.Shipping.Cache

  defp counted(agent, result) do
    fn ->
      Agent.update(agent, &(&1 + 1))
      result
    end
  end

  setup do
    {:ok, agent} = Agent.start_link(fn -> 0 end)
    %{agent: agent}
  end

  describe "without the process" do
    test "fetch just calls the function every time", %{agent: agent} do
      assert {:ok, 1} = Cache.fetch(:k, 1_000, counted(agent, {:ok, 1}))
      assert {:ok, 1} = Cache.fetch(:k, 1_000, counted(agent, {:ok, 1}))
      assert Agent.get(agent, & &1) == 2
    end

    test "clear is harmless" do
      assert Cache.clear() == :ok
    end
  end

  describe "with the process" do
    setup do
      start_supervised!(Cache)
      :ok
    end

    test "caches {:ok, _} results", %{agent: agent} do
      assert {:ok, :a} = Cache.fetch(:k, 60_000, counted(agent, {:ok, :a}))
      assert {:ok, :a} = Cache.fetch(:k, 60_000, counted(agent, {:ok, :b}))
      assert Agent.get(agent, & &1) == 1
    end

    test "does not cache errors", %{agent: agent} do
      assert {:error, :boom} = Cache.fetch(:k, 60_000, counted(agent, {:error, :boom}))
      assert {:ok, :fine} = Cache.fetch(:k, 60_000, counted(agent, {:ok, :fine}))
      assert Agent.get(agent, & &1) == 2
    end

    test "keys are independent", %{agent: agent} do
      Cache.fetch(:one, 60_000, counted(agent, {:ok, 1}))
      Cache.fetch(:two, 60_000, counted(agent, {:ok, 2}))
      assert Agent.get(agent, & &1) == 2
    end

    test "entries expire", %{agent: agent} do
      Cache.fetch(:k, 1, counted(agent, {:ok, 1}))
      Process.sleep(5)
      Cache.fetch(:k, 1, counted(agent, {:ok, 1}))
      assert Agent.get(agent, & &1) == 2
    end

    test "a zero ttl is never cached", %{agent: agent} do
      Cache.fetch(:k, 0, counted(agent, {:ok, 1}))
      Cache.fetch(:k, 0, counted(agent, {:ok, 1}))
      assert Agent.get(agent, & &1) == 2
    end

    test "clear drops everything", %{agent: agent} do
      Cache.fetch(:k, 60_000, counted(agent, {:ok, 1}))
      assert Cache.clear() == :ok
      Cache.fetch(:k, 60_000, counted(agent, {:ok, 1}))
      assert Agent.get(agent, & &1) == 2
    end

    test "sweep removes only expired entries" do
      Cache.fetch(:stale, 1, fn -> {:ok, 1} end)
      Cache.fetch(:fresh, 60_000, fn -> {:ok, 2} end)
      Process.sleep(5)

      assert Cache.sweep() == 1
      assert :ets.info(:phoenix_kit_ecommerce_shipping_cache, :size) == 1
    end

    test "the periodic sweep message is handled" do
      pid = Process.whereis(Cache)
      send(pid, :sweep)
      send(pid, :unexpected)
      assert is_map(:sys.get_state(pid))
    end

    test "negative entries need negative_ttl and an accepting predicate", %{agent: agent} do
      opts = [negative_ttl: 60_000, cacheable_error?: &(&1 == :offline)]

      assert {:error, :offline} =
               Cache.fetch(:a, 60_000, counted(agent, {:error, :offline}), opts)

      assert {:error, :offline} =
               Cache.fetch(:a, 60_000, counted(agent, {:error, :offline}), opts)

      assert Agent.get(agent, & &1) == 1

      # rejected by the predicate
      Cache.fetch(:b, 60_000, counted(agent, {:error, :other}), opts)
      Cache.fetch(:b, 60_000, counted(agent, {:error, :other}), opts)
      assert Agent.get(agent, & &1) == 3

      # no negative_ttl at all
      Cache.fetch(:c, 60_000, counted(agent, {:error, :offline}),
        cacheable_error?: fn _ -> true end
      )

      Cache.fetch(:c, 60_000, counted(agent, {:error, :offline}),
        cacheable_error?: fn _ -> true end
      )

      assert Agent.get(agent, & &1) == 5
    end

    test "negative entries expire", %{agent: agent} do
      opts = [negative_ttl: 1, cacheable_error?: fn _ -> true end]

      Cache.fetch(:a, 60_000, counted(agent, {:error, :offline}), opts)
      Process.sleep(5)
      Cache.fetch(:a, 60_000, counted(agent, {:error, :offline}), opts)
      assert Agent.get(agent, & &1) == 2
    end

    test "a non-integer ttl caches nothing", %{agent: agent} do
      Cache.fetch(:a, :infinity, counted(agent, {:ok, 1}))
      Cache.fetch(:a, :infinity, counted(agent, {:ok, 1}))
      Cache.fetch(:b, "10", counted(agent, {:ok, 1}))
      Cache.fetch(:b, "10", counted(agent, {:ok, 1}))
      assert Agent.get(agent, & &1) == 4
    end

    test "the table never grows past the configured maximum" do
      Application.put_env(:phoenix_kit_ecommerce, :shipping_cache_max_entries, 20)

      on_exit(fn ->
        Application.delete_env(:phoenix_kit_ecommerce, :shipping_cache_max_entries)
      end)

      for n <- 1..100, do: Cache.fetch({:k, n}, 60_000 + n, fn -> {:ok, n} end)

      assert :ets.info(:phoenix_kit_ecommerce_shipping_cache, :size) <= 20
    end

    test "when full, expired entries go first, then those closest to expiry", %{agent: agent} do
      Application.put_env(:phoenix_kit_ecommerce, :shipping_cache_max_entries, 3)

      on_exit(fn ->
        Application.delete_env(:phoenix_kit_ecommerce, :shipping_cache_max_entries)
      end)

      Cache.fetch(:soon, 1_000, fn -> {:ok, 1} end)
      Cache.fetch(:later, 60_000, fn -> {:ok, 2} end)
      Cache.fetch(:latest, 120_000, fn -> {:ok, 3} end)
      Cache.fetch(:new, 90_000, fn -> {:ok, 4} end)

      Cache.fetch(:later, 60_000, counted(agent, {:ok, 2}))
      Cache.fetch(:latest, 120_000, counted(agent, {:ok, 3}))
      Cache.fetch(:new, 90_000, counted(agent, {:ok, 4}))
      assert Agent.get(agent, & &1) == 0

      Cache.fetch(:soon, 1_000, counted(agent, {:ok, 1}))
      assert Agent.get(agent, & &1) == 1
    end

    test "overwriting a key in a full table evicts nothing" do
      Application.put_env(:phoenix_kit_ecommerce, :shipping_cache_max_entries, 2)

      on_exit(fn ->
        Application.delete_env(:phoenix_kit_ecommerce, :shipping_cache_max_entries)
      end)

      Cache.fetch(:a, 60_000, fn -> {:ok, 1} end)
      Cache.fetch(:b, 60_000, fn -> {:ok, 2} end)
      Cache.clear()
      Cache.fetch(:a, 60_000, fn -> {:ok, 1} end)
      Cache.fetch(:b, 60_000, fn -> {:ok, 2} end)

      assert :ets.info(:phoenix_kit_ecommerce_shipping_cache, :size) == 2
    end

    test "a group of entries is bounded apart from the table" do
      Application.put_env(:phoenix_kit_ecommerce, :shipping_cache_max_lookup_entries, 4)

      on_exit(fn ->
        Application.delete_env(:phoenix_kit_ecommerce, :shipping_cache_max_lookup_entries)
      end)

      Cache.fetch(:plain, 60_000, fn -> {:ok, :kept} end)
      for n <- 1..40, do: Cache.fetch({:q, n}, 60_000 + n, fn -> {:ok, n} end, group: :query)

      grouped =
        :ets.select_count(:phoenix_kit_ecommerce_shipping_cache, [
          {{:_, :_, :_, :query}, [], [true]}
        ])

      assert grouped in 1..4
      assert {:ok, :kept} = Cache.fetch(:plain, 60_000, fn -> :recomputed end)
    end

    test "a group that is full evicts the entries closest to expiry among its own" do
      Application.put_env(:phoenix_kit_ecommerce, :shipping_cache_max_lookup_entries, 2)

      on_exit(fn ->
        Application.delete_env(:phoenix_kit_ecommerce, :shipping_cache_max_lookup_entries)
      end)

      Cache.fetch(:other, 1_000, fn -> {:ok, 0} end)
      Cache.fetch(:a, 60_000, fn -> {:ok, 1} end, group: :query)
      Cache.fetch(:b, 120_000, fn -> {:ok, 2} end, group: :query)
      Cache.fetch(:c, 90_000, fn -> {:ok, 3} end, group: :query)

      # The shortest-lived of the group (:a) went, the ungrouped one stayed.
      assert {:ok, 0} = Cache.fetch(:other, 1_000, fn -> :recomputed end)
      assert {:ok, 2} = Cache.fetch(:b, 120_000, fn -> :recomputed end, group: :query)
      assert {:ok, 3} = Cache.fetch(:c, 90_000, fn -> :recomputed end, group: :query)
      assert :recomputed = Cache.fetch(:a, 60_000, fn -> :recomputed end, group: :query)
    end

    test "list? skips lists over the size limit", %{agent: agent} do
      Application.put_env(:phoenix_kit_ecommerce, :shipping_cache_max_list_size, 2)

      on_exit(fn ->
        Application.delete_env(:phoenix_kit_ecommerce, :shipping_cache_max_list_size)
      end)

      Cache.fetch(:long, 60_000, counted(agent, {:ok, [1, 2, 3]}), list?: true)
      Cache.fetch(:long, 60_000, counted(agent, {:ok, [1, 2, 3]}), list?: true)
      assert Agent.get(agent, & &1) == 2

      Cache.fetch(:short, 60_000, counted(agent, {:ok, [1, 2]}), list?: true)
      Cache.fetch(:short, 60_000, counted(agent, {:ok, [1, 2]}), list?: true)
      assert Agent.get(agent, & &1) == 3

      # Without the option a list is a value like any other.
      Cache.fetch(:plain, 60_000, counted(agent, {:ok, [1, 2, 3]}))
      Cache.fetch(:plain, 60_000, counted(agent, {:ok, [1, 2, 3]}))
      assert Agent.get(agent, & &1) == 4
    end

    test "child_spec starts a named process" do
      assert %{id: Cache, start: {Cache, :start_link, _}} = Cache.child_spec([])
    end
  end

  describe "ttl/1" do
    setup do
      on_exit(fn -> Application.delete_env(:phoenix_kit_ecommerce, :shipping_cache_ttl) end)
    end

    test "defaults" do
      assert Cache.ttl(:lookups) == :timer.hours(6)
      assert Cache.ttl(:quotes) == :timer.minutes(10)
    end

    test "negative entries default to 30 seconds" do
      assert Cache.ttl(:negative) == 30_000
    end

    test "invalid configuration falls back to the defaults" do
      Application.put_env(:phoenix_kit_ecommerce, :shipping_cache_ttl,
        quotes: :infinity,
        lookups: -5,
        negative: "x"
      )

      assert Cache.ttl(:quotes) == :timer.minutes(10)
      assert Cache.ttl(:lookups) == :timer.hours(6)
      assert Cache.ttl(:negative) == 30_000
    end

    test "can be configured per kind" do
      Application.put_env(:phoenix_kit_ecommerce, :shipping_cache_ttl, quotes: 123)

      assert Cache.ttl(:quotes) == 123
      assert Cache.ttl(:lookups) == :timer.hours(6)
    end
  end
end
