defmodule PhoenixKitEcommerce.SaveBillingProfileTest do
  @moduledoc """
  `convert_cart_to_order/2` with `save_billing_profile: true`: the entered
  billing details become a billing profile of the logged-in user, created in
  the conversion's own transaction, and the order references it.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitEcommerce, as: Shop

  setup do
    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Saved Profile Widget"},
        "price" => Decimal.new("10.00"),
        "status" => "active",
        "currency" => "USD",
        "product_type" => "digital",
        "requires_shipping" => false,
        "weight_grams" => 0
      })

    {:ok, product: product}
  end

  defp user_cart(user, product) do
    {:ok, cart} = Shop.create_cart(user_uuid: user.uuid)
    {:ok, cart} = Shop.add_to_cart(cart, product, 1)
    cart
  end

  defp billing_data(extra \\ %{}) do
    "EE"
    |> complete_billing("save-profile")
    |> Map.merge(%{"type" => "individual", "middle_name" => "Q", "state" => "Harju"})
    |> Map.merge(extra)
  end

  test "creates the profile, makes the first one default and references it from the order",
       %{product: product} do
    user = fixture_user()
    cart = user_cart(user, product)

    assert {:ok, order} =
             Shop.convert_cart_to_order(cart,
               billing_data: billing_data(),
               user_uuid: user.uuid,
               save_billing_profile: true
             )

    assert [profile] = Billing.list_user_billing_profiles(user.uuid)
    assert order.billing_profile_uuid == profile.uuid
    assert profile.is_default
    assert profile.middle_name == "Q"
    assert profile.state == "Harju"
    assert profile.address_line1 == "1 Test Street"
  end

  test "a later profile is not the default", %{product: product} do
    user = fixture_user()

    {:ok, existing} =
      Billing.create_billing_profile(user, %{
        "first_name" => "Old",
        "last_name" => "Profile",
        "email" => "old@example.com"
      })

    assert existing.is_default

    assert {:ok, order} =
             Shop.convert_cart_to_order(user_cart(user, product),
               billing_data: billing_data(),
               user_uuid: user.uuid,
               save_billing_profile: true
             )

    profiles = Billing.list_user_billing_profiles(user.uuid)
    assert length(profiles) == 2

    new = Enum.find(profiles, &(&1.uuid == order.billing_profile_uuid))
    refute new.is_default
    assert Enum.find(profiles, & &1.is_default).uuid == existing.uuid
  end

  test "without the flag nothing is saved and the order carries a snapshot",
       %{product: product} do
    user = fixture_user()

    assert {:ok, order} =
             Shop.convert_cart_to_order(user_cart(user, product),
               billing_data: billing_data(),
               user_uuid: user.uuid
             )

    assert Billing.list_user_billing_profiles(user.uuid) == []
    assert is_nil(order.billing_profile_uuid)
    assert order.billing_snapshot["first_name"] == "Test"
  end

  test "a guest never gets a saved profile", %{product: product} do
    {:ok, cart} =
      Shop.create_cart(session_id: "save-profile-#{System.unique_integer([:positive])}")

    {:ok, cart} = Shop.add_to_cart(cart, product, 1)

    assert {:ok, order} =
             Shop.convert_cart_to_order(cart,
               billing_data: billing_data(),
               save_billing_profile: true
             )

    assert order.user_uuid
    assert Billing.list_user_billing_profiles(order.user_uuid) == []
    assert is_nil(order.billing_profile_uuid)
    assert order.billing_snapshot["first_name"] == "Test"
  end

  test "only the form fields reach the profile", %{product: product} do
    user = fixture_user()

    data =
      billing_data(%{
        "is_default" => "false",
        "user_uuid" => Ecto.UUID.generate(),
        "metadata" => %{"x" => 1}
      })

    assert {:ok, order} =
             Shop.convert_cart_to_order(user_cart(user, product),
               billing_data: data,
               user_uuid: user.uuid,
               save_billing_profile: true
             )

    profile = Billing.get_billing_profile(order.billing_profile_uuid)
    assert profile.user_uuid == user.uuid
    assert profile.is_default
    assert profile.metadata == %{}
  end

  test "an invalid profile rolls the whole conversion back", %{product: product} do
    user = fixture_user()
    cart = user_cart(user, product)

    # Passes the context's name check (first_name is present) but is no valid
    # individual profile: last_name is required.
    data = billing_data(%{"last_name" => ""})

    assert {:error, {:billing_profile_invalid, changeset}} =
             Shop.convert_cart_to_order(cart,
               billing_data: data,
               user_uuid: user.uuid,
               save_billing_profile: true
             )

    assert %{last_name: [_ | _]} = errors_on(changeset)
    assert Billing.list_user_billing_profiles(user.uuid) == []
    assert Billing.list_user_orders(user.uuid) == []
    assert Shop.get_cart!(cart.uuid).status == "active"
  end

  test "a blank country is refused instead of becoming billing's default", %{product: product} do
    user = fixture_user()
    cart = user_cart(user, product)

    assert {:error, {:billing_profile_invalid, changeset}} =
             Shop.convert_cart_to_order(cart,
               billing_data: billing_data(%{"country" => ""}),
               user_uuid: user.uuid,
               save_billing_profile: true
             )

    assert %{country: [_ | _]} = errors_on(changeset)
    assert Billing.list_user_billing_profiles(user.uuid) == []
    assert Shop.get_cart!(cart.uuid).status == "active"
    assert is_nil(Shop.get_cart!(cart.uuid).shipping_country)
  end

  test "a profile created before a later failure is rolled back with the order", %{} do
    user = fixture_user()

    {:ok, physical} =
      Shop.create_product(%{
        "title" => %{"en" => "Parcel Widget"},
        "price" => Decimal.new("25.00"),
        "status" => "active",
        "currency" => "USD",
        "product_type" => "physical",
        "requires_shipping" => true,
        "weight_grams" => 500
      })

    {:ok, method} =
      Shop.create_shipping_method(%{
        "name" => "Estonia Only",
        "price" => Decimal.new("5.00"),
        "active" => true,
        "countries" => ["EE"]
      })

    {:ok, cart} = Shop.create_cart(user_uuid: user.uuid)
    {:ok, cart} = Shop.add_to_cart(cart, physical, 1)
    {:ok, cart} = Shop.set_cart_shipping(cart, method, "EE")

    # The profile is created first; the US address then rules the chosen
    # method out, which fails the conversion further down the same transaction.
    assert {:error, :shipping_method_unavailable} =
             Shop.convert_cart_to_order(cart,
               billing_data: billing_data(%{"country" => "US"}),
               user_uuid: user.uuid,
               save_billing_profile: true
             )

    assert Billing.list_user_billing_profiles(user.uuid) == []
    assert Billing.list_user_orders(user.uuid) == []
    assert Shop.get_cart!(cart.uuid).status == "active"
  end

  test "the flag is ignored when an existing profile is given", %{product: product} do
    user = fixture_user()

    {:ok, existing} =
      Billing.create_billing_profile(user, %{
        "first_name" => "Old",
        "last_name" => "Profile",
        "email" => "old@example.com"
      })

    assert {:ok, order} =
             Shop.convert_cart_to_order(user_cart(user, product),
               billing_profile_uuid: existing.uuid,
               billing_data: billing_data(),
               user_uuid: user.uuid,
               save_billing_profile: true
             )

    assert order.billing_profile_uuid == existing.uuid
    assert [_only] = Billing.list_user_billing_profiles(user.uuid)
  end
end
