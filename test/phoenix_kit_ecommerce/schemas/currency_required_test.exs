defmodule PhoenixKitEcommerce.Schemas.CurrencyRequiredTest do
  @moduledoc """
  Pins §4.2/§7.3/N3 of the currency design spec: `Cart` and `CartItem` no
  longer default `:currency` to `"USD"` — a missing currency must fail
  loudly on the changeset, never persist as a silent literal. Plain
  `ExUnit.Case` (not `DataCase`) — no database access needed, and this
  suite must actually execute rather than be excluded as `:integration`.
  """

  use ExUnit.Case, async: true
  alias PhoenixKitEcommerce.{Cart, CartItem}

  test "a cart without currency fails loudly instead of persisting NULL" do
    cs = Cart.changeset(%Cart{}, %{session_id: "s1"})
    assert {"can't be blank", _} = cs.errors[:currency]
  end

  test "a cart item without currency fails loudly" do
    cs =
      CartItem.changeset(%CartItem{}, %{
        product_title: "x",
        unit_price: Decimal.new("1"),
        quantity: 1
      })

    assert {"can't be blank", _} = cs.errors[:currency]
  end

  test "schema structs carry no silent USD any more" do
    assert %Cart{currency: nil} = %Cart{}
    assert %CartItem{currency: nil} = %CartItem{}
  end
end
