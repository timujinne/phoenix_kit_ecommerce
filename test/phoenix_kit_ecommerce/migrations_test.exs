defmodule PhoenixKitEcommerce.MigrationsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.Migrations

  @tables ~w(
    phoenix_kit_shop_config
    phoenix_kit_shop_shipping_methods
    phoenix_kit_shop_categories
    phoenix_kit_shop_products
    phoenix_kit_shop_product_slugs
    phoenix_kit_shop_category_slugs
    phoenix_kit_shop_carts
    phoenix_kit_shop_cart_items
    phoenix_kit_shop_import_configs
    phoenix_kit_shop_import_logs
  )

  test "chain is V2 and marks phoenix_kit_shop_config" do
    assert Migrations.current_version() == 2
    assert Migrations.version_table() == "phoenix_kit_shop_config"
  end

  test "up_statements creates every owned table idempotently and stamps the marker" do
    stmts = Migrations.up_statements("public")

    for t <- @tables do
      assert Enum.any?(stmts, &String.contains?(&1, "CREATE TABLE IF NOT EXISTS public.#{t} ("))
    end

    assert List.last(stmts) == "COMMENT ON TABLE public.phoenix_kit_shop_config IS 'pke_schema:2'"
  end

  test "no statement can destroy data, in either direction" do
    all = Migrations.up_statements("public") ++ Migrations.down_statements("public", 0)

    # The two adopted slug-projection functions (sync_shop_product_slugs/
    # sync_shop_category_slugs) contain a scoped `DELETE FROM ... WHERE
    # <fk>_uuid = NEW.uuid` as their own pre-existing, core-authored
    # upsert-by-replace body (unchanged here) — that is runtime trigger
    # logic being adopted verbatim, not a migration-time destructive
    # statement against the chain's tables. Only the `$function$...
    # $function$` body is stripped before scanning — a DROP/TRUNCATE
    # added to the function's own DDL wrapper, or appended after one,
    # still fails this test.
    #
    # The destructive-statement scan targets DELETE as a *statement*
    # (`DELETE FROM ...`), not the referential-action keyword `ON DELETE
    # CASCADE|SET NULL|...` that every adopted foreign key carries
    # verbatim from core's dump — those never delete a row on their own.
    # `DROP` is matched by the OBJECT KIND that follows it, not on its own:
    # V2's `ALTER COLUMN "currency" DROP DEFAULT` removes a column default,
    # which rewrites nothing and reads no rows. Every kind of DROP that can
    # lose data or structure is still refused, and so is a bare `DROP` with
    # nothing recognizable after it.
    for s <- all do
      scanned = Regex.replace(~r/\$function\$.*?\$function\$/s, s, "")

      refute scanned =~ ~r/\bDROP\b(?!\s+(DEFAULT|NOT\s+NULL)\b)/i,
             "destructive statement: #{s}"

      refute scanned =~ ~r/\bTRUNCATE\b/i, "destructive statement: #{s}"
      refute scanned =~ ~r/\bDELETE\s+FROM\b/i, "destructive statement: #{s}"
    end
  end

  test "the chain has exactly the objects the block 0 plan enumerates" do
    stmts = Migrations.up_statements("public")

    # 10 tables + 2 functions + 23 constraints + 2 triggers + 39 indexes
    # + 4 V2 `DROP DEFAULT`s + 1 marker
    assert length(stmts) == 81

    for name <- ~w(
          idx_shop_config_key
          phoenix_kit_shop_categories_slug_gin_idx
        ) do
      assert Enum.any?(stmts, &String.contains?(&1, "INDEX IF NOT EXISTS #{name} ON")),
             "missing index #{name}"
    end

    for name <- ~w(
          phoenix_kit_shop_product_slugs_pkey
          fk_shop_cart_items_cart_uuid
          fk_shop_carts_payment_option_uuid
        ) do
      assert Enum.any?(stmts, &String.contains?(&1, "ADD CONSTRAINT #{name} ")),
             "missing constraint #{name}"
    end
  end

  test "no statement leaks the public schema under a foreign prefix" do
    refute Enum.any?(Migrations.up_statements("tenant_x"), &String.contains?(&1, "public.")),
           "statement leaks the public schema under a foreign prefix"
  end

  # Core names these five with its `pn` prefix embedding (`__PK_NAME_EXEMPT__`
  # in its expected-schema manifest): bare under "public", `<prefix>_`-prefixed
  # otherwise. A bare name under a foreign prefix misses core's index entirely
  # and builds a second, redundant unique index on every prefixed install.
  @exempt_uuid_indexes ~w(
    phoenix_kit_shop_cart_items_uuid_idx
    phoenix_kit_shop_carts_uuid_idx
    phoenix_kit_shop_categories_uuid_idx
    phoenix_kit_shop_products_uuid_idx
    phoenix_kit_shop_shipping_methods_uuid_idx
  )

  test "the uuid indexes core embeds the schema name into are named the same way" do
    public = Migrations.up_statements("public")
    tenant = Migrations.up_statements("tenant_x")

    for name <- @exempt_uuid_indexes do
      assert Enum.any?(public, &String.contains?(&1, "INDEX IF NOT EXISTS #{name} ON")),
             "missing #{name} under the public schema"

      assert Enum.any?(tenant, &String.contains?(&1, "INDEX IF NOT EXISTS tenant_x_#{name} ON")),
             "#{name} does not carry the prefix embedding core gives it"
    end
  end

  test "no other index carries the prefix embedding" do
    names =
      Migrations.up_statements("tenant_x")
      |> Enum.flat_map(fn stmt ->
        case Regex.run(~r/INDEX IF NOT EXISTS (\S+) ON/, stmt) do
          [_, name] -> [name]
          nil -> []
        end
      end)

    assert length(names) == 39

    assert names |> Enum.filter(&String.starts_with?(&1, "tenant_x_")) |> Enum.sort() ==
             @exempt_uuid_indexes |> Enum.map(&("tenant_x_" <> &1)) |> Enum.sort()
  end

  test "every CREATE INDEX and constraint is guarded" do
    for s <- Migrations.up_statements("public"), s =~ ~r/CREATE (UNIQUE )?INDEX/ do
      assert s =~ ~r/CREATE (UNIQUE )?INDEX IF NOT EXISTS/
    end

    for s <- Migrations.up_statements("public"), s =~ ~r/ADD CONSTRAINT/ do
      assert s =~ ~r/DO \$\$/ and s =~ ~r/IF NOT EXISTS/
    end
  end

  @currency_tables ~w(
    phoenix_kit_shop_carts
    phoenix_kit_shop_cart_items
    phoenix_kit_shop_products
    phoenix_kit_shop_shipping_methods
  )

  test "V2 drops the DEFAULT 'USD' core declares on every currency column" do
    stmts = Migrations.up_statements("public")

    for t <- @currency_tables do
      assert ~s(ALTER TABLE public.#{t} ALTER COLUMN "currency" DROP DEFAULT) in stmts,
             "#{t}.currency keeps core's 'USD' column default"
    end
  end

  test "down rewrites the marker and puts the currency defaults back" do
    restores =
      for t <- @currency_tables,
          do:
            ~s(ALTER TABLE public.#{t} ALTER COLUMN "currency" SET DEFAULT 'USD'::character varying)

    assert Migrations.down_statements("public", 0) ==
             restores ++ ["COMMENT ON TABLE public.phoenix_kit_shop_config IS NULL"]

    assert Migrations.down_statements("public", 1) ==
             restores ++ ["COMMENT ON TABLE public.phoenix_kit_shop_config IS 'pke_schema:1'"]

    # Rolling back TO V2 is not rolling V2 back — the defaults stay dropped.
    assert Migrations.down_statements("public", 2) ==
             ["COMMENT ON TABLE public.phoenix_kit_shop_config IS 'pke_schema:2'"]
  end

  test "prefix is validated before it reaches DDL" do
    assert_raise ArgumentError, fn -> Migrations.up_statements("public; DROP") end
  end

  test "the module registers the chain" do
    assert PhoenixKitEcommerce.migration_module() == Migrations
  end

  test "the slug projections come with their functions and triggers, guarded" do
    joined = Enum.join(Migrations.up_statements("public"), "\n")

    for f <- ~w(sync_shop_product_slugs sync_shop_category_slugs) do
      assert joined =~ "CREATE OR REPLACE FUNCTION public.#{f}()"
    end

    for t <- ~w(trg_shop_product_slugs trg_shop_category_slugs) do
      assert joined =~ ~r/IF NOT EXISTS \(SELECT 1 FROM pg_trigger WHERE tgname = '#{t}'/
    end
  end
end
