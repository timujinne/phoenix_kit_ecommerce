defmodule PhoenixKitEcommerce.API.OrderExportTest do
  @moduledoc """
  The order as an external system reads it (`OrderExport`): the fields and
  their formats, the lines against the catalogue, the shipping and payment
  blocks, the buyer's contacts only on request, and what never leaves.
  """

  use PhoenixKitEcommerce.DataCase, async: true

  @moduletag :billing_order_sync

  import PhoenixKitEcommerce.OrderFixtures

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.API.OrderExport
  alias PhoenixKitEcommerce.APIFixtures, as: F

  describe "the order" do
    test "carries identity, timestamps, money as decimal strings and an unmarked sync" do
      order = order!(%{"line_items" => [shipping_line()]})

      map = OrderExport.serialize(order)

      assert map["id"] == order.uuid
      assert map["number"] == order.order_number
      assert map["status"] == "pending"
      assert {:ok, _, 0} = DateTime.from_iso8601(map["created_at"])
      assert {:ok, _, 0} = DateTime.from_iso8601(map["updated_at"])
      assert %{"confirmed_at" => nil, "paid_at" => nil, "cancelled_at" => nil} = map
      assert map["currency"] == "UAH"
      refute Map.has_key?(map, "tax_included")
      refute Map.has_key?(map, "notes")

      assert map["totals"] == %{
               "subtotal" => "900.00",
               "discount" => "0.00",
               "shipping" => "42.50",
               "tax" => "0.00",
               "total" => "942.50"
             }

      assert %{"state" => "pending", "revision" => 1, "external_id" => nil, "error" => nil} =
               map["sync"]
    end

    test "survives a JSON round trip and never carries internal data" do
      order = order!()

      json = order |> OrderExport.serialize(contacts: true) |> Jason.encode!()

      refute json =~ order.internal_notes
      refute json =~ order.metadata["session_id"]
      refute json =~ "billing_snapshot"
      assert Jason.decode!(json)["id"] == order.uuid
    end

    test "reports the confirmation and payment times and status" do
      order = order!()
      {:ok, order} = Billing.confirm_order(order)
      {:ok, order} = Billing.mark_order_paid(order)

      map = OrderExport.serialize(order)

      assert map["status"] == "paid"
      assert is_binary(map["confirmed_at"]) and is_binary(map["paid_at"])
      assert map["payment"]["status"] == "paid"
    end

    test "the sync block follows the mark and reopens when the order changes" do
      order = order!()

      {:ok, order} =
        Billing.put_order_sync(order, %{revision: 1, state: "synced", external_id: "ext-1"})

      assert %{"state" => "synced", "external_id" => "ext-1", "revision" => 1} =
               OrderExport.serialize(order)["sync"]

      {:ok, order} = Billing.update_order(order, %{"notes" => "changed"})

      assert %{"state" => "pending", "external_id" => "ext-1", "revision" => 2} =
               OrderExport.serialize(order)["sync"]
    end

    test "include narrows the sections; the base fields stay" do
      map = OrderExport.serialize(order!(), include: [:lines])

      assert Map.has_key?(map, "lines")
      refute Map.has_key?(map, "customer")
      refute Map.has_key?(map, "shipping")
      refute Map.has_key?(map, "payment")
      assert map["totals"]["total"] == "942.50"
    end

    test "serialize_many keeps the order given" do
      [a, b, c] = for _ <- 1..3, do: order!()

      assert [c.uuid, a.uuid, b.uuid] ==
               Enum.map(OrderExport.serialize_many([c, a, b]), & &1["id"])

      assert OrderExport.serialize_many([], []) == []
    end
  end

  describe "lines" do
    @describetag :catalogue

    test "number the product lines, leave the shipping charge to its own block" do
      order =
        order!(%{
          "line_items" => [
            %{
              "name" => "A",
              "quantity" => 1,
              "unit_price" => "10",
              "total" => "10",
              "sku" => "A"
            },
            shipping_line(),
            %{
              "name" => "B",
              "quantity" => 3,
              "unit_price" => "5.5",
              "total" => "16.50",
              "sku" => "B"
            }
          ]
        })

      lines = OrderExport.serialize(order)["lines"]

      assert Enum.map(lines, &{&1["line"], &1["name"]}) == [{1, "A"}, {2, "B"}]

      assert %{"quantity" => "3", "unit_price" => "5.50", "total" => "16.50", "unit" => "piece"} =
               Enum.at(lines, 1)

      assert Enum.all?(lines, &(&1["price_on_request"] == false))
    end

    test "take sku, external id and unit from the catalogue item as it is now" do
      catalogue = F.shop_catalogue!()

      item =
        F.item!(catalogue, %{
          sku: "4820111111111",
          unit: "pack",
          data: %{"api" => %{"external_id" => "GUID-1"}}
        })

      order =
        order!(%{
          "line_items" => [
            %{
              "name" => "Moved",
              "quantity" => 1,
              "unit_price" => "1",
              "total" => "1",
              "sku" => "OLD-SKU",
              "catalogue_item_uuid" => item.uuid
            },
            %{
              "name" => "Same",
              "quantity" => 1,
              "unit_price" => "1",
              "total" => "1",
              "sku" => "4820111111111",
              "catalogue_item_uuid" => item.uuid
            }
          ]
        })

      [moved, same] = OrderExport.serialize(order)["lines"]

      assert %{
               "product_id" => product_id,
               "sku" => "4820111111111",
               "sku_at_order" => "OLD-SKU",
               "external_id" => "GUID-1",
               "unit" => "pack"
             } = moved

      assert product_id == item.uuid
      assert same["sku"] == "4820111111111"
      refute Map.has_key?(same, "sku_at_order")
    end

    test "keep the recorded sku for a product the catalogue no longer has" do
      order =
        order!(%{
          "line_items" => [
            %{
              "name" => "Gone",
              "quantity" => 1,
              "unit_price" => "1",
              "total" => "1",
              "sku" => "RECORDED",
              "catalogue_item_uuid" => Ecto.UUID.generate()
            },
            %{"name" => "Free text", "quantity" => 1, "unit_price" => "1", "total" => "1"}
          ]
        })

      [gone, free] = OrderExport.serialize(order)["lines"]

      assert %{"sku" => "RECORDED", "external_id" => nil} = gone
      refute Map.has_key?(gone, "sku_at_order")
      assert %{"sku" => nil, "product_id" => nil} = free
    end

    test "say whether each line was taxable; a line that does not say reads as taxable" do
      order =
        order!(%{
          "tax_amount" => Decimal.new("18.00"),
          "line_items" => [
            %{
              "name" => "Taxed",
              "quantity" => 1,
              "unit_price" => "10",
              "total" => "10",
              "taxable" => true
            },
            %{
              "name" => "Zero rated",
              "quantity" => 1,
              "unit_price" => "5",
              "total" => "5",
              "taxable" => false
            },
            %{"name" => "Old line", "quantity" => 1, "unit_price" => "1", "total" => "1"}
          ]
        })

      map = OrderExport.serialize(order)

      assert Enum.map(map["lines"], & &1["taxable"]) == [true, false, true]
      assert map["totals"]["tax"] == "18.00"
      refute Map.has_key?(map, "tax_included")
    end

    test "flag a line sold at a price on request" do
      order =
        order!(%{
          "line_items" => [
            %{
              "name" => "Quote",
              "quantity" => 1,
              "unit_price" => "0",
              "total" => "0",
              "price_on_request" => true
            }
          ]
        })

      assert [%{"price_on_request" => true, "total" => "0.00"}] =
               OrderExport.serialize(order)["lines"]
    end
  end

  describe "shipping" do
    test "is absent for an order that ships nothing" do
      assert OrderExport.serialize(order!())["shipping"] == nil
    end

    test "names the method, the provider, the destination and the amount" do
      {:ok, method} =
        Shop.create_shipping_method(%{
          "name" => "Courier",
          "price" => Decimal.new("42.50"),
          "active" => true
        })

      order =
        order!(%{
          "line_items" => [shipping_line()],
          "metadata" => %{
            "shipping_method_uuid" => method.uuid,
            "shipping_provider" => %{"provider" => "nova_poshta", "service" => "warehouse"},
            "shipping_pay_on_delivery" => true,
            "shipping_destination" => %{
              "locality" => %{"id" => "city-ref", "name" => "Kyiv", "country" => "UA"},
              "pickup_point" => %{"id" => "wh-ref", "name" => "Branch 5", "number" => "5"}
            }
          }
        })

      assert %{
               "method_id" => method_id,
               "method_code" => "courier",
               "name" => "Courier",
               "provider" => "nova_poshta",
               "service" => "warehouse",
               "pay_on_delivery" => true,
               "amount" => "42.50",
               "destination" => %{
                 "city" => "Kyiv",
                 "city_ref" => "city-ref",
                 "warehouse" => "Branch 5",
                 "warehouse_ref" => "wh-ref",
                 "country" => "UA"
               }
             } = OrderExport.serialize(order)["shipping"]

      assert method_id == method.uuid
    end

    test "the buyer's delivery address goes with the contacts only; the pickup point is public" do
      courier =
        order!(%{
          "line_items" => [shipping_line()],
          "metadata" => %{
            "shipping_destination" => %{
              "locality" => %{"id" => "city-ref", "name" => "Kyiv", "country" => "UA"},
              "address" => %{
                "postcode" => "01001",
                "street" => "Khreshchatyk",
                "house" => "1",
                "apartment" => "5"
              }
            }
          }
        })

      assert %{"city" => "Kyiv", "postcode" => nil, "address" => nil} =
               OrderExport.serialize(courier)["shipping"]["destination"]

      assert %{"city" => "Kyiv", "postcode" => "01001", "address" => "Khreshchatyk 1 5"} =
               OrderExport.serialize(courier, contacts: true)["shipping"]["destination"]

      typed =
        order!(%{
          "line_items" => [shipping_line()],
          "metadata" => %{
            "shipping_destination" => %{
              "address" => %{"line" => "1 Free Text St", "street" => "ignored"}
            }
          }
        })

      assert %{"address" => nil} = OrderExport.serialize(typed)["shipping"]["destination"]

      assert %{"address" => "1 Free Text St"} =
               OrderExport.serialize(typed, contacts: true)["shipping"]["destination"]

      branch =
        order!(%{
          "line_items" => [shipping_line()],
          "metadata" => %{
            "shipping_destination" => %{
              "pickup_point" => %{
                "id" => "wh-ref",
                "name" => "Branch 5",
                "postcode" => "02002",
                "address" => "5 Branch St"
              },
              "address" => %{"line" => "home address"}
            }
          }
        })

      assert %{"warehouse" => "Branch 5", "postcode" => "02002", "address" => "5 Branch St"} =
               OrderExport.serialize(branch)["shipping"]["destination"]
    end

    test "falls back to the shipping line when the method was deleted" do
      order = order!(%{"line_items" => [shipping_line("10")]})

      assert %{
               "method_id" => nil,
               "method_code" => nil,
               "name" => "Shipping: Courier",
               "amount" => "10.00"
             } =
               OrderExport.serialize(order)["shipping"]
    end
  end

  describe "payment" do
    test "names the option the buyer chose and says whether it is paid" do
      option =
        Billing.get_payment_option_by_code("cod") ||
          elem(
            Billing.create_payment_option(%{
              "name" => "Cash on delivery",
              "code" => "cod",
              "type" => "offline"
            }),
            1
          )

      order =
        order!(%{
          "payment_option_uuid" => option.uuid,
          "metadata" => %{"payment_option_code" => option.code}
        })

      assert %{"option_code" => code, "name" => name, "status" => "unpaid"} =
               OrderExport.serialize(order)["payment"]

      assert code == option.code
      assert name == option.name
    end

    test "an order without an option has only the status" do
      assert %{"option_code" => nil, "name" => nil, "status" => "unpaid"} =
               OrderExport.serialize(order!())["payment"]
    end
  end

  describe "customer" do
    test "is the buyer's id and type until contacts are asked for" do
      order = order!()

      assert OrderExport.serialize(order)["customer"] == %{
               "type" => "user",
               "id" => order.user_uuid
             }
    end

    test "the buyer's notes go with the contacts; without them the key is absent" do
      order = order!(%{"notes" => "call +380000000000, flat 5"})

      refute Map.has_key?(OrderExport.serialize(order), "notes")
      refute Map.has_key?(OrderExport.serialize(order, include: [:lines]), "notes")
      refute Jason.encode!(OrderExport.serialize(order)) =~ "+380000000000"

      assert OrderExport.serialize(order, contacts: true)["notes"] == "call +380000000000, flat 5"
    end

    test "a guest checkout is a guest" do
      order = order!(%{"metadata" => %{"guest_checkout" => true}})

      assert %{"type" => "guest"} = OrderExport.serialize(order)["customer"]
    end

    test "carries the contacts from the billing snapshot on request" do
      order = order!()

      assert %{
               "type" => "user",
               "first_name" => "Ivan",
               "last_name" => "Petrenko",
               "middle_name" => nil,
               "phone" => "+380000000" <> _,
               "email" => "buyer" <> _,
               "company" => nil,
               "tax_id" => nil,
               "address" => %{
                 "country" => "UA",
                 "city" => "Kyiv",
                 "postal_code" => "01001",
                 "line1" => "1 Test St",
                 "line2" => nil
               }
             } = OrderExport.serialize(order, contacts: true)["customer"]
    end

    test "a company buyer has the company name and tax id" do
      order =
        order!(%{
          "billing_snapshot" => %{
            "type" => "company",
            "company_name" => "Acme",
            "company_vat_number" => "1234567890",
            "email" => "acme@example.com"
          }
        })

      assert %{"company" => "Acme", "tax_id" => "1234567890", "email" => "acme@example.com"} =
               OrderExport.serialize(order, contacts: true)["customer"]
    end

    test "fills what the snapshot lacks from the billing profile" do
      user = fixture_user()

      {:ok, profile} =
        Billing.create_billing_profile(user, %{
          "type" => "individual",
          "first_name" => "Olena",
          "last_name" => "Shevchenko",
          "email" => "olena@example.com",
          "phone" => "+380501234567",
          "address_line1" => "2 Profile St",
          "city" => "Lviv",
          "postal_code" => "79000",
          "country" => "UA"
        })

      {:ok, order} =
        Billing.create_order(user, %{
          "status" => "pending",
          "currency" => "UAH",
          "total" => Decimal.new("10"),
          "billing_profile_uuid" => profile.uuid,
          "billing_snapshot" => %{"email" => "olena@example.com"}
        })

      assert %{
               "first_name" => "Olena",
               "address" => %{"city" => "Lviv", "line1" => "2 Profile St"}
             } =
               OrderExport.serialize(order, contacts: true)["customer"]
    end

    test "a guest's email comes from the checkout mark when nothing else has one" do
      order =
        order!(%{
          "billing_snapshot" => %{"first_name" => "Guest", "email" => "guest@example.com"},
          "metadata" => %{"guest_checkout" => true, "guest_checkout_email" => "guest@example.com"}
        })

      assert %{"email" => "guest@example.com"} =
               OrderExport.serialize(order, contacts: true)["customer"]
    end
  end
end
