defmodule PhoenixKitEcommerce.Search.QueryTypoUnboxedTest do
  @moduledoc """
  The typo threshold must live exactly as long as the typo path's transaction.

  The sandbox wraps a whole test in one transaction, so there `set_config(..., true)`
  survives whether or not `Search.Query` opens its own transaction, and a regression that
  dropped it would only show in production. This test runs on a real connection (committed
  rows, removed afterwards) where the setting dies at the end of its statement unless the
  query path holds a transaction around it. `async: false`: it commits to a shared database.
  """
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitEcommerce.Search.Entry
  alias PhoenixKitEcommerce.Search.Query
  alias PhoenixKitEcommerce.Search.Trigram
  alias PhoenixKitEcommerce.Test.Repo

  @moduletag :integration
  @moduletag :requires_pg_trgm

  # a language code no other test uses; the 'simple' configuration applies
  @language "zz"

  setup do
    unboxed(fn ->
      Repo.delete_all(from(e in Entry, where: e.language == @language))

      Repo.query!(
        """
        INSERT INTO phoenix_kit_shop_search_index
          (item_uuid, language, title, title_trgm, document)
        VALUES ($1, $2, 'Ceramic Vase', 'ceramic vase', to_tsvector('simple', 'Ceramic Vase'))
        """,
        [Ecto.UUID.bingenerate(), @language]
      )
    end)

    Trigram.reset_cache()

    on_exit(fn ->
      Trigram.reset_cache()
      unboxed(fn -> Repo.delete_all(from(e in Entry, where: e.language == @language)) end)
    end)
  end

  test "the 0.45 threshold applies on a plain connection, not the extension default of 0.6" do
    # word_similarity('cerumic', 'ceramic vase') = 0.4545
    result = unboxed(fn -> Query.run(%{q: "cerumic"}, @language) end)

    assert result.mode == :typo
    assert result.count == 1
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
