defmodule PhoenixKitEcommerce.Shopify.PriceFitSeamTest do
  @moduledoc """
  Seam tests for the Shopify variant price-fit chain (`docs/superpowers/
  specs/2026-09-23-shopify-variant-price-fit-design.md`, "Тест стыка
  (обязателен)"): one value travels through four places —
  `VariantMapper.build/2` -> `Writer.finalize_variant_sync/4` -> the sync
  worker's own run record -> the sync page's template — and the item's
  own `price_fit_rule` travels the other way, from a form save into the
  next sync. Each of Tasks 3-6's own unit tests covers its own piece in
  isolation; NONE of them proves the pieces fit together end to end, so
  these two tests run the real `ShopifyMediaSyncWorker.run/3` (a client
  stub, no network) against real catalogue items and the real sync page.

  These should pass on the code Tasks 1-6 already shipped. A failure
  here means the seam itself is broken — fix the OWNING task's code, not
  this test.

  Needs `phoenix_kit_catalogue` AND `phoenix_kit_entities` loaded —
  tagged `:catalogue` and excluded via `test_helper.exs` whenever the
  optional dependencies aren't present, same as `writer_variants_test.exs`/
  `shopify_media_sync_worker_test.exs`/`shopify_sync_media_panel_test.exs`.
  `async: false`: flips the process-wide `shop_product_source` config key
  and the `entities_enabled` setting, same reason those three are.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  @moduletag :catalogue

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}
  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue.AttributeSets}
  @compile {:no_warn_undefined, PhoenixKitEntities}

  alias PhoenixKit.Integrations
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.AttributeSets
  alias PhoenixKitEcommerce.Catalogue.ItemCommerce
  alias PhoenixKitEcommerce.ShopConfig
  alias PhoenixKitEcommerce.Test.Repo
  alias PhoenixKitEcommerce.Workers.ShopifyMediaSyncWorker, as: Worker

  # Personalized: two options (Printing File Ready? x Print or Figure
  # Height), 14 variants, not additive — same fixture numbers
  # `VariantMapperTest`'s own `personalized/0` uses (Task 3), copied here
  # rather than shared: that helper builds a bare Shopify payload map,
  # this stub is a `client:` module `Worker.run/3` calls by behaviour,
  # not by data — there is nothing to extract into a common function
  # without coupling the two test files to each other's internals.
  defmodule SeamStub do
    @moduledoc false

    @heights ~w(4 5 6 7 8 9 10)

    def fetch_products(_integration_uuid, _opts) do
      {:ok, [personalized_product(), mug_product()]}
    end

    def personalized_product do
      with_file = ~w(29.28 35.64 45.36 51.36 58.56 70.56 82.56)
      without_file = ~w(215.28 225.24 231.36 239.76 245.76 253.92 263.16)

      variants =
        Enum.zip(@heights, with_file)
        |> Enum.map(fn {h, p} -> %{"option1" => "Have", "option2" => h, "price" => p} end)
        |> Kernel.++(
          Enum.zip(@heights, without_file)
          |> Enum.map(fn {h, p} -> %{"option1" => "None", "option2" => h, "price" => p} end)
        )

      %{
        "id" => 1,
        "handle" => "personalized",
        "options" => [
          %{"name" => "Printing File Ready?", "position" => 1, "values" => ["Have", "None"]},
          %{"name" => "Print or Figure Height", "position" => 2, "values" => @heights}
        ],
        "variants" => variants
      }
    end

    # Additive — one option, two values — same Size 10.00/15.00 shape
    # `ShopifyMediaSyncWorkerTest`'s own `VariantsStub` uses, under a
    # different handle so it never collides with `personalized`.
    defp mug_product do
      %{
        "id" => 2,
        "handle" => "mug",
        "options" => [%{"name" => "Size", "position" => 1, "values" => ["Small", "Large"]}],
        "variants" => [
          %{"option1" => "Small", "price" => "10.00"},
          %{"option1" => "Large", "price" => "15.00"}
        ]
      }
    end
  end

  setup %{conn: conn} do
    AttributeSets.register_deletion_guard()
    PhoenixKit.Settings.update_setting("entities_enabled", "true")

    on_exit(fn ->
      PhoenixKit.Settings.update_setting("entities_enabled", "false")
      set_product_source("legacy")
    end)

    set_product_source("catalogue")
    connect_shopify()

    # Named "decor3dprint" — `Query.catalogue_uuid/0`'s own default,
    # which is how the worker finds ITS catalogue (see
    # `shopify_media_sync_worker_test.exs`'s own setup for the same
    # reasoning).
    {:ok, catalogue} = Catalogue.create_catalogue(%{name: "decor3dprint"})
    actor = PhoenixKitEcommerce.DataCase.fixture_user()

    {:ok, conn: put_test_scope(conn, fake_scope()), catalogue: catalogue, actor: actor}
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

  defp connect_shopify do
    {:ok, %{uuid: uuid}} =
      Integrations.add_connection("shopify", "Test Shop #{System.unique_integer([:positive])}")

    {:ok, _} =
      Integrations.save_setup(uuid, %{
        "shop_domain" => "test-shop.myshopify.com",
        "access_token" => "shpat_test_token"
      })

    uuid
  end

  # `base_price` defaults to each product's cheapest Shopify variant
  # (Personalized 29.28, Mug 10.00) — the state a synced item is in once
  # its price has been applied; the drift test passes its own.
  defp create_item(catalogue_uuid, name, handle, base_price \\ nil) do
    base_price = base_price || if(handle == "personalized", do: "29.28", else: "10.00")

    {:ok, item} =
      Catalogue.create_item(%{
        catalogue_uuid: catalogue_uuid,
        name: name,
        base_price: Decimal.new(base_price),
        status: "active",
        data: %{
          "_primary_language" => "en",
          "ecommerce" => %{"shop_status" => "active", "shopify" => %{"handle" => handle}}
        }
      })

    item
  end

  # Resolves `label` to the value slug a Shopify sync's write against
  # `set_slug` (bare, e.g. "size") ended up giving it — the same
  # "look the real attachment/entity up" pattern the existing unit
  # tests use, so this never hardcodes a guessed slug.
  defp value_slug(set_slug, label) do
    ("catalogue_set_" <> set_slug)
    |> PhoenixKitEntities.get_entity_by_name()
    |> AttributeSets.list_values()
    |> Enum.find(&(&1.title == label))
    |> Map.fetch!(:slug)
  end

  test "worker run: price fit lands on the item, the run record, and the sync page", %{
    conn: conn,
    catalogue: catalogue,
    actor: actor
  } do
    personalized = create_item(catalogue.uuid, "Personalized", "personalized")
    mug = create_item(catalogue.uuid, "Mug", "mug")

    assert {:ok, %{errors: [], warnings: [warning]}} =
             Worker.run("variants", actor.uuid,
               client: SeamStub,
               integration_uuid: "test-integration"
             )

    assert warning["product"] == "personalized"
    assert warning["reason"] =~ "5 of 14"
    assert warning["reason"] =~ "+5.40"

    reloaded_personalized = Catalogue.get_item!(personalized.uuid)
    fit = get_in(reloaded_personalized.data, ["ecommerce", "shopify", "price_fit"])

    assert %{
             "rule" => "never_cheaper",
             "variants" => 14,
             "over" => 5,
             "under" => 0,
             "max_over" => "5.40",
             "max_under" => "0.00"
           } = fit

    assert is_binary(fit["synced_at"])

    modifiers = reloaded_personalized.data["ecommerce"]["price_modifiers"]

    have_slug = value_slug("printing_file_ready", "Have")
    none_slug = value_slug("printing_file_ready", "None")
    assert modifiers["printing_file_ready"][have_slug] == "0.00"
    assert modifiers["printing_file_ready"][none_slug] == "186.00"

    expected_heights = Enum.zip(~w(4 5 6 7 8 9 10), ~w(0.00 9.96 16.08 24.48 30.48 41.28 53.28))

    for {height, amount} <- expected_heights do
      slug = value_slug("print_or_figure_height", height)
      assert modifiers["print_or_figure_height"][slug] == amount
    end

    reloaded_mug = Catalogue.get_item!(mug.uuid)
    refute Map.has_key?(reloaded_mug.data["ecommerce"]["shopify"], "price_fit")

    mug_modifiers = reloaded_mug.data["ecommerce"]["price_modifiers"]
    small_slug = value_slug("size", "Small")
    large_slug = value_slug("size", "Large")
    assert mug_modifiers["size"][small_slug] == "0.00"
    assert mug_modifiers["size"][large_slug] == "5.00"

    progress = Worker.get_progress("variants")
    assert progress["errors"] == []
    assert progress["stats"]["approximated"] == 1
    assert [%{"product" => "personalized"}] = progress["warnings"]

    {:ok, view, html} = live(conn, "/en/admin/shop/shopify-sync?tab=media")
    assert html =~ "1 with approximated prices"
    assert view |> element("#media-sync-warnings-variants") |> render() =~ "personalized"

    # The storefront leg: what `calculate_product_price/2` actually charges
    # for each Shopify combination, from the stored modifiers and base —
    # never below Shopify, and above it on exactly the 5 variants the fit
    # reported.
    product = PhoenixKitEcommerce.get_product(personalized.uuid)

    deltas =
      for variant <- SeamStub.personalized_product()["variants"] do
        specs = %{
          "printing_file_ready" => variant["option1"],
          "print_or_figure_height" => variant["option2"]
        }

        product
        |> PhoenixKitEcommerce.calculate_product_price(specs)
        |> Decimal.sub(Decimal.new(variant["price"]))
      end

    assert Enum.all?(deltas, &(not Decimal.negative?(&1)))
    assert Enum.count(deltas, &Decimal.gt?(&1, 0)) == 5
    assert deltas |> Enum.max(Decimal) |> Decimal.to_string() == "5.40"
  end

  # The variant sync re-anchors modifiers to Shopify's cheapest variant but
  # never writes the base (the Changes tab does). A base left behind shows
  # up as the storefront's real offset, not as a clean "5 above" fit.
  test "a base that is not Shopify's cheapest variant is reported with its offset", %{
    catalogue: catalogue,
    actor: actor
  } do
    personalized = create_item(catalogue.uuid, "Personalized", "personalized", "10.00")
    _mug = create_item(catalogue.uuid, "Mug", "mug")

    assert {:ok, %{errors: [], warnings: [warning]}} =
             Worker.run("variants", actor.uuid,
               client: SeamStub,
               integration_uuid: "test-integration"
             )

    assert warning["reason"] =~ "base price is -19.28 off"

    fit =
      get_in(Catalogue.get_item!(personalized.uuid).data, ["ecommerce", "shopify", "price_fit"])

    assert %{"base_offset" => "-19.28", "under" => 14} = fit
  end

  test "the item's price_fit_rule picked in the form reaches the next sync, and back", %{
    catalogue: catalogue,
    actor: actor
  } do
    item = create_item(catalogue.uuid, "Personalized", "personalized")
    # SeamStub always returns both products — give "mug" a match too, so
    # it never shows up as a "no_matching_item" error and clutters the
    # `errors: []` assertions below.
    _mug = create_item(catalogue.uuid, "Mug", "mug")

    {:ok, cheapest} = ItemCommerce.cast(%{"price_fit_rule" => "cheapest"}, item.data["ecommerce"])
    {:ok, item} = Catalogue.update_item(item, %{data: Map.put(item.data, "ecommerce", cheapest)})

    assert {:ok, %{errors: []}} =
             Worker.run("variants", actor.uuid,
               client: SeamStub,
               integration_uuid: "test-integration"
             )

    item = Catalogue.get_item!(item.uuid)
    fit = get_in(item.data, ["ecommerce", "shopify", "price_fit"])
    assert fit["rule"] == "cheapest"
    # `VariantMapper.build(personalized(), rule: :cheapest)` puts 3 of the
    # 14 variants under Shopify (verified directly against the module —
    # `variant_mapper_test.exs`'s own ":cheapest" test pins `max_under`
    # but never pinned this count).
    assert fit["under"] == 3
    assert fit["max_under"] == "3.60"

    {:ok, never_cheaper} =
      ItemCommerce.cast(%{"price_fit_rule" => "never_cheaper"}, item.data["ecommerce"])

    {:ok, item} =
      Catalogue.update_item(item, %{data: Map.put(item.data, "ecommerce", never_cheaper)})

    assert {:ok, %{errors: []}} =
             Worker.run("variants", actor.uuid,
               client: SeamStub,
               integration_uuid: "test-integration"
             )

    item = Catalogue.get_item!(item.uuid)
    fit = get_in(item.data, ["ecommerce", "shopify", "price_fit"])
    assert fit["under"] == 0

    expected_heights = Enum.zip(~w(4 5 6 7 8 9 10), ~w(0.00 9.96 16.08 24.48 30.48 41.28 53.28))
    modifiers = item.data["ecommerce"]["price_modifiers"]

    for {height, amount} <- expected_heights do
      slug = value_slug("print_or_figure_height", height)
      assert modifiers["print_or_figure_height"][slug] == amount
    end
  end
end
