defmodule PhoenixKitEcommerce.Search.DocumentNamePrefixTest do
  @moduledoc """
  The storefront name prefix setting is global, so the test that sets it runs
  alone (`async: false`), like the other tests of that setting.
  """
  use PhoenixKitEcommerce.DataCase, async: false

  import PhoenixKitEcommerce.SearchFixtures

  alias PhoenixKitEcommerce.API.Facts
  alias PhoenixKitEcommerce.API.Record
  alias PhoenixKitEcommerce.Category
  alias PhoenixKitEcommerce.Product
  alias PhoenixKitEcommerce.Search.Document

  setup do
    disable_languages!()
    :ok
  end

  test "names are indexed as stored: the storefront name prefix does not strip them" do
    {:ok, _} = PhoenixKit.Settings.update_setting("shop_name_prefixes", "3D Printed")

    uuid = Ecto.UUID.generate()

    category =
      struct(Category,
        uuid: uuid,
        name: %{"en" => "3D Printed Home"},
        parent_uuid: nil,
        status: "active"
      )

    product =
      struct(Product,
        uuid: Ecto.UUID.generate(),
        title: %{"en" => "3D Printed Red Vase"},
        description: %{},
        body_html: %{},
        tags: [],
        metadata: %{},
        price: Decimal.new("20.00"),
        inserted_at: ~U[2026-01-02 03:04:05Z]
      )

    record = %Record{
      id: product.uuid,
      product: product,
      facts: %Facts{item_status: "active", shop_status: "active", position: 3},
      state: :listed,
      category: category,
      chain: [category]
    }

    row = Document.build(record, "en")

    assert row.title == "3D Printed Red Vase"
    assert row.category_path == ["3D Printed Home"]
    assert row.text_b =~ "3D Printed Home"
  end
end
