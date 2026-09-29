defmodule PhoenixKitEcommerce.Shopify.ProductDiffMerchantStatusTest do
  @moduledoc """
  `ProductDiff` compares the MERCHANT status we store, not the status the
  storefront derives for display.

  Under the catalogue source those two are different values.
  `ProductSource.Catalogue.View.product_status/2` deliberately forces
  `"archived"` whenever the catalogue itself has retired the item
  (`item.status != "active"`), regardless of the `shop_status` the last
  Shopify sync wrote — a visibility rule that keeps a retired item from
  staying purchasable at its own URL.

  Comparing that derived value against Shopify's merchant status reported
  a difference no apply could ever close: `Writer.update_from_shopify/3`
  writes `shop_status`, which was already correct, while the view kept
  answering `"archived"`. Measured on a live shop (2026-09-22): seven
  retired products sat in the report as `archived -> active` with
  `shop_status` already `"active"` in the database, surviving every apply.

  The fix is symmetry — diff the field the apply writes. An item whose
  stored merchant status genuinely differs still reports, so a real
  discrepancy is not hidden; only the phantom one goes.
  """

  # `ExUnit.Case`, not `DataCase`: every test here is pure — hand-built
  # `%Product{}` structs, an explicit `base_locale` so `diff/4` never
  # reaches `Translations.default_language/0`, and no `Repo` call at all.
  # `DataCase` would tag the file `:integration`, which `mix test` excludes
  # whenever Postgres is unavailable — the regression guard for the live
  # defect would then quietly run nowhere but a machine with a database.
  # Same case `product_diff_test.exs` uses for the same reason.
  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.Product
  alias PhoenixKitEcommerce.Shopify.ProductDiff

  defp shopify(status, handle \\ "mug") do
    %{
      "handle" => handle,
      "id" => 1,
      "title" => "Mug",
      "body_html" => "",
      "vendor" => "",
      "tags" => "",
      "status" => status,
      "variants" => []
    }
  end

  # Catalogue-backed view-struct: matched by `metadata["_shopify"]["handle"]`.
  defp catalogue_product(fields) do
    base = %{
      uuid: Ecto.UUID.generate(),
      title: %{"en" => "Mug"},
      description: %{"en" => ""},
      body_html: %{"en" => ""},
      tags: [],
      metadata: %{"_shopify" => %{"handle" => "mug"}}
    }

    struct(Product, Map.merge(base, fields))
  end

  # Legacy product: no `_shopify` metadata, matched by `slug[base_locale]`,
  # and no `merchant_status` — `:status` is already the merchant value there.
  defp legacy_product(fields) do
    base = %{
      uuid: Ecto.UUID.generate(),
      title: %{"en" => "Mug"},
      description: %{"en" => ""},
      body_html: %{"en" => ""},
      tags: [],
      slug: %{"en" => "mug"}
    }

    struct(Product, Map.merge(base, fields))
  end

  describe "catalogue source — derived vs merchant status" do
    test "a retired item whose stored merchant status already matches reports no status change" do
      # What the live defect looked like: the view derives "archived"
      # because the catalogue retired the item, while `shop_status` — the
      # field an apply writes — is already "active", same as Shopify.
      #
      # `vendor` differs so a `Change` still exists: asserting on an empty
      # result would also pass if the whole comparison had broken, and the
      # claim here is narrower — the STATUS is not reported, while the rest
      # of the diff keeps working.
      local = catalogue_product(%{status: "archived", merchant_status: "active", vendor: "Acme"})

      [change] = ProductDiff.diff([local], [shopify("active")], "en")

      refute Map.has_key?(change.changes, :status)
      assert Map.has_key?(change.changes, :vendor)
    end

    test "a retired item matching Shopify on every field reports nothing at all" do
      local = catalogue_product(%{status: "archived", merchant_status: "active"})

      assert ProductDiff.diff([local], [shopify("active")], "en") == []
    end

    test "a retired item whose stored merchant status really differs still reports" do
      local = catalogue_product(%{status: "archived", merchant_status: "archived"})

      [change] = ProductDiff.diff([local], [shopify("active")], "en")

      assert change.changes[:status] == %{current: "archived", incoming: "active"}
    end

    test "an active item is unaffected — derived and merchant status agree there" do
      local = catalogue_product(%{status: "active", merchant_status: "active"})

      assert ProductDiff.diff([local], [shopify("active")], "en") == []
    end

    test "an active item with a real status difference still reports" do
      local = catalogue_product(%{status: "active", merchant_status: "active"})

      [change] = ProductDiff.diff([local], [shopify("draft")], "en")

      assert change.changes[:status] == %{current: "active", incoming: "draft"}
    end
  end

  # The mirror image of the defect above, arriving from the write end: a
  # status the apply cannot store faithfully. `Writer.shopify_shop_status/1`
  # coerces anything outside the three to "draft", so reporting such a
  # difference would offer an apply that retires the product AND still
  # reports a difference on the next check.
  describe "an incoming status the apply cannot land" do
    test "is not reported at all" do
      for incoming <- ["ACTIVE", "unlisted", "", nil] do
        local = catalogue_product(%{status: "active", merchant_status: "active"})

        assert ProductDiff.diff([local], [shopify(incoming)], "en") == []
      end
    end

    test "does not suppress the rest of the diff" do
      local = catalogue_product(%{status: "active", merchant_status: "active", vendor: "Acme"})

      [change] = ProductDiff.diff([local], [shopify("ACTIVE")], "en")

      refute Map.has_key?(change.changes, :status)
      assert Map.has_key?(change.changes, :vendor)
    end

    test "legacy products are covered by the same rule" do
      local = legacy_product(%{status: "active"})

      assert ProductDiff.diff([local], [shopify("ACTIVE")], "en") == []
    end
  end

  describe "legacy source — no merchant_status on the struct" do
    test "falls back to :status, which IS the merchant status there" do
      local = legacy_product(%{status: "draft"})

      [change] = ProductDiff.diff([local], [shopify("active")], "en")

      assert change.changes[:status] == %{current: "draft", incoming: "active"}
    end

    test "falls back to :status and reports nothing when it already agrees" do
      local = legacy_product(%{status: "active"})

      assert ProductDiff.diff([local], [shopify("active")], "en") == []
    end
  end
end
