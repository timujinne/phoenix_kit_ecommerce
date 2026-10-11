defmodule PhoenixKitEcommerce.ShopifyDefaultUpgradeTest do
  @moduledoc """
  The V3 upgrade step of the module-owned chain: `shopify_enabled?/0` now
  defaults to off, so an install that already uses Shopify and never wrote a
  `shop_shopify_enabled` row must get one written with "true" — otherwise the
  default flip would quietly turn its sync off. Only a MISSING row on an
  already-configured install is written; an existing row is never touched.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKitEcommerce.Migrations

  defp run_step(prefix \\ "public") do
    Enum.each(Migrations.shopify_upgrade_statements(prefix), &Repo.query!/1)
  end

  defp stored_row(prefix \\ "public") do
    %{rows: rows} =
      Repo.query!(
        "SELECT value, module FROM #{prefix}.phoenix_kit_settings " <>
          "WHERE key = 'shop_shopify_enabled'"
      )

    rows
  end

  defp insert_shopify_connection(prefix \\ "public") do
    uuid = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO #{prefix}.phoenix_kit_settings (key, value_json, module) " <>
        "VALUES ($1, $2, 'integrations')",
      [uuid, %{"provider" => "shopify", "name" => "default", "status" => "disconnected"}]
    )
  end

  defp insert_other_connection do
    Repo.query!(
      "INSERT INTO phoenix_kit_settings (key, value_json, module) VALUES ($1, $2, 'integrations')",
      [Ecto.UUID.generate(), %{"provider" => "openrouter", "name" => "default"}]
    )
  end

  defp insert_catalogue_item(data) do
    Repo.query!(
      "INSERT INTO phoenix_kit_cat_items (name, data, inserted_at, updated_at) " <>
        "VALUES ('Item', $1, now(), now())",
      [data]
    )
  end

  defp insert_legacy_product(metadata) do
    Repo.query!(
      "INSERT INTO phoenix_kit_shop_products (price, metadata) VALUES (1, $1)",
      [metadata]
    )
  end

  defp set_row(value) do
    PhoenixKit.Settings.update_boolean_setting_with_module("shop_shopify_enabled", value, "shop")
  end

  test "fresh install: no row, step writes nothing, Shopify stays off" do
    run_step()

    assert stored_row() == []
    refute PhoenixKitEcommerce.shopify_enabled?()
  end

  test "a Shopify connection and no row: the step enables Shopify" do
    insert_shopify_connection()
    refute PhoenixKitEcommerce.shopify_enabled?()

    run_step()

    assert stored_row() == [["true", "shop"]]
    assert PhoenixKitEcommerce.shopify_enabled?()
  end

  test "a connection of another provider does not count as Shopify being configured" do
    insert_other_connection()

    run_step()

    assert stored_row() == []
    refute PhoenixKitEcommerce.shopify_enabled?()
  end

  test "catalogue items carrying a Shopify product id and no row: the step enables Shopify" do
    insert_catalogue_item(%{"ecommerce" => %{"shopify" => %{"product_id" => "8123456789"}}})

    run_step()

    assert stored_row() == [["true", "shop"]]
    assert PhoenixKitEcommerce.shopify_enabled?()
  end

  test "catalogue items without a Shopify id do not count" do
    insert_catalogue_item(%{"ecommerce" => %{"base_price" => "10"}})
    insert_catalogue_item(%{"ecommerce" => %{"shopify" => %{"product_id" => ""}}})
    insert_catalogue_item(%{})

    run_step()

    assert stored_row() == []
  end

  test "legacy products linked to Shopify and no row: the step enables Shopify" do
    insert_legacy_product(%{"_shopify" => %{"product_id" => "8123456789"}})

    run_step()

    assert stored_row() == [["true", "shop"]]
  end

  test "legacy products without a Shopify link do not count" do
    insert_legacy_product(%{"note" => "hand made"})
    insert_legacy_product(%{"_shopify" => %{"product_id" => ""}})

    run_step()

    assert stored_row() == []
  end

  test "an explicit false row stays false even when Shopify is configured" do
    insert_shopify_connection()
    set_row(false)

    run_step()

    assert stored_row() == [["false", "shop"]]
    refute PhoenixKitEcommerce.shopify_enabled?()
  end

  test "an explicit true row is left as it is, and the step is idempotent" do
    set_row(true)

    run_step()
    run_step()

    assert stored_row() == [["true", "shop"]]
  end

  test "running the step twice on a configured install writes one row" do
    insert_shopify_connection()

    run_step()
    run_step()

    assert stored_row() == [["true", "shop"]]
  end

  describe "tables the step looks at are absent" do
    setup do
      # A schema holding only the settings table: no catalogue items, no
      # legacy products. DDL rolls back with the sandbox transaction.
      Repo.query!("CREATE SCHEMA pke_bare")

      Repo.query!(
        "CREATE TABLE pke_bare.phoenix_kit_settings " <>
          "(LIKE public.phoenix_kit_settings INCLUDING ALL)"
      )

      :ok
    end

    test "does not crash, and writes nothing when nothing marks Shopify as configured" do
      run_step("pke_bare")

      assert stored_row("pke_bare") == []
    end

    test "still enables Shopify when a connection exists" do
      insert_shopify_connection("pke_bare")

      run_step("pke_bare")

      assert stored_row("pke_bare") == [["true", "shop"]]
    end
  end
end
