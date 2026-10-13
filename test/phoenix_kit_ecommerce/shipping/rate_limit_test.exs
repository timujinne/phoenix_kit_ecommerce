defmodule PhoenixKitEcommerce.Shipping.RateLimitTest do
  # Needs the named cache process, which owns the table, and the app env.
  use ExUnit.Case, async: false

  alias PhoenixKitEcommerce.Shipping.{Cache, RateLimit}

  @table :phoenix_kit_ecommerce_shipping_rate_limit

  setup do
    on_exit(fn -> Application.delete_env(:phoenix_kit_ecommerce, :shipping_lookup_rate) end)
    :ok
  end

  test "nothing is limited without the cache process" do
    Application.put_env(:phoenix_kit_ecommerce, :shipping_lookup_rate, 1)

    for _ <- 1..10, do: assert(RateLimit.take("acme_post") == :ok)
    assert RateLimit.reset() == :ok
  end

  describe "with the process" do
    setup do
      start_supervised!(Cache)
      :ok
    end

    test "defaults to 20 calls per second" do
      assert RateLimit.rate() == 20

      for bad <- [0, -3, "5", nil, 1.5] do
        Application.put_env(:phoenix_kit_ecommerce, :shipping_lookup_rate, bad)
        assert RateLimit.rate() == 20
      end

      Application.put_env(:phoenix_kit_ecommerce, :shipping_lookup_rate, 7)
      assert RateLimit.rate() == 7
    end

    test "lets a burst of the rate through, then limits" do
      Application.put_env(:phoenix_kit_ecommerce, :shipping_lookup_rate, 4)

      assert for(_ <- 1..4, do: RateLimit.take("acme_post")) == [:ok, :ok, :ok, :ok]
      assert RateLimit.take("acme_post") == :rate_limited
      assert RateLimit.take("acme_post") == :rate_limited
    end

    test "buckets are per provider" do
      Application.put_env(:phoenix_kit_ecommerce, :shipping_lookup_rate, 1)

      assert RateLimit.take("acme_post") == :ok
      assert RateLimit.take("acme_post") == :rate_limited
      assert RateLimit.take("other_post") == :ok
    end

    test "tokens come back with time, up to the capacity" do
      Application.put_env(:phoenix_kit_ecommerce, :shipping_lookup_rate, 2)
      for _ <- 1..2, do: RateLimit.take("acme_post")
      assert RateLimit.take("acme_post") == :rate_limited

      # Half a second ago the bucket was empty: one token has come back.
      [{key, tokens, at}] = :ets.lookup(@table, "acme_post")
      :ets.insert(@table, {key, tokens, at - 500})

      assert RateLimit.take("acme_post") == :ok
      assert RateLimit.take("acme_post") == :rate_limited

      # A long pause fills the bucket, not beyond it.
      [{key, tokens, at}] = :ets.lookup(@table, "acme_post")
      :ets.insert(@table, {key, tokens, at - 3_600_000})

      assert for(_ <- 1..3, do: RateLimit.take("acme_post")) == [:ok, :ok, :rate_limited]
    end

    test "concurrent takers never spend more than the bucket holds" do
      Application.put_env(:phoenix_kit_ecommerce, :shipping_lookup_rate, 50)

      results =
        1..200
        |> Task.async_stream(fn _ -> RateLimit.take("acme_post") end,
          max_concurrency: 50,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, result} -> result end)

      # The bucket held 50 and a few milliseconds refill a little more.
      allowed = Enum.count(results, &(&1 == :ok))
      assert allowed >= 50 and allowed < 100
    end

    test "reset refills every bucket" do
      Application.put_env(:phoenix_kit_ecommerce, :shipping_lookup_rate, 1)
      RateLimit.take("acme_post")
      assert RateLimit.take("acme_post") == :rate_limited

      RateLimit.reset()
      assert RateLimit.take("acme_post") == :ok
    end
  end
end
