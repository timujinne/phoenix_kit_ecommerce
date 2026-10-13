defmodule PhoenixKitEcommerce.Schemas.ShippingMethodTest do
  use PhoenixKitEcommerce.DataCase, async: true

  alias PhoenixKitEcommerce.ShippingMethod

  @valid %{"name" => "Standard", "price" => Decimal.new("5.00")}

  describe "changeset/2 validity" do
    test "is valid with name and price" do
      assert ShippingMethod.changeset(%ShippingMethod{}, @valid).valid?
    end

    test "auto-generates a slug from the name" do
      cs =
        ShippingMethod.changeset(%ShippingMethod{}, %{"name" => "Express Post", "price" => "1"})

      assert get_change(cs, :slug) == "express-post"
    end
  end

  describe "changeset/2 required and numeric validations" do
    test "requires name (price has a schema default of 0, so it's never blank)" do
      errors = errors_on(ShippingMethod.changeset(%ShippingMethod{}, %{}))
      assert "can't be blank" in errors.name
      # `price` defaults to Decimal.new("0") on the schema, so even with no
      # input it satisfies validate_required.
      refute Map.has_key?(errors, :price)
    end

    test "rejects negative price" do
      cs = ShippingMethod.changeset(%ShippingMethod{}, %{@valid | "price" => Decimal.new("-1")})
      assert %{price: [_ | _]} = errors_on(cs)
    end

    test "free_above_amount must be > 0 when present" do
      cs = ShippingMethod.changeset(%ShippingMethod{}, Map.put(@valid, "free_above_amount", "0"))
      assert %{free_above_amount: [_ | _]} = errors_on(cs)
    end

    test "currency must be 3 chars" do
      cs = ShippingMethod.changeset(%ShippingMethod{}, Map.put(@valid, "currency", "US"))
      assert %{currency: [_ | _]} = errors_on(cs)
    end

    test "normalizes string booleans" do
      cs = ShippingMethod.changeset(%ShippingMethod{}, Map.put(@valid, "active", "false"))
      assert get_field(cs, :active) == false
    end
  end

  describe "calculate_cost/2" do
    test "returns price when no free threshold" do
      method = %ShippingMethod{price: Decimal.new("5"), free_above_amount: nil}

      assert Decimal.equal?(
               ShippingMethod.calculate_cost(method, Decimal.new("100")),
               Decimal.new("5")
             )
    end

    test "is free at or above the threshold" do
      method = %ShippingMethod{price: Decimal.new("5"), free_above_amount: Decimal.new("50")}

      assert Decimal.equal?(
               ShippingMethod.calculate_cost(method, Decimal.new("50")),
               Decimal.new("0")
             )

      assert Decimal.equal?(
               ShippingMethod.calculate_cost(method, Decimal.new("49")),
               Decimal.new("5")
             )
    end
  end

  describe "available_for?/2" do
    test "inactive methods are never available" do
      refute ShippingMethod.available_for?(%ShippingMethod{active: false}, %{country: "US"})
    end

    test "respects country allow/exclude lists" do
      allowed = %ShippingMethod{active: true, countries: ["US"], excluded_countries: []}
      assert ShippingMethod.available_for?(allowed, %{country: "US"})
      refute ShippingMethod.available_for?(allowed, %{country: "EE"})

      excluded = %ShippingMethod{active: true, countries: [], excluded_countries: ["RU"]}
      refute ShippingMethod.available_for?(excluded, %{country: "RU"})
      assert ShippingMethod.available_for?(excluded, %{country: "US"})
    end
  end

  describe "pay on delivery" do
    test "a top-level form flag is stored as metadata[\"pay_on_delivery\"] = true" do
      cs =
        ShippingMethod.changeset(%ShippingMethod{}, Map.put(@valid, "pay_on_delivery", "true"))

      assert cs.valid?
      assert get_field(cs, :metadata) == %{"pay_on_delivery" => true}
      assert ShippingMethod.pay_on_delivery?(apply_changes(cs))
    end

    test "an atom-key flag works like the form's string key" do
      cs =
        ShippingMethod.changeset(%ShippingMethod{}, %{
          name: "Carrier",
          price: Decimal.new("5"),
          pay_on_delivery: true
        })

      assert ShippingMethod.pay_on_delivery?(apply_changes(cs))
      assert Decimal.equal?(get_field(cs, :price), Decimal.new("0"))
    end

    test "a metadata-level flag is normalized to a boolean" do
      cs =
        ShippingMethod.changeset(
          %ShippingMethod{},
          Map.put(@valid, "metadata", %{"pay_on_delivery" => "true", "carrier" => "np"})
        )

      assert get_field(cs, :metadata) == %{"pay_on_delivery" => true, "carrier" => "np"}
    end

    test "the price is forced to 0 and the free threshold cleared" do
      cs =
        ShippingMethod.changeset(
          %ShippingMethod{},
          @valid
          |> Map.put("pay_on_delivery", "true")
          |> Map.put("free_above_amount", "100")
        )

      assert cs.valid?
      assert Decimal.equal?(get_field(cs, :price), Decimal.new("0"))
      assert get_field(cs, :free_above_amount) == nil
    end

    test "unchecking removes the flag and keeps other metadata keys" do
      method = %ShippingMethod{
        name: "Carrier",
        price: Decimal.new("0"),
        metadata: %{"pay_on_delivery" => true, "carrier" => "np"}
      }

      cs = ShippingMethod.changeset(method, %{"pay_on_delivery" => "false", "price" => "4"})

      assert get_field(cs, :metadata) == %{"carrier" => "np"}
      assert Decimal.equal?(get_field(cs, :price), Decimal.new("4"))
      refute ShippingMethod.pay_on_delivery?(apply_changes(cs))
    end

    test "an update that does not mention the flag keeps it" do
      method = %ShippingMethod{
        name: "Carrier",
        price: Decimal.new("0"),
        metadata: %{"pay_on_delivery" => true}
      }

      cs = ShippingMethod.changeset(method, %{"name" => "Acme Post", "price" => "7"})

      assert ShippingMethod.pay_on_delivery?(apply_changes(cs))
      assert Decimal.equal?(get_field(cs, :price), Decimal.new("0"))
    end

    test "pay_on_delivery?/1 is false for anything but a flagged method" do
      refute ShippingMethod.pay_on_delivery?(%ShippingMethod{})
      refute ShippingMethod.pay_on_delivery?(%ShippingMethod{metadata: nil})

      refute ShippingMethod.pay_on_delivery?(%ShippingMethod{
               metadata: %{"pay_on_delivery" => "true"}
             })

      refute ShippingMethod.pay_on_delivery?(nil)
      refute ShippingMethod.pay_on_delivery?(%Ecto.Association.NotLoaded{})
    end
  end

  describe "delivery_estimate/1" do
    test "formats day ranges" do
      assert ShippingMethod.delivery_estimate(%ShippingMethod{
               estimated_days_min: 1,
               estimated_days_max: 1
             }) == "1 day"

      assert ShippingMethod.delivery_estimate(%ShippingMethod{
               estimated_days_min: 3,
               estimated_days_max: 5
             }) == "3-5 days"

      assert ShippingMethod.delivery_estimate(%ShippingMethod{estimated_days_min: nil}) == nil
    end
  end

  # Regression: ShippingMethod.changeset/1 now pins the real DB index name
  # `phoenix_kit_shop_shipping_methods_slug_unique`, so a duplicate-slug insert
  # is surfaced as a changeset error instead of raising Ecto.ConstraintError.
  describe "duplicate slug" do
    test "returns a changeset error (constraint name matches DB index)" do
      {:ok, _} =
        %ShippingMethod{}
        |> ShippingMethod.changeset(%{"name" => "Dup", "price" => "1", "slug" => "dup-ship"})
        |> Repo.insert()

      assert {:error, changeset} =
               %ShippingMethod{}
               |> ShippingMethod.changeset(%{
                 "name" => "Dup2",
                 "price" => "1",
                 "slug" => "dup-ship"
               })
               |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).slug
    end
  end
end
