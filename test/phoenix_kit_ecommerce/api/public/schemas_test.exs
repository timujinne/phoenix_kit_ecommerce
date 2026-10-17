defmodule PhoenixKitEcommerce.API.Public.SchemasTest do
  use ExUnit.Case, async: true

  @compile {:no_warn_undefined, PhoenixKit.API.Validator}

  alias PhoenixKit.API.Validator
  alias PhoenixKitEcommerce.API.Public.Schemas

  test "control_fields/0 declares exactly language and currency, both strings" do
    fields = Schemas.control_fields()

    assert Map.keys(fields) |> Enum.sort() == ["currency", "language"]
    assert Enum.all?(fields, fn {_name, schema} -> schema["type"] == "string" end)
  end

  @tag :requires_core_api
  test "money, list item and card schemas accept what the cards build" do
    money = %{"amount" => "12.50", "currency" => "EUR"}

    assert {:ok, _} = Validator.validate(Schemas.money(), money)

    assert {:error, [%{path: "amount"}]} =
             Validator.validate(Schemas.money(), %{
               "amount" => 12.5,
               "currency" => "EUR"
             })

    item = %{
      "id" => "a",
      "title" => "T",
      "status" => "active",
      "price" => money,
      "discount_pct" => 20,
      "price_on_request" => false,
      "category_path" => [%{"id" => "c", "name" => "N"}]
    }

    assert {:ok, _} = Validator.validate(Schemas.list_item(), item)

    assert {:ok, _} =
             Validator.validate(Schemas.card(), Map.put(item, "tags", ["x"]))

    # The stub of a discontinued product is a card with only the three required fields.
    assert {:ok, _} =
             Validator.validate(Schemas.card(), %{
               "id" => "a",
               "title" => "T",
               "status" => "discontinued"
             })

    assert {:error, [%{path: "id"}]} =
             Validator.validate(Schemas.card(), %{"title" => "T", "status" => "x"})
  end
end
