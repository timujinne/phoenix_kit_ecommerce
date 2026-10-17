defmodule PhoenixKitEcommerce.API.PricePlanTest do
  @moduledoc """
  Planning one `ecommerce.set_prices` row: what changes, whether it is
  dangerous, what is written. Pure: items are plain maps.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.API.PricePlan

  defp dec(value), do: Decimal.new(value)

  defp item(overrides \\ %{}) do
    Map.merge(
      %{
        uuid: "item-1",
        base_price: dec("100.00"),
        status: "active",
        data: %{
          "ecommerce" => %{
            "compare_at_price" => "120.00",
            "price_modifiers" => %{"liquid" => %{"black" => "32.00", "blue" => 5}},
            "shopify" => %{"product_id" => "9001", "handle" => "mug"},
            "tags" => ["a"]
          }
        }
      },
      overrides
    )
  end

  defp sets do
    [%{key: "catalogue_set_liquid", values: [%{key: "black"}, %{key: "blue"}, %{key: "red"}]}]
  end

  defp plan(row, item \\ item(), opts \\ []) do
    PricePlan.plan(row, item, Keyword.merge([pct: 30, sets: sets()], opts))
  end

  defp plan!(row, item \\ item(), opts \\ []) do
    assert {:ok, plan} = plan(row, item, opts)
    plan
  end

  describe "a price" do
    test "the same price changes nothing and writes nothing" do
      plan = plan!(%{"price" => "100.00"})

      refute plan.changed?
      assert plan.changes == %{}
      assert plan.attrs == %{}
      assert plan.owned_paths == []
    end

    test "a new price is a base_price write, with no data path" do
      plan = plan!(%{"price" => "110.00"})

      assert plan.changed?
      assert plan.changes == %{"price" => %{"from" => "100.00", "to" => "110.00"}}
      assert plan.attrs == %{base_price: dec("110.00")}
      assert plan.owned_paths == []
    end

    test "a first price is never held back, whatever the number" do
      for current <- [nil, dec("0.00")] do
        plan = plan!(%{"price" => "5000.00"}, item(%{base_price: current}))
        refute plan.dangerous?
      end
    end

    test "a price of zero is held whatever it replaces: a first price included" do
      for current <- [nil, dec("5.00")] do
        assert plan!(%{"price" => "0.00"}, item(%{base_price: current})).dangerous?
      end
    end

    test "a price that is zero already and stays zero is not a change to hold" do
      plan = plan!(%{"price" => "0.00", "compare_at" => "5.00"}, item(%{base_price: dec("0.00")}))

      refute plan.dangerous?
    end

    test "exactly the threshold is not 'more than', one cent past it is" do
      refute plan!(%{"price" => "130.00"}).dangerous?
      assert plan!(%{"price" => "130.01"}).dangerous?
      refute plan!(%{"price" => "70.00"}).dangerous?
      assert plan!(%{"price" => "69.99"}).dangerous?
    end

    test "a price that falls to zero is a 100 percent move" do
      assert plan!(%{"price" => "0.00"}).dangerous?
    end

    test "the threshold is the one given" do
      refute plan!(%{"price" => "190.00"}, item(), pct: 100).dangerous?
      assert plan!(%{"price" => "100.01"}, item(), pct: 0).dangerous?
    end

    test "refuses prices that are rounded, misread or not strings" do
      for bad <- ["12,5", "12.505", "-1", "1e3", " 5", 12.5, 12, nil] do
        assert {:error, [%{path: "price"}]} = plan(%{"price" => bad})
      end
    end
  end

  describe "compare_at" do
    test "sets it as a string at its own path" do
      plan = plan!(%{"compare_at" => "150.00"})

      assert plan.changes == %{"compare_at" => %{"from" => "120.00", "to" => "150.00"}}
      assert plan.attrs == %{data: %{"ecommerce" => %{"compare_at_price" => "150.00"}}}
      assert plan.owned_paths == [["ecommerce", "compare_at_price"]]
    end

    test "null clears it" do
      plan = plan!(%{"compare_at" => nil})

      assert plan.attrs == %{data: %{"ecommerce" => %{"compare_at_price" => nil}}}
      assert plan.changes["compare_at"]["to"] == nil
    end

    test "warns when it is not above the price, and is not dangerous by itself" do
      plan = plan!(%{"compare_at" => "90.00"})

      assert "compare_at_not_above_price" in plan.warnings
      refute plan.dangerous?
    end
  end

  describe "guard (what the plan reads of the item)" do
    defp with_modifiers(modifiers),
      do: item(%{data: %{"ecommerce" => %{"price_modifiers" => modifiers}}})

    test "leaves out the option prices the row does not name" do
      row = %{"price_modifiers" => %{"liquid" => %{"red" => "3.00"}}}
      before = plan!(row, with_modifiers(%{"liquid" => %{"black" => "32.00"}}))

      synced =
        plan!(row, with_modifiers(%{"liquid" => %{"black" => "40.00"}, "size" => %{"l" => "9"}}))

      refute before.from == synced.from
      assert before.guard == synced.guard
    end

    test "carries the option price the row names, the base price and the compare-at price" do
      row = %{"price_modifiers" => %{"liquid" => %{"black" => "50.00"}}}
      base = plan!(row, with_modifiers(%{"liquid" => %{"black" => "32.00"}}))

      refute base.guard == plan!(row, with_modifiers(%{"liquid" => %{"black" => "33.00"}})).guard

      refute base.guard ==
               plan!(row, %{
                 with_modifiers(%{"liquid" => %{"black" => "32.00"}})
                 | base_price: dec("90.00")
               }).guard

      assert base.guard.price == dec("100.00")
      assert base.guard.price_modifiers == %{"liquid" => %{"black" => "32.00"}}
    end
  end

  describe "price_modifiers" do
    test "adds a value and owns only that leaf: the stored ones, a numeric leaf included, are not in the write" do
      plan = plan!(%{"price_modifiers" => %{"liquid" => %{"red" => "3.00"}}})

      assert plan.changes == %{"price_modifiers.liquid.red" => %{"from" => nil, "to" => "3.00"}}

      # Only the leaf the row writes, so a concurrent writer of any other
      # option or value (the API, the Shopify sync) is never overwritten.
      assert plan.attrs.data["ecommerce"]["price_modifiers"] == %{"liquid" => %{"red" => "3.00"}}
      assert plan.owned_paths == [["ecommerce", "price_modifiers", "liquid", "red"]]
      refute plan.dangerous?
    end

    test "null removes one value: an explicit nil at that leaf, the catalogue prunes what it empties" do
      plan = plan!(%{"price_modifiers" => %{"liquid" => %{"black" => nil, "blue" => nil}}})

      assert plan.attrs.data["ecommerce"]["price_modifiers"] ==
               %{"liquid" => %{"black" => nil, "blue" => nil}}

      assert plan.owned_paths == [
               ["ecommerce", "price_modifiers", "liquid", "black"],
               ["ecommerce", "price_modifiers", "liquid", "blue"]
             ]

      assert plan.changes["price_modifiers.liquid.black"] == %{"from" => "32.00", "to" => nil}
      assert plan.changes["price_modifiers.liquid.blue"] == %{"from" => "5.00", "to" => nil}
    end

    test "a stored non-finite leaf is kept as it is and can be replaced or removed" do
      stored =
        item(%{
          data: %{
            "ecommerce" => %{
              "price_modifiers" => %{"liquid" => %{"black" => "Infinity", "blue" => "NaN"}}
            }
          }
        })

      assert {:ok, set} =
               plan(%{"price_modifiers" => %{"liquid" => %{"black" => "4.00"}}}, stored)

      assert set.changed?
      assert set.changes["price_modifiers.liquid.black"]["to"] == "4.00"
      refute set.dangerous?

      assert {:ok, removed} =
               plan(
                 %{"price_modifiers" => %{"liquid" => %{"black" => nil, "blue" => nil}}},
                 stored
               )

      assert removed.changed?
      refute removed.dangerous?

      assert {:ok, price_only} = plan(%{"price" => "100.00"}, stored)
      refute price_only.changed?
    end

    test "removing a modifier that is not there changes nothing" do
      plan = plan!(%{"price_modifiers" => %{"liquid" => %{"red" => nil}}})
      refute plan.changed?
    end

    test "moving a non-zero modifier past the threshold is dangerous" do
      assert plan!(%{"price_modifiers" => %{"liquid" => %{"black" => "50.00"}}}).dangerous?
      assert plan!(%{"price_modifiers" => %{"liquid" => %{"black" => nil}}}).dangerous?
      refute plan!(%{"price_modifiers" => %{"liquid" => %{"black" => "33.00"}}}).dangerous?
    end

    test "a new option price is judged against the product's price: a big discount or surcharge is held" do
      assert plan!(%{"price_modifiers" => %{"liquid" => %{"red" => "-99.00"}}}).dangerous?
      assert plan!(%{"price_modifiers" => %{"liquid" => %{"red" => "-100.00"}}}).dangerous?
      assert plan!(%{"price_modifiers" => %{"liquid" => %{"red" => "999.00"}}}).dangerous?
    end

    test "a new option price at exactly the threshold is not held, one cent past it is" do
      refute plan!(%{"price_modifiers" => %{"liquid" => %{"red" => "30.00"}}}).dangerous?
      assert plan!(%{"price_modifiers" => %{"liquid" => %{"red" => "30.01"}}}).dangerous?
      refute plan!(%{"price_modifiers" => %{"liquid" => %{"red" => "-30.00"}}}).dangerous?
      assert plan!(%{"price_modifiers" => %{"liquid" => %{"red" => "-30.01"}}}).dangerous?
      refute plan!(%{"price_modifiers" => %{"liquid" => %{"red" => "3.00"}}}).dangerous?
    end

    test "a stored zero option price is no exemption" do
      zero =
        item(%{data: %{"ecommerce" => %{"price_modifiers" => %{"liquid" => %{"red" => "0.00"}}}}})

      assert plan!(%{"price_modifiers" => %{"liquid" => %{"red" => "9999999999.00"}}}, zero).dangerous?
      refute plan!(%{"price_modifiers" => %{"liquid" => %{"red" => "1.00"}}}, zero).dangerous?
    end

    test "removing a large option price is held by the size of what is taken away" do
      big =
        item(%{
          data: %{"ecommerce" => %{"price_modifiers" => %{"liquid" => %{"red" => "99.00"}}}}
        })

      assert plan!(%{"price_modifiers" => %{"liquid" => %{"red" => nil}}}, big).dangerous?
    end

    test "an unpriced product has no price to measure an option price against" do
      for current <- [nil, dec("0.00")] do
        unpriced = item(%{base_price: current})

        refute plan!(%{"price_modifiers" => %{"liquid" => %{"red" => "999.00"}}}, unpriced).dangerous?
      end
    end

    test "refuses an unknown option and an unknown value, naming the allowed ones" do
      assert {:error, [%{path: "price_modifiers.size", allowed: ["liquid"]}]} =
               plan(%{"price_modifiers" => %{"size" => %{"l" => "3.00"}}})

      assert {:error,
              [%{path: "price_modifiers.liquid.green", allowed: ["black", "blue", "red"]}]} =
               plan(%{"price_modifiers" => %{"liquid" => %{"green" => "3.00"}}})
    end

    test "an unknown option on a product with no option sets says why" do
      assert {:error, [%{path: "price_modifiers.size", message: message, allowed: []}]} =
               plan(%{"price_modifiers" => %{"size" => %{"l" => "3.00"}}}, item(), sets: [])

      assert message =~ "entities module"
    end

    test "a value the item already stores may be edited even if its set no longer lists it" do
      stale =
        item(%{data: %{"ecommerce" => %{"price_modifiers" => %{"gone" => %{"x" => "1.00"}}}}})

      assert {:ok, plan} = plan(%{"price_modifiers" => %{"gone" => %{"x" => "2.00"}}}, stale)
      assert plan.changes["price_modifiers.gone.x"]["to"] == "2.00"
    end

    test "without sets the names are not checked" do
      assert {:ok, _} =
               plan(%{"price_modifiers" => %{"size" => %{"l" => "3.00"}}}, item(), sets: nil)
    end

    test "refuses a malformed amount, a non-object value and a non-object option" do
      assert {:error, [%{path: "price_modifiers.liquid.red"}]} =
               plan(%{"price_modifiers" => %{"liquid" => %{"red" => "abc"}}})

      assert {:error, [%{path: "price_modifiers.liquid"}]} =
               plan(%{"price_modifiers" => %{"liquid" => "3.00"}})

      assert {:error, [%{path: "price_modifiers"}]} = plan(%{"price_modifiers" => "x"})
    end

    test "refuses a modifier that would make the cheapest combination negative" do
      assert {:error, [%{path: "price_modifiers", message: message}]} =
               plan(%{"price_modifiers" => %{"liquid" => %{"red" => "-200.00"}}})

      assert message =~ "less than zero"
    end

    test "option and value names with dots are written, owned and reported as they are" do
      stored =
        item(%{
          data: %{
            "ecommerce" => %{
              "price_modifiers" => %{"a.b" => %{"c" => "1.00"}, "a" => %{"b.c" => "2.00"}}
            }
          }
        })

      plan =
        plan!(
          %{
            "price_modifiers" => %{"a.b" => %{"c" => "3.00"}, "a" => %{"b.c" => nil}}
          },
          stored,
          sets: nil
        )

      assert plan.changed?

      assert Enum.sort(plan.owned_paths) == [
               ["ecommerce", "price_modifiers", "a", "b.c"],
               ["ecommerce", "price_modifiers", "a.b", "c"]
             ]

      assert plan.attrs.data["ecommerce"]["price_modifiers"] ==
               %{"a.b" => %{"c" => "3.00"}, "a" => %{"b.c" => nil}}
    end
  end

  describe "the cheapest combination" do
    defp cheap_item do
      item(%{
        base_price: dec("5.00"),
        data: %{"ecommerce" => %{"price_modifiers" => %{"liquid" => %{"black" => "-10.00"}}}}
      })
    end

    test "a row that touches neither the price nor a modifier is not held to it" do
      assert {:ok, plan} = plan(%{"compare_at" => "9.00"}, cheap_item())
      assert plan.changes == %{"compare_at" => %{"from" => nil, "to" => "9.00"}}
    end

    test "a modifier row that changes nothing is not held to it either" do
      assert {:ok, plan} =
               plan(%{"price_modifiers" => %{"liquid" => %{"black" => "-10.00"}}}, cheap_item())

      refute plan.changed?
    end

    test "a row that gives the price is held to it, even with the same price" do
      assert {:error, [%{path: "price_modifiers", message: message}]} =
               plan(%{"price" => "5.00"}, cheap_item())

      assert message =~ "less than zero"
    end

    test "a row that changes a modifier is held to it" do
      assert {:error, [%{path: "price_modifiers"}]} =
               plan(%{"price_modifiers" => %{"liquid" => %{"red" => "1.00"}}}, cheap_item())
    end
  end

  describe "a stored price that is not a finite number" do
    test "counts as no price: shown as none, and replaced like a first price" do
      nan = item(%{base_price: Decimal.new("NaN")})

      assert PricePlan.current(nan).price == nil

      plan = plan!(%{"price" => "5000.00"}, nan)
      assert plan.changes == %{"price" => %{"from" => nil, "to" => "5000.00"}}
      refute plan.dangerous?
      assert plan.attrs == %{base_price: dec("5000.00")}
    end
  end

  describe "the row as a whole" do
    test "a row that asks for nothing is refused" do
      assert {:error, [%{path: "", message: message}]} = plan(%{})
      assert message =~ "nothing to change"
    end

    test "reports every bad field at once" do
      assert {:error, errors} = plan(%{"price" => "x", "compare_at" => "y"})
      assert Enum.sort(Enum.map(errors, & &1.path)) == ["compare_at", "price"]
    end

    test "writes price, compare_at and modifiers together" do
      plan =
        plan!(%{
          "price" => "110.00",
          "compare_at" => "150.00",
          "price_modifiers" => %{"liquid" => %{"red" => "3.00"}}
        })

      assert plan.attrs.base_price == dec("110.00")
      assert plan.attrs.data["ecommerce"]["compare_at_price"] == "150.00"

      assert plan.owned_paths == [
               ["ecommerce", "compare_at_price"],
               ["ecommerce", "price_modifiers", "liquid", "red"]
             ]
    end

    test "an item with no data at all is planned like any other" do
      assert {:ok, plan} = plan(%{"price" => "10.00"}, item(%{data: nil, base_price: nil}))
      assert plan.changed?
    end
  end

  describe "validate_write/1" do
    # Money already refuses what ItemCommerce would, so no row can reach the
    # second line of defence; a hand-built plan does.
    test "refuses through ItemCommerce a value Money would have let through" do
      plan = %{
        changed?: true,
        changes: %{"compare_at" => %{}},
        to: %{compare_at: dec("-1.00")},
        leaves: []
      }

      assert {:error, [%{path: "compare_at_price", allowed: nil}]} =
               PricePlan.validate_write(plan)
    end

    test "passes a plan whose written values are valid, and one that changes nothing" do
      plan = %{
        changed?: true,
        changes: %{"compare_at" => %{}},
        to: %{compare_at: dec("5.00")},
        leaves: []
      }

      assert {:ok, ^plan} = PricePlan.validate_write(plan)
      assert {:ok, %{changed?: false}} = PricePlan.validate_write(%{changed?: false})
    end
  end

  describe "the Shopify warning" do
    test "appears only while the sync is on and the item is linked to Shopify" do
      assert "shopify_sync_may_overwrite" in plan!(%{"price" => "110.00"}, item(),
               shopify_enabled?: true
             ).warnings

      refute "shopify_sync_may_overwrite" in plan!(%{"price" => "110.00"}).warnings

      unlinked = item(%{data: %{"ecommerce" => %{}}})

      refute "shopify_sync_may_overwrite" in plan!(%{"price" => "110.00"}, unlinked,
               shopify_enabled?: true
             ).warnings
    end

    test "an item linked by its handle alone gets it too, like the settings page's own rule" do
      by_handle = item(%{data: %{"ecommerce" => %{"shopify" => %{"handle" => "mug"}}}})

      assert "shopify_sync_may_overwrite" in plan!(%{"price" => "110.00"}, by_handle,
               shopify_enabled?: true
             ).warnings
    end
  end

  describe "moved_over?/3 and change_pct/2" do
    test "the boundary and the empty cases" do
      refute PricePlan.moved_over?(dec("100"), dec("130"), 30)
      assert PricePlan.moved_over?(dec("100"), dec("130.01"), 30)
      refute PricePlan.moved_over?(nil, dec("5"), 30)
      refute PricePlan.moved_over?(dec("0.00"), dec("5"), 30)
      assert PricePlan.moved_over?(dec("10"), nil, 30)
    end

    test "the percentage is one decimal, signed, and nil from zero" do
      assert PricePlan.change_pct(dec("100"), dec("130")) == "30.0"
      assert PricePlan.change_pct(dec("80"), dec("60")) == "-25.0"
      assert PricePlan.change_pct(dec("0"), dec("5")) == nil
      assert PricePlan.change_pct(nil, dec("5")) == nil
    end
  end
end
