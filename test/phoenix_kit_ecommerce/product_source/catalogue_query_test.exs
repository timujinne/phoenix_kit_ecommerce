defmodule PhoenixKitEcommerce.ProductSource.Catalogue.QueryTest do
  use PhoenixKitEcommerce.DataCase, async: false

  # Needs `phoenix_kit_catalogue` loaded (with its own migrations applied
  # to the test DB) — excluded via `test_helper.exs`'s
  # `ExUnit.configure(exclude: ...)` whenever the optional dependency
  # isn't present. `async: false`: `Query.catalogue_uuid/0` resolves the
  # shop's one catalogue by NAME across the whole test DB, so two async
  # tests both bootstrapping a catalogue named "decor3dprint" would race.
  @moduletag :catalogue

  # Quiets the compiler's static xref check for `mix test` runs where the
  # optional `phoenix_kit_catalogue` dependency isn't declared — every
  # test in this module is excluded in that case (see `test_helper.exs`),
  # so the calls below are never actually reached.
  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce.ProductSource.Catalogue.Query
  alias PhoenixKitEcommerce.ProductSource.Catalogue.View

  setup do
    {:ok, catalogue} = Catalogue.create_catalogue(%{name: "decor3dprint"})
    %{catalogue: catalogue}
  end

  defp create_item(catalogue, attrs) do
    {:ok, item} =
      Catalogue.create_item(Map.merge(%{catalogue_uuid: catalogue.uuid}, attrs))

    item
  end

  describe "list_items/1" do
    test "filters by status (item.status active AND shop_status active) and search", %{
      catalogue: catalogue
    } do
      create_item(catalogue, %{
        name: "Red Vase",
        base_price: Decimal.new("10.00"),
        status: "active",
        data: %{"ecommerce" => %{"shop_status" => "active"}}
      })

      create_item(catalogue, %{
        name: "Blue Vase",
        base_price: Decimal.new("15.00"),
        status: "active",
        data: %{"ecommerce" => %{"shop_status" => "draft"}}
      })

      create_item(catalogue, %{
        name: "Green Bowl",
        base_price: Decimal.new("20.00"),
        status: "active",
        data: %{"ecommerce" => %{"shop_status" => "active"}}
      })

      results = Query.list_items(status: "active", search: "vase")

      assert Enum.map(results, & &1.name) == ["Red Vase"]
    end

    test "search matches a non-primary language bucket's _name / _description, like the legacy adapter",
         %{catalogue: catalogue} do
      create_item(catalogue, %{
        name: "Red Vase",
        base_price: Decimal.new("10.00"),
        status: "active",
        data: %{
          "_primary_language" => "en-US",
          "en-US" => %{"_name" => "Red Vase", "_description" => "A red vase"},
          "fr-FR" => %{"_name" => "Vase Rouge", "_description" => "Un vase en céramique"},
          "ecommerce" => %{"shop_status" => "active"}
        }
      })

      create_item(catalogue, %{
        name: "Green Bowl",
        base_price: Decimal.new("20.00"),
        status: "active",
        data: %{
          "_primary_language" => "en-US",
          "en-US" => %{"_name" => "Green Bowl"},
          "ecommerce" => %{"shop_status" => "active"}
        }
      })

      assert Enum.map(Query.list_items(search: "rouge"), & &1.name) == ["Red Vase"]
      assert Enum.map(Query.list_items(search: "céramique"), & &1.name) == ["Red Vase"]
      # Scalar top-level keys (`_primary_language`) are skipped, never matched on.
      assert Query.list_items(search: "en-US") == []
      # LIKE metacharacters stay literal.
      assert Query.list_items(search: "%") == []
    end

    test "status: \"archived\" returns a retired item with a stale shop_status: active, matching View.product_status/2",
         %{catalogue: catalogue} do
      retired =
        create_item(catalogue, %{
          name: "Retired",
          base_price: Decimal.new("10.00"),
          status: "discontinued",
          data: %{"ecommerce" => %{"shop_status" => "active"}}
        })

      create_item(catalogue, %{
        name: "Live",
        base_price: Decimal.new("10.00"),
        status: "active",
        data: %{"ecommerce" => %{"shop_status" => "active"}}
      })

      create_item(catalogue, %{
        name: "Drafted",
        base_price: Decimal.new("10.00"),
        status: "active",
        data: %{"ecommerce" => %{"shop_status" => "draft"}}
      })

      assert Enum.map(Query.list_items(status: "archived"), & &1.name) == ["Retired"]
      assert Enum.map(Query.list_items(status: "draft"), & &1.name) == ["Drafted"]
      assert Enum.map(Query.list_items(status: "active"), & &1.name) == ["Live"]

      assert View.product_view(retired, sets: [], base_currency: "USD", languages: []).status ==
               "archived"
    end

    test "a pre-resolved catalogue_uuid is used as-is, nil included", %{catalogue: catalogue} do
      create_item(catalogue, %{name: "Ours", base_price: Decimal.new("1.00")})

      assert Enum.map(Query.list_items(catalogue_uuid: catalogue.uuid), & &1.name) == ["Ours"]
      assert Query.list_items(catalogue_uuid: nil) == []
      assert Query.list_items_with_count(catalogue_uuid: nil) == {[], 0}
      assert Query.list_categories(catalogue_uuid: nil) == []
    end

    test "filters by price range and vendor", %{catalogue: catalogue} do
      create_item(catalogue, %{
        name: "Cheap",
        base_price: Decimal.new("5.00"),
        data: %{"ecommerce" => %{"shop_status" => "active", "vendor" => "Acme"}}
      })

      create_item(catalogue, %{
        name: "Mid",
        base_price: Decimal.new("15.00"),
        data: %{"ecommerce" => %{"shop_status" => "active", "vendor" => "Acme"}}
      })

      create_item(catalogue, %{
        name: "Pricey",
        base_price: Decimal.new("50.00"),
        data: %{"ecommerce" => %{"shop_status" => "active", "vendor" => "Other"}}
      })

      by_price =
        Query.list_items(price_min: Decimal.new("10.00"), price_max: Decimal.new("20.00"))

      assert Enum.map(by_price, & &1.name) == ["Mid"]

      by_vendor = Query.list_items(vendors: ["Acme"])
      assert Enum.map(by_vendor, & &1.name) |> Enum.sort() == ["Cheap", "Mid"]
    end

    test "paginates and counts", %{catalogue: catalogue} do
      for n <- 1..5 do
        create_item(catalogue, %{
          name: "Item #{n}",
          base_price: Decimal.new("1.00"),
          data: %{"ecommerce" => %{"shop_status" => "active"}}
        })
      end

      assert {_, 5} = Query.list_items_with_count(status: "active")

      {page1, total} = Query.list_items_with_count(status: "active", page: 1, per_page: 2)
      assert total == 5
      assert length(page1) == 2
    end

    test "status: \"active\" falls back to item.status when shop_status is absent, matching View.product_status/2",
         %{catalogue: catalogue} do
      no_shop_status =
        create_item(catalogue, %{name: "No Shop Status", base_price: Decimal.new("1.00")})

      inactive_item =
        create_item(catalogue, %{
          name: "Inactive",
          base_price: Decimal.new("1.00"),
          status: "inactive"
        })

      results = Query.list_items(status: "active")

      assert no_shop_status.uuid in Enum.map(results, & &1.uuid)
      refute inactive_item.uuid in Enum.map(results, & &1.uuid)
    end

    test "exclude_hidden_categories: true keeps position/name ordering (no DISTINCT ON uuid)",
         %{catalogue: catalogue} do
      {:ok, category} =
        Catalogue.create_category(%{name: "Shown", catalogue_uuid: catalogue.uuid})

      later =
        create_item(catalogue, %{
          name: "Zebra",
          position: 2,
          category_uuid: category.uuid,
          base_price: Decimal.new("1.00"),
          data: %{"ecommerce" => %{"shop_status" => "active"}}
        })

      earlier =
        create_item(catalogue, %{
          name: "Apple",
          position: 1,
          category_uuid: category.uuid,
          base_price: Decimal.new("1.00"),
          data: %{"ecommerce" => %{"shop_status" => "active"}}
        })

      names =
        Query.list_items(status: "active", exclude_hidden_categories: true)
        |> Enum.map(& &1.name)

      assert names == [earlier.name, later.name]
    end

    test "filters by product_type with the same physical default as View.product_view/2", %{
      catalogue: catalogue
    } do
      physical =
        create_item(catalogue, %{
          name: "Mug",
          base_price: Decimal.new("1.00"),
          data: %{"ecommerce" => %{"shop_status" => "active"}}
        })

      digital =
        create_item(catalogue, %{
          name: "PDF",
          base_price: Decimal.new("1.00"),
          data: %{"ecommerce" => %{"shop_status" => "active", "product_type" => "digital"}}
        })

      names =
        Query.list_items(status: "active", product_type: "physical") |> Enum.map(& &1.name)

      assert physical.name in names
      refute digital.name in names
    end
  end

  describe "price_range/1 and vendor_counts/1" do
    test "aggregate over active items", %{catalogue: catalogue} do
      create_item(catalogue, %{
        name: "A",
        base_price: Decimal.new("10.00"),
        data: %{"ecommerce" => %{"shop_status" => "active", "vendor" => "Acme"}}
      })

      create_item(catalogue, %{
        name: "B",
        base_price: Decimal.new("30.00"),
        data: %{"ecommerce" => %{"shop_status" => "active", "vendor" => "Acme"}}
      })

      assert Query.price_range() == {Decimal.new("10.00"), Decimal.new("30.00")}
      assert [%{value: "Acme", count: 2}] = Query.vendor_counts()
    end

    test "an item with no shop_status is counted, matching the listing fallback", %{
      catalogue: catalogue
    } do
      {:ok, category} =
        Catalogue.create_category(%{name: "Counted", catalogue_uuid: catalogue.uuid})

      create_item(catalogue, %{
        name: "No Shop Status",
        base_price: Decimal.new("12.00"),
        category_uuid: category.uuid
      })

      assert Query.product_counts_by_category()[category.uuid] == 1
      assert Query.price_range() == {Decimal.new("12.00"), Decimal.new("12.00")}
    end

    # Regression: `filter_by_status(query, "active")` (backs `list_items/1`)
    # and `active_visibility/1` (backs `product_counts_by_category/0`,
    # `price_range/1`, `vendor_counts/1`, the facet counters) both claim to
    # express the SAME "storefront-visible" rule and must agree on every
    # item, including one with no `shop_status` at all — a real shape
    # (10 of the owner's 20 catalogue categories have no `ecommerce` block
    # either). They once diverged: `active_visibility/1` tested a literal
    # `shop_status = 'active'` with no `COALESCE`, so an absent shop_status
    # counted as active in the listing but NOT active in the counts/facets.
    # Fixed upstream (`Fix post-merge review findings`, 0.5.0), pinned here
    # so a future edit to either function that reintroduces the divergence
    # fails a test rather than only showing up as a live count mismatch.
    test "filter_by_status(\"active\") and active_visibility/1 agree on an item with no shop_status",
         %{catalogue: catalogue} do
      {:ok, category} =
        Catalogue.create_category(%{name: "Agreement", catalogue_uuid: catalogue.uuid})

      create_item(catalogue, %{
        name: "No Shop Status Block",
        base_price: Decimal.new("7.00"),
        status: "active",
        category_uuid: category.uuid
      })

      assert Enum.map(Query.list_items(status: "active"), & &1.name) ==
               ["No Shop Status Block"]

      assert Query.product_counts_by_category()[category.uuid] == 1
    end

    test "exclude_hidden_categories drops hidden-category items from vendor counts and price_range",
         %{catalogue: catalogue} do
      {:ok, hidden} =
        Catalogue.create_category(%{
          name: "Hidden",
          catalogue_uuid: catalogue.uuid,
          data: %{"ecommerce" => %{"shop_status" => "hidden"}}
        })

      {:ok, shown} =
        Catalogue.create_category(%{
          name: "Shown",
          catalogue_uuid: catalogue.uuid,
          data: %{"ecommerce" => %{"shop_status" => "active"}}
        })

      create_item(catalogue, %{
        name: "Hidden Item",
        base_price: Decimal.new("99.00"),
        category_uuid: hidden.uuid,
        data: %{"ecommerce" => %{"shop_status" => "active", "vendor" => "HiddenCo"}}
      })

      create_item(catalogue, %{
        name: "Shown Item",
        base_price: Decimal.new("10.00"),
        category_uuid: shown.uuid,
        data: %{"ecommerce" => %{"shop_status" => "active", "vendor" => "ShownCo"}}
      })

      assert Query.price_range(exclude_hidden_categories: true) ==
               {Decimal.new("10.00"), Decimal.new("10.00")}

      assert [%{value: "ShownCo", count: 1}] =
               Query.vendor_counts(exclude_hidden_categories: true)
    end
  end

  describe "slug lookups" do
    test "get_item_by_slug + View.product_view round-trips a real item", %{catalogue: catalogue} do
      item =
        create_item(catalogue, %{
          name: "Vase Rouge",
          base_price: Decimal.new("23.76"),
          slug: %{"fr-FR" => "vase-rouge"},
          data: %{"ecommerce" => %{"shop_status" => "active"}}
        })

      assert {:ok, found} = Catalogue.get_item_by_slug("vase-rouge", "fr-FR")
      assert found.uuid == item.uuid

      product = View.product_view(found, sets: [])
      assert product.price == Decimal.new("23.76")
    end
  end

  describe "list_categories/1" do
    test "scoped to the shop catalogue", %{catalogue: catalogue} do
      {:ok, category} =
        Catalogue.create_category(%{name: "Vases", catalogue_uuid: catalogue.uuid})

      {:ok, other_catalogue} = Catalogue.create_catalogue(%{name: "Warehouse Stock"})
      Catalogue.create_category(%{name: "Shelving", catalogue_uuid: other_catalogue.uuid})

      assert Enum.map(Query.list_categories(), & &1.name) == [category.name]
    end

    test "status/statuses filter the ecommerce shop_status (active|unlisted|hidden), not the catalogue's own status column",
         %{catalogue: catalogue} do
      {:ok, active} =
        Catalogue.create_category(%{
          name: "Active Cat",
          catalogue_uuid: catalogue.uuid,
          data: %{"ecommerce" => %{"shop_status" => "active"}}
        })

      {:ok, unlisted} =
        Catalogue.create_category(%{
          name: "Unlisted Cat",
          catalogue_uuid: catalogue.uuid,
          data: %{"ecommerce" => %{"shop_status" => "unlisted"}}
        })

      {:ok, hidden} =
        Catalogue.create_category(%{
          name: "Hidden Cat",
          catalogue_uuid: catalogue.uuid,
          data: %{"ecommerce" => %{"shop_status" => "hidden"}}
        })

      assert Enum.map(Query.list_categories(status: "active"), & &1.name) == [active.name]

      assert Query.list_categories(status: ["active", "unlisted"])
             |> Enum.map(& &1.name)
             |> Enum.sort() == Enum.sort([active.name, unlisted.name])

      refute hidden.name in Enum.map(Query.list_categories(status: "active"), & &1.name)
    end

    test "search matches the primary name and any language bucket's _name (admin category search box)",
         %{catalogue: catalogue} do
      {:ok, _} =
        Catalogue.create_category(%{
          name: "Vases",
          catalogue_uuid: catalogue.uuid,
          data: %{
            "_primary_language" => "en-US",
            "en-US" => %{"_name" => "Vases"},
            "fr-FR" => %{"_name" => "Vases en céramique"}
          }
        })

      {:ok, _} = Catalogue.create_category(%{name: "Shelving", catalogue_uuid: catalogue.uuid})

      assert Enum.map(Query.list_categories(search: "vase"), & &1.name) == ["Vases"]
      assert Enum.map(Query.list_categories(search: "céramique"), & &1.name) == ["Vases"]
      assert Query.list_categories(search: "%") == []
      assert length(Query.list_categories(search: "")) == 2
    end

    test "a category with no shop_status defaults to active", %{catalogue: catalogue} do
      {:ok, category} =
        Catalogue.create_category(%{name: "No Shop Status", catalogue_uuid: catalogue.uuid})

      assert Enum.map(Query.list_categories(status: "active"), & &1.name) == [category.name]
    end

    test "a catalogue-deleted category is excluded even with a stale shop_status: active",
         %{catalogue: catalogue} do
      {:ok, deleted} =
        Catalogue.create_category(%{
          name: "Ghost Cat",
          catalogue_uuid: catalogue.uuid,
          status: "deleted",
          data: %{"ecommerce" => %{"shop_status" => "active"}}
        })

      refute deleted.name in Enum.map(Query.list_categories(status: "active"), & &1.name)
    end
  end

  describe "list_items_by_uuids/1 and list_categories_by_uuids/1" do
    test "scoped to the shop catalogue — an item/category from another catalogue is dropped",
         %{catalogue: catalogue} do
      item = create_item(catalogue, %{name: "Ours", base_price: Decimal.new("1.00")})

      {:ok, category} =
        Catalogue.create_category(%{name: "Ours Cat", catalogue_uuid: catalogue.uuid})

      {:ok, other_catalogue} = Catalogue.create_catalogue(%{name: "Warehouse Stock"})

      other_item =
        create_item(other_catalogue, %{name: "Theirs", base_price: Decimal.new("1.00")})

      {:ok, other_category} =
        Catalogue.create_category(%{name: "Theirs Cat", catalogue_uuid: other_catalogue.uuid})

      assert Enum.map(Query.list_items_by_uuids([item.uuid, other_item.uuid]), & &1.uuid) == [
               item.uuid
             ]

      assert Enum.map(
               Query.list_categories_by_uuids([category.uuid, other_category.uuid]),
               & &1.uuid
             ) == [category.uuid]
    end
  end

  describe "resolve_category_images/1" do
    test "an explicit featured_item_uuid resolves to that item's own featured_image_uuid",
         %{catalogue: catalogue} do
      item =
        create_item(catalogue, %{
          name: "Vase",
          base_price: Decimal.new("1.00"),
          data: %{"featured_image_uuid" => "img-explicit"}
        })

      {:ok, category} =
        Catalogue.create_category(%{
          name: "Vases",
          catalogue_uuid: catalogue.uuid,
          data: %{"ecommerce" => %{"featured_item_uuid" => item.uuid}}
        })

      assert Query.resolve_category_images([category]) == %{category.uuid => "img-explicit"}
    end

    test "an explicit featured_item_uuid falls back to the first media_order entry when the item has no featured_image_uuid",
         %{catalogue: catalogue} do
      item =
        create_item(catalogue, %{
          name: "Vase",
          base_price: Decimal.new("1.00"),
          data: %{"media_order" => ["img-from-media-order", "img-second"]}
        })

      {:ok, category} =
        Catalogue.create_category(%{
          name: "Vases",
          catalogue_uuid: catalogue.uuid,
          data: %{"ecommerce" => %{"featured_item_uuid" => item.uuid}}
        })

      assert Query.resolve_category_images([category]) == %{
               category.uuid => "img-from-media-order"
             }
    end

    test "an explicit featured item with no image never falls back to auto-detect",
         %{catalogue: catalogue} do
      {:ok, category} =
        Catalogue.create_category(%{name: "Cat", catalogue_uuid: catalogue.uuid})

      featured_no_image =
        create_item(catalogue, %{
          name: "Featured No Image",
          base_price: Decimal.new("1.00"),
          category_uuid: category.uuid,
          position: 0,
          data: %{"ecommerce" => %{"shop_status" => "active"}}
        })

      create_item(catalogue, %{
        name: "Other With Image",
        base_price: Decimal.new("1.00"),
        category_uuid: category.uuid,
        position: 1,
        data: %{
          "ecommerce" => %{"shop_status" => "active"},
          "featured_image_uuid" => "img-other"
        }
      })

      {:ok, category} =
        Catalogue.update_category(category, %{
          data: %{"ecommerce" => %{"featured_item_uuid" => featured_no_image.uuid}}
        })

      assert Query.resolve_category_images([category]) == %{}
    end

    test "with no explicit featured item, auto-detects the first active item (by position) that carries an image",
         %{catalogue: catalogue} do
      {:ok, category} =
        Catalogue.create_category(%{name: "Cat", catalogue_uuid: catalogue.uuid})

      create_item(catalogue, %{
        name: "First, no image",
        base_price: Decimal.new("1.00"),
        category_uuid: category.uuid,
        position: 0,
        data: %{"ecommerce" => %{"shop_status" => "active"}}
      })

      create_item(catalogue, %{
        name: "Second, inactive but has image",
        base_price: Decimal.new("1.00"),
        category_uuid: category.uuid,
        position: 1,
        status: "inactive",
        data: %{
          "ecommerce" => %{"shop_status" => "active"},
          "featured_image_uuid" => "img-inactive"
        }
      })

      create_item(catalogue, %{
        name: "Third, active with image",
        base_price: Decimal.new("1.00"),
        category_uuid: category.uuid,
        position: 2,
        data: %{
          "ecommerce" => %{"shop_status" => "active"},
          "featured_image_uuid" => "img-third"
        }
      })

      assert Query.resolve_category_images([category]) == %{category.uuid => "img-third"}
    end

    test "a category with no items (or none carrying an image) has no entry in the result",
         %{catalogue: catalogue} do
      {:ok, empty_category} =
        Catalogue.create_category(%{name: "Empty", catalogue_uuid: catalogue.uuid})

      {:ok, no_image_category} =
        Catalogue.create_category(%{name: "No Images", catalogue_uuid: catalogue.uuid})

      create_item(catalogue, %{
        name: "No Image Item",
        base_price: Decimal.new("1.00"),
        category_uuid: no_image_category.uuid,
        data: %{"ecommerce" => %{"shop_status" => "active"}}
      })

      assert Query.resolve_category_images([empty_category, no_image_category]) == %{}
    end

    test "auto-detect orders by position, then name, and picks the first item that carries an image",
         %{catalogue: catalogue} do
      {:ok, category} =
        Catalogue.create_category(%{name: "Cat", catalogue_uuid: catalogue.uuid})

      # The position-1 item sorts FIRST by name, so an ORDER BY that dropped
      # `position` would pick it; the B/A pair at position 0 pins the name
      # tie-break the same way.
      for {name, position, image} <- [
            {"A later position", 1, "img-later-position"},
            {"B same position", 0, "img-b"},
            {"A same position", 0, "img-a"}
          ] do
        create_item(catalogue, %{
          name: name,
          base_price: Decimal.new("1.00"),
          category_uuid: category.uuid,
          position: position,
          data: %{"featured_image_uuid" => image}
        })
      end

      assert Query.resolve_category_images([category]) == %{category.uuid => "img-a"}
    end

    test "auto-detect resolves each category independently from its own items",
         %{catalogue: catalogue} do
      {:ok, cat_a} = Catalogue.create_category(%{name: "Cat A", catalogue_uuid: catalogue.uuid})
      {:ok, cat_b} = Catalogue.create_category(%{name: "Cat B", catalogue_uuid: catalogue.uuid})
      {:ok, cat_c} = Catalogue.create_category(%{name: "Cat C", catalogue_uuid: catalogue.uuid})

      create_item(catalogue, %{
        name: "A1",
        base_price: Decimal.new("1.00"),
        category_uuid: cat_a.uuid,
        position: 1,
        data: %{"featured_image_uuid" => "img-a1"}
      })

      create_item(catalogue, %{
        name: "A0 no image",
        base_price: Decimal.new("1.00"),
        category_uuid: cat_a.uuid,
        position: 0
      })

      create_item(catalogue, %{
        name: "B0",
        base_price: Decimal.new("1.00"),
        category_uuid: cat_b.uuid,
        position: 0,
        data: %{"media_order" => ["img-b0"]}
      })

      create_item(catalogue, %{
        name: "C0 no image",
        base_price: Decimal.new("1.00"),
        category_uuid: cat_c.uuid,
        position: 0
      })

      assert Query.resolve_category_images([cat_a, cat_b, cat_c]) == %{
               cat_a.uuid => "img-a1",
               cat_b.uuid => "img-b0"
             }
    end

    test "auto-detect prefers featured_image_uuid over media_order, and falls back to media_order when it is empty",
         %{catalogue: catalogue} do
      {:ok, featured_cat} =
        Catalogue.create_category(%{name: "Featured", catalogue_uuid: catalogue.uuid})

      {:ok, empty_featured_cat} =
        Catalogue.create_category(%{name: "Empty featured", catalogue_uuid: catalogue.uuid})

      create_item(catalogue, %{
        name: "Both",
        base_price: Decimal.new("1.00"),
        category_uuid: featured_cat.uuid,
        data: %{"featured_image_uuid" => "img-featured", "media_order" => ["img-media"]}
      })

      create_item(catalogue, %{
        name: "Empty featured",
        base_price: Decimal.new("1.00"),
        category_uuid: empty_featured_cat.uuid,
        data: %{"featured_image_uuid" => "", "media_order" => ["img-media-2"]}
      })

      assert Query.resolve_category_images([featured_cat, empty_featured_cat]) == %{
               featured_cat.uuid => "img-featured",
               empty_featured_cat.uuid => "img-media-2"
             }
    end

    test "auto-detect treats an unusable image field as no image and moves on to the next item",
         %{catalogue: catalogue} do
      # Only the FIRST media_order entry counts, exactly as `item_image/1`
      # reads it: an empty / non-string first entry does not fall through to
      # the second one, the whole item is skipped.
      unusable = [
        {"empty media_order", %{"media_order" => []}},
        {"media_order not a list", %{"media_order" => "img-string"}},
        {"media_order is a map", %{"media_order" => %{"0" => "img-map"}}},
        {"empty first entry", %{"media_order" => ["", "img-second"]}},
        {"non-string first entry", %{"media_order" => [42, "img-second"]}},
        {"null first entry", %{"media_order" => [nil, "img-second"]}},
        {"featured not a string", %{"featured_image_uuid" => 7}},
        {"featured null", %{"featured_image_uuid" => nil}},
        {"featured empty and no media_order", %{"featured_image_uuid" => ""}}
      ]

      {:ok, category} =
        Catalogue.create_category(%{name: "Cat", catalogue_uuid: catalogue.uuid})

      unusable
      |> Enum.with_index()
      |> Enum.each(fn {{name, data}, position} ->
        create_item(catalogue, %{
          name: name,
          base_price: Decimal.new("1.00"),
          category_uuid: category.uuid,
          position: position,
          data: data
        })
      end)

      assert Query.resolve_category_images([category]) == %{}

      create_item(catalogue, %{
        name: "Usable, last",
        base_price: Decimal.new("1.00"),
        category_uuid: category.uuid,
        position: length(unusable),
        data: %{"media_order" => ["img-usable"]}
      })

      assert Query.resolve_category_images([category]) == %{category.uuid => "img-usable"}
    end

    test "auto-detect ignores items hidden from the storefront",
         %{catalogue: catalogue} do
      {:ok, category} =
        Catalogue.create_category(%{name: "Cat", catalogue_uuid: catalogue.uuid})

      for {name, position, status, shop_status} <- [
            {"Inactive", 0, "inactive", "active"},
            {"Deleted", 1, "deleted", "active"},
            {"Archived shop_status", 2, "active", "archived"},
            {"Draft shop_status", 3, "active", "draft"}
          ] do
        create_item(catalogue, %{
          name: name,
          base_price: Decimal.new("1.00"),
          category_uuid: category.uuid,
          position: position,
          status: status,
          data: %{
            "ecommerce" => %{"shop_status" => shop_status},
            "featured_image_uuid" => "img-hidden-#{position}"
          }
        })
      end

      assert Query.resolve_category_images([category]) == %{}

      # No shop_status override at all counts as active, like `View.product_status/2`.
      create_item(catalogue, %{
        name: "Visible by default",
        base_price: Decimal.new("1.00"),
        category_uuid: category.uuid,
        position: 4,
        data: %{"featured_image_uuid" => "img-visible"}
      })

      assert Query.resolve_category_images([category]) == %{category.uuid => "img-visible"}
    end

    test "resolves images for many categories without one query per category (no N+1)",
         %{catalogue: catalogue} do
      categories =
        for n <- 1..6 do
          {:ok, category} =
            Catalogue.create_category(%{name: "Cat #{n}", catalogue_uuid: catalogue.uuid})

          create_item(catalogue, %{
            name: "Item #{n}",
            base_price: Decimal.new("1.00"),
            category_uuid: category.uuid,
            data: %{
              "ecommerce" => %{"shop_status" => "active"},
              "featured_image_uuid" => "img-#{n}"
            }
          })

          category
        end

      handler_id = {:resolve_category_images_query_count, self()}
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:phoenix_kit_ecommerce, :test, :repo, :query],
        fn _event, _measurements, _metadata, _config -> send(test_pid, :query_ran) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      images = Query.resolve_category_images(categories)

      assert map_size(images) == 6
      assert images == Map.new(1..6, &{Enum.at(categories, &1 - 1).uuid, "img-#{&1}"})

      query_count = count_received(:query_ran)

      # One query fetching each category's active items (auto-detect —
      # none of the 6 set an explicit featured_item_uuid here), never one
      # per category. A generous ceiling (well under 6) proves the batch
      # shape without pinning the exact count to an implementation detail.
      assert query_count <= 3
    end

    defp count_received(message, acc \\ 0) do
      receive do
        ^message -> count_received(message, acc + 1)
      after
        0 -> acc
      end
    end
  end

  describe "category_item_image_options/1" do
    test "lists only items with an image, labeled by name, ordered by position",
         %{catalogue: catalogue} do
      {:ok, category} =
        Catalogue.create_category(%{name: "Cat", catalogue_uuid: catalogue.uuid})

      create_item(catalogue, %{
        name: "No Image",
        base_price: Decimal.new("1.00"),
        category_uuid: category.uuid,
        position: 0
      })

      second =
        create_item(catalogue, %{
          name: "Second",
          base_price: Decimal.new("1.00"),
          category_uuid: category.uuid,
          position: 2,
          data: %{"featured_image_uuid" => "img-second"}
        })

      first =
        create_item(catalogue, %{
          name: "First",
          base_price: Decimal.new("1.00"),
          category_uuid: category.uuid,
          position: 1,
          data: %{"media_order" => ["img-first"]}
        })

      # Each candidate carries the picture it would give the category, so
      # the picker can show it rather than only the item's name.
      assert Query.category_item_image_options(category.uuid) == [
               %{name: first.name, uuid: first.uuid, image_uuid: "img-first"},
               %{name: second.name, uuid: second.uuid, image_uuid: "img-second"}
             ]
    end

    test "an item from a different category is excluded", %{catalogue: catalogue} do
      {:ok, category} =
        Catalogue.create_category(%{name: "Cat", catalogue_uuid: catalogue.uuid})

      {:ok, other_category} =
        Catalogue.create_category(%{name: "Other", catalogue_uuid: catalogue.uuid})

      create_item(catalogue, %{
        name: "Elsewhere",
        base_price: Decimal.new("1.00"),
        category_uuid: other_category.uuid,
        data: %{"featured_image_uuid" => "img-elsewhere"}
      })

      assert Query.category_item_image_options(category.uuid) == []
    end

    test "nil category_uuid returns an empty list" do
      assert Query.category_item_image_options(nil) == []
    end
  end
end
