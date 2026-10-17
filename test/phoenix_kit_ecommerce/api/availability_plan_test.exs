defmodule PhoenixKitEcommerce.API.AvailabilityPlanTest do
  @moduledoc """
  Planning one `ecommerce.set_availability` row. Pure: items are plain maps.
  The current visibility is the storefront's own reading
  (`View.merchant_status/1`): an item with no `shop_status` counts as active.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.API.AvailabilityPlan

  defp item(ecommerce \\ %{"shop_status" => "draft"}, overrides \\ %{}) do
    Map.merge(
      %{
        uuid: "item-1",
        base_price: Decimal.new("5.00"),
        status: "active",
        data: %{"ecommerce" => ecommerce}
      },
      overrides
    )
  end

  defp plan!(row, item \\ item()) do
    assert {:ok, plan} = AvailabilityPlan.plan(row, item)
    plan
  end

  test "publishing writes shop_status at its own path" do
    plan = plan!(%{"visibility" => "active"})

    assert plan.changed?
    assert plan.changes == %{"visibility" => %{"from" => "draft", "to" => "active"}}
    assert plan.attrs == %{data: %{"ecommerce" => %{"shop_status" => "active"}}}
    assert plan.owned_paths == [["ecommerce", "shop_status"]]
    refute plan.dangerous?
  end

  test "an item with no shop_status already counts as active, like on the storefront" do
    plan = plan!(%{"visibility" => "active"}, item(%{}))
    refute plan.changed?
    assert plan.from.visibility == "active"
  end

  test "a garbage stored shop_status is read as active too" do
    assert AvailabilityPlan.current(item(%{"shop_status" => "weird"})).visibility == "active"
  end

  test "made_to_order and visibility are independent fields" do
    plan = plan!(%{"made_to_order" => true})

    assert plan.changes == %{"made_to_order" => %{"from" => false, "to" => true}}
    assert plan.owned_paths == [["ecommerce", "made_to_order"]]

    both = plan!(%{"visibility" => "archived", "made_to_order" => true})
    assert both.owned_paths == [["ecommerce", "shop_status"], ["ecommerce", "made_to_order"]]
  end

  test "a product with no price cannot be made active, unless it is price on request" do
    no_price = item(%{"shop_status" => "draft"}, %{base_price: nil})

    assert {:error, [%{path: "visibility", message: message}]} =
             AvailabilityPlan.plan(%{"visibility" => "active"}, no_price)

    assert message =~ "set a price first"

    on_request = item(%{"shop_status" => "draft", "price_on_request" => true}, %{base_price: nil})
    assert {:ok, _} = AvailabilityPlan.plan(%{"visibility" => "active"}, on_request)
  end

  test "a stored price that is not a finite number counts as no price" do
    for bad <- [Decimal.new("NaN"), Decimal.new("Infinity")] do
      unpriced = item(%{"shop_status" => "draft"}, %{base_price: bad})

      assert {:error, [%{path: "visibility", message: message}]} =
               AvailabilityPlan.plan(%{"visibility" => "active"}, unpriced)

      assert message =~ "set a price first"
    end
  end

  test "a free product (price zero) can be made active" do
    free = item(%{"shop_status" => "draft"}, %{base_price: Decimal.new(0)})

    assert {:ok, %{changed?: true}} = AvailabilityPlan.plan(%{"visibility" => "active"}, free)
  end

  test "drafting or archiving a product with no price is fine" do
    no_price = item(%{"shop_status" => "active"}, %{base_price: nil})
    assert {:ok, _} = AvailabilityPlan.plan(%{"visibility" => "archived"}, no_price)
  end

  test "warns when the catalogue itself keeps the item hidden" do
    plan =
      plan!(%{"visibility" => "active"}, item(%{"shop_status" => "draft"}, %{status: "inactive"}))

    assert plan.warnings == ["item_not_active"]
  end

  describe "validate_write/1" do
    # The planner refuses an unknown visibility first, so no row can reach the
    # second line of defence; a hand-built plan does.
    test "refuses through ItemCommerce a shop_status the namespace would refuse" do
      plan = %{changed?: true, attrs: %{data: %{"ecommerce" => %{"shop_status" => "weird"}}}}

      assert {:error, [%{path: "shop_status"}]} = AvailabilityPlan.validate_write(plan)
    end

    test "passes valid values, and a plan that changes nothing" do
      plan = %{changed?: true, attrs: %{data: %{"ecommerce" => %{"shop_status" => "active"}}}}

      assert {:ok, ^plan} = AvailabilityPlan.validate_write(plan)
      assert {:ok, %{changed?: false}} = AvailabilityPlan.validate_write(%{changed?: false})
    end
  end

  describe "the Shopify warning" do
    defp linked(overrides \\ %{}),
      do:
        item(Map.merge(%{"shop_status" => "draft", "shopify" => %{"handle" => "mug"}}, overrides))

    defp warnings(row, item, opts) do
      assert {:ok, plan} = AvailabilityPlan.plan(row, item, opts)
      plan.warnings
    end

    test "a visibility change to a product linked to Shopify (by handle alone) carries it" do
      assert warnings(%{"visibility" => "active"}, linked(), shopify_enabled?: true) ==
               ["shopify_sync_may_overwrite"]

      assert warnings(
               %{"visibility" => "active"},
               item(%{"shop_status" => "draft", "shopify" => %{"product_id" => "7"}}),
               shopify_enabled?: true
             ) == ["shopify_sync_may_overwrite"]
    end

    test "not while the sync is off, not for an unlinked product, not for a flag the sync does not write" do
      assert warnings(%{"visibility" => "active"}, linked(), []) == []
      assert warnings(%{"visibility" => "active"}, item(), shopify_enabled?: true) == []
      assert warnings(%{"made_to_order" => true}, linked(), shopify_enabled?: true) == []
    end

    test "not for a row that changes nothing" do
      assert warnings(%{"visibility" => "draft"}, linked(), shopify_enabled?: true) == []
    end
  end

  test "refuses an unknown visibility, a non-boolean flag and an empty row" do
    assert {:error, [%{path: "visibility", allowed: ["draft", "active", "archived"]}]} =
             AvailabilityPlan.plan(%{"visibility" => "hidden"}, item())

    assert {:error, [%{path: "made_to_order"}]} =
             AvailabilityPlan.plan(%{"made_to_order" => "yes"}, item())

    assert {:error, [%{path: "", message: message}]} = AvailabilityPlan.plan(%{}, item())
    assert message =~ "nothing to change"
  end
end
