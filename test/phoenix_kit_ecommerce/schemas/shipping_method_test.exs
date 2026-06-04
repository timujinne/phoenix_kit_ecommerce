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
