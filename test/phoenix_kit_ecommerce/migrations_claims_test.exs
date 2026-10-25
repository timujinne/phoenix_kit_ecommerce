defmodule PhoenixKitEcommerce.MigrationsClaimsTest do
  @moduledoc """
  V5 of the module chain: the claims table of the public cart API and the
  analytics exclusion for the claim URL. Statement-level checks only (no
  database); the table itself is exercised by `CartClaimTest`.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.Migrations

  test "the chain is at V6 and stamps the marker last" do
    assert Migrations.current_version() == 6

    assert List.last(Migrations.up_statements("public")) ==
             "COMMENT ON TABLE public.phoenix_kit_shop_config IS 'pke_schema:6'"
  end

  test "claims_statements creates the table with its keys inline, then three guarded indexes" do
    assert [table | indexes] = Migrations.claims_statements("public")

    assert table =~ "CREATE TABLE IF NOT EXISTS public.phoenix_kit_shop_cart_claims ("
    assert table =~ ~s|"token_hash" character varying(64) NOT NULL|
    assert table =~ ~s|"cart_token_hash" character varying(64) NOT NULL|
    assert table =~ ~s|"language" character varying(16) NOT NULL|
    assert table =~ ~s|"expires_at" timestamp with time zone NOT NULL|
    assert table =~ ~s|"used_at" timestamp with time zone,|
    assert table =~ ~s|"superseded_at" timestamp with time zone,|

    assert table =~
             ~s|REFERENCES public.phoenix_kit_shop_carts("uuid") ON DELETE CASCADE|

    assert length(indexes) == 3
    assert Enum.all?(indexes, &(&1 =~ ~r/^CREATE (UNIQUE )?INDEX IF NOT EXISTS /))

    assert Enum.any?(
             indexes,
             &(&1 =~ "CREATE UNIQUE INDEX IF NOT EXISTS idx_shop_cart_claims_token_hash ON")
           )

    assert Enum.any?(indexes, &(&1 =~ "idx_shop_cart_claims_cart_token_hash ON"))
    assert Enum.any?(indexes, &(&1 =~ "idx_shop_cart_claims_cart_uuid ON"))
  end

  test "up_statements runs the claims step before the analytics step, both before the marker" do
    stmts = Migrations.up_statements("public")
    [table | _] = Migrations.claims_statements("public")
    [analytics] = Migrations.claim_analytics_statements("public")

    table_at = Enum.find_index(stmts, &(&1 == table))
    analytics_at = Enum.find_index(stmts, &(&1 == analytics))

    assert is_integer(table_at) and is_integer(analytics_at)
    assert table_at < analytics_at
    # Followed by V6's three columns, then the marker.
    assert analytics_at ==
             length(stmts) - 2 - length(Migrations.v6_base_currency_columns("public"))
  end

  test "no V5 statement leaks the public schema under a foreign prefix" do
    stmts =
      Migrations.claims_statements("tenant_x") ++
        Migrations.claim_analytics_statements("tenant_x")

    refute Enum.any?(stmts, &String.contains?(&1, "public."))
    assert Enum.any?(stmts, &String.contains?(&1, "tenant_x.phoenix_kit_shop_cart_claims"))
  end

  test "the analytics step names the claim pattern with a trailing star and only ever inserts or appends" do
    [step] = Migrations.claim_analytics_statements("public")

    assert step =~ "to_regclass('public.phoenix_kit_web_analytics_events')"
    assert step =~ "/checkout/claim/*"
    assert step =~ "ON CONFLICT (key) DO NOTHING"
    refute step =~ ~r/\bDELETE\s+FROM\b/i
    refute step =~ ~r/\bDROP\b/i
    refute step =~ ~r/\bTRUNCATE\b/i
  end

  test "the prefix is validated before it reaches DDL" do
    assert_raise ArgumentError, fn -> Migrations.claims_statements("public; DROP") end
    assert_raise ArgumentError, fn -> Migrations.claim_analytics_statements("public; DROP") end
  end

  test "down keeps the claims table, like every table of the chain" do
    down = Migrations.down_statements("public", 4)
    refute Enum.any?(down, &(&1 =~ "cart_claims"))
    assert List.last(down) == "COMMENT ON TABLE public.phoenix_kit_shop_config IS 'pke_schema:4'"
  end
end
