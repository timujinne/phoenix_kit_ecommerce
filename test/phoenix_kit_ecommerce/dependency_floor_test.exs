defmodule PhoenixKitEcommerce.DependencyFloorTest do
  @moduledoc """
  Pins the symbols the declared `phoenix_kit` / `phoenix_kit_billing` floors
  exist to guarantee.

  A too-low floor is invisible in this workspace — `mix.lock` carries the
  latest of everything, so the build that proves the package is the one
  build that can never resolve an older dep. The failure lands in a
  consumer's project instead: a compile error on a module core does not
  ship, or, worse, a field silently dropped by `cast/3`.

  These assertions run against the RESOLVED dependency, so they fail
  wherever a resolution actually lands below the floor — a host's build, or
  a `<APP>_PATH` checkout pointed at an older tree.
  """
  use ExUnit.Case, async: true

  test "the phoenix_kit floor ships PhoenixKitWeb.Live.UrlState" do
    # `Web.Products` and `Web.Categories` `use` it at compile time, so a core
    # without it is a compile failure in the consumer, or an
    # UndefinedFunctionError on `on_mount/4` from a precompiled artefact.
    assert Code.ensure_loaded?(PhoenixKitWeb.Live.UrlState)
    assert macro_exported?(PhoenixKitWeb.Live.UrlState, :__using__, 1)
  end

  test "the phoenix_kit floor ships the runtime migration-version accessor" do
    # `payment_option_column_available?/0` asks core, at runtime, whether the
    # host has migrated past V162. Its rescue clause fails closed, so an
    # absent accessor would not crash — it would quietly stop recording the
    # payment option on every order.
    assert Code.ensure_loaded?(PhoenixKit.Migrations.Postgres)
    assert function_exported?(PhoenixKit.Migrations.Postgres, :migrated_version_runtime, 1)
  end

  test "the phoenix_kit floor ships Slug.put_slug/3" do
    # ShippingMethod.changeset/2 calls it. Against 2.0–2.3 this is an
    # UndefinedFunctionError on every shipping-method save, in the host.
    assert Code.ensure_loaded?(PhoenixKit.Utils.Slug)
    assert function_exported?(PhoenixKit.Utils.Slug, :put_slug, 3)
  end

  test "the phoenix_kit floor ships the V171 shop slug projection" do
    # Product/Category unique_constraint names are the projection pkeys.
    # Without V171 those names do not exist and a collision is a raw
    # Postgrex.Error instead of a changeset error on :slug.
    assert Code.ensure_loaded?(PhoenixKit.Migrations.Postgres.ShopSlugProjection)
  end

  test "the phoenix_kit_billing floor ships Order.payment_option_uuid" do
    # `maybe_put_payment_option/2` writes this attr once core is at V162.
    # `cast/3` ignores a key the schema does not declare, so against an older
    # billing the linkage vanishes with no error anywhere.
    assert :payment_option_uuid in PhoenixKitBilling.Order.__schema__(:fields)
  end

  test "the phoenix_kit_billing floor ships the tax API this module reads" do
    # Added in billing 0.1.3; `~> 0.1` admitted 0.1.0-0.1.2 without them
    # (0.1.0 predates the `PhoenixKitBilling` namespace altogether).
    assert Code.ensure_loaded?(PhoenixKitBilling)
    assert function_exported?(PhoenixKitBilling, :tax_enabled?, 0)
    assert function_exported?(PhoenixKitBilling, :get_tax_rate, 0)
    assert function_exported?(PhoenixKitBilling, :get_tax_rate_percent, 0)
  end
end
