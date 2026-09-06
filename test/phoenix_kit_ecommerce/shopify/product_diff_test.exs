defmodule PhoenixKitEcommerce.Shopify.ProductDiffTest do
  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.Product
  alias PhoenixKitEcommerce.Shopify.ProductDiff
  alias PhoenixKitEcommerce.Shopify.ProductDiff.Change

  @base_locale "en"

  defp product(overrides) do
    defaults = %Product{
      uuid: Ecto.UUID.generate(),
      slug: %{"en" => "planter"},
      title: %{"en" => "Planter"},
      body_html: %{"en" => "<p>Original</p>"},
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
        "title" => "Planter",
        "body_html" => "<p>Original</p>",
        "vendor" => "Acme",
        "tags" => "clay, garden",
        "status" => "active",
        "variants" => [%{"price" => "20.00"}]
      },
      overrides
    )
  end

  defp diff(local, shopify) do
    ProductDiff.diff(local, shopify, @base_locale)
  end

  describe "matching" do
    test "a Shopify product with no local handle match is skipped" do
      local = [product(slug: %{"en" => "planter"})]
      shopify = [shopify_product(%{"handle" => "unmatched-handle", "title" => "Something else"})]

      assert diff(local, shopify) == []
    end

    test "an identical matched product produces no change" do
      local = [product([])]
      shopify = [shopify_product(%{})]

      assert diff(local, shopify) == []
    end

    test "the returned Change carries the product uuid, handle, and a display title" do
      p = product(uuid: "fixed-uuid")
      local = [p]
      shopify = [shopify_product(%{"title" => "New Title"})]

      assert [%Change{} = change] = diff(local, shopify)
      assert change.product_uuid == "fixed-uuid"
      assert change.handle == "planter"
      assert change.title == "Planter"
      # Carried so `Shopify.Sync.apply_change/2` writes localized fields
      # back into the same locale this change was diffed against.
      assert change.base_locale == @base_locale
    end

    test "the returned Change carries the Shopify product id, even though it isn't a diffed field" do
      local = [product([])]
      # Any real field difference is enough to surface a Change — `id` is
      # carried regardless of which fields actually differ.
      shopify = [shopify_product(%{"id" => 987, "title" => "New Title"})]

      assert [%Change{product_id: 987}] = diff(local, shopify)
    end
  end

  describe "field: title" do
    test "changed title is included in changes" do
      local = [product(title: %{"en" => "Old Title"})]
      shopify = [shopify_product(%{"title" => "New Title"})]

      assert [%Change{changes: %{title: %{current: "Old Title", incoming: "New Title"}}}] =
               diff(local, shopify)
    end

    test "unchanged title does not appear in changes" do
      local = [product(title: %{"en" => "Same"})]
      shopify = [shopify_product(%{"title" => "Same"})]

      assert diff(local, shopify) == []
    end
  end

  describe "field: body_html" do
    test "changed body_html is included" do
      local = [product(body_html: %{"en" => "<p>Old</p>"})]
      shopify = [shopify_product(%{"body_html" => "<p>New</p>"})]

      assert [%Change{changes: %{body_html: %{current: "<p>Old</p>", incoming: "<p>New</p>"}}}] =
               diff(local, shopify)
    end

    test "unchanged body_html does not appear in changes" do
      local = [
        product(body_html: %{"en" => "<p>Same</p>"}, description: %{"en" => "Same"})
      ]

      shopify = [shopify_product(%{"body_html" => "<p>Same</p>"})]

      assert diff(local, shopify) == []
    end
  end

  describe "field: description" do
    test "description is derived by stripping the incoming body_html and compared to the local description" do
      local = [product(description: %{"en" => "Old description"})]
      shopify = [shopify_product(%{"body_html" => "<p>New description</p>"})]

      assert [
               %Change{
                 changes: %{
                   description: %{current: "Old description", incoming: "New description"}
                 }
               }
             ] =
               diff(local, shopify)
    end

    test "unchanged description does not appear in changes" do
      local = [product(description: %{"en" => "Same"}, body_html: %{"en" => "<p>Same</p>"})]
      shopify = [shopify_product(%{"body_html" => "<p>Same</p>"})]

      assert diff(local, shopify) == []
    end
  end

  describe "field: vendor" do
    test "changed vendor is included" do
      local = [product(vendor: "Old Co")]
      shopify = [shopify_product(%{"vendor" => "New Co"})]

      assert [%Change{changes: %{vendor: %{current: "Old Co", incoming: "New Co"}}}] =
               diff(local, shopify)
    end

    test "unchanged vendor does not appear in changes" do
      local = [product(vendor: "Same Co")]
      shopify = [shopify_product(%{"vendor" => "Same Co"})]

      assert diff(local, shopify) == []
    end
  end

  describe "field: status" do
    test "changed status is included" do
      local = [product(status: "draft")]
      shopify = [shopify_product(%{"status" => "active"})]

      assert [%Change{changes: %{status: %{current: "draft", incoming: "active"}}}] =
               diff(local, shopify)
    end

    test "unchanged status does not appear in changes" do
      local = [product(status: "archived")]
      shopify = [shopify_product(%{"status" => "archived"})]

      assert diff(local, shopify) == []
    end
  end

  describe "field: tags" do
    test "a real tag-set difference is included, with parsed incoming tags" do
      local = [product(tags: ["clay"])]
      shopify = [shopify_product(%{"tags" => "clay, garden"})]

      assert [%Change{changes: %{tags: %{current: ["clay"], incoming: ["clay", "garden"]}}}] =
               diff(local, shopify)
    end

    test "same tags in a different order produce no diff" do
      local = [product(tags: ["clay", "garden"])]
      shopify = [shopify_product(%{"tags" => "garden, clay"})]

      assert diff(local, shopify) == []
    end

    test "extra whitespace around incoming tags does not create a false diff" do
      local = [product(tags: ["clay", "garden"])]
      shopify = [shopify_product(%{"tags" => "  clay ,  garden  "})]

      assert diff(local, shopify) == []
    end

    test "a nil local tags list is treated as empty, not a crash" do
      local = [product(tags: nil)]
      shopify = [shopify_product(%{"tags" => "clay, garden"})]

      assert [%Change{changes: %{tags: %{current: [], incoming: ["clay", "garden"]}}}] =
               diff(local, shopify)
    end
  end

  describe "field: price" do
    test "a changed price is included, using the minimum variant price" do
      local = [product(price: Decimal.new("20.00"))]

      shopify = [
        shopify_product(%{
          "variants" => [%{"price" => "30.00"}, %{"price" => "25.00"}]
        })
      ]

      assert [%Change{changes: %{price: %{current: current, incoming: incoming}}}] =
               diff(local, shopify)

      assert Decimal.eq?(current, "20.00")
      assert Decimal.eq?(incoming, "25.00")
    end

    test "unchanged price does not appear in changes" do
      local = [product(price: Decimal.new("20.00"))]
      shopify = [shopify_product(%{"variants" => [%{"price" => "20.00"}]})]

      assert diff(local, shopify) == []
    end

    test "no variants means price is not compared at all" do
      local = [product(price: Decimal.new("20.00"))]
      shopify = [shopify_product(%{"variants" => []})]

      assert diff(local, shopify) == []
    end

    test "a nil local price against an incoming price is reported as a change, not a crash" do
      local = [product(price: nil)]
      shopify = [shopify_product(%{"variants" => [%{"price" => "20.00"}]})]

      assert [%Change{changes: %{price: %{current: nil, incoming: incoming}}}] =
               diff(local, shopify)

      assert Decimal.eq?(incoming, "20.00")
    end
  end

  describe "field: compare_at_price" do
    test "a changed compare_at_price is included, using the minimum variant compare_at_price" do
      local = [product(compare_at_price: Decimal.new("30.00"))]

      shopify = [
        shopify_product(%{
          "variants" => [
            %{"price" => "20.00", "compare_at_price" => "45.00"},
            %{"price" => "20.00", "compare_at_price" => "40.00"}
          ]
        })
      ]

      assert [%Change{changes: %{compare_at_price: %{current: current, incoming: incoming}}}] =
               diff(local, shopify)

      assert Decimal.eq?(current, "30.00")
      assert Decimal.eq?(incoming, "40.00")
    end

    test "unchanged compare_at_price does not appear in changes" do
      local = [product(compare_at_price: Decimal.new("30.00"))]

      shopify = [
        shopify_product(%{"variants" => [%{"price" => "20.00", "compare_at_price" => "30.00"}]})
      ]

      assert diff(local, shopify) == []
    end

    test "no variant carrying compare_at_price means it is not compared at all" do
      local = [product(compare_at_price: Decimal.new("30.00"))]
      shopify = [shopify_product(%{"variants" => [%{"price" => "20.00"}]})]

      assert diff(local, shopify) == []
    end

    test "a nil local compare_at_price against an incoming value is reported as a change" do
      local = [product(compare_at_price: nil)]

      shopify = [
        shopify_product(%{"variants" => [%{"price" => "20.00", "compare_at_price" => "35.00"}]})
      ]

      assert [%Change{changes: %{compare_at_price: %{current: nil, incoming: incoming}}}] =
               diff(local, shopify)

      assert Decimal.eq?(incoming, "35.00")
    end
  end

  describe "matching: catalogue view-struct handle" do
    # `ProductSource.Catalogue.View` writes `metadata["_shopify"]["handle"]`
    # from `data["ecommerce"]["shopify"]["handle"]` on every catalogue
    # view-struct — matching must prefer it over `slug[base_locale]`,
    # since a catalogue item's slug is a URL, not necessarily the Shopify
    # handle it was migrated from.
    test "a product with metadata._shopify.handle matches by that, not by slug" do
      local = [
        product(
          slug: %{"en" => "totally-different-url-slug"},
          metadata: %{"_shopify" => %{"handle" => "original-shopify-handle"}}
        )
      ]

      shopify = [shopify_product(%{"handle" => "original-shopify-handle", "title" => "New"})]

      assert [%Change{handle: "original-shopify-handle"}] = diff(local, shopify)
    end

    test "falls back to slug[base_locale] when metadata carries no _shopify handle" do
      local = [product(slug: %{"en" => "planter"}, metadata: %{})]
      shopify = [shopify_product(%{"title" => "New"})]

      assert [%Change{handle: "planter"}] = diff(local, shopify)
    end
  end

  describe "new_product_changes/3" do
    test "a Shopify handle with no local match becomes a create-Change" do
      local = [product(slug: %{"en" => "planter"})]

      shopify = [
        shopify_product(%{}),
        %{"handle" => "brand-new-mug", "title" => "Brand New Mug"}
      ]

      assert [change] = ProductDiff.new_product_changes(local, shopify, @base_locale)

      assert change.create?
      assert change.product_uuid == nil
      assert change.handle == "brand-new-mug"
      assert change.title == "Brand New Mug"
      assert change.changes == %{}
      assert change.shopify_product == %{"handle" => "brand-new-mug", "title" => "Brand New Mug"}
    end

    test "carries the Shopify product id on a create-Change too" do
      local = [product(slug: %{"en" => "planter"})]

      shopify = [
        shopify_product(%{}),
        %{"handle" => "brand-new-mug", "title" => "Brand New Mug", "id" => 42}
      ]

      assert [change] = ProductDiff.new_product_changes(local, shopify, @base_locale)
      assert change.product_id == 42
    end

    test "a Shopify handle already matched by diff/4 is not surfaced as a create-Change" do
      local = [product(slug: %{"en" => "planter"})]
      shopify = [shopify_product(%{})]

      assert ProductDiff.new_product_changes(local, shopify, @base_locale) == []
    end

    test "a Shopify entry with no handle at all is skipped, not surfaced as a create-Change" do
      local = [product(slug: %{"en" => "planter"})]
      shopify = [shopify_product(%{}), %{"title" => "No handle at all"}]

      assert ProductDiff.new_product_changes(local, shopify, @base_locale) == []
    end
  end

  describe "price_extreme?" do
    test "flags a price change whose ratio exceeds 3x" do
      local = [product(price: Decimal.new("10.00"))]
      shopify = [shopify_product(%{"variants" => [%{"price" => "40.00"}]})]

      assert [%Change{price_extreme?: true}] = diff(local, shopify)
    end

    test "does not flag a price change within 3x" do
      local = [product(price: Decimal.new("10.00"))]
      shopify = [shopify_product(%{"variants" => [%{"price" => "25.00"}]})]

      assert [%Change{price_extreme?: false}] = diff(local, shopify)
    end

    test "is false when price did not change, even if other fields did" do
      local = [product(price: Decimal.new("10.00"), vendor: "Old Co")]

      shopify = [
        shopify_product(%{"vendor" => "New Co", "variants" => [%{"price" => "10.00"}]})
      ]

      assert [%Change{price_extreme?: false, changes: changes}] = diff(local, shopify)
      refute Map.has_key?(changes, :price)
    end
  end

  describe "comparable_fields/0" do
    test "returns the exact field list diff/4 compares by default" do
      # Pinned literally, not derived from the module's own attribute —
      # `Source` treats this function as the source of truth for "every
      # field", so its return value needs a real assertion, not a
      # tautology (`@x ProductDiff.comparable_fields()` followed by
      # `assert ... == @x` proves nothing about what it actually returns).
      assert ProductDiff.comparable_fields() == [
               :title,
               :body_html,
               :description,
               :vendor,
               :tags,
               :status,
               :price,
               :compare_at_price
             ]
    end

    test "is genuinely equivalent to diff/4's implicit default, on a product differing in every field" do
      local = [product([])]

      shopify = [
        %{
          "handle" => "planter",
          "title" => "New Title",
          "body_html" => "<p>New body</p>",
          "vendor" => "NewVendor",
          "tags" => "new, tags",
          "status" => "draft",
          "variants" => [%{"price" => "99.00", "compare_at_price" => "150.00"}]
        }
      ]

      explicit =
        ProductDiff.diff(local, shopify, @base_locale, only: ProductDiff.comparable_fields())

      # `diff/2` (this file's helper) already omits `only:` — the case
      # that matters is that passing the function's own output back in
      # behaves exactly like never having passed `only:` at all.
      assert explicit == diff(local, shopify)

      # Guards against a vacuous pass: confirm every comparable field
      # actually differed, so a `comparable_fields/0` missing one of them
      # would make this fail rather than silently pass on 6 out of 7.
      assert [change] = explicit
      assert Enum.sort(Map.keys(change.changes)) == Enum.sort(ProductDiff.comparable_fields())
    end
  end

  describe "diff/4 with :only" do
    test "compares just the listed fields and ignores the rest" do
      local = [product(title: %{"en" => "Real title"}, price: Decimal.new("10.00"))]
      # Storefront-shaped product: handle and variants only, no title key.
      shopify = [%{"handle" => "planter", "variants" => [%{"price" => "12.00"}]}]

      assert [change] = ProductDiff.diff(local, shopify, @base_locale, only: [:price])

      assert Enum.sort(Map.keys(change.changes)) == [:price]
      assert Decimal.eq?(change.changes.price.incoming, Decimal.new("12.00"))
    end

    test "without :only the same input reports a bogus title deletion" do
      local = [product(title: %{"en" => "Real title"}, price: Decimal.new("10.00"))]
      shopify = [%{"handle" => "planter", "variants" => [%{"price" => "12.00"}]}]

      assert [change] = ProductDiff.diff(local, shopify, @base_locale)

      # This is the trap :only exists to avoid. Asserted so the reason this
      # option exists cannot be refactored away silently.
      assert change.changes.title.incoming == nil
    end

    test "only: [] filters out every field, so no changes are ever reported" do
      local = [product(title: %{"en" => "Real title"}, price: Decimal.new("10.00"))]
      shopify = [%{"handle" => "planter", "variants" => [%{"price" => "12.00"}]}]

      assert ProductDiff.diff(local, shopify, @base_locale, only: []) == []
    end

    test "an unknown opts key raises instead of silently comparing every field" do
      local = [product(title: %{"en" => "Real title"}, price: Decimal.new("10.00"))]
      shopify = [%{"handle" => "planter", "variants" => [%{"price" => "12.00"}]}]

      assert_raise ArgumentError, fn ->
        ProductDiff.diff(local, shopify, @base_locale, onlyy: [:price])
      end
    end

    # A typo'd KEY (`onlyy:`, above) already raised. A typo'd VALUE inside
    # a real `:only` (`:titel` for `:title`) is the more dangerous mistake
    # for a sync tool: `field not in only` is true for every real field
    # name, so every product silently reports zero changes — a catalog
    # that was never actually compared reads as "in sync". Must raise
    # instead, same as the key typo.
    test "an unrecognized field atom inside :only raises instead of silently comparing nothing" do
      local = [product(title: %{"en" => "Real title"}, price: Decimal.new("10.00"))]
      shopify = [%{"handle" => "planter", "title" => "Different title"}]

      assert_raise ArgumentError, fn ->
        ProductDiff.diff(local, shopify, @base_locale, only: [:titel])
      end

      # Confirm the correctly-spelled field really would have reported a
      # change — proof this is "reports nothing" going wrong, not merely
      # a coincidence of this fixture never differing.
      assert [_change] = ProductDiff.diff(local, shopify, @base_locale, only: [:title])
    end

    test "a non-string base_locale raises instead of silently matching nothing" do
      local = [product([])]
      shopify = [shopify_product(%{})]

      assert_raise FunctionClauseError, fn ->
        ProductDiff.diff(local, shopify, only: [:price])
      end
    end
  end

  describe "matched_count/3" do
    test "counts a match with no field difference — diff/4 would report zero changes for it" do
      local = [product(slug: %{"en" => "planter"})]
      shopify = [shopify_product(%{})]

      assert ProductDiff.diff(local, shopify, @base_locale) == []
      assert ProductDiff.matched_count(local, shopify, @base_locale) == 1
    end

    test "does not count a local product with no matching Shopify handle" do
      local = [
        product(slug: %{"en" => "planter"}),
        product(slug: %{"en" => "no-such-shopify-product"})
      ]

      shopify = [shopify_product(%{})]

      assert ProductDiff.matched_count(local, shopify, @base_locale) == 1
    end

    test "does not count a Shopify handle with no local match" do
      local = [product(slug: %{"en" => "planter"})]

      shopify = [
        shopify_product(%{}),
        shopify_product(%{"handle" => "no-local-product"})
      ]

      assert ProductDiff.matched_count(local, shopify, @base_locale) == 1
    end

    # The property `Sync.check/2`'s coverage figure actually needs: the
    # matched count is independent of how many fields differ (unlike
    # `length(diff/4's result)`) and independent of the local catalog's
    # total size (unlike counting every local product).
    test "matched count is neither the diff count nor the total local product count" do
      matched_no_diff = product(slug: %{"en" => "matched-no-diff"})
      matched_with_diff = product(slug: %{"en" => "matched-with-diff"}, vendor: "Old Co")
      unmatched = product(slug: %{"en" => "unmatched"})

      local = [matched_no_diff, matched_with_diff, unmatched]

      shopify = [
        shopify_product(%{"handle" => "matched-no-diff"}),
        shopify_product(%{"handle" => "matched-with-diff", "vendor" => "New Co"}),
        shopify_product(%{"handle" => "some-shopify-only-product"})
      ]

      changes = ProductDiff.diff(local, shopify, @base_locale)
      assert length(changes) == 1

      assert ProductDiff.matched_count(local, shopify, @base_locale) == 2
    end

    # `index_by_handle/2` maps a handle to a single local product, so
    # duplicate handles in the Shopify list can only ever point back to
    # the SAME local product — dedup by product uuid, not by raw entry
    # count, so a Shopify listing with a repeated handle doesn't inflate
    # coverage.
    test "counts a matched local product once even if the Shopify list has its handle twice" do
      local = [product(slug: %{"en" => "planter"})]
      shopify = [shopify_product(%{}), shopify_product(%{})]

      assert ProductDiff.matched_count(local, shopify, @base_locale) == 1
    end
  end
end
