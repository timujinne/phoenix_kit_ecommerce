defmodule PhoenixKitEcommerce.ProductSource.Catalogue.ViewTest do
  use ExUnit.Case, async: true

  # Pure logic — no DB, no live catalogue data. Still requires
  # `phoenix_kit_catalogue` to be loaded: although `View`'s own moduledoc
  # says it accepts duck-typed maps (no pattern-matching on the catalogue
  # STRUCTS), `product_view/2`/`category_view/2` unconditionally call
  # `PhoenixKitCatalogue.Catalogue.translated_name/2` and friends — a
  # real dependency on the `Catalogue` MODULE regardless of fixture
  # shape. Verified empirically: `Code.ensure_loaded?(PhoenixKitCatalogue)`
  # is `false` in this fork's own `mix test` (no dependency declared,
  # see mix.exs), and calling `View.product_view/2` here without the
  # guard raises `UndefinedFunctionError`. Excluded (via
  # `test_helper.exs`'s `ExUnit.configure(exclude: ...)`) whenever the
  # optional dependency isn't present, same as every other catalogue
  # adapter test — see Global Constraints in the block-3 plan.
  @moduletag :catalogue

  alias PhoenixKitEcommerce.PriceDisplay
  alias PhoenixKitEcommerce.ProductSource.Catalogue.View

  @item_uuid "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
  @image_uuid "11111111-1111-1111-1111-111111111111"
  @second_image_uuid "22222222-2222-2222-2222-222222222222"

  defp build_item(data_overrides \\ %{}, field_overrides \\ %{}) do
    data =
      %{
        "_primary_language" => "en-US",
        "en-US" => %{
          "_name" => "Geometric Planter",
          "_description" => "<p>A <strong>lovely</strong> planter</p>",
          "_summary" => "A lovely planter.",
          "_seo_title" => "Buy Geometric Planter",
          "_seo_description" => "The best planter, geometric."
        },
        "fr-FR" => %{
          "_name" => "Cache-pot géométrique",
          "_description" => "<p>Un joli cache-pot</p>",
          "_summary" => "Un joli cache-pot."
        },
        "ecommerce" => %{
          "shop_status" => "active",
          "vendor" => "Acme",
          "tags" => ["planter", "geometric"],
          "price_modifiers" => %{"size" => %{"5-inches-13-cm" => "9.00"}},
          "legacy_metadata" => %{
            "_option_slots" => [%{"key" => "size", "type" => "select"}],
            "_image_mappings" => %{"size" => %{"5-inches-13-cm" => @image_uuid}}
          }
        },
        "featured_image_uuid" => @image_uuid,
        "media_order" => [@image_uuid, @second_image_uuid]
      }
      |> deep_merge(data_overrides)

    struct(
      PhoenixKitCatalogue.Schemas.Item,
      Map.merge(
        %{
          uuid: @item_uuid,
          name: "Geometric Planter",
          description: "A lovely planter",
          base_price: Decimal.new("23.76"),
          status: "active",
          category_uuid: nil,
          slug: %{"en-US" => "geometric-planter", "fr-FR" => "cache-pot-geometrique"},
          data: data,
          inserted_at: ~U[2026-01-01 00:00:00Z],
          updated_at: ~U[2026-01-01 00:00:00Z]
        },
        field_overrides
      )
    )
  end

  defp deep_merge(a, b),
    do:
      Map.merge(a, b, fn _k, v1, v2 ->
        if is_map(v1) and is_map(v2), do: deep_merge(v1, v2), else: v2
      end)

  @sets [
    %{
      key: "size",
      values: [
        %{key: "5-inches-13-cm", label: "5 inches (13 cm)"},
        %{key: "4-inches-10-cm", label: "4 inches (10 cm)"}
      ],
      selected: ["5-inches-13-cm", "4-inches-10-cm"]
    }
  ]

  describe "product_view/2" do
    test "builds a read-only view-struct with translated fields, price, status and metadata" do
      item = build_item()

      product = View.product_view(item, sets: @sets)

      assert %PhoenixKitEcommerce.Product{} = product
      assert product.__meta__.state == :built

      assert product.title["en-US"] == "Geometric Planter"
      assert product.title["fr-FR"] == "Cache-pot géométrique"
      assert product.body_html["fr-FR"] == "<p>Un joli cache-pot</p>"
      assert product.description["en-US"] == "A lovely planter."
      assert product.seo_title["en-US"] == "Buy Geometric Planter"
      # fr-FR has no _seo_title override — omitted, not inherited.
      refute Map.has_key?(product.seo_title, "fr-FR")

      assert product.price == Decimal.new("23.76")
      assert product.status == "active"
      assert product.uuid == @item_uuid
      assert product.image_uuids == [@image_uuid, @second_image_uuid]
      assert product.featured_image_uuid == @image_uuid
      assert product.images == []
      assert product.featured_image == nil

      assert product.metadata["_option_values"] == %{
               "size" => ["5 inches (13 cm)", "4 inches (10 cm)"]
             }

      assert product.metadata["_price_modifiers"] == %{
               "size" => %{"5 inches (13 cm)" => "9.00"}
             }

      assert product.metadata["_option_slots"] == [%{"key" => "size", "type" => "select"}]

      assert product.metadata["_image_mappings"] == %{
               "size" => %{"5-inches-13-cm" => @image_uuid}
             }
    end

    test "status falls back to item.status when shop_status is absent" do
      item =
        build_item(%{"ecommerce" => %{"shop_status" => nil, "price_modifiers" => %{}}})

      assert View.product_view(item, sets: []).status == "active"

      inactive = build_item(%{"ecommerce" => %{"shop_status" => nil}}, %{status: "inactive"})
      assert View.product_view(inactive, sets: []).status == "archived"
    end

    test "description falls back to the first 300 chars of stripped body_html when _summary is absent" do
      item =
        build_item(%{
          "en-US" => %{"_summary" => nil, "_description" => "<p>Only body, no summary</p>"}
        })

      assert View.product_view(item, sets: []).description["en-US"] == "Only body, no summary"
    end

    test "accepts sets as either a bare list or a resolve_for_item/2-shaped map" do
      item = build_item()

      from_list = View.product_view(item, sets: @sets)
      from_wrapped = View.product_view(item, sets: %{schema_version: 2, sets: @sets})

      assert from_list.metadata["_option_values"] == from_wrapped.metadata["_option_values"]
    end

    test "strips the entities blueprint's catalogue_set_ prefix so _option_values/_price_modifiers key on the bare slug" do
      # `AttributeSets.resolve_set/2` returns `key: set.name`, and
      # `AttributeSets.create_set/2` always stores that name prefixed
      # (`"catalogue_set_" <> slug`) — while `data["ecommerce"]["price_modifiers"]`
      # is keyed by the bare slug (as the app migration writes it). A set
      # resolved with the real prefixed key must still produce
      # `_option_values`/`_price_modifiers` keyed "size", and the price
      # modifier for that set must survive.
      prefixed_sets = [
        %{
          key: "catalogue_set_size",
          values: [
            %{key: "5-inches-13-cm", label: "5 inches (13 cm)"},
            %{key: "4-inches-10-cm", label: "4 inches (10 cm)"}
          ],
          selected: ["5-inches-13-cm", "4-inches-10-cm"]
        }
      ]

      item = build_item()

      metadata = View.product_view(item, sets: prefixed_sets).metadata

      assert metadata["_option_values"] == %{
               "size" => ["5 inches (13 cm)", "4 inches (10 cm)"]
             }

      assert metadata["_price_modifiers"] == %{
               "size" => %{"5 inches (13 cm)" => "9.00"}
             }
    end

    test "omits _option_values/_price_modifiers when there are no attachments" do
      item = build_item()

      metadata = View.product_view(item, sets: []).metadata

      refute Map.has_key?(metadata, "_option_values")
      refute Map.has_key?(metadata, "_price_modifiers")
      # The rest of the snapshot survives untouched.
      assert metadata["_option_slots"] == [%{"key" => "size", "type" => "select"}]
    end

    test "carries price_unit/price_from/price_on_request under the _price_display key PriceDisplay reads" do
      item =
        build_item(%{
          "ecommerce" => %{
            "price_unit" => %{"en-US" => "per hour"},
            "price_from" => true
          }
        })

      metadata = View.product_view(item, sets: []).metadata

      assert metadata[PriceDisplay.metadata_key()] == %{
               "unit" => %{"en-US" => "per hour"},
               "from" => true
             }
    end

    test "omits _price_display entirely when nothing is set (matches build/3's empty-map contract)" do
      item = build_item()

      refute Map.has_key?(View.product_view(item, sets: []).metadata, PriceDisplay.metadata_key())
    end

    test "attaches a preloaded category view-struct when given" do
      category = struct(PhoenixKitCatalogue.Schemas.Category, uuid: "cat-uuid", name: "Planters")
      item = build_item()

      product = View.product_view(item, sets: [], category: category)

      assert product.category == category
    end
  end

  describe "product_view/2 with :language (2026-09-06 plan, Task 3)" do
    # A value's per-language override lives in its OWN `:extras` (whatever
    # `AttributeSets.resolve_set/2` read off the value's `EntityData.data`
    # column — see `View`'s `translated_value_label/2` doc), not on the
    # item's own `data` at all — no `build_item/2` override needed here.
    @color_sets [
      %{
        key: "color",
        values: [
          %{
            key: "red",
            label: "Red",
            extras: %{"_primary_language" => "en-US", "fr-FR" => %{"_title" => "Rouge"}}
          }
        ],
        selected: ["red"]
      }
    ]

    test "picks data[language]['_title'] over the untranslated label" do
      item =
        build_item(%{"ecommerce" => %{"price_modifiers" => %{"color" => %{"red" => "5.00"}}}})

      fr = View.product_view(item, sets: @color_sets, language: "fr-FR")
      assert fr.metadata["_option_values"] == %{"color" => ["Rouge"]}
      # Consistency: the picker's displayed option and its price-modifier
      # lookup key on the SAME translated label — `selected_specs` built
      # from what's on screen must find the modifier `Options.
      # get_price_modifier/2` looks up by that exact label.
      assert fr.metadata["_price_modifiers"] == %{"color" => %{"Rouge" => "5.00"}}
      assert fr.metadata["_value_slugs"] == %{"color" => %{"Rouge" => "red"}}
    end

    test "language: en-US (no fr-FR override) keeps the untranslated label" do
      item =
        build_item(%{"ecommerce" => %{"price_modifiers" => %{"color" => %{"red" => "5.00"}}}})

      en = View.product_view(item, sets: @color_sets, language: "en-US")
      assert en.metadata["_option_values"] == %{"color" => ["Red"]}
      assert en.metadata["_price_modifiers"] == %{"color" => %{"Red" => "5.00"}}
      assert en.metadata["_value_slugs"] == %{"color" => %{"Red" => "red"}}
    end

    test "no :language given (default) behaves exactly as before this option existed" do
      item = build_item()

      metadata = View.product_view(item, sets: @color_sets).metadata
      assert metadata["_option_values"] == %{"color" => ["Red"]}
    end

    test "_option_labels carries each set's own :name, stripped of the catalogue_set_ prefix" do
      item = build_item()
      sets = [%{key: "catalogue_set_color", name: "Color", values: [], selected: []}]

      assert View.product_view(item, sets: sets).metadata["_option_labels"] == %{
               "color" => "Color"
             }
    end

    test "_option_labels omits a set with no resolvable :name" do
      item = build_item()

      refute Map.has_key?(View.product_view(item, sets: @color_sets).metadata, "_option_labels")
    end
  end

  describe "category_view/2" do
    defp build_category(data_overrides \\ %{}) do
      data =
        %{
          "_primary_language" => "en-US",
          "en-US" => %{"_name" => "Planters", "_description" => "Pots and planters"},
          "fr-FR" => %{"_name" => "Cache-pots"},
          "ecommerce" => %{
            "shop_status" => "active",
            "option_schema" => [%{"key" => "size"}],
            "image_uuid" => "cat-img-uuid",
            "featured_item_uuid" => "feat-item-uuid"
          }
        }
        |> deep_merge(data_overrides)

      struct(PhoenixKitCatalogue.Schemas.Category,
        uuid: "cat-uuid",
        name: "Planters",
        description: "Pots and planters",
        position: 2,
        status: "active",
        parent_uuid: nil,
        slug: %{"en-US" => "planters"},
        data: data,
        inserted_at: ~U[2026-01-01 00:00:00Z],
        updated_at: ~U[2026-01-01 00:00:00Z]
      )
    end

    test "builds a read-only view-struct from a catalogue category" do
      category = build_category()

      view = View.category_view(category)

      assert %PhoenixKitEcommerce.Category{} = view
      assert view.__meta__.state == :built
      assert view.name["en-US"] == "Planters"
      assert view.name["fr-FR"] == "Cache-pots"
      assert view.description["en-US"] == "Pots and planters"
      assert view.status == "active"
      assert view.position == 2
      assert view.option_schema == [%{"key" => "size"}]
      assert view.image_uuid == "cat-img-uuid"
      assert view.featured_product_uuid == "feat-item-uuid"
      assert view.metadata == %{}
      assert view.storefront_filters == %{}
    end

    test "status defaults to active when shop_status is absent" do
      category = build_category(%{"ecommerce" => %{"shop_status" => nil}})
      assert View.category_view(category).status == "active"
    end

    test "storefront_filters is read from data.ecommerce.storefront_filters" do
      overrides = %{
        "ecommerce" => %{
          "storefront_filters" => %{"price" => %{"enabled" => false}}
        }
      }

      category = build_category(overrides)

      assert View.category_view(category).storefront_filters == %{
               "price" => %{"enabled" => false}
             }
    end
  end

  describe "legacy_metadata/2" do
    test "computes _option_values/_price_modifiers fresh and merges the rest of the snapshot" do
      item = build_item()

      metadata = View.legacy_metadata(item, @sets)

      assert metadata == %{
               "_option_slots" => [%{"key" => "size", "type" => "select"}],
               "_image_mappings" => %{"size" => %{"5-inches-13-cm" => @image_uuid}},
               "_option_values" => %{"size" => ["5 inches (13 cm)", "4 inches (10 cm)"]},
               "_price_modifiers" => %{"size" => %{"5 inches (13 cm)" => "9.00"}},
               "_value_slugs" => %{
                 "size" => %{
                   "5 inches (13 cm)" => "5-inches-13-cm",
                   "4 inches (10 cm)" => "4-inches-10-cm"
                 }
               }
             }
    end

    test "a stale snapshot copy of _option_values/_price_modifiers never survives the merge" do
      item =
        build_item(%{
          "ecommerce" => %{
            "legacy_metadata" => %{
              "_option_values" => %{"stale_key" => ["stale label"]},
              "_price_modifiers" => %{"stale_key" => %{"stale label" => "0.00"}}
            }
          }
        })

      metadata = View.legacy_metadata(item, @sets)

      assert metadata["_option_values"] == %{"size" => ["5 inches (13 cm)", "4 inches (10 cm)"]}
      assert metadata["_price_modifiers"] == %{"size" => %{"5 inches (13 cm)" => "9.00"}}
    end
  end
end
