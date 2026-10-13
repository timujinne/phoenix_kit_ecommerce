defmodule PhoenixKitEcommerce.GuestCheckoutAccountReuseTest do
  @moduledoc """
  A guest checkout types an email; that proves nothing about who owns an
  account already holding it. An unconfirmed account somebody registered has
  a password its creator knows, so binding the order to it would show the
  shopper's name and address to whoever signed up with that address first.
  Only an unconfirmed account guest checkout itself created is reused.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKit.Users.Auth
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Cart
  alias PhoenixKitEcommerce.Test.Repo, as: TestRepo

  defp lang do
    PhoenixKitEcommerce.SlugResolver.normalize_language_public(
      PhoenixKitEcommerce.Translations.default_language()
    )
  end

  defp guest_cart do
    n = System.unique_integer([:positive])
    {:ok, cart} = Shop.create_cart(session_id: "s-#{System.unique_integer([:positive])}")

    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Wand #{n}", lang() => "Wand #{n}"},
        "slug" => %{lang() => "guest-reuse-#{n}"},
        "price" => Decimal.new("21.80"),
        "status" => "active",
        "currency" => "USD",
        "requires_shipping" => false
      })

    {:ok, cart} = Shop.add_to_cart(cart, product, 1)
    cart
  end

  defp billing(email), do: Map.put(complete_billing("US"), "email", email)

  defp unique_email, do: "victim-#{System.unique_integer([:positive])}@example.com"

  test "an unconfirmed REGISTERED account with the typed email does not receive the order" do
    email = unique_email()

    {:ok, squatter} =
      Auth.register_user(%{
        "email" => email,
        "password" => "squatter-password-123",
        "first_name" => "Squat",
        "last_name" => "Ter"
      })

    assert is_nil(squatter.confirmed_at)
    cart = guest_cart()

    assert {:error, :email_already_registered} =
             Shop.convert_cart_to_order(cart, billing_data: billing(email))

    assert PhoenixKitBilling.list_user_orders(squatter.uuid) == []

    # The shopper's name is not written onto the squatter's row either.
    assert %{first_name: "Squat", last_name: "Ter"} = Auth.get_user(squatter.uuid)

    # The cart is untouched, so signing in or using another address completes
    # the same purchase.
    reloaded = TestRepo.get!(Cart, cart.uuid)
    assert reloaded.status == "active"
    assert is_nil(reloaded.user_uuid)

    assert {:ok, order} =
             Shop.convert_cart_to_order(reloaded, billing_data: billing(unique_email()))

    refute order.user_uuid == squatter.uuid
  end

  test "an unconfirmed account guest checkout created is reused by the next guest order" do
    email = unique_email()

    assert {:ok, first} = Shop.convert_cart_to_order(guest_cart(), billing_data: billing(email))
    assert first.user_uuid

    guest = Auth.get_user(first.user_uuid)
    assert is_nil(guest.confirmed_at)
    assert guest.custom_fields["source"] == "guest_checkout"

    # The first order is the proof the account is guest checkout's own.
    assert first.metadata["guest_checkout"] == true
    assert first.metadata["guest_checkout_email"] == email

    assert {:ok, second} = Shop.convert_cart_to_order(guest_cart(), billing_data: billing(email))
    assert second.user_uuid == first.user_uuid
  end

  test "a returning guest is recognised whatever the letter case they type" do
    email = unique_email()

    assert {:ok, first} = Shop.convert_cart_to_order(guest_cart(), billing_data: billing(email))

    assert {:ok, second} =
             Shop.convert_cart_to_order(guest_cart(),
               billing_data: billing(String.upcase(email))
             )

    assert second.user_uuid == first.user_uuid
  end

  # Core's profile form writes `custom_fields` as submitted, so the account's
  # own holder can add the stamp. `update_user_profile/2` is that form's write.
  defp forge_stamp(user) do
    {:ok, forged} =
      Auth.update_user_profile(user, %{
        "custom_fields" => Map.put(user.custom_fields || %{}, "source", "guest_checkout")
      })

    assert forged.custom_fields["source"] == "guest_checkout"
    assert is_nil(forged.confirmed_at)
    forged
  end

  test "a registered account that forged the guest stamp is not reused" do
    email = unique_email()

    {:ok, squatter} =
      Auth.register_user(%{"email" => email, "password" => "squatter-password-123"})

    squatter = forge_stamp(squatter)
    cart = guest_cart()

    assert {:error, :email_already_registered} =
             Shop.convert_cart_to_order(cart, billing_data: billing(email))

    assert PhoenixKitBilling.list_user_orders(squatter.uuid) == []
    assert TestRepo.get!(Cart, cart.uuid).status == "active"
  end

  test "an order the forger placed while signed in is not proof either" do
    email = unique_email()

    {:ok, squatter} =
      Auth.register_user(%{"email" => email, "password" => "squatter-password-123"})

    squatter = forge_stamp(squatter)

    # Signed in with a guest cart: the logged-in branch, which marks nothing.
    assert {:ok, own} =
             Shop.convert_cart_to_order(guest_cart(),
               user_uuid: squatter.uuid,
               billing_data: billing(email)
             )

    assert own.user_uuid == squatter.uuid
    refute Map.has_key?(own.metadata, "guest_checkout")
    refute Map.has_key?(own.metadata, "guest_checkout_email")

    assert {:error, :email_already_registered} =
             Shop.convert_cart_to_order(guest_cart(), billing_data: billing(email))
  end

  test "a real guest account whose email was changed to someone else's is not reused" do
    own_email = unique_email()
    victim_email = unique_email()

    assert {:ok, first} =
             Shop.convert_cart_to_order(guest_cart(), billing_data: billing(own_email))

    guest = Auth.get_user(first.user_uuid)
    {:ok, moved} = Auth.update_user_profile(guest, %{"email" => victim_email})
    assert moved.email == victim_email
    assert is_nil(moved.confirmed_at)

    assert {:error, :email_already_registered} =
             Shop.convert_cart_to_order(guest_cart(), billing_data: billing(victim_email))

    assert length(PhoenixKitBilling.list_user_orders(moved.uuid)) == 1
  end

  test "a guest account with no marked order falls to the registered-email refusal" do
    email = unique_email()

    {:ok, guest} = Auth.create_guest_user(%{email: email, first_name: "Old", last_name: "Guest"})
    assert guest.custom_fields["source"] == "guest_checkout"

    assert {:error, :email_already_registered} =
             Shop.convert_cart_to_order(guest_cart(), billing_data: billing(email))
  end
end
