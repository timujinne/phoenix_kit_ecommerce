defmodule PhoenixKitEcommerce.Schemas.CartTest do
  use PhoenixKitEcommerce.DataCase, async: true

  alias PhoenixKitEcommerce.Cart

  describe "changeset/2 identity validation" do
    test "is valid with a session_id (guest cart)" do
      assert Cart.changeset(%Cart{}, %{session_id: "abc"}).valid?
    end

    test "is valid with a user_uuid" do
      assert Cart.changeset(%Cart{}, %{user_uuid: Ecto.UUID.generate()}).valid?
    end

    test "is invalid without any identity" do
      cs = Cart.changeset(%Cart{}, %{})
      assert %{base: ["Either user_uuid or session_id must be set"]} = errors_on(cs)
    end
  end

  describe "changeset/2 field validations" do
    test "rejects invalid status" do
      cs = Cart.changeset(%Cart{}, %{session_id: "x", status: "bogus"})
      assert %{status: ["is invalid"]} = errors_on(cs)
    end

    test "currency must be 3 chars" do
      cs = Cart.changeset(%Cart{}, %{session_id: "x", currency: "US"})
      assert %{currency: [_ | _]} = errors_on(cs)
    end

    test "shipping_country max 2 chars" do
      cs = Cart.changeset(%Cart{}, %{session_id: "x", shipping_country: "USA"})
      assert %{shipping_country: [_ | _]} = errors_on(cs)
    end

    test "guest carts get a default expires_at" do
      cs = Cart.changeset(%Cart{}, %{session_id: "x"})
      assert get_change(cs, :expires_at)
    end

    test "user carts do not set expires_at" do
      cs = Cart.changeset(%Cart{}, %{user_uuid: Ecto.UUID.generate()})
      refute get_change(cs, :expires_at)
    end
  end

  describe "status_changeset/3 transitions" do
    test "active -> converting is allowed" do
      assert Cart.status_changeset(%Cart{status: "active"}, "converting").valid?
    end

    test "active -> converted is allowed" do
      assert Cart.status_changeset(%Cart{status: "active"}, "converted").valid?
    end

    test "converted is terminal" do
      cs = Cart.status_changeset(%Cart{status: "converted"}, "active")
      refute cs.valid?
      assert %{status: [_ | _]} = errors_on(cs)
    end

    test "rejects an unknown transition" do
      cs = Cart.status_changeset(%Cart{status: "active"}, "frozen")
      refute cs.valid?
    end
  end

  describe "predicates" do
    test "active?/1, guest?/1, empty?/1" do
      assert Cart.active?(%Cart{status: "active"})
      assert Cart.guest?(%Cart{user_uuid: nil})
      assert Cart.empty?(%Cart{items_count: 0})
      refute Cart.empty?(%Cart{items_count: 3})
    end

    test "convertible?/1 needs active status and items" do
      assert Cart.convertible?(%Cart{status: "active", items_count: 1})
      refute Cart.convertible?(%Cart{status: "active", items_count: 0})
      refute Cart.convertible?(%Cart{status: "converted", items_count: 1})
    end

    test "expired?/1" do
      past = DateTime.add(DateTime.utc_now(), -10, :day) |> DateTime.truncate(:second)
      future = DateTime.add(DateTime.utc_now(), 10, :day) |> DateTime.truncate(:second)
      assert Cart.expired?(%Cart{expires_at: past})
      refute Cart.expired?(%Cart{expires_at: future})
      refute Cart.expired?(%Cart{expires_at: nil})
    end
  end
end
