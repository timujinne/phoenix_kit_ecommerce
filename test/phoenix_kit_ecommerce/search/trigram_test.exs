defmodule PhoenixKitEcommerce.Search.TrigramTest do
  # async: false - the answer is cached in a process-global :persistent_term.
  use PhoenixKitEcommerce.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitEcommerce.Search.Trigram
  alias PhoenixKitEcommerce.Test.Repo

  setup do
    Trigram.reset_cache()
    on_exit(&Trigram.reset_cache/0)
    :ok
  end

  defp installed? do
    %{rows: [[installed]]} =
      Repo.query!("SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm')")

    installed
  end

  test "available?/0 reports whether pg_trgm is installed in this database" do
    assert Trigram.available?() == installed?()
  end

  test "available?/0 is false while the operator is not on the search path, though the extension is installed" do
    assert installed?()

    # Rolled back with the test's sandbox transaction.
    Repo.query!("SET LOCAL search_path TO pg_catalog")

    assert Trigram.available?() == false
  end

  test "put_cache/1 overrides the answer until reset_cache/0" do
    Trigram.put_cache(false)
    assert Trigram.available?() == false

    Trigram.put_cache(true)
    assert Trigram.available?() == true

    Trigram.reset_cache()
    assert Trigram.available?() == installed?()
  end

  test "a failed check is not cached: the next call asks again" do
    # In manual mode this process owns no connection, so the query raises.
    Sandbox.mode(Repo, :manual)

    assert Trigram.available?() == false

    :ok = Sandbox.checkout(Repo)
    assert Trigram.available?() == installed?()
  end
end
