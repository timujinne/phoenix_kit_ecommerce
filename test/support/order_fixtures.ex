defmodule PhoenixKitEcommerce.OrderFixtures do
  @moduledoc """
  Orders shaped the way checkout writes them, for the tests of the order tools
  and of the order export: product and shipping lines, the shipping and
  payment facts in `metadata`, the buyer in `billing_snapshot`.
  """

  import Ecto.Query, only: [from: 2]

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitEcommerce.DataCase
  alias PhoenixKitEcommerce.Test.Repo

  @doc """
  A pending order. `attrs` (string keys) override the defaults; `metadata` is
  merged into the default metadata rather than replacing it.
  """
  def order!(attrs \\ %{}) do
    n = System.unique_integer([:positive])
    {metadata, attrs} = Map.pop(attrs, "metadata", %{})

    defaults = %{
      "status" => "pending",
      "currency" => "UAH",
      "subtotal" => Decimal.new("900.00"),
      "discount_amount" => Decimal.new("0"),
      "tax_amount" => Decimal.new("0"),
      "total" => Decimal.new("942.50"),
      "notes" => "ring twice",
      "internal_notes" => "internal only #{n}",
      "billing_snapshot" => %{
        "type" => "individual",
        "first_name" => "Ivan",
        "last_name" => "Petrenko",
        "phone" => "+380000000#{n}",
        "email" => "buyer#{n}@example.com",
        "country" => "UA",
        "city" => "Kyiv",
        "postal_code" => "01001",
        "address_line1" => "1 Test St"
      },
      "line_items" => [
        %{
          "name" => "Product",
          "quantity" => 2,
          "unit_price" => "450.00",
          "total" => "900.00",
          "sku" => "4820000000000",
          "type" => "product"
        }
      ],
      "metadata" =>
        Map.merge(%{"source" => "shop_checkout", "session_id" => "sess-#{n}"}, metadata)
    }

    {:ok, order} = Billing.create_order(DataCase.fixture_user(), Map.merge(defaults, attrs))
    order
  end

  @doc "A shipping line of `amount`."
  def shipping_line(amount \\ "42.50") do
    %{
      "name" => "Shipping: Courier",
      "quantity" => 1,
      "unit_price" => amount,
      "total" => amount,
      "type" => "shipping",
      "pay_on_delivery" => false
    }
  end

  @doc "Sets `updated_at` without going through a changeset."
  def touch!(order, %DateTime{} = updated_at) do
    Repo.update_all(from(o in PhoenixKitBilling.Order, where: o.uuid == ^order.uuid),
      set: [updated_at: DateTime.truncate(updated_at, :second)]
    )

    Billing.get_order(order.uuid)
  end
end
