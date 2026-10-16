defmodule PhoenixKitEcommerce.ProductSource.CatalogueUnstampedPricesTest do
  @moduledoc """
  `Query.list_priced_items_without_currency/1` — the read-only audit for
  prices a Shopify sync wrote while the shop had no base currency.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :catalogue

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce.ProductSource.Catalogue.Query

  setup do
    {:ok, catalogue} = Catalogue.create_catalogue(%{name: "decor3dprint"})
    {:ok, other} = Catalogue.create_catalogue(%{name: "not-the-shop"})
    %{catalogue: catalogue, other: other}
  end

  defp item!(catalogue, name, base_price, ecommerce) do
    {:ok, item} =
      Catalogue.create_item(%{
        catalogue_uuid: catalogue.uuid,
        name: name,
        base_price: base_price,
        status: "active",
        data: %{"ecommerce" => ecommerce}
      })

    item
  end

  test "lists every unstamped item that carries money, and only those", ctx do
    priced =
      item!(ctx.catalogue, "A priced", Decimal.new("9.00"), %{"shopify" => %{"handle" => "a"}})

    compare = item!(ctx.catalogue, "B compare", nil, %{"compare_at_price" => "15.00"})

    modifiers =
      item!(ctx.catalogue, "C modifiers", Decimal.new("0"), %{
        "price_modifiers" => %{"size" => %{"large" => "7.00"}}
      })

    _stamped = item!(ctx.catalogue, "D stamped", Decimal.new("9.00"), %{"currency" => "EUR"})
    _free = item!(ctx.catalogue, "E free", Decimal.new("0"), %{"price_modifiers" => %{}})
    _unpriced = item!(ctx.catalogue, "F unpriced", nil, %{})
    _elsewhere = item!(ctx.other, "G elsewhere", Decimal.new("9.00"), %{})

    listed = Query.list_priced_items_without_currency()

    assert Enum.map(listed, & &1.uuid) == [priced.uuid, compare.uuid, modifiers.uuid]

    assert [%{name: "A priced", status: "active", shopify_handle: "a", base_price: price} | _] =
             listed

    assert Decimal.equal?(price, Decimal.new("9.00"))
  end

  test "stamps nothing: the rows read back exactly as they were", ctx do
    item = item!(ctx.catalogue, "A priced", Decimal.new("9.00"), %{"vendor" => "Acme"})

    assert [_one] = Query.list_priced_items_without_currency()
    assert [_one] = Query.list_priced_items_without_currency()

    assert Catalogue.get_item!(item.uuid).data == item.data
  end

  test "no shop catalogue resolves: an empty list, not a crash" do
    assert Query.list_priced_items_without_currency(catalogue_uuid: nil) == []
  end
end
