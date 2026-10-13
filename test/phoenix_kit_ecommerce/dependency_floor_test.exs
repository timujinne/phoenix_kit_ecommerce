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

  alias PhoenixKit.Migrations.Postgres, as: CoreMigrations
  alias PhoenixKitBilling.Currency

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

  test "the phoenix_kit floor ships the cache API StorefrontCache runs on" do
    # `PhoenixKitEcommerce.children/0` starts a `PhoenixKit.Cache` with `:ttl`
    # and `:max_size`, and `StorefrontCache` reads it through `remember/4`,
    # `clear/1` and `Registry.cache_exists?/1`. Without them the storefront
    # cache fails to start or every /shop mount raises.
    assert Code.ensure_loaded?(PhoenixKit.Cache)
    assert function_exported?(PhoenixKit.Cache, :remember, 4)
    assert function_exported?(PhoenixKit.Cache, :clear, 1)
    assert Code.ensure_loaded?(PhoenixKit.Cache.Registry)
    assert function_exported?(PhoenixKit.Cache.Registry, :cache_exists?, 1)
    assert {:children, 0} in PhoenixKit.Module.behaviour_info(:callbacks)
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

  test "the phoenix_kit_billing floor ships the per-domain-currency resolution API" do
    # create_cart/1 and both add-to-cart paths (Э1-E1) call all five of
    # these. Below the floor that raised billing's `~> 0.7` to `~> 0.11`,
    # get_base_currency/0 and get_display_currency/0 do not exist at all
    # (they are new, not renamed), so a checkout call would be
    # UndefinedFunctionError, not a silently wrong value.
    assert Code.ensure_loaded?(PhoenixKitBilling)
    assert function_exported?(PhoenixKitBilling, :get_base_currency, 0)
    assert function_exported?(PhoenixKitBilling, :get_display_currency, 0)
    assert function_exported?(PhoenixKitBilling, :resolve_display_currency, 1)
    assert Code.ensure_loaded?(Currency)
    assert function_exported?(Currency, :present, 3)
    assert function_exported?(Currency, :effective_rate, 2)
  end

  test "the phoenix_kit_billing floor ships the shared billing profile form" do
    # Checkout renders the component and validates over `fields_changeset/3`;
    # both arrived in billing 0.20. Below it the page fails at runtime.
    assert Code.ensure_loaded?(PhoenixKitBilling.Web.Components.BillingProfileFields)

    assert function_exported?(
             PhoenixKitBilling.Web.Components.BillingProfileFields,
             :billing_profile_fields,
             1
           )

    # function_exported?/3 is false for a module that is not loaded yet.
    assert Code.ensure_loaded?(PhoenixKitBilling.BillingProfile)
    assert function_exported?(PhoenixKitBilling.BillingProfile, :fields_changeset, 3)
    assert function_exported?(PhoenixKitBilling.BillingProfile, :form_fields, 0)
    assert Code.ensure_loaded?(PhoenixKitBilling.Gettext)
  end

  test "the declared billing requirement excludes releases without the checkout form" do
    # The resolved symbols above cannot catch a lowered requirement while
    # mix.lock still selects a newer release. Inspect the shipped pin too,
    # including when a local path override is active for this test run.
    assert [_, requirement] =
             Regex.run(~r/:phoenix_kit_billing,\s*"([^"]+)"/, File.read!("mix.exs"))

    refute Version.match?("0.19.0", requirement)
    assert Version.match?("0.20.0", requirement)
    assert Version.match?("0.21.0", requirement)
  end

  test "the phoenix_kit floor ships V186's cart/order freeze columns" do
    # Cart/CartItem cast base_currency/exchange_rate/base_unit_price —
    # real table columns core's V186 adds (first released in 2.16.0), not
    # attrs the schema merely declares. Below V186 the ALTER TABLEs never
    # ran, so every cart/cart-item write in Э1-E1 raises Postgrex.Error
    # (undefined_column) at the database, not a dropped-attr no-op.
    assert CoreMigrations.current_version() >= 186
  end
end
