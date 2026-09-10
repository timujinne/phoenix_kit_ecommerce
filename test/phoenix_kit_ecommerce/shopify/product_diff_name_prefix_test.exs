defmodule PhoenixKitEcommerce.Shopify.ProductDiffNamePrefixTest do
  @moduledoc """
  `shop_name_prefixes` must never reach `ProductDiff.diff/4` — the value
  compared against Shopify's title, and the value carried on a `Change`
  for `Sync.apply_change/2` to write, must stay the RAW stored title. A
  stripped comparison would make a product whose stored title carries
  the configured prefix look permanently "changed" (title never
  matching Shopify's own raw title again), and a stripped write would
  corrupt local storage with text that never round-trips back to what
  Shopify actually holds.

  Needs `PhoenixKit.Settings` (a DB write), so this is a separate
  `DataCase`-backed file rather than an addition to the plain
  `ExUnit.Case, async: true` `product_diff_test.exs` — `ProductDiff`
  itself has no DB dependency at all, which is exactly the point being
  proven here: it never calls `Settings`, `NamePrefix`, or
  `Translations.get_display/3`.
  """
  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKitEcommerce.NamePrefix
  alias PhoenixKitEcommerce.Product
  alias PhoenixKitEcommerce.Shopify.ProductDiff
  alias PhoenixKitEcommerce.Shopify.ProductDiff.Change

  @base_locale "en"

  setup do
    PhoenixKit.Settings.update_setting(NamePrefix.setting_key(), "3D Printed")
    :ok
  end

  defp product(overrides) do
    defaults = %Product{
      uuid: Ecto.UUID.generate(),
      slug: %{"en" => "planter"},
      title: %{"en" => "3D Printed Planter"},
      body_html: %{"en" => "Original"},
      description: %{"en" => "Original"},
      vendor: "Acme",
      tags: ["clay", "garden"],
      status: "active",
      price: Decimal.new("20.00")
    }

    struct(defaults, overrides)
  end

  defp shopify_product(overrides) do
    Map.merge(
      %{
        "handle" => "planter",
        "title" => "3D Printed Planter",
        "body_html" => "<p>Original</p>",
        "vendor" => "Acme",
        "tags" => "clay, garden",
        "status" => "active",
        "variants" => [%{"price" => "20.00"}]
      },
      overrides
    )
  end

  test "identical RAW titles (both carrying the configured prefix) produce no change" do
    local = [product([])]
    shopify = [shopify_product(%{})]

    assert ProductDiff.diff(local, shopify, @base_locale) == []
  end

  test "a genuine title change carries the RAW Shopify title, not a stripped one" do
    local = [product([])]
    shopify = [shopify_product(%{"title" => "3D Printed Planter Deluxe"})]

    assert [%Change{changes: %{title: %{current: current, incoming: incoming}}}] =
             ProductDiff.diff(local, shopify, @base_locale)

    assert current == "3D Printed Planter"
    assert incoming == "3D Printed Planter Deluxe"
  end

  test "the Change's display title (unrelated to the field diff) stays the RAW local title" do
    local = [product(uuid: "fixed-uuid")]
    # Title itself is unchanged; price differs, so a Change is still
    # produced, and its :title field must be the RAW local title.
    shopify = [shopify_product(%{"variants" => [%{"price" => "25.00"}]})]

    assert [%Change{title: "3D Printed Planter"}] = ProductDiff.diff(local, shopify, @base_locale)
  end

  test "a brand-new Shopify product's create-Change display title stays the RAW Shopify title" do
    shopify = [shopify_product(%{"handle" => "new-planter"})]

    assert [%Change{title: "3D Printed Planter", create?: true}] =
             ProductDiff.new_product_changes([], shopify)
  end
end
