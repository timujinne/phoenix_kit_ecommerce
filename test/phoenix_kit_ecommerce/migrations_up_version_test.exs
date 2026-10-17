defmodule PhoenixKitEcommerce.MigrationsUpVersionTest do
  @moduledoc """
  `Migrations.up/1` honours `:version`: a host migration generated for one
  version applies the chain up to it and nothing later.

  The chain is run for real, through an `Ecto.Migration` runner, into a
  scratch schema holding only the tables it references; the DDL rolls back
  with the sandbox transaction. The version groups are compared by the
  catalog they leave behind, so a statement moved to the wrong version shows
  as a difference rather than passing on a name match.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  alias Ecto.Migration.Runner
  alias PhoenixKitEcommerce.Migrations

  defmodule Up do
    @moduledoc false
    use Ecto.Migration

    def up, do: Migrations.up(Process.get(:pke_up_opts))
  end

  defp run_up(opts) do
    Process.put(:pke_up_opts, opts)
    Runner.run(Repo, Repo.config(), 1, Up, :forward, :up, :up, log: false)
  end

  # What the chain references but does not create.
  defp create_schema(prefix) do
    Repo.query!("CREATE SCHEMA #{prefix}")

    Repo.query!("""
    CREATE FUNCTION #{prefix}.uuid_generate_v7() RETURNS uuid
    LANGUAGE sql AS 'SELECT public.uuid_generate_v7()'
    """)

    for table <- ~w(phoenix_kit_users phoenix_kit_payment_options phoenix_kit_settings) do
      Repo.query!("CREATE TABLE #{prefix}.#{table} (LIKE public.#{table} INCLUDING ALL)")
    end

    # Marks the install as already using Shopify, so V3 has a row to write.
    Repo.query!(
      "INSERT INTO #{prefix}.phoenix_kit_settings (key, value_json, module) " <>
        "VALUES ($1, $2, 'integrations')",
      [Ecto.UUID.generate(), %{"provider" => "shopify", "name" => "default"}]
    )

    prefix
  end

  defp version(prefix), do: Migrations.migrated_version_runtime(prefix: prefix)

  # V2's effect: how many of the four `currency` columns still default to USD.
  defp currency_defaults(prefix) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(*) FROM information_schema.columns
        WHERE table_schema = $1 AND column_name = 'currency'
          AND table_name LIKE 'phoenix_kit_shop_%' AND column_default IS NOT NULL
        """,
        [prefix]
      )

    count
  end

  # V4's and V5's effect: the tables they create.
  defp table?(prefix, table) do
    %{rows: [[found]]} = Repo.query!("SELECT to_regclass($1) IS NOT NULL", ["#{prefix}.#{table}"])
    found
  end

  # V3's effect.
  defp shopify_row?(prefix) do
    %{rows: rows} =
      Repo.query!(
        "SELECT 1 FROM #{prefix}.phoenix_kit_settings WHERE key = 'shop_shopify_enabled'"
      )

    rows != []
  end

  # Tables and columns, indexes, constraints, functions, triggers and the
  # version marker of the shop objects in `prefix`, with the schema name
  # replaced so two schemas compare equal when they hold the same thing.
  defp catalog(prefix) do
    queries = [
      columns: """
      SELECT table_name, column_name, data_type, is_nullable,
             COALESCE(column_default, ''), ordinal_position::text
      FROM information_schema.columns
      WHERE table_schema = $1 AND table_name LIKE 'phoenix_kit_shop_%'
      ORDER BY 1, 6
      """,
      indexes: """
      SELECT tablename, indexname, indexdef FROM pg_indexes
      WHERE schemaname = $1 AND tablename LIKE 'phoenix_kit_shop_%'
      ORDER BY 1, 2
      """,
      constraints: """
      SELECT c.conrelid::regclass::text, c.conname, pg_get_constraintdef(c.oid)
      FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace
      WHERE n.nspname = $1 AND c.conrelid::regclass::text LIKE '%phoenix_kit_shop_%'
      ORDER BY 1, 2
      """,
      functions: """
      SELECT p.proname, pg_get_functiondef(p.oid)
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = $1 AND p.proname LIKE '%shop%'
      ORDER BY 1
      """,
      triggers: """
      SELECT c.relname, t.tgname, pg_get_triggerdef(t.oid)
      FROM pg_trigger t
      JOIN pg_class c ON c.oid = t.tgrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = $1 AND NOT t.tgisinternal AND c.relname LIKE 'phoenix_kit_shop_%'
      ORDER BY 1, 2
      """,
      marker: """
      SELECT obj_description(c.oid, 'pg_class')
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = $1 AND c.relname = 'phoenix_kit_shop_config'
      """
    ]

    for {name, sql} <- queries do
      %{rows: rows} = Repo.query!(sql, [prefix])
      {name, Enum.map(rows, fn row -> Enum.map(row, &neutral(&1, prefix)) end)}
    end
  end

  defp neutral(value, prefix) when is_binary(value), do: String.replace(value, prefix, "SCHEMA")
  defp neutral(value, _prefix), do: value

  describe "a fresh schema" do
    test "version: 1 adopts the tables and stops: no V2, no V3, marker 1" do
      prefix = create_schema("pke_up_one")

      run_up(prefix: prefix, version: 1)

      assert version(prefix) == 1
      assert currency_defaults(prefix) == 4
      refute shopify_row?(prefix)
    end

    test "version: 2 also drops the currency defaults and stops before V3" do
      prefix = create_schema("pke_up_two")

      run_up(prefix: prefix, version: 2)

      assert version(prefix) == 2
      assert currency_defaults(prefix) == 0
      refute shopify_row?(prefix)
    end

    test "version: 3 applies V1 to V3 and stops before the search index and the claims" do
      prefix = create_schema("pke_up_three")

      run_up(prefix: prefix, version: 3)

      assert version(prefix) == 3
      assert currency_defaults(prefix) == 0
      assert shopify_row?(prefix)
      refute table?(prefix, "phoenix_kit_shop_search_index")
      refute table?(prefix, "phoenix_kit_shop_cart_claims")
    end

    test "version: 4 adds the search index and stops before the claims" do
      prefix = create_schema("pke_up_four")

      run_up(prefix: prefix, version: 4)

      assert version(prefix) == 4
      assert table?(prefix, "phoenix_kit_shop_search_index")
      refute table?(prefix, "phoenix_kit_shop_cart_claims")
    end

    test "no :version means the current version" do
      prefix = create_schema("pke_up_default")

      run_up(prefix: prefix)

      assert version(prefix) == Migrations.current_version()
      assert currency_defaults(prefix) == 0
      assert shopify_row?(prefix)
      assert table?(prefix, "phoenix_kit_shop_search_index")
      assert table?(prefix, "phoenix_kit_shop_cart_claims")
    end
  end

  describe "upgrades" do
    test "one version at a time leaves the same catalog as one full run" do
      stepwise = create_schema("pke_up_steps")
      full = create_schema("pke_up_full")

      for target <- 1..Migrations.current_version() do
        run_up(prefix: stepwise, version: target)
        assert version(stepwise) == target
      end

      run_up(prefix: full)

      assert catalog(stepwise) == catalog(full)
      assert shopify_row?(stepwise) == shopify_row?(full)
    end

    test "a database at V3, the last version before the search index, upgrades to the current one" do
      prefix = create_schema("pke_up_from_three")
      full = create_schema("pke_up_reference")

      run_up(prefix: prefix, version: 3)
      run_up(prefix: prefix)
      run_up(prefix: full)

      assert version(prefix) == Migrations.current_version()
      assert table?(prefix, "phoenix_kit_shop_search_index")
      assert table?(prefix, "phoenix_kit_shop_cart_claims")
      assert catalog(prefix) == catalog(full)
    end

    test "from 1 straight to the current version" do
      prefix = create_schema("pke_up_jump")
      full = create_schema("pke_up_jump_full")

      run_up(prefix: prefix, version: 1)
      run_up(prefix: prefix)
      run_up(prefix: full)

      assert version(prefix) == Migrations.current_version()
      assert catalog(prefix) == catalog(full)
    end

    test "replaying a version changes nothing" do
      prefix = create_schema("pke_up_replay")

      run_up(prefix: prefix, version: 2)
      before = catalog(prefix)
      run_up(prefix: prefix, version: 2)

      assert catalog(prefix) == before
      refute shopify_row?(prefix)
    end

    test "a database already past the target is left exactly as it is" do
      prefix = create_schema("pke_up_newer")

      run_up(prefix: prefix, version: 3)
      before = catalog(prefix)

      # What a generated "to V1" or "to V2" migration does on such a database.
      run_up(prefix: prefix, version: 1)
      run_up(prefix: prefix, version: 2)

      assert version(prefix) == 3
      assert catalog(prefix) == before
    end
  end

  describe "the public schema" do
    test "a full replay leaves the migrated catalog and the marker untouched" do
      before = catalog("public")
      assert version("public") == Migrations.current_version()

      run_up([])
      run_up(prefix: "public", version: Migrations.current_version())

      assert catalog("public") == before
    end

    test "an upgrade from each earlier version ends at the same catalog" do
      current = catalog("public")

      for from <- 0..(Migrations.current_version() - 1) do
        Enum.each(Migrations.down_statements("public", from), &Repo.query!/1)
        assert version("public") == from

        run_up(prefix: "public")

        assert catalog("public") == current, "upgrading from V#{from}"
      end
    end
  end

  describe "a target this code has no step for" do
    test "is refused before anything runs" do
      prefix = create_schema("pke_up_refused")

      for bad <- [Migrations.current_version() + 1, 0, -1, "2", nil] do
        assert_raise ArgumentError, ~r/invalid migration target/, fn ->
          run_up(prefix: prefix, version: bad)
        end
      end

      assert version(prefix) == 0
    end
  end
end
