defmodule PhoenixKitEcommerce.NotificationsTest do
  @moduledoc """
  Who hears about an order or an import, and the two contracts that keep
  the audit trail and the notification layer from doubling up.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Notifications, as: ShopNotifications

  describe "notification_types/0" do
    test "declares separate admin and customer sub-types" do
      [%{key: "shop", sub_types: subs}] = PhoenixKitEcommerce.notification_types()

      keys = Enum.map(subs, & &1.key)
      assert "orders" in keys
      assert "order_confirmations" in keys
      assert "imports" in keys

      # Separate sub-types are the point: a shop operator muting the order
      # firehose must not also silence their own receipts.
      orders = Enum.find(subs, &(&1.key == "orders"))
      confirmations = Enum.find(subs, &(&1.key == "order_confirmations"))

      assert orders.actions == ["shop.order_placed"]
      assert confirmations.actions == ["shop.order_confirmed"]
    end

    test "every action belongs to exactly one sub-type" do
      [%{sub_types: subs}] = PhoenixKitEcommerce.notification_types()

      all = Enum.flat_map(subs, & &1.actions)
      assert all == Enum.uniq(all)
    end

    test "the audit action is NOT registered as a notification action" do
      # core's Activity.log/1 auto-derives notifications from registered
      # actions, so an audit row written with a notify action would deliver
      # a duplicate on top of the explicit fan-out.
      [%{sub_types: subs}] = PhoenixKitEcommerce.notification_types()
      registered = Enum.flat_map(subs, & &1.actions)

      refute "shop.order_converted" in registered
      refute "shop.import_run_completed" in registered
      refute "shop.import_run_failed" in registered
    end
  end

  describe "recipient resolution" do
    test "returns a unique list and never raises" do
      recipients = ShopNotifications.admin_recipients("shop.manage_carts")

      assert is_list(recipients)
      assert recipients == Enum.uniq(recipients)
      assert Enum.all?(recipients, &is_binary/1)
    end
  end

  describe "sends are best-effort" do
    test "order_placed/1 tolerates a malformed order rather than raising" do
      # The caller is the checkout path, AFTER the money is committed: a
      # notification must never be able to undo a placed order.
      assert :ok = ShopNotifications.order_placed(%{})
    end

    test "import notifications no-op for logs without an initiator" do
      # Import logs predate the user_uuid column; there is nobody to tell.
      assert :ok = ShopNotifications.import_completed(%{user_uuid: nil}, %{created: 1})
      assert :ok = ShopNotifications.import_failed(%{user_uuid: nil}, :boom)
    end
  end

  describe "order_placed/2 admin notification link" do
    setup do
      create_admin_user()
      :ok
    end

    test "leads to the order's Billing page while Billing is enabled" do
      Settings.update_boolean_setting_with_module("billing_enabled", true, "billing")
      order = placed_order("ORD-LINK-ON")

      assert :ok = ShopNotifications.order_placed(order)

      assert links = notification_links_mentioning("New order ORD-LINK-ON")
      assert Enum.uniq(links) == [Routes.path("/admin/billing/orders/#{order.uuid}")]
    end

    test "stays on the carts list while Billing is disabled" do
      Settings.update_boolean_setting_with_module("billing_enabled", false, "billing")
      order = placed_order("ORD-LINK-OFF")

      assert :ok = ShopNotifications.order_placed(order)

      assert links = notification_links_mentioning("New order ORD-LINK-OFF")
      assert Enum.uniq(links) == [Routes.path("/admin/shop/carts")]
    end
  end

  describe "order_placed/2 when the buyer is a shop operator" do
    test "the operator who placed the order gets both the admin and the customer message" do
      buyer = create_admin_user()
      confirm_user!(buyer)

      assert :ok = ShopNotifications.order_placed(placed_order("ORD-SELF-1", buyer.uuid))

      texts = notification_texts_for(buyer.uuid)
      assert Enum.any?(texts, &(&1 =~ "New order ORD-SELF-1"))
      assert Enum.any?(texts, &(&1 =~ "Your order ORD-SELF-1 is confirmed"))
    end

    test "a buyer without shop access gets only the customer message" do
      operator = create_admin_user()
      buyer = fixture_user()
      confirm_user!(buyer)

      assert :ok = ShopNotifications.order_placed(placed_order("ORD-SELF-2", buyer.uuid))

      assert [text] = notification_texts_for(buyer.uuid)
      assert text =~ "Your order ORD-SELF-2 is confirmed"
      assert Enum.any?(notification_texts_for(operator.uuid), &(&1 =~ "New order ORD-SELF-2"))
    end
  end

  describe "cart signals" do
    setup do
      # toggles default OFF; each test enables what it needs. The cart
      # belongs to a real registered user so admin_recipients has someone
      # to resolve — that user is the first ever registered in this
      # sandboxed transaction, so core auto-promotes it to Owner.
      %{cart: insert_cart_with_item()}
    end

    test "cart_item_added is silent when toggles are off", %{cart: cart} do
      [item] = cart.items
      assert :ok = ShopNotifications.cart_item_added(cart, item, item.product)
      assert notifications_for_action("shop.cart_first_item_added") == []
      assert notifications_for_action("shop.cart_item_added") == []
    end

    test "first add notifies once per cart, second add does not re-fire first-item", %{
      cart: cart
    } do
      PhoenixKit.Settings.update_setting_with_module(
        "shop_notify_cart_first_item",
        "true",
        "shop"
      )

      [item] = cart.items
      assert :ok = ShopNotifications.cart_item_added(cart, item, item.product)
      assert notifications_for_action("shop.cart_first_item_added") != []
      before = length(notifications_for_action("shop.cart_first_item_added"))
      assert :ok = ShopNotifications.cart_item_added(cart, item, item.product)
      assert length(notifications_for_action("shop.cart_first_item_added")) == before
    end

    test "cart-signal text includes the product's title, not the raw struct", %{cart: cart} do
      # Product has no `:name` field — the title lives in `:title`, an i18n
      # map (`%{"en" => "Notify Widget"}`, set by `insert_cart_with_item/0`).
      # Regression for `product_name/1` matching on a field that doesn't
      # exist and silently falling back to the literal string "product".
      PhoenixKit.Settings.update_setting_with_module(
        "shop_notify_cart_first_item",
        "true",
        "shop"
      )

      [item] = cart.items
      assert :ok = ShopNotifications.cart_item_added(cart, item, item.product)

      assert [text] = notification_texts_for_action("shop.cart_first_item_added")
      assert text =~ "Notify Widget"
    end

    test "every-add toggle fires on adds after the first", %{cart: cart} do
      PhoenixKit.Settings.update_setting_with_module(
        "shop_notify_cart_first_item",
        "true",
        "shop"
      )

      PhoenixKit.Settings.update_setting_with_module("shop_notify_cart_item", "true", "shop")
      [item] = cart.items
      # first → first-item action only
      :ok = ShopNotifications.cart_item_added(cart, item, item.product)
      assert notifications_for_action("shop.cart_item_added") == []
      # second → every-add action
      :ok = ShopNotifications.cart_item_added(cart, item, item.product)
      assert notifications_for_action("shop.cart_item_added") != []
    end

    test "toggle flipped on mid-lifecycle does not misfire first-item on a non-empty cart" do
      # Cart already has two items in it BEFORE the first-item toggle is
      # ever turned on — simulates an admin flipping the setting while
      # shoppers already have carts in progress. The next add must not be
      # mistaken for "this cart's actual first item".
      owner = fixture_user()

      {:ok, product_a} =
        Shop.create_product(%{
          "title" => %{"en" => "Widget A"},
          "price" => Decimal.new("10.00"),
          "status" => "active",
          "currency" => "USD",
          "product_type" => "digital",
          "requires_shipping" => false,
          "weight_grams" => 0
        })

      {:ok, product_b} =
        Shop.create_product(%{
          "title" => %{"en" => "Widget B"},
          "price" => Decimal.new("5.00"),
          "status" => "active",
          "currency" => "USD",
          "product_type" => "digital",
          "requires_shipping" => false,
          "weight_grams" => 0
        })

      {:ok, cart} = Shop.create_cart(user_uuid: owner.uuid)
      {:ok, cart} = Shop.add_to_cart(cart, product_a, 1)

      # Only now does the operator turn the toggle on — after the cart
      # already has an item in it.
      PhoenixKit.Settings.update_setting_with_module(
        "shop_notify_cart_first_item",
        "true",
        "shop"
      )

      # `add_to_cart/3` alone, with no call to the notifier from here: the
      # second add is what must not announce a "first item".
      {:ok, cart} = Shop.add_to_cart(cart, product_b, 1)

      assert cart.items_count == 2
      assert notifications_for_action("shop.cart_first_item_added") == []
    end

    test "toggle flipped on mid-lifecycle still emits every-add when that toggle is on" do
      owner = fixture_user()

      {:ok, product_a} =
        Shop.create_product(%{
          "title" => %{"en" => "Widget A"},
          "price" => Decimal.new("10.00"),
          "status" => "active",
          "currency" => "USD",
          "product_type" => "digital",
          "requires_shipping" => false,
          "weight_grams" => 0
        })

      {:ok, product_b} =
        Shop.create_product(%{
          "title" => %{"en" => "Widget B"},
          "price" => Decimal.new("5.00"),
          "status" => "active",
          "currency" => "USD",
          "product_type" => "digital",
          "requires_shipping" => false,
          "weight_grams" => 0
        })

      {:ok, cart} = Shop.create_cart(user_uuid: owner.uuid)
      {:ok, cart} = Shop.add_to_cart(cart, product_a, 1)

      PhoenixKit.Settings.update_setting_with_module(
        "shop_notify_cart_first_item",
        "true",
        "shop"
      )

      PhoenixKit.Settings.update_setting_with_module("shop_notify_cart_item", "true", "shop")

      # `add_to_cart/3` alone, with no call to the notifier from here: this
      # fails if the context stops announcing the add.
      {:ok, _cart} = Shop.add_to_cart(cart, product_b, 1)

      assert notifications_for_action("shop.cart_first_item_added") == []
      assert notifications_for_action("shop.cart_item_added") != []
    end

    test "checkout_started notifies once per cart", %{cart: cart} do
      PhoenixKit.Settings.update_setting_with_module(
        "shop_notify_checkout_started",
        "true",
        "shop"
      )

      assert :ok = ShopNotifications.checkout_started(cart)
      n = length(notifications_for_action("shop.checkout_started"))
      assert n >= 1
      assert :ok = ShopNotifications.checkout_started(cart)
      assert length(notifications_for_action("shop.checkout_started")) == n
    end

    test "shop_recipients honors the configured recipient list" do
      %{uuid: u1} = create_admin_user()
      %{uuid: _u2} = create_admin_user()

      PhoenixKit.Settings.update_json_setting_with_module(
        "shop_notification_recipients",
        %{"uuids" => [u1]},
        "shop"
      )

      assert ShopNotifications.shop_recipients() == [u1]
    end

    test "shop_recipients drops a stored uuid that is no longer a shop admin" do
      # The setting is a snapshot of who was an operator the day it was
      # saved. Revoking someone's shop access has to stop the cart-activity
      # feed too — those messages carry what visitors are shopping for.
      %{uuid: admin_uuid} = create_admin_user()
      %{uuid: outsider_uuid} = fixture_user()

      PhoenixKit.Settings.update_json_setting_with_module(
        "shop_notification_recipients",
        %{"uuids" => [admin_uuid, outsider_uuid]},
        "shop"
      )

      recipients = ShopNotifications.shop_recipients()
      assert admin_uuid in recipients
      refute outsider_uuid in recipients
    end

    test "shop_recipients falls back to all admins when list empty" do
      %{uuid: u1} = create_admin_user()

      PhoenixKit.Settings.update_json_setting_with_module(
        "shop_notification_recipients",
        %{"uuids" => []},
        "shop"
      )

      assert u1 in ShopNotifications.shop_recipients()
    end
  end

  describe "claim_cart_flag/2 under real concurrency" do
    # The sequential "second call returns false" coverage above (e.g. "first
    # add notifies once per cart...") is a reasonable proxy for the atomic
    # `UPDATE ... WHERE NOT (metadata ? flag)` claim, but doesn't actually
    # contend the row. This test races ~8 processes against the same
    # cart/flag pair to back the changelog's claim ("concurrent tabs cannot
    # double-fire") with a real race rather than an inference from the SQL.
    #
    # `async: false` above puts this module's sandbox owner in `shared`
    # mode (`shared: not tags[:async]` in `DataCase`), so every spawned
    # task shares the same DB connection without needing explicit
    # `Sandbox.allow/3` calls.
    test "exactly one of many concurrent claims on the same cart/flag succeeds" do
      cart = insert_cart_with_item()

      results =
        1..8
        |> Task.async_stream(
          fn _ -> Shop.claim_cart_flag(cart, "concurrent_claim_test") end,
          max_concurrency: 8,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, claimed?} -> claimed? end)

      assert length(results) == 8
      assert Enum.count(results, & &1) == 1
    end
  end

  # The fields `order_placed/2` reads, without going through checkout; a guest
  # order (no buyer account) unless `user_uuid` is given.
  defp placed_order(order_number, user_uuid \\ nil) do
    %{
      uuid: Ecto.UUID.generate(),
      user_uuid: user_uuid,
      order_number: order_number,
      metadata: %{},
      total: Decimal.new("10.00"),
      currency: "USD"
    }
  end

  # The customer notification goes only to a confirmed account.
  defp confirm_user!(user) do
    user
    |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update!()
  end

  defp notification_texts_for(user_uuid) do
    from(n in "phoenix_kit_notifications",
      where: n.recipient_uuid == type(^user_uuid, Ecto.UUID),
      select: n.metadata
    )
    |> Repo.all()
    |> Enum.map(& &1["notification_text"])
  end

  # Builds a real cart (owned by a freshly registered user, so
  # admin-recipient resolution has someone to find) with one item in it.
  defp insert_cart_with_item do
    owner = fixture_user()

    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Notify Widget"},
        "price" => Decimal.new("10.00"),
        "status" => "active",
        "currency" => "USD",
        "product_type" => "digital",
        "requires_shipping" => false,
        "weight_grams" => 0
      })

    {:ok, cart} = Shop.create_cart(user_uuid: owner.uuid)
    {:ok, cart} = Shop.add_to_cart(cart, product, 1)

    Repo.preload(cart, items: :product)
  end

  # A user holding the "shop.manage_carts" permission via the (non-Owner)
  # "Admin" system role — the same resolution path `admin_recipients/1`
  # unions over. Explicit grant because module-discovery auto-granting
  # sub-permissions to Admin happens at host boot, which this package's
  # test env does not run.
  defp create_admin_user do
    user = fixture_user()
    role = Roles.get_role_by_name("Admin")
    {:ok, _} = Roles.assign_role(user, "Admin")
    {:ok, _} = Permissions.grant_permission(role.uuid, "shop.manage_carts")
    user
  end
end
