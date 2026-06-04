defmodule PhoenixKitEcommerce.Schemas.CartItemTest do
  use PhoenixKitEcommerce.DataCase, async: true

  alias PhoenixKitEcommerce.CartItem
  alias PhoenixKitEcommerce.Product

  @valid %{
    cart_uuid: Ecto.UUID.generate(),
    product_title: "Widget",
    unit_price: Decimal.new("10.00"),
    quantity: 3
  }

  describe "changeset/2 validity" do
    test "is valid with the required fields" do
      assert CartItem.changeset(%CartItem{}, @valid).valid?
    end

    test "computes line_total as unit_price * quantity" do
      cs = CartItem.changeset(%CartItem{}, @valid)
      assert Decimal.equal?(get_change(cs, :line_total), Decimal.new("30.00"))
    end
  end

  describe "changeset/2 required and numeric validations" do
    test "requires cart_uuid, product_title, unit_price, quantity" do
      errors = errors_on(CartItem.changeset(%CartItem{}, %{}))
      assert "can't be blank" in errors.cart_uuid
      assert "can't be blank" in errors.product_title
      assert "can't be blank" in errors.unit_price
      # quantity has a schema default of 1, so it's never blank.
      refute Map.has_key?(errors, :quantity)
    end

    test "quantity must be greater than 0" do
      cs = CartItem.changeset(%CartItem{}, %{@valid | quantity: 0})
      assert %{quantity: [_ | _]} = errors_on(cs)
    end

    test "unit_price must be >= 0" do
      cs = CartItem.changeset(%CartItem{}, %{@valid | unit_price: Decimal.new("-1")})
      assert %{unit_price: [_ | _]} = errors_on(cs)
    end

    test "currency must be 3 chars" do
      cs = CartItem.changeset(%CartItem{}, Map.put(@valid, :currency, "US"))
      assert %{currency: [_ | _]} = errors_on(cs)
    end
  end

  describe "from_product/2" do
    test "snapshots product title, price and weight" do
      product = %Product{
        uuid: Ecto.UUID.generate(),
        title: %{"en" => "Gizmo"},
        slug: %{"en" => "gizmo"},
        price: Decimal.new("42.00"),
        currency: "USD",
        weight_grams: 250,
        taxable: true
      }

      attrs = CartItem.from_product(product, 2)
      assert attrs.product_title == "Gizmo"
      assert attrs.product_slug == "gizmo"
      assert Decimal.equal?(attrs.unit_price, Decimal.new("42.00"))
      assert attrs.quantity == 2
      assert attrs.weight_grams == 250
    end
  end

  describe "predicates" do
    test "on_sale?/1 and discount_percentage/1" do
      sale = %CartItem{unit_price: Decimal.new("80"), compare_at_price: Decimal.new("100")}
      assert CartItem.on_sale?(sale)
      assert CartItem.discount_percentage(sale) == 20
    end

    test "product_deleted?/1" do
      assert CartItem.product_deleted?(%CartItem{product_uuid: nil})
      refute CartItem.product_deleted?(%CartItem{product_uuid: Ecto.UUID.generate()})
    end
  end
end
