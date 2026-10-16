defmodule PhoenixKitEcommerce.CompatShopTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Shop, as: LegacyShop

  test "the transitional namespace exports the new checkout, cache and stock APIs" do
    assert Code.ensure_loaded?(LegacyShop)

    for name <- [
          :default_checkout_country,
          :children,
          :stock_tracking_enabled?,
          :warehouse_status
        ] do
      assert function_exported?(LegacyShop, name, 0),
             "PhoenixKit.Modules.Shop is missing #{name}/0"
    end

    # `apply/3`: the shim is deprecated, and a direct call is a compile warning.
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    assert apply(LegacyShop, :children, []) == PhoenixKitEcommerce.children()
  end
end
