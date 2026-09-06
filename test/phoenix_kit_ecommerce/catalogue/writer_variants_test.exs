defmodule PhoenixKitEcommerce.Catalogue.WriterVariantsTest do
  @moduledoc """
  `PhoenixKitEcommerce.Catalogue.Writer.sync_variants/2` (Block 7 Task 2,
  `docs/superpowers/plans/2026-09-06-block7-shopify-media-collections.md`):
  Shopify options/variants attached to a catalogue item as attribute
  sets, unknown option values created as `draft`, slug-keyed price
  modifiers written to `data["ecommerce"]["price_modifiers"]`, and a
  second run against the same payload staying idempotent.

  Needs `phoenix_kit_catalogue` AND `phoenix_kit_entities` loaded (with
  their migrations applied to the test DB) — excluded via
  `test_helper.exs`'s `catalogue_exclude` whenever the optional
  dependencies aren't present, same as `value_resolver_test.exs`/
  `sync_catalogue_test.exs`. `async: false`: flips the process-wide
  `shop_product_source` config key and the `entities_enabled` setting.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :catalogue

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}
  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue.AttributeSets}
  @compile {:no_warn_undefined, PhoenixKitEntities}

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.AttributeSets
  alias PhoenixKitEcommerce.Catalogue.Writer
  alias PhoenixKitEcommerce.ShopConfig
  alias PhoenixKitEcommerce.Test.Repo

  setup do
    AttributeSets.register_deletion_guard()
    PhoenixKit.Settings.update_setting("entities_enabled", "true")

    on_exit(fn ->
      PhoenixKit.Settings.update_setting("entities_enabled", "false")
      set_product_source("legacy")
    end)

    {:ok, catalogue} =
      Catalogue.create_catalogue(%{name: "writer-variants-#{System.unique_integer([:positive])}"})

    {:ok, item} =
      Catalogue.create_item(%{
        catalogue_uuid: catalogue.uuid,
        name: "Two-Option Mug",
        base_price: Decimal.new("10.00"),
        status: "active",
        data: %{
          "_primary_language" => "en",
          "ecommerce" => %{
            "shop_status" => "active",
            "shopify" => %{"handle" => "two-option-mug", "product_id" => "999"}
          }
        }
      })

    %{item: item}
  end

  defp set_product_source(value) do
    case Repo.get(ShopConfig, "shop_product_source") do
      nil ->
        %ShopConfig{}
        |> ShopConfig.changeset(%{key: "shop_product_source", value: %{"value" => value}})
        |> Repo.insert!()

      config ->
        config
        |> ShopConfig.changeset(%{value: %{"value" => value}})
        |> Repo.update!()
    end
  end

  # Size (Small/Medium/Large, prices 10/12/15) x Color (Red/Blue, +0/+1) —
  # same fixture shape `VariantMapperTest` uses, so the cheapest value in
  # each option ("Small", "Red") is exactly the product's own cheapest
  # variant.
  defp two_option_product do
    %{
      "id" => 999,
      "options" => [
        %{"name" => "Size", "position" => 1, "values" => ["Small", "Medium", "Large"]},
        %{"name" => "Color", "position" => 2, "values" => ["Red", "Blue"]}
      ],
      "variants" => [
        %{"option1" => "Small", "option2" => "Red", "price" => "10.00"},
        %{"option1" => "Small", "option2" => "Blue", "price" => "11.00"},
        %{"option1" => "Medium", "option2" => "Red", "price" => "12.00"},
        %{"option1" => "Medium", "option2" => "Blue", "price" => "13.00"},
        %{"option1" => "Large", "option2" => "Red", "price" => "15.00"},
        %{"option1" => "Large", "option2" => "Blue", "price" => "16.00"}
      ]
    }
  end

  describe "sync_variants/2 — legacy source" do
    test "is a no-op returning :catalogue_source_inactive", %{item: item} do
      assert Writer.sync_variants(item, two_option_product()) ==
               {:error, :catalogue_source_inactive}
    end
  end

  describe "sync_variants/2 — catalogue source" do
    setup do
      set_product_source("catalogue")
      :ok
    end

    test "attaches one set per option, creating every unknown value as draft", %{item: item} do
      assert {:ok, %{sets: 2, values_created: 5}} =
               Writer.sync_variants(item, two_option_product())

      attachments = AttributeSets.list_attachments(item.uuid)
      assert length(attachments) == 2

      size_set = PhoenixKitEntities.get_entity_by_name("catalogue_set_size")
      color_set = PhoenixKitEntities.get_entity_by_name("catalogue_set_color")
      assert size_set
      assert color_set

      size_values = AttributeSets.list_values(size_set)
      assert Enum.all?(size_values, &(&1.status == "draft"))
      assert Enum.map(size_values, & &1.title) |> Enum.sort() == ["Large", "Medium", "Small"]
    end

    test "writes slug-keyed price modifiers, the cheapest value at each option is \"0.00\"", %{
      item: item
    } do
      {:ok, _} = Writer.sync_variants(item, two_option_product())

      updated = Catalogue.get_item!(item.uuid)
      modifiers = updated.data["ecommerce"]["price_modifiers"]

      size_set = PhoenixKitEntities.get_entity_by_name("catalogue_set_size")
      small_slug = size_set |> AttributeSets.list_values() |> Enum.find(&(&1.title == "Small"))
      medium_slug = size_set |> AttributeSets.list_values() |> Enum.find(&(&1.title == "Medium"))

      assert modifiers["size"][small_slug.slug] == "0.00"
      assert modifiers["size"][medium_slug.slug] == "2.00"

      color_set = PhoenixKitEntities.get_entity_by_name("catalogue_set_color")
      red_slug = color_set |> AttributeSets.list_values() |> Enum.find(&(&1.title == "Red"))
      assert modifiers["color"][red_slug.slug] == "0.00"
    end

    test "records the attached set slugs under data.ecommerce.shopify.set_slugs", %{
      item: item
    } do
      {:ok, _} = Writer.sync_variants(item, two_option_product())

      updated = Catalogue.get_item!(item.uuid)
      assert Enum.sort(updated.data["ecommerce"]["shopify"]["set_slugs"]) == ["color", "size"]
      # The identity fields another Shopify-sync writer already wrote
      # survive untouched.
      assert updated.data["ecommerce"]["shopify"]["handle"] == "two-option-mug"
      assert updated.data["ecommerce"]["shopify"]["product_id"] == "999"
    end

    test "selects values in Shopify's variant-first-appearance order", %{item: item} do
      {:ok, _} = Writer.sync_variants(item, two_option_product())

      size_set = PhoenixKitEntities.get_entity_by_name("catalogue_set_size")
      values = AttributeSets.list_values(size_set)
      small = Enum.find(values, &(&1.title == "Small"))
      medium = Enum.find(values, &(&1.title == "Medium"))
      large = Enum.find(values, &(&1.title == "Large"))

      [attachment] =
        AttributeSets.list_attachments(item.uuid) |> Enum.filter(&(&1.set_uuid == size_set.uuid))

      assert attachment.data["selected_value_slugs"] == [small.slug, medium.slug, large.slug]
    end

    test "a second run against the same payload creates no new values and stays attached", %{
      item: item
    } do
      assert {:ok, %{sets: 2, values_created: 5}} =
               Writer.sync_variants(item, two_option_product())

      assert {:ok, %{sets: 2, values_created: 0}} =
               Writer.sync_variants(item, two_option_product())

      assert length(AttributeSets.list_attachments(item.uuid)) == 2

      size_set = PhoenixKitEntities.get_entity_by_name("catalogue_set_size")
      assert length(AttributeSets.list_values(size_set)) == 3
    end

    test "detaches a set the product no longer has options for, and drops it from set_slugs", %{
      item: item
    } do
      {:ok, material_set} = AttributeSets.create_set(%{name: "Material", kind: "fixed"})
      {:ok, _} = AttributeSets.attach_set(item.uuid, material_set.uuid)

      {:ok, item} =
        Catalogue.update_item(item, %{
          data: put_in(item.data, ["ecommerce", "shopify", "set_slugs"], ["material"])
        })

      assert {:ok, %{sets: 2}} = Writer.sync_variants(item, two_option_product())

      attachments = AttributeSets.list_attachments(item.uuid)
      refute Enum.any?(attachments, &(&1.set_uuid == material_set.uuid))

      updated = Catalogue.get_item!(item.uuid)
      refute "material" in updated.data["ecommerce"]["shopify"]["set_slugs"]
      refute Map.has_key?(updated.data["ecommerce"]["price_modifiers"], "material")
    end

    test "preserves a price modifier for a set this sync run never touched", %{item: item} do
      # An operator-authored modifier for a set Shopify has never driven
      # (not in `set_slugs`, so `sync_variants/2` never attaches or
      # detaches it) — `finalize_variant_sync/3` must write only the
      # `size`/`color` keys this run computed, not replace the whole
      # `price_modifiers` map.
      {:ok, item} =
        Catalogue.update_item(item, %{
          data:
            put_in(item.data, ["ecommerce", "price_modifiers"], %{
              "brand" => %{"acme" => "1.50"}
            })
        })

      assert {:ok, %{sets: 2}} = Writer.sync_variants(item, two_option_product())

      updated = Catalogue.get_item!(item.uuid)
      assert updated.data["ecommerce"]["price_modifiers"]["brand"] == %{"acme" => "1.50"}
      assert Map.has_key?(updated.data["ecommerce"]["price_modifiers"], "size")
      assert Map.has_key?(updated.data["ecommerce"]["price_modifiers"], "color")
    end

    test "a product with only Shopify's default option attaches no sets", %{item: item} do
      product = %{
        "options" => [%{"name" => "Title", "position" => 1, "values" => ["Default Title"]}],
        "variants" => [%{"option1" => "Default Title", "price" => "9.99"}]
      }

      assert {:ok, %{sets: 0, values_created: 0}} = Writer.sync_variants(item, product)
      assert AttributeSets.list_attachments(item.uuid) == []
    end
  end
end
