defmodule PhoenixKitEcommerce.BaseCurrencyRepriceTest do
  @moduledoc """
  `PhoenixKitEcommerce.reprice_for_base_change/3` is the ecommerce half of
  the base-currency-change operation (spec §4.9 steps 2-4). Billing owns
  steps 1 and 5 (`PhoenixKitBilling.change_base_currency/2`) and calls this
  function as its `:reprice` callback, INSIDE its own transaction, handing
  over the multiplier it already computed. This suite calls the function
  directly — the ecommerce half is unit-tested independent of that
  transaction.

  NOTE ON SCOPE: this checkout's `feature/currency-e3` branch (stacked on
  e2, no e3 commits of its own yet) does not carry the catalogue product
  source (`ProductSource` / `phoenix_kit_catalogue`). That work exists only
  on `stand/catalogue-product-source+currency-e1`, never merged into the
  e1->e2->e3 stack — confirmed by grepping this checkout's `lib/` (no
  `ProductSource` symbol anywhere) and `mix.exs` (no `phoenix_kit_catalogue`
  dependency). So this suite exercises only the LEGACY
  `PhoenixKitEcommerce.Product` path. Catalogue-item repricing is simply
  not implemented here; it needs its own coverage once that branch merges
  into the currency stack.

  Legacy price modifiers do not live in one per-item field the way a
  catalogue item's `data["ecommerce"]["price_modifiers"]` reportedly would.
  Reading `options/options.ex` shows they are split across three stores:
  the global option schema (`phoenix_kit_shop_config`, key
  `"global_option_schema"`), each category's own `option_schema`, and a
  product's own `metadata["_price_modifiers"]` overrides. All three hold
  FIXED-amount entries next to PERCENT ones (`modifier_type` per option);
  only the FIXED ones are money and must reprice, the PERCENT ones are
  currency-free and must not move. This suite pins the global-schema case
  (the one the operation would most obviously forget); the option system
  itself is unit-tested elsewhere.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Currency
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Options
  alias PhoenixKitEcommerce.Product

  defp lang do
    PhoenixKitEcommerce.SlugResolver.normalize_language_public(
      PhoenixKitEcommerce.Translations.default_language()
    )
  end

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
      ])

    :ok
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

  defp money_snapshot_product(product_uuid) do
    product = Shop.get_product!(product_uuid)

    %{
      price: product.price,
      compare_at_price: product.compare_at_price,
      cost_per_item: product.cost_per_item,
      currency: product.currency,
      metadata: product.metadata
    }
  end

  # `create_product/1` runs every attrs map through
  # `MetadataValidator.normalize_product_attrs/1`, which collapses an
  # explicit `%{"type" => ..., "value" => ...}` override to a bare string
  # on the way in — so building a fixture that actually PERSISTS the
  # explicit format (the only way to exercise the pre-flight guard at
  # all) has to go around that context function, straight through the
  # changeset, the same way data imported before this normalizer existed
  # would already sit in the table.
  defp insert_product_with_raw_metadata!(attrs) do
    %Product{}
    |> Product.changeset(attrs)
    |> Repo.insert!()
  end

  defp billing_data(n) do
    %{
      "email" => "reprice-#{n}@example.com",
      "first_name" => "Test",
      "last_name" => "Buyer",
      "address_line1" => "1 Test Street",
      "city" => "Testville",
      "postal_code" => "10001",
      "country" => "US"
    }
  end

  test "reprices products, global-schema modifiers and shipping methods; leaves carts and orders alone" do
    n = System.unique_integer([:positive])

    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Vase #{n}", lang() => "Vase #{n}"},
        "slug" => %{lang() => "reprice-#{n}"},
        "price" => Decimal.new("138.00"),
        "compare_at_price" => Decimal.new("180.00"),
        "status" => "active",
        "currency" => "USD",
        "requires_shipping" => true,
        "weight_grams" => 300
      })

    {:ok, method} =
      Shop.create_shipping_method(%{
        "name" => "Flat#{n}",
        "price" => Decimal.new("10.00"),
        "free_above_amount" => Decimal.new("130.00"),
        "min_order_amount" => Decimal.new("20.00"),
        "max_order_amount" => Decimal.new("500.00"),
        "active" => true
      })

    # A non-empty cart, left ACTIVE across the switch.
    Currency.put_request_currency("EUR")
    {:ok, cart} = Shop.create_cart(session_id: "reprice-cart-#{n}")
    {:ok, cart} = Shop.add_to_cart(cart, product, 1)
    {:ok, cart} = Shop.set_cart_shipping(cart, method, "US")
    Currency.put_request_currency(nil)

    cart_before = money_snapshot_cart(cart.uuid)
    assert cart_before.items != []

    # A second cart, converted to an order BEFORE the switch.
    Currency.put_request_currency("EUR")
    {:ok, order_cart} = Shop.create_cart(session_id: "reprice-order-#{n}")
    {:ok, order_cart} = Shop.add_to_cart(order_cart, product, 1)
    {:ok, order_cart} = Shop.set_cart_shipping(order_cart, method, "US")
    Currency.put_request_currency(nil)

    {:ok, order} = Shop.convert_cart_to_order(order_cart, billing_data: billing_data(n))
    order_before = money_snapshot_order(order.uuid)

    # -- the operation under test --
    assert {:ok,
            %{
              products: products,
              shipping_methods: shipping_methods,
              global_modifiers: global_modifiers,
              category_modifiers: category_modifiers,
              product_modifiers: product_modifiers
            }} = Shop.reprice_for_base_change("USD", "EUR", Decimal.new("0.909091"))

    assert products == 1
    assert shipping_methods == 1
    # "material" is fixed: both its entries ("PLA" => "0", "PETG" =>
    # "10.00") are touched = 2. "finish" is percent and contributes 0.
    assert global_modifiers == 2
    # No categories exist in this test.
    assert category_modifiers == 0
    # This test's product has no metadata override.
    assert product_modifiers == 0

    reloaded_product = Shop.get_product!(product.uuid)
    assert Decimal.equal?(reloaded_product.price, Decimal.new("125.45"))
    assert Decimal.equal?(reloaded_product.compare_at_price, Decimal.new("163.64"))
    assert reloaded_product.currency == "EUR"

    [material, finish] = Options.get_global_options()
    assert Decimal.equal?(Decimal.new(material["price_modifiers"]["PLA"]), Decimal.new("0"))
    assert Decimal.equal?(Decimal.new(material["price_modifiers"]["PETG"]), Decimal.new("9.09"))
    assert finish["modifier_type"] == "percent"
    assert Decimal.equal?(Decimal.new(finish["price_modifiers"]["Premium"]), Decimal.new("20"))
    assert Decimal.equal?(Decimal.new(finish["price_modifiers"]["Standard"]), Decimal.new("0"))

    reloaded_method = Shop.get_shipping_method!(method.uuid)
    assert Decimal.equal?(reloaded_method.price, Decimal.new("9.09"))
    assert Decimal.equal?(reloaded_method.free_above_amount, Decimal.new("118.18"))
    assert Decimal.equal?(reloaded_method.min_order_amount, Decimal.new("18.18"))
    assert Decimal.equal?(reloaded_method.max_order_amount, Decimal.new("454.55"))
    assert reloaded_method.currency == "EUR"

    # Carts and orders: untouched, in EVERY money field, not spot-checked.
    assert money_snapshot_cart(cart.uuid) == cart_before
    assert money_snapshot_order(order.uuid) == order_before
  end

  test "reprices category-schema fixed modifiers and per-product overrides, leaving percent alone" do
    n = System.unique_integer([:positive])

    {:ok, category} =
      Shop.create_category(%{
        "name" => %{"en" => "Pots #{n}", lang() => "Pots #{n}"},
        "slug" => %{lang() => "pots-#{n}"},
        "option_schema" => [
          %{
            "key" => "size",
            "label" => "Size",
            "type" => "select",
            "options" => ["S", "L"],
            "affects_price" => true,
            "modifier_type" => "fixed",
            "allow_override" => true,
            "price_modifiers" => %{"S" => "0", "L" => "20.00"}
          }
        ]
      })

    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Pot #{n}", lang() => "Pot #{n}"},
        "slug" => %{lang() => "reprice-cat-#{n}"},
        "price" => Decimal.new("50.00"),
        "status" => "active",
        "currency" => "USD",
        "requires_shipping" => false,
        "category_uuid" => category.uuid,
        "metadata" => %{"_price_modifiers" => %{"size" => %{"L" => "15.00"}}}
      })

    assert {:ok,
            %{
              products: 1,
              shipping_methods: 0,
              global_modifiers: global_modifiers,
              category_modifiers: category_modifiers,
              product_modifiers: product_modifiers
            }} = Shop.reprice_for_base_change("USD", "EUR", Decimal.new("0.909091"))

    # The `setup` block's global schema is still in effect (each test gets
    # its own sandboxed transaction, so it runs fresh here too): "material"
    # (fixed, 2 entries: "PLA"/"PETG").
    assert global_modifiers == 2
    # This test's own category schema ("size", fixed, 2 entries: "S"/"L").
    assert category_modifiers == 2
    # The product's own override on "L".
    assert product_modifiers == 1

    reloaded_category = Shop.get_category!(category.uuid)
    [size_option] = reloaded_category.option_schema
    assert Decimal.equal?(Decimal.new(size_option["price_modifiers"]["L"]), Decimal.new("18.18"))

    reloaded_product = Shop.get_product!(product.uuid)
    assert Decimal.equal?(reloaded_product.price, Decimal.new("45.45"))
    assert reloaded_product.currency == "EUR"

    override = reloaded_product.metadata["_price_modifiers"]["size"]["L"]
    assert Decimal.equal?(Decimal.new(override), Decimal.new("13.64"))
  end

  test "refuses when an explicit override's type disagrees with its option's schema, and writes nothing" do
    n = System.unique_integer([:positive])

    {:ok, control_product} =
      Shop.create_product(%{
        "title" => %{"en" => "Control #{n}", lang() => "Control #{n}"},
        "slug" => %{lang() => "reprice-control-#{n}"},
        "price" => Decimal.new("100.00"),
        "status" => "active",
        "currency" => "USD",
        "requires_shipping" => false
      })

    # "material" is schema `modifier_type: "fixed"` (see setup); this
    # override explicitly claims "percent" for the same option/value —
    # exactly the disagreement the pre-flight guard exists to catch.
    ambiguous_product =
      insert_product_with_raw_metadata!(%{
        "title" => %{"en" => "Ambiguous #{n}", lang() => "Ambiguous #{n}"},
        "slug" => %{lang() => "reprice-ambiguous-#{n}"},
        "price" => Decimal.new("60.00"),
        "status" => "active",
        "currency" => "USD",
        "requires_shipping" => false,
        "metadata" => %{
          "_price_modifiers" => %{
            "material" => %{"PETG" => %{"type" => "percent", "value" => "5"}}
          }
        }
      })

    control_before = money_snapshot_product(control_product.uuid)
    ambiguous_before = money_snapshot_product(ambiguous_product.uuid)
    global_options_before = Options.get_global_options()

    assert {:error, {:ambiguous_modifier_overrides, mismatches}} =
             Shop.reprice_for_base_change("USD", "EUR", Decimal.new("0.909091"))

    assert mismatches == [
             %{
               product_uuid: ambiguous_product.uuid,
               option_key: "material",
               stored_type: "percent",
               schema_type: "fixed"
             }
           ]

    # Nothing written anywhere — not even the unrelated, otherwise-fine
    # control product — proving the WHOLE operation refused up front
    # rather than skipping just the one bad row.
    assert money_snapshot_product(control_product.uuid) == control_before
    assert money_snapshot_product(ambiguous_product.uuid) == ambiguous_before
    assert Options.get_global_options() == global_options_before
  end

  test "an explicit override whose type agrees with its schema does not refuse, and reprices normally" do
    n = System.unique_integer([:positive])

    # Same explicit-map shape as the mismatch case, but "type" agrees
    # with "material"'s schema default ("fixed") — the normalizer's
    # eventual collapse to a bare string is lossless here, so this must
    # NOT refuse.
    product =
      insert_product_with_raw_metadata!(%{
        "title" => %{"en" => "Agrees #{n}", lang() => "Agrees #{n}"},
        "slug" => %{lang() => "reprice-agrees-#{n}"},
        "price" => Decimal.new("70.00"),
        "status" => "active",
        "currency" => "USD",
        "requires_shipping" => false,
        "metadata" => %{
          "_price_modifiers" => %{
            "material" => %{"PETG" => %{"type" => "fixed", "value" => "12.00"}}
          }
        }
      })

    assert {:ok, %{products: 1, product_modifiers: product_modifiers}} =
             Shop.reprice_for_base_change("USD", "EUR", Decimal.new("0.909091"))

    assert product_modifiers == 1

    reloaded = Shop.get_product!(product.uuid)
    assert Decimal.equal?(reloaded.price, Decimal.new("63.64"))
    assert reloaded.currency == "EUR"

    override = reloaded.metadata["_price_modifiers"]["material"]["PETG"]
    assert Decimal.equal?(Decimal.new(override), Decimal.new("10.91"))
  end
end
