defmodule PhoenixKitEcommerce.BillingUserMenuGateTest do
  @moduledoc """
  Billing offers "My Orders" and "Billing Profiles" in the avatar dropdown
  only while the shop module is enabled. Billing cannot see a shop from its
  own suite (it does not depend on this module), so the positive half of that
  gate lives here, where the shop is registered with core.
  """
  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKit.Dashboard.Tab

  @moduletag :requires_core_user_menu
  @moduletag :requires_billing_user_menu

  test "billing's user tabs reach the dropdown while the shop is enabled, not after" do
    {:ok, _} = PhoenixKitEcommerce.enable_system()
    assert PhoenixKitBilling.user_menu_with_shop?(nil)

    for tab <- PhoenixKitBilling.user_dashboard_tabs() do
      assert Tab.user_menu?(tab, nil), "#{inspect(tab.id)} missing while the shop is enabled"
    end

    {:ok, _} = PhoenixKitEcommerce.disable_system()
    refute PhoenixKitBilling.user_menu_with_shop?(nil)

    for tab <- PhoenixKitBilling.user_dashboard_tabs() do
      refute Tab.user_menu?(tab, nil), "#{inspect(tab.id)} listed while the shop is disabled"
    end
  end
end
