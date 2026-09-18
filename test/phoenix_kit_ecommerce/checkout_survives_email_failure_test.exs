defmodule PhoenixKitEcommerce.CheckoutSurvivesEmailFailureTest do
  @moduledoc """
  The steps that run AFTER the checkout transaction commits must not be able
  to undo, or skip each other over, a fact the shopper has already completed.

  `do_convert_cart_to_order/2` runs three of them in a row — the guest
  confirmation email, the activity record, the operator's "new order"
  notification — and its own comment promises the first one's failure is
  logged rather than raised. It was not: a raise there killed the caller (the
  checkout LiveView, which then remounted onto an empty cart and told the
  shopper their cart was empty) and took the other two steps with it, so the
  order existed while nobody was told about it.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  import Ecto.Query, only: [select: 3]

  alias PhoenixKitEcommerce.Test.Repo, as: TestRepo

  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKitEcommerce, as: Shop

  defmodule ThrowingProvider do
    @moduledoc false
    # A raise is not the only way the mail path can end badly — a throw or an
    # exit from anything below it (a GenServer call into a dead mailer, say)
    # unwinds past `rescue` and needs the `catch` clause. The original bug
    # shipped from precisely this kind of unexercised path.
    def get_active_template_by_name(_name), do: %{name: "register", id: 1}
    def render_template(_template, _variables, _locale), do: throw(:mailer_gone)
    def track_usage(_template), do: :ok
  end

  defmodule RaisingProvider do
    @moduledoc false
    # Stands in for the real failure seen in production: an active database
    # template whose render answers in a shape the caller mis-reads. Any raise
    # on the send path reproduces the same collapse.
    def get_active_template_by_name(_name), do: %{name: "register", id: 1}

    def render_template(_template, _variables, _locale),
      do: raise(KeyError, key: :text, term: %{})

    def track_usage(_template), do: :ok
  end

  defp lang do
    PhoenixKitEcommerce.SlugResolver.normalize_language_public(
      PhoenixKitEcommerce.Translations.default_language()
    )
  end

  setup do
    previous = Application.get_env(:phoenix_kit, :email_provider)
    Application.put_env(:phoenix_kit, :email_provider, RaisingProvider)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit, :email_provider, previous),
        else: Application.delete_env(:phoenix_kit, :email_provider)
    end)

    :ok
  end

  defp guest_cart do
    {:ok, cart} = Shop.create_cart(session_id: "s-#{System.unique_integer([:positive])}")

    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Wand", lang() => "Wand"},
        "slug" => %{lang() => "email-fail-#{System.unique_integer([:positive])}"},
        "price" => Decimal.new("21.80"),
        "status" => "active",
        "currency" => "USD",
        "requires_shipping" => false
      })

    {:ok, cart} = Shop.add_to_cart(cart, product, 1)
    cart
  end

  defp guest_billing do
    %{
      "email" => "guest-#{System.unique_integer([:positive])}@example.com",
      "first_name" => "Guest",
      "last_name" => "Buyer",
      "address_line1" => "1 Test Street",
      "city" => "Testville",
      "postal_code" => "10001",
      "country" => "US"
    }
  end

  test "a guest checkout still returns its order when the confirmation email raises" do
    cart = guest_cart()

    assert {:ok, order} = Shop.convert_cart_to_order(cart, billing_data: guest_billing())
    assert order.order_number
  end

  test "the steps after the email still run" do
    # The activity record sits between the failing email and the operator's
    # notification. If it is missing, the chain aborted at the email and the
    # notification never had a chance either — which is exactly how an order
    # reached the database with nobody informed.
    cart = guest_cart()

    {:ok, order} = Shop.convert_cart_to_order(cart, billing_data: guest_billing())

    assert_activity_logged("shop.order_converted", resource_uuid: order.uuid)
  end

  test "the operator's new-order notification still goes out" do
    # The third post-commit step, and the one the shopper never sees: if the
    # email failure had aborted the chain, this is the row that would be
    # missing when the operator asks why nobody told them about the order.
    # Matched on the rendered text: the admin fan-out does not stamp
    # `metadata["action"]` (only `notify_shop/1` does), so
    # `notifications_for_action/1` cannot see these rows.
    %{uuid: admin_uuid} = create_admin_user()
    cart = guest_cart()

    {:ok, order} = Shop.convert_cart_to_order(cart, billing_data: guest_billing())

    assert admin_uuid in new_order_recipients(order.order_number)
  end

  test "a throw from the mail path is survived too, not only a raise" do
    Application.put_env(:phoenix_kit, :email_provider, ThrowingProvider)
    cart = guest_cart()

    assert {:ok, order} = Shop.convert_cart_to_order(cart, billing_data: guest_billing())
    assert_activity_logged("shop.order_converted", resource_uuid: order.uuid)
  end

  # A user holding "shop.manage_carts" through the "Admin" system role — the
  # resolution path `admin_recipients/1` unions over. Explicit grant because
  # module-discovery auto-granting happens at host boot, which this package's
  # test env does not run.
  defp new_order_recipients(order_number) do
    "phoenix_kit_notifications"
    |> select([n], %{recipient_uuid: type(n.recipient_uuid, Ecto.UUID), metadata: n.metadata})
    |> TestRepo.all()
    |> Enum.filter(
      &String.starts_with?(&1.metadata["notification_text"] || "", "New order #{order_number}")
    )
    |> Enum.map(& &1.recipient_uuid)
  end

  defp create_admin_user do
    user = fixture_user()
    role = Roles.get_role_by_name("Admin")
    {:ok, _} = Roles.assign_role(user, "Admin")
    {:ok, _} = Permissions.grant_permission(role.uuid, "shop.manage_carts")
    user
  end

  test "the cart is still marked converted" do
    cart = guest_cart()

    {:ok, _order} = Shop.convert_cart_to_order(cart, billing_data: guest_billing())

    assert Shop.get_cart(cart.uuid).status == "converted"
  end
end
