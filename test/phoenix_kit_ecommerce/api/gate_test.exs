defmodule PhoenixKitEcommerce.API.GateTest do
  @moduledoc """
  The precondition of every admin e-commerce tool: the shop reads a catalogue
  that is new enough. Each refusal is `unsupported_source` with its reason.

  The tests are split by what is installed, because they cannot all run in
  one build: `:no_catalogue` runs only without `phoenix_kit_catalogue`,
  `:old_catalogue` only with a catalogue that lacks the API, `:catalogue_api`
  only with one that has it. `test_helper.exs` excludes the others, so run the
  suite once per build.

  `async: false`: it flips the process-wide `shop_product_source` config key.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKitCatalogue.Schemas.{Category, Item}
  alias PhoenixKitEcommerce.API.Gate
  alias PhoenixKitEcommerce.APIFixtures, as: F

  test "catalogue authorization fails closed without an identifiable key owner" do
    for ctx <- [
          %{},
          %{actor: nil},
          %{actor: %{kind: :anonymous, user_uuid: Ecto.UUID.generate()}},
          %{actor: %{kind: :key, user_uuid: nil}},
          %{actor: %{kind: :key, user_uuid: "invalid"}},
          %{actor: %{kind: :key, user_uuid: Ecto.UUID.generate()}}
        ] do
      assert {:error, :forbidden, _, %{required_permission: "catalogue"}} =
               Gate.authorize_catalogue(ctx)
    end
  end

  @tag :no_catalogue
  test "without phoenix_kit_catalogue the shop has no catalogue to write" do
    assert {:error, :unsupported_source, detail, %{reason: "catalogue_missing"}} = Gate.check()
    assert detail =~ "phoenix_kit_catalogue is not installed"
    refute Gate.catalogue_api_ready?()
  end

  @tag :catalogue
  test "the legacy source is refused" do
    F.put_config!("shop_product_source", "legacy")

    assert {:error, :unsupported_source, detail, %{reason: "legacy_source"}} = Gate.check()
    assert detail =~ "legacy"
  end

  @tag :old_catalogue
  test "a catalogue without the API is too old" do
    F.put_config!("shop_product_source", "catalogue")

    assert {:error, :unsupported_source, detail, %{reason: "catalogue_too_old"}} = Gate.check()
    assert detail =~ "too old"
    refute Gate.catalogue_api_ready?()
  end

  describe "with a catalogue that has the API" do
    @describetag :catalogue_api

    test "answers the uuid of the catalogue the shop reads" do
      catalogue = F.shop_catalogue!()

      assert Gate.catalogue_api_ready?()
      assert {:ok, uuid} = Gate.check()
      assert uuid == catalogue.uuid
    end

    test "the schemas and columns with_locked_items queries are the catalogue's" do
      # `CatalogueWrites.with_locked_items/2` selects, locks and orders by
      # these directly; `catalogue_api_ready?/0` probes the same ones.
      assert :uuid in Item.__schema__(:fields)
      assert :category_uuid in Item.__schema__(:fields)
      assert :uuid in Category.__schema__(:fields)
      assert Gate.catalogue_api_ready?()
    end

    test "a shop catalogue that does not exist is refused" do
      F.put_config!("shop_product_source", "catalogue")
      F.put_config!("shop_catalogue", "no-such-catalogue-#{System.unique_integer([:positive])}")

      assert {:error, :unsupported_source, _detail, %{reason: "no_shop_catalogue"}} = Gate.check()
    end

    test "a catalogue_id other than the shop's is a validation error naming the right one" do
      catalogue = F.shop_catalogue!()
      other = F.other_catalogue!()

      assert {:ok, _} = Gate.check(%{"catalogue_id" => catalogue.uuid})

      assert {:error, :validation_failed, _detail, %{errors: [error]}} =
               Gate.check(%{"catalogue_id" => other.uuid})

      assert error.path == "catalogue_id"
      assert error.allowed == [catalogue.uuid]
      refute Map.has_key?(error, :given)
    end

    test "the shop catalogue's uuid is accepted in any letter case" do
      catalogue = F.shop_catalogue!()

      assert {:ok, uuid} = Gate.check(%{"catalogue_id" => String.upcase(catalogue.uuid)})
      assert uuid == catalogue.uuid
    end

    test "a catalogue_id that is not a uuid is refused" do
      F.shop_catalogue!()

      assert {:error, :validation_failed, _detail, %{errors: [%{path: "catalogue_id"}]}} =
               Gate.check(%{"catalogue_id" => 42})
    end
  end
end
