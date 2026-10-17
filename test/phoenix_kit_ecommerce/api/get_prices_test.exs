defmodule PhoenixKitEcommerce.API.GetPricesTest do
  @moduledoc """
  `ecommerce.get_prices`: what it answers per product, that its idea of
  `shop_status_visible` is the storefront's own verdict on the product's status, and that it works for a
  shop that never heard of Shopify.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :catalogue_api
  @moduletag :core_api

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}

  alias Ecto.Adapters.SQL
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce.APICase
  alias PhoenixKitEcommerce.APIFixtures, as: F
  alias PhoenixKitEcommerce.ProductSource.Catalogue.View
  alias PhoenixKitEcommerce.Test.Repo

  setup do
    catalogue = F.shop_catalogue!()
    %{catalogue: catalogue, ctx: F.ctx(F.user!())}
  end

  defp run(refs, ctx), do: APICase.call("ecommerce.get_prices", %{"refs" => refs}, ctx)

  test "answers price, compare_at, option prices, visibility and the made-to-order flag",
       %{catalogue: catalogue, ctx: ctx} do
    item =
      F.item!(catalogue, %{
        sku: "GP-1",
        base_price: Decimal.new("35.52"),
        data: %{
          "_primary_language" => "en",
          "ecommerce" => %{
            "shop_status" => "active",
            "currency" => "EUR",
            "compare_at_price" => "40.00",
            "made_to_order" => true,
            "price_modifiers" => %{"liquid_color" => %{"black" => "32.00", "blue" => 5}}
          }
        }
      })

    assert {:ok, %{"results" => [by_id, by_sku, missing], "summary" => summary}} =
             run([%{"id" => item.uuid}, %{"sku" => "GP-1"}, %{"sku" => "GP-NONE"}], ctx)

    assert by_id["id"] == item.uuid
    assert by_id["price"] == %{"amount" => "35.52", "currency" => "EUR"}
    assert by_id["compare_at"] == %{"amount" => "40.00", "currency" => "EUR"}
    assert by_id["currency"] == "EUR"

    assert by_id["price_modifiers"] == %{
             "liquid_color" => %{"black" => "32.00", "blue" => "5.00"}
           }

    assert by_id["visibility"] == "active"
    assert by_id["made_to_order"] == true
    assert by_id["item_status"] == "active"
    assert by_id["shop_status_visible"] == true

    assert Map.delete(by_sku, "ref") == Map.delete(by_id, "ref")
    assert missing["error"]["code"] == "not_found"
    assert missing["ref"] == %{"sku" => "GP-NONE"}
    assert summary == %{"found" => 2, "error" => 1}
  end

  test "each product answers in its own currency; one with none stored answers in the base currency",
       %{catalogue: catalogue, ctx: ctx} do
    %{code: base} = PhoenixKitEcommerce.get_base_currency()
    own = if base == "USD", do: "GBP", else: "USD"

    ecommerce = fn extra ->
      %{
        "ecommerce" =>
          Map.merge(%{"shop_status" => "active", "compare_at_price" => "9.00"}, extra)
      }
    end

    foreign =
      F.item!(catalogue, %{
        data: Map.put(ecommerce.(%{"currency" => own}), "_primary_language", "en")
      })

    plain = F.item!(catalogue, %{data: Map.put(ecommerce.(%{}), "_primary_language", "en")})

    assert {:ok, %{"results" => [one, two]}} =
             run([%{"id" => foreign.uuid}, %{"id" => plain.uuid}], ctx)

    assert one["currency"] == own
    assert one["price"]["currency"] == own
    assert one["compare_at"]["currency"] == own

    assert two["currency"] == base
    assert two["price"]["currency"] == base
    assert two["compare_at"]["currency"] == base
  end

  test "a blank sku is that row's error and does not stop the others", %{
    catalogue: catalogue,
    ctx: ctx
  } do
    item = F.item!(catalogue, %{sku: "GP-BLANK"})

    assert {:ok, %{"results" => [blank, found], "summary" => %{"found" => 1, "error" => 1}}} =
             run([%{"sku" => " "}, %{"sku" => "GP-BLANK"}], ctx)

    assert blank["error"]["code"] == "validation_failed"
    assert blank["error"]["message"] == "sku must not be empty"
    assert found["id"] == item.uuid
  end

  test "a product with no price and no extras answers nils, not errors", %{
    catalogue: catalogue,
    ctx: ctx
  } do
    item = F.item!(catalogue, %{base_price: nil, data: %{"_primary_language" => "en"}})

    assert {:ok, %{"results" => [row]}} = run([%{"id" => item.uuid}], ctx)

    assert row["price"] == nil
    assert row["compare_at"] == nil
    assert row["price_modifiers"] == %{}
    assert row["made_to_order"] == false
  end

  test "a product with a price but no currency, its own or the shop's, answers no price instead of money in no currency",
       %{catalogue: catalogue, ctx: ctx} do
    Repo.update_all(PhoenixKitBilling.Currency, set: [is_default: false])
    PhoenixKit.Cache.clear(:billing_currencies)
    on_exit(fn -> PhoenixKit.Cache.clear(:billing_currencies) end)
    assert PhoenixKitEcommerce.get_base_currency() == nil

    item =
      F.item!(catalogue, %{
        base_price: Decimal.new("12.00"),
        data: %{
          "_primary_language" => "en",
          "ecommerce" => %{"shop_status" => "active", "compare_at_price" => "15.00"}
        }
      })

    assert {:ok, %{"results" => [row]}} = run([%{"id" => item.uuid}], ctx)

    assert row["currency"] == nil
    assert row["price"] == nil
    assert row["compare_at"] == nil
  end

  test "shop_status_visible is the storefront's verdict for every status a product can be in",
       %{catalogue: catalogue, ctx: ctx} do
    for status <- ["active", "inactive", "discontinued"],
        shop_status <- [nil, "draft", "active", "archived", "weird"] do
      ecommerce = if shop_status, do: %{"shop_status" => shop_status}, else: %{}

      item =
        F.item!(catalogue, %{
          status: status,
          data: %{"_primary_language" => "en", "ecommerce" => ecommerce}
        })

      assert {:ok, %{"results" => [row]}} = run([%{"id" => item.uuid}], ctx)

      storefront = View.product_view(item).status == "active"

      assert row["shop_status_visible"] == storefront,
             "status #{status}, shop_status #{inspect(shop_status)}: API says #{row["shop_status_visible"]}, storefront says #{storefront}"
    end
  end

  test "a stored non-finite option price is shown as it is and does not fail the call",
       %{catalogue: catalogue, ctx: ctx} do
    bad =
      F.item!(catalogue, %{
        sku: "GP-INF",
        data: %{
          "_primary_language" => "en",
          "ecommerce" => %{
            "shop_status" => "active",
            "price_modifiers" => %{"liquid" => %{"a" => "Infinity", "b" => "NaN", "c" => "2"}}
          }
        }
      })

    good = F.item!(catalogue, %{sku: "GP-OK"})

    assert {:ok, %{"results" => [bad_row, good_row], "summary" => summary}} =
             run([%{"id" => bad.uuid}, %{"id" => good.uuid}], ctx)

    assert bad_row["price_modifiers"] == %{
             "liquid" => %{"a" => "Infinity", "b" => "NaN", "c" => "2.00"}
           }

    assert good_row["id"] == good.uuid
    assert summary == %{"found" => 2, "error" => 0}
  end

  test "a stored base_price that is not a number is answered as no price",
       %{catalogue: catalogue, ctx: ctx} do
    item = F.item!(catalogue, %{sku: "GP-NAN"})

    SQL.query!(
      Repo,
      "UPDATE phoenix_kit_cat_items SET base_price = 'NaN' WHERE uuid = $1",
      [Ecto.UUID.dump!(item.uuid)]
    )

    assert {:ok, %{"results" => [row]}} = run([%{"id" => item.uuid}], ctx)
    assert row["id"] == item.uuid
    assert row["price"] == nil
  end

  test "shop_status_visible is about the product's own status: a product in a hidden category still says true",
       %{catalogue: catalogue, ctx: ctx} do
    {:ok, category} =
      Catalogue.create_category(%{
        name: "API hidden #{System.unique_integer([:positive])}",
        catalogue_uuid: catalogue.uuid,
        data: %{"ecommerce" => %{"shop_status" => "hidden"}}
      })

    item = F.item!(catalogue, %{category_uuid: category.uuid})

    assert {:ok, %{"results" => [row]}} = run([%{"id" => item.uuid}], ctx)

    # The storefront hides this product (`exclude_hidden_categories`, query.ex:421-435).
    # The field does not claim to know that, which is why it is not called
    # "visible in the shop"; that needs a verdict that also looks at the categories.
    assert row["shop_status_visible"] == true
    refute Map.has_key?(row, "visible_in_shop")
  end

  test "a trashed product is not found", %{catalogue: catalogue, ctx: ctx} do
    item = F.item!(catalogue)
    {:ok, _} = Catalogue.trash_item(item)

    assert {:ok, %{"results" => [%{"error" => %{"code" => "not_found"}}]}} =
             run([%{"id" => item.uuid}], ctx)
  end

  test "reads a product that was never linked to Shopify like any other", %{
    catalogue: catalogue,
    ctx: ctx
  } do
    item =
      F.item!(catalogue, %{
        data: %{"_primary_language" => "en", "ecommerce" => %{"shop_status" => "active"}}
      })

    assert {:ok, %{"results" => [row], "summary" => %{"found" => 1}}} =
             run([%{"id" => item.uuid}], ctx)

    refute Map.has_key?(row, "shopify")
  end

  test "the legacy source answers unsupported_source and reads nothing", %{
    catalogue: catalogue,
    ctx: ctx
  } do
    item = F.item!(catalogue)
    F.put_config!("shop_product_source", "legacy")

    assert {:error, :unsupported_source, _detail, %{reason: "legacy_source"}} =
             run([%{"id" => item.uuid}], ctx)
  end

  test "a catalogue_id that is not the shop's is refused", %{catalogue: catalogue, ctx: ctx} do
    other = F.other_catalogue!()
    item = F.item!(catalogue)

    input = %{"catalogue_id" => other.uuid, "refs" => [%{"id" => item.uuid}]}

    assert {:error, :validation_failed, _detail, _context} =
             APICase.call("ecommerce.get_prices", input, ctx)
  end
end
