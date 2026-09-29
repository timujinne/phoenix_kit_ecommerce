defmodule PhoenixKitEcommerce.TranslationSweepTickLockTest do
  @moduledoc """
  Two direct sweep ticks at once — two tabs pressing Run sweep — must not
  both run: the second answers `:sweep_running`. The sandbox cannot race,
  so a second, real connection holds the tick lock and the tick is asked.
  """
  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKitEcommerce.Test.Repo
  alias PhoenixKitEcommerce.Workers.TranslationSweepWorker

  @key "phoenix_kit_ecommerce:translation_sweep_tick"

  test "a tick while another holds the lock answers sweep_running" do
    opts = Keyword.take(Repo.config(), [:hostname, :port, :username, :password, :database])
    {:ok, conn} = Postgrex.start_link(opts)
    Postgrex.query!(conn, "SELECT pg_advisory_lock(hashtext($1))", [@key])

    assert {:sweep_running, %{}} = TranslationSweepWorker.run_manual_tick()

    Postgrex.query!(conn, "SELECT pg_advisory_unlock(hashtext($1))", [@key])
    {reason, _info} = TranslationSweepWorker.run_manual_tick()
    refute reason == :sweep_running
  end

  # A direct tick's jobs are invisible until it commits, and the engine
  # never refuses a scheduled tick for a direct one: the scheduled tick
  # must wait for the lock, or it re-enqueues the direct tick's pairs.
  test "a scheduled tick waits for a direct tick to finish" do
    opts = Keyword.take(Repo.config(), [:hostname, :port, :username, :password, :database])
    {:ok, conn} = Postgrex.start_link(opts)
    Postgrex.query!(conn, "SELECT pg_advisory_lock(hashtext($1))", [@key])

    job = %Oban.Job{id: 1, args: %{}, attempt: 1, max_attempts: 1}
    tick = Task.async(fn -> TranslationSweepWorker.perform(job) end)
    assert Task.yield(tick, 300) == nil

    Postgrex.query!(conn, "SELECT pg_advisory_unlock(hashtext($1))", [@key])
    assert Task.await(tick) == :ok
  end
end
