defmodule PhoenixKitEcommerce.BaseCurrencyRepriceCatalogueTest do
  @moduledoc """
  `PhoenixKitEcommerce.reprice_for_base_change/3`'s CATALOGUE leg — the
  counterpart to `base_currency_reprice_test.exs`'s legacy suite, added on
  `stand/catalogue-product-source+currency-e1` once the legacy half was
  ported here from `feature/currency-e3` (see that function's moduledoc,
  "Product source scope").

  Needs `phoenix_kit_catalogue` loaded (with its own migrations applied to
  the test DB) — excluded via `test_helper.exs`'s `catalogue_exclude`
  whenever the optional dependency isn't present, same as
  `cart_catalogue_test.exs`/`catalogue_view_test.exs`. `async: false`:
  flips the process-wide `shop_product_source` config key.

  Money model pinned here (see the function's moduledoc for the full
  citation trail): the item's own `base_price` column;
  `data["ecommerce"]["compare_at_price"]`/`["cost_per_item"]` as decimal
  STRINGS; `data["ecommerce"]["currency"]` as the label; item-level
  `data["ecommerce"]["price_modifiers"]` (`option_key -> value_slug ->
  decimal string`, no per-value type tag) whose FIXED-vs-percent split is
  resolved through the owning CATEGORY's `data["ecommerce"]["option_schema"]`
  `modifier_type` — the same resolution the live storefront price calc
  uses. `markup_percentage`/`discount_percentage` are deliberately absent
  from every fixture here: they are percentages, currency-free by
  construction, and this suite has nothing to prove about them beyond
  "reprice never references them" (true by inspection of the diff, not
  something a test can usefully pin).
  """

  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :catalogue

  # Quiets the compiler's static xref check for `mix test` runs where the
  # optional `phoenix_kit_catalogue` dependency isn't declared — every test
  # in this module is excluded in that case (see `test_helper.exs`), so the
  # calls below are never actually reached.
  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Currency
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Options
  alias PhoenixKitEcommerce.ProductSource.Catalogue, as: CatalogueSource
  alias PhoenixKitEcommerce.ShopConfig

  setup do
    PhoenixKit.Cache.clear(:billing_currencies)
    Currency.put_request_currency(nil)
    on_exit(fn -> Currency.put_request_currency(nil) end)

    Repo.delete_all(PhoenixKitBilling.Currency)

    {:ok, _usd} =
      Billing.create_currency(%{
        code: "USD",
        name: "Dollar",
        symbol: "$",
        is_default: true,
        exchange_rate: "1.0"
      })

    {:ok, _eur} =
      Billing.create_currency(%{
        code: "EUR",
        name: "Euro",
        symbol: "€",
        exchange_rate: "0.909091"
      })

    set_product_source("catalogue")
    on_exit(fn -> set_product_source("legacy") end)

    :ok
  end

  # No `PhoenixKitEcommerce.update_config/2` exists yet — writes the
  # `phoenix_kit_shop_config` row directly, same as `cart_catalogue_test.exs`.
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

  defp billing_data(n) do
    %{
      "email" => "reprice-cat-#{n}@example.com",
      "first_name" => "Test",
      "last_name" => "Buyer",
      "address_line1" => "1 Test Street",
      "city" => "Testville",
      "postal_code" => "10001",
      "country" => "US"
    }
  end

  defp money_snapshot_cart(cart_uuid) do
    cart = Shop.get_cart!(cart_uuid)

    %{
      currency: cart.currency,
      base_currency: cart.base_currency,
      exchange_rate: cart.exchange_rate,
      subtotal: cart.subtotal,
      shipping_amount: cart.shipping_amount,
      tax_amount: cart.tax_amount,
      discount_amount: cart.discount_amount,
      total: cart.total,
      items:
        cart.items
        |> Enum.sort_by(& &1.uuid)
        |> Enum.map(fn item ->
          %{
            uuid: item.uuid,
            unit_price: item.unit_price,
            compare_at_price: item.compare_at_price,
            base_unit_price: item.base_unit_price,
            currency: item.currency,
            line_total: item.line_total
          }
        end)
    }
  end

  defp money_snapshot_order(order_uuid) do
    order = Billing.get_order_by_uuid(order_uuid)

    %{
      currency: order.currency,
      base_currency: order.base_currency,
      exchange_rate: order.exchange_rate,
      subtotal: order.subtotal,
      tax_amount: order.tax_amount,
      tax_rate: order.tax_rate,
      discount_amount: order.discount_amount,
      total: order.total,
      base_total: order.base_total,
      line_items: order.line_items
    }
  end

  test "reprices a catalogue item and its category's fixed modifiers; leaves the percentage, sibling data, carts and orders alone" do
    n = System.unique_integer([:positive])

    {:ok, cat} = Catalogue.create_catalogue(%{name: "decor3dprint"})

    {:ok, category} =
      Catalogue.create_category(%{
        name: "Vases #{n}",
        catalogue_uuid: cat.uuid,
        data: %{
          "ecommerce" => %{
            "option_schema" => [
              %{
                "key" => "material",
                "label" => "Material",
                "type" => "select",
                "options" => ["PLA", "PETG"],
                "affects_price" => true,
                "modifier_type" => "fixed",
                "price_modifiers" => %{"PLA" => "0", "PETG" => "10.00"}
              },
              %{
                "key" => "finish",
                "label" => "Finish",
                "type" => "select",
                "options" => ["Standard", "Premium"],
                "affects_price" => true,
                "modifier_type" => "percent",
                "price_modifiers" => %{"Standard" => "0", "Premium" => "20"}
              }
            ]
          }
        }
      })

    {:ok, item} =
      Catalogue.create_item(%{
        catalogue_uuid: cat.uuid,
        category_uuid: category.uuid,
        name: "Vase #{n}",
        base_price: Decimal.new("138.00"),
        status: "active",
        data: %{
          "ecommerce" => %{
            "shop_status" => "active",
            "currency" => "USD",
            "compare_at_price" => "180.00",
            "vendor" => "Acme",
            "tags" => ["vase", "ceramic"],
            "shopify" => %{"handle" => "vase-#{n}", "product_id" => "123"},
            # A fixed override on "material" (schema type "fixed") and a
            # percent override on "finish" (schema type "percent") — the
            # exact "both a fixed and a percentage modifier" fixture, and
            # the same numbers `base_currency_reprice_test.exs`'s legacy
            # suite pins for the identical fixed amount.
            "price_modifiers" => %{
              "material" => %{"petg" => "10.00"},
              "finish" => %{"premium" => "20"}
            }
          }
        }
      })

    {:ok, method} =
      Shop.create_shipping_method(%{
        "name" => "Flat#{n}",
        "price" => Decimal.new("10.00"),
        "active" => true
      })

    product = CatalogueSource.get_product(item.uuid, [])

    # A non-empty cart, left ACTIVE across the switch.
    Currency.put_request_currency("EUR")
    {:ok, cart} = Shop.create_cart(session_id: "reprice-cat-cart-#{n}")
    {:ok, cart} = Shop.add_to_cart(cart, product, 1)
    {:ok, cart} = Shop.set_cart_shipping(cart, method, "US")
    Currency.put_request_currency(nil)

    cart_before = money_snapshot_cart(cart.uuid)
    assert cart_before.items != []

    # A second cart, converted to an order BEFORE the switch.
    Currency.put_request_currency("EUR")
    {:ok, order_cart} = Shop.create_cart(session_id: "reprice-cat-order-#{n}")
    {:ok, order_cart} = Shop.add_to_cart(order_cart, product, 1)
    {:ok, order_cart} = Shop.set_cart_shipping(order_cart, method, "US")
    Currency.put_request_currency(nil)

    {:ok, order} = Shop.convert_cart_to_order(order_cart, billing_data: billing_data(n))
    order_before = money_snapshot_order(order.uuid)

    # -- the operation under test --
    assert {:ok,
            %{
              shipping_methods: shipping_methods,
              catalogue_items: catalogue_items,
              catalogue_category_modifiers: catalogue_category_modifiers,
              catalogue_item_modifiers: catalogue_item_modifiers
            }} = Shop.reprice_for_base_change("USD", "EUR", Decimal.new("0.909091"))

    assert shipping_methods == 1
    assert catalogue_items == 1
    # "material" is fixed: both its entries ("PLA" => "0", "PETG" =>
    # "10.00") are touched = 2. "finish" is percent and contributes 0.
    assert catalogue_category_modifiers == 2
    # Only the item's "material" override is fixed; "finish" is percent.
    assert catalogue_item_modifiers == 1

    reloaded_item = Catalogue.get_item!(item.uuid)
    assert Decimal.equal?(reloaded_item.base_price, Decimal.new("125.45"))

    ecommerce = reloaded_item.data["ecommerce"]
    assert Decimal.equal?(Decimal.new(ecommerce["compare_at_price"]), Decimal.new("163.64"))
    assert ecommerce["currency"] == "EUR"

    assert Decimal.equal?(
             Decimal.new(ecommerce["price_modifiers"]["material"]["petg"]),
             Decimal.new("9.09")
           )

    # Percent entry: byte-identical, not merely numerically unchanged.
    assert ecommerce["price_modifiers"]["finish"]["premium"] == "20"

    # Every sibling key in data["ecommerce"] survives the merge untouched.
    assert ecommerce["shop_status"] == "active"
    assert ecommerce["vendor"] == "Acme"
    assert ecommerce["tags"] == ["vase", "ceramic"]
    assert ecommerce["shopify"] == %{"handle" => "vase-#{n}", "product_id" => "123"}

    reloaded_category = Catalogue.get_category!(category.uuid)
    [material, finish] = reloaded_category.data["ecommerce"]["option_schema"]

    assert Decimal.equal?(Decimal.new(material["price_modifiers"]["PLA"]), Decimal.new("0"))

    assert Decimal.equal?(
             Decimal.new(material["price_modifiers"]["PETG"]),
             Decimal.new("9.09")
           )

    assert finish["modifier_type"] == "percent"
    assert finish["price_modifiers"]["Premium"] == "20"
    assert finish["price_modifiers"]["Standard"] == "0"

    reloaded_method = Shop.get_shipping_method!(method.uuid)
    assert Decimal.equal?(reloaded_method.price, Decimal.new("9.09"))

    # Carts and orders: untouched, in EVERY money field, not spot-checked.
    assert money_snapshot_cart(cart.uuid) == cart_before
    assert money_snapshot_order(order.uuid) == order_before
  end

  test "refuses when a catalogue item's explicit override type disagrees with its category's schema" do
    n = System.unique_integer([:positive])

    {:ok, cat} = Catalogue.create_catalogue(%{name: "decor3dprint"})

    {:ok, category} =
      Catalogue.create_category(%{
        name: "Ambiguous #{n}",
        catalogue_uuid: cat.uuid,
        data: %{
          "ecommerce" => %{
            "option_schema" => [
              %{
                "key" => "material",
                "label" => "Material",
                "type" => "select",
                "options" => ["PLA", "PETG"],
                "affects_price" => true,
                "modifier_type" => "fixed",
                "price_modifiers" => %{"PLA" => "0", "PETG" => "10.00"}
              }
            ]
          }
        }
      })

    # "material" is schema `modifier_type: "fixed"`; this item's override
    # explicitly claims "percent" for the same key — exactly the
    # disagreement the pre-flight guard exists to catch, catalogue-shaped.
    {:ok, item} =
      Catalogue.create_item(%{
        catalogue_uuid: cat.uuid,
        category_uuid: category.uuid,
        name: "Ambiguous Vase #{n}",
        base_price: Decimal.new("60.00"),
        status: "active",
        data: %{
          "ecommerce" => %{
            "shop_status" => "active",
            "currency" => "USD",
            "price_modifiers" => %{
              "material" => %{"petg" => %{"type" => "percent", "value" => "5"}}
            }
          }
        }
      })

    item_before = Catalogue.get_item!(item.uuid)
    category_before = Catalogue.get_category!(category.uuid)

    assert {:error, {:ambiguous_modifier_overrides, mismatches}} =
             Shop.reprice_for_base_change("USD", "EUR", Decimal.new("0.909091"))

    assert mismatches == [
             %{
               item_uuid: item.uuid,
               option_key: "material",
               stored_type: "percent",
               schema_type: "fixed"
             }
           ]

    # Nothing written anywhere — the whole operation refused up front.
    assert Catalogue.get_item!(item.uuid) == item_before
    assert Catalogue.get_category!(category.uuid) == category_before
  end

  test "reprices a category's own fixed option-schema modifiers even with no items in it, leaving its percentage alone" do
    n = System.unique_integer([:positive])

    {:ok, cat} = Catalogue.create_catalogue(%{name: "decor3dprint"})

    {:ok, category} =
      Catalogue.create_category(%{
        name: "Empty Category #{n}",
        catalogue_uuid: cat.uuid,
        data: %{
          "ecommerce" => %{
            "option_schema" => [
              %{
                "key" => "material",
                "label" => "Material",
                "type" => "select",
                "options" => ["PLA", "PETG"],
                "affects_price" => true,
                "modifier_type" => "fixed",
                "price_modifiers" => %{"PLA" => "0", "PETG" => "10.00"}
              },
              %{
                "key" => "finish",
                "label" => "Finish",
                "type" => "select",
                "options" => ["Standard", "Premium"],
                "affects_price" => true,
                "modifier_type" => "percent",
                "price_modifiers" => %{"Standard" => "0", "Premium" => "20"}
              }
            ]
          }
        }
      })

    assert {:ok,
            %{
              catalogue_items: 0,
              catalogue_category_modifiers: catalogue_category_modifiers
            }} = Shop.reprice_for_base_change("USD", "EUR", Decimal.new("0.909091"))

    # "material" (fixed, 2 entries: PLA/PETG). "finish" is percent and
    # contributes 0. Reached purely by listing categories, not through any
    # item — proves the category leg doesn't depend on having items.
    assert catalogue_category_modifiers == 2

    reloaded_category = Catalogue.get_category!(category.uuid)
    [material, finish] = reloaded_category.data["ecommerce"]["option_schema"]

    assert Decimal.equal?(Decimal.new(material["price_modifiers"]["PLA"]), Decimal.new("0"))

    assert Decimal.equal?(
             Decimal.new(material["price_modifiers"]["PETG"]),
             Decimal.new("9.09")
           )

    assert finish["modifier_type"] == "percent"
    assert finish["price_modifiers"]["Premium"] == "20"
    assert finish["price_modifiers"]["Standard"] == "0"
  end

  test "reprices an item with no category without crashing; price_modifiers resolve only against the global schema" do
    n = System.unique_integer([:positive])

    {:ok, _} =
      Options.update_global_options([
        %{
          "key" => "material",
          "label" => "Material",
          "type" => "select",
          "options" => ["PLA", "PETG"],
          "affects_price" => true,
          "modifier_type" => "fixed",
          "price_modifiers" => %{"PLA" => "0", "PETG" => "10.00"}
        }
      ])

    {:ok, cat} = Catalogue.create_catalogue(%{name: "decor3dprint"})

    {:ok, item} =
      Catalogue.create_item(%{
        catalogue_uuid: cat.uuid,
        name: "Uncategorized Vase #{n}",
        base_price: Decimal.new("50.00"),
        status: "active",
        data: %{
          "ecommerce" => %{
            "shop_status" => "active",
            "currency" => "USD",
            "price_modifiers" => %{
              # Resolves via the GLOBAL schema — there is no category to
              # check at all.
              "material" => %{"petg" => "10.00"},
              # Orphaned: matches no option in any schema. Left untouched,
              # not refused (see `reprice_catalogue_price_modifiers/4`'s
              # comment) — this is the SAME code path a categorized item's
              # unmatched key takes, just reached via a `nil` category
              # instead of a category whose schema doesn't have the key.
              "size" => %{"large" => "7.00"}
            }
          }
        }
      })

    assert item.category_uuid == nil

    assert {:ok,
            %{
              catalogue_items: 1,
              catalogue_item_modifiers: catalogue_item_modifiers
            }} = Shop.reprice_for_base_change("USD", "EUR", Decimal.new("0.909091"))

    assert catalogue_item_modifiers == 1

    reloaded_item = Catalogue.get_item!(item.uuid)
    assert Decimal.equal?(reloaded_item.base_price, Decimal.new("45.45"))

    ecommerce = reloaded_item.data["ecommerce"]
    assert ecommerce["currency"] == "EUR"

    assert Decimal.equal?(
             Decimal.new(ecommerce["price_modifiers"]["material"]["petg"]),
             Decimal.new("9.09")
           )

    # Orphaned key: byte-identical, not repriced, not refused.
    assert ecommerce["price_modifiers"]["size"]["large"] == "7.00"
  end
end
