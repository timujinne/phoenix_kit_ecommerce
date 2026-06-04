defmodule PhoenixKitEcommerce.Schemas.ProductTest do
  use PhoenixKitEcommerce.DataCase, async: true

  alias PhoenixKitEcommerce.Product

  @valid %{
    "title" => %{"en" => "Widget"},
    "price" => Decimal.new("19.99")
  }

  describe "changeset/2 validity" do
    test "is valid with an English title and a price" do
      assert Product.changeset(%Product{}, @valid).valid?
    end

    test "auto-generates a slug from the title" do
      cs = Product.changeset(%Product{}, @valid)
      assert get_change(cs, :slug) == %{"en" => "widget"}
    end
  end

  describe "changeset/2 required fields" do
    test "requires price" do
      cs = Product.changeset(%Product{}, %{"title" => %{"en" => "X"}})
      assert "can't be blank" in errors_on(cs).price
    end

    test "requires an English title translation" do
      cs = Product.changeset(%Product{}, %{"price" => Decimal.new("1")})
      assert %{title: ["en translation is required"]} = errors_on(cs)
    end

    test "blank English title is rejected" do
      cs = Product.changeset(%Product{}, %{"title" => %{"en" => ""}, "price" => Decimal.new("1")})
      assert %{title: ["en translation is required"]} = errors_on(cs)
    end
  end

  describe "changeset/2 custom validations" do
    test "rejects negative price" do
      cs = Product.changeset(%Product{}, %{@valid | "price" => Decimal.new("-1")})
      assert %{price: ["must be greater than or equal to 0"]} = errors_on(cs)
    end

    test "rejects invalid status" do
      cs = Product.changeset(%Product{}, Map.put(@valid, "status", "bogus"))
      assert %{status: ["is invalid"]} = errors_on(cs)
    end

    test "accepts each valid status" do
      for status <- ["draft", "active", "archived"] do
        assert Product.changeset(%Product{}, Map.put(@valid, "status", status)).valid?
      end
    end

    test "rejects invalid product_type" do
      cs = Product.changeset(%Product{}, Map.put(@valid, "product_type", "service"))
      assert %{product_type: ["is invalid"]} = errors_on(cs)
    end

    test "currency must be exactly 3 chars" do
      cs = Product.changeset(%Product{}, Map.put(@valid, "currency", "US"))
      assert %{currency: [_ | _]} = errors_on(cs)
    end

    test "rejects negative weight_grams" do
      cs = Product.changeset(%Product{}, Map.put(@valid, "weight_grams", -5))
      assert %{weight_grams: [_ | _]} = errors_on(cs)
    end

    test "download_limit must be positive when given" do
      cs = Product.changeset(%Product{}, Map.put(@valid, "download_limit", 0))
      assert %{download_limit: [_ | _]} = errors_on(cs)
    end
  end

  describe "predicates" do
    test "active?/1" do
      assert Product.active?(%Product{status: "active"})
      refute Product.active?(%Product{status: "draft"})
    end

    test "digital?/1 and physical?/1" do
      assert Product.digital?(%Product{product_type: "digital"})
      assert Product.physical?(%Product{product_type: "physical"})
    end

    test "requires_shipping?/1 is false for digital products" do
      refute Product.requires_shipping?(%Product{product_type: "digital"})

      assert Product.requires_shipping?(%Product{
               product_type: "physical",
               requires_shipping: true
             })
    end

    test "on_sale?/1 and discount_percentage/1" do
      sale = %Product{price: Decimal.new("80"), compare_at_price: Decimal.new("100")}
      assert Product.on_sale?(sale)
      assert Product.discount_percentage(sale) == 20

      not_sale = %Product{price: Decimal.new("100"), compare_at_price: nil}
      refute Product.on_sale?(not_sale)
      assert Product.discount_percentage(not_sale) == 0
    end
  end
end
