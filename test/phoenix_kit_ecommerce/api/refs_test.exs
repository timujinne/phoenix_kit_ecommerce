defmodule PhoenixKitEcommerce.API.RefsTest do
  @moduledoc """
  Product references against a real catalogue: id, sku and external_id inside
  the shop's catalogue, one answer per reference in order, and a bad
  reference only fails its own row.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :catalogue_api

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce.API.Refs
  alias PhoenixKitEcommerce.APIFixtures, as: F

  setup do
    catalogue = F.shop_catalogue!()
    %{catalogue: catalogue}
  end

  test "resolves an id and a sku, in the order given", %{catalogue: catalogue} do
    a = F.item!(catalogue, %{sku: "REF-A"})
    b = F.item!(catalogue, %{sku: "REF-B"})

    assert [{:ok, found_b}, {:ok, found_a}] =
             Refs.resolve([%{"sku" => "REF-B"}, %{"id" => a.uuid}], catalogue.uuid)

    assert found_b.uuid == b.uuid
    assert found_a.uuid == a.uuid
  end

  test "an unknown reference, an ambiguous sku and a malformed one fail their own row only",
       %{catalogue: catalogue} do
    ok = F.item!(catalogue, %{sku: "REF-OK"})
    one = F.item!(catalogue, %{sku: "REF-TWICE"})
    two = F.item!(catalogue, %{sku: "REF-TWICE"})

    answers =
      Refs.resolve(
        [
          %{"sku" => "REF-MISSING"},
          %{"sku" => "REF-TWICE"},
          %{},
          %{"id" => "not-a-uuid"},
          %{"sku" => "REF-OK", "id" => ok.uuid},
          %{"sku" => "REF-OK"}
        ],
        catalogue.uuid
      )

    assert [
             {:error, %{"code" => "not_found"}},
             {:error, %{"code" => "ambiguous_ref", "context" => %{"candidates" => candidates}}},
             {:error, %{"code" => "validation_failed"}},
             {:error, %{"code" => "validation_failed", "message" => "id must be a UUID"}},
             {:error, %{"code" => "validation_failed"}},
             {:ok, found}
           ] = answers

    assert Enum.sort(candidates) == Enum.sort([one.uuid, two.uuid])
    assert found.uuid == ok.uuid
  end

  test "an empty or blank sku or external_id is refused, whatever the catalogue holds", %{
    catalogue: catalogue
  } do
    F.item!(catalogue, %{sku: ""})

    answers =
      Refs.resolve(
        [
          %{"sku" => ""},
          %{"sku" => " "},
          %{"sku" => "\t\n"},
          %{"external_id" => ""},
          %{"external_id" => "   "}
        ],
        catalogue.uuid
      )

    assert [
             {:error, %{"code" => "validation_failed", "message" => "sku must not be empty"}},
             {:error, %{"code" => "validation_failed", "message" => "sku must not be empty"}},
             {:error, %{"code" => "validation_failed", "message" => "sku must not be empty"}},
             {:error,
              %{"code" => "validation_failed", "message" => "external_id must not be empty"}},
             {:error,
              %{"code" => "validation_failed", "message" => "external_id must not be empty"}}
           ] = answers
  end

  test "a trashed product and a product of another catalogue are not found", %{
    catalogue: catalogue
  } do
    trashed = F.item!(catalogue, %{sku: "REF-TRASHED"})
    {:ok, _} = Catalogue.trash_item(trashed)

    foreign = F.item!(F.other_catalogue!(), %{sku: "REF-FOREIGN"})

    assert [{:error, %{"code" => "not_found"}}, {:error, %{"code" => "not_found"}}] =
             Refs.resolve([%{"id" => trashed.uuid}, %{"id" => foreign.uuid}], catalogue.uuid)
  end

  test "an external_id resolves like a sku", %{catalogue: catalogue} do
    item =
      F.item!(catalogue, %{
        data: %{"_primary_language" => "en", "api" => %{"external_id" => "ERP-77"}}
      })

    assert [{:ok, found}] = Refs.resolve([%{"external_id" => "ERP-77"}], catalogue.uuid)
    assert found.uuid == item.uuid
  end

  test "no references, no lookup", %{catalogue: catalogue} do
    assert Refs.resolve([], catalogue.uuid) == []
  end
end
