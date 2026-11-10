defmodule PhoenixKitEcommerce.OrderEmailsTest do
  @moduledoc """
  The order emails: who gets which one and when, what they say, in which
  language, and that an order sends each of them once.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog
  import Swoosh.TestAssertions

  alias PhoenixKit.Email.Catalog
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.OrderEvents
  alias PhoenixKitBilling.Workers.OrderEventWorker
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.OrderEmailDefaults
  alias PhoenixKitEcommerce.OrderEmailHandler
  alias PhoenixKitEcommerce.OrderEmails
  alias PhoenixKitEcommerce.Policy
  alias PhoenixKitEcommerce.SearchFixtures
  alias PhoenixKitEcommerce.Workers.OrderEmailWorker

  defmodule RaisingProvider do
    @moduledoc false
    def intercept_before_send(_email, _opts), do: raise("mail server gone")
    def adapter_to_provider_name(_adapter, _default), do: "test"
  end

  @snapshot %{
    "first_name" => "Jane",
    "last_name" => "Doe",
    "email" => "jane@example.com",
    "phone" => "+372 555 5555",
    "address_line1" => "Pikk 1",
    "postal_code" => "10111",
    "city" => "Tallinn",
    "country" => "EE"
  }

  @vase %{
    "type" => "product",
    "name" => "Vase",
    "quantity" => 2,
    "unit_price" => "10.00",
    "total" => "20.00",
    "selected_specs" => %{"color" => "Red"}
  }

  @post %{
    "type" => "shipping",
    "name" => "Shipping: Post",
    "quantity" => 1,
    "unit_price" => "5.00",
    "total" => "5.00"
  }

  setup do
    {:ok, user: fixture_user()}
  end

  defp order(user, attrs \\ %{}) do
    {:ok, order} =
      Billing.create_order(
        user,
        Map.merge(
          %{
            "total" => Decimal.new("25.00"),
            "subtotal" => Decimal.new("20.00"),
            "currency" => "USD",
            "status" => "confirmed",
            "billing_snapshot" => @snapshot,
            "line_items" => [@vase, @post],
            "metadata" => %{"source" => "shop_checkout", "checkout_language" => "en"}
          },
          attrs
        )
      )

    order
  end

  defp jobs(order) do
    worker = inspect(OrderEmailWorker)

    Repo.all(from(j in Oban.Job, where: j.worker == ^worker))
    |> Enum.filter(&(&1.args["order_uuid"] == order.uuid))
    |> Enum.map(& &1.args["email"])
    |> Enum.sort()
  end

  defp mail_to_shop!(addresses \\ "shop@example.com") do
    {:ok, _} = OrderEmails.set_shop_recipients(addresses)
  end

  defp delivered(email, order) do
    assert :ok = OrderEmails.deliver(email, Billing.get_order(order.uuid))
    assert_received {:email, mail}
    mail
  end

  describe "an order just placed" do
    test "queues the buyer's confirmation and the shop's email", %{user: user} do
      order = order(user)

      assert :ok = OrderEmails.order_placed(order)

      assert jobs(order) == ["buyer_placed", "shop"]
    end

    test "that awaits an online payment queues nothing", %{user: user} do
      order =
        order(user, %{
          "status" => "pending",
          "metadata" => %{"source" => "shop_checkout", "payment_option_type" => "online"}
        })

      assert :ok = OrderEmails.order_placed(order)

      assert jobs(order) == []
    end

    test "queues nothing twice", %{user: user} do
      order = order(user)

      OrderEmails.order_placed(order)
      OrderEmails.order_placed(order)

      assert jobs(order) == ["buyer_placed", "shop"]
    end

    test "the checkout queues them with the order, and sends nothing itself" do
      {:ok, cart} = Shop.create_cart(session_id: "mail-#{System.unique_integer([:positive])}")
      {:ok, product} = digital_product()
      {:ok, cart} = Shop.add_to_cart(cart, product, 1)

      {:ok, order} = Shop.convert_cart_to_order(cart, billing_data: complete_billing("EE"))

      assert jobs(order) == ["buyer_placed", "shop"]
      assert order.metadata["checkout_language"]
    end
  end

  describe "an order that becomes paid" do
    test "billing's event queues the buyer's paid email and the shop's", %{user: user} do
      {:ok, paid} = Billing.mark_order_paid(order(user))
      handler = inspect(OrderEmailHandler)
      worker = inspect(OrderEventWorker)

      job =
        Repo.all(from(j in Oban.Job, where: j.worker == ^worker))
        |> Enum.find(&(&1.args["order_uuid"] == paid.uuid and &1.args["handler"] == handler))

      assert OrderEmailHandler in OrderEvents.handlers()
      assert :ok = OrderEventWorker.perform(job)

      assert jobs(paid) == ["buyer_paid", "shop"]
    end

    test "nothing for an order the shop did not place", %{user: user} do
      order = order(user, %{"metadata" => %{}})
      {:ok, paid} = Billing.mark_order_paid(order)

      assert :ok = OrderEmailHandler.handle_order_event(:paid, paid)

      assert jobs(paid) == []
    end

    test "nothing for a :paid that arrives after the refund", %{user: user} do
      {:ok, paid} = Billing.mark_order_paid(order(user))
      {:ok, refunded} = Billing.mark_order_refunded(paid)

      assert :ok = OrderEmailHandler.handle_order_event(:paid, refunded)

      assert jobs(refunded) == []
    end

    test "nothing on a refund or a cancellation", %{user: user} do
      order = order(user)

      assert :ok = OrderEmailHandler.handle_order_event(:refunded, order)
      assert :ok = OrderEmailHandler.handle_order_event(:cancelled, order)

      assert jobs(order) == []
    end
  end

  describe "the buyer's emails" do
    test "go to the address on the order, with everything it holds", %{user: user} do
      order = order(user)

      mail = delivered("buyer_placed", order)

      assert mail.to == [{"", "jane@example.com"}]
      assert mail.subject == "Your order #{order.order_number}"

      for body <- [mail.html_body, mail.text_body] do
        assert body =~ "Hello Jane Doe,"
        assert body =~ order.order_number
        assert body =~ "Vase × 2"
        assert body =~ "Color: Red"
        assert body =~ "Shipping: Post"
        assert body =~ "Pikk 1, 10111, Tallinn, EE"
        assert body =~ "25"
      end
    end

    test "the paid one says so", %{user: user} do
      order = order(user)

      mail = delivered("buyer_paid", order)

      assert mail.subject == "Payment received for order #{order.order_number}"
      assert mail.text_body =~ "is paid and confirmed"
    end

    test "fall back to the account's address", %{user: user} do
      order = order(user)

      Repo.update_all(from(o in Billing.Order, where: o.uuid == ^order.uuid),
        set: [billing_snapshot: %{"first_name" => "Jane"}]
      )

      assert delivered("buyer_placed", order).to == [{"", user.email}]
    end

    test "are in the language of the checkout", %{user: user} do
      SearchFixtures.enable_languages!(["en", "de"])

      order =
        order(user, %{
          "metadata" => %{"source" => "shop_checkout", "checkout_language" => "de"}
        })

      mail = delivered("buyer_placed", order)

      assert mail.subject == "Ihre Bestellung #{order.order_number}"
      assert mail.text_body =~ "Vielen Dank für Ihre Bestellung"
    end

    test "name a pickup point instead of the address", %{user: user} do
      line = Map.put(@post, "destination_label", "Omniva, Viru keskus")
      order = order(user, %{"line_items" => [@vase, line]})

      mail = delivered("buyer_placed", order)

      assert mail.text_body =~ "Omniva, Viru keskus"
      refute mail.text_body =~ "Pikk 1"
    end

    test "say nothing of delivery for an order that ships nothing", %{user: user} do
      order = order(user, %{"line_items" => [@vase]})

      refute delivered("buyer_placed", order).text_body =~ "Delivery"
    end

    test "never show a price on request or a carrier's rates as an amount", %{user: user} do
      lines = [
        Map.merge(@vase, %{"total" => "0.00", "unit_price" => "0", "price_on_request" => true}),
        Map.merge(@post, %{"total" => "0.00", "unit_price" => "0", "pay_on_delivery" => true})
      ]

      order =
        order(user, %{
          "line_items" => lines,
          "total" => Decimal.new("0"),
          "metadata" => %{"source" => "shop_checkout", "shipping_pay_on_delivery" => true}
        })

      mail = delivered("buyer_placed", order)

      assert mail.text_body =~ "Price on request"
      assert mail.text_body =~ "Paid on delivery"
      assert mail.text_body =~ "Items priced on request are not included in this total."
      assert mail.text_body =~ "you pay the carrier at their rates on delivery"
      refute mail.text_body =~ "Vase × 2 (Color: Red): $0"
    end

    test "escape what a shopper or a catalogue typed", %{user: user} do
      line = Map.put(@vase, "name", "<script>alert(1)</script>")
      snapshot = Map.put(@snapshot, "first_name", "<b>Jane</b>")
      order = order(user, %{"line_items" => [line], "billing_snapshot" => snapshot})

      mail = delivered("buyer_placed", order)

      refute mail.html_body =~ "<script>alert"
      refute mail.html_body =~ "<b>Jane"
    end

    test "can be turned off", %{user: user} do
      assert OrderEmails.buyer_emails_enabled?()
      {:ok, false} = OrderEmails.set_buyer_emails_enabled(false)

      assert :ok = OrderEmails.deliver("buyer_placed", order(user))

      refute_received {:email, _}
    end
  end

  describe "the link to the order" do
    test "an account opens its own order page", %{user: user} do
      user |> Ecto.Changeset.change(confirmed_at: now()) |> Repo.update!()
      order = order(user)

      mail = delivered("buyer_placed", order)

      assert mail.text_body =~ Routes.base_url()
      assert mail.text_body =~ "/dashboard/orders/#{order.uuid}"
    end

    test "a guest gets none while the order page needs their session", %{user: user} do
      assert Policy.order_lookup_policy() == :strict

      mail = delivered("buyer_placed", order(guest(user)))

      refute mail.text_body =~ "View your order"
      refute mail.html_body =~ "View your order"
    end

    test "a guest gets the order page where the link is the credential", %{user: user} do
      Settings.update_setting_with_module("shop_order_lookup_policy", "link", "shop")
      order = order(guest(user))

      assert delivered("buyer_placed", order).text_body =~ "/checkout/complete/#{order.uuid}"
    end
  end

  describe "the shop's email" do
    test "goes to every configured address with the buyer's contacts", %{user: user} do
      mail_to_shop!("shop@example.com, owner@example.com")
      order = order(user)

      mail = delivered("shop", order)

      assert Enum.map(mail.to, &elem(&1, 1)) == ["shop@example.com", "owner@example.com"]
      assert mail.subject == "New order #{order.order_number}"
      assert mail.reply_to == {"", "jane@example.com"}

      for body <- [mail.html_body, mail.text_body] do
        assert body =~ "Jane Doe"
        assert body =~ "jane@example.com"
        assert body =~ "+372 555 5555"
        assert body =~ "Pikk 1, 10111, Tallinn, EE"
        assert body =~ "Vase × 2"
        assert body =~ "/admin/billing/orders/#{order.uuid}"
      end
    end

    test "is in the site's language, whatever the buyer's", %{user: user} do
      SearchFixtures.enable_languages!(["en", "de"])
      mail_to_shop!()

      order =
        order(user, %{
          "metadata" => %{"source" => "shop_checkout", "checkout_language" => "de"}
        })

      assert delivered("shop", order).subject == "New order #{order.order_number}"
    end

    test "is in the language chosen for it", %{user: user} do
      SearchFixtures.enable_languages!(["en", "de"])
      mail_to_shop!()
      {:ok, "de"} = OrderEmails.set_shop_email_language("de")

      order = order(user)

      assert delivered("shop", order).subject == "Neue Bestellung #{order.order_number}"
    end

    test "falls back to the site's language when the chosen one is no longer served",
         %{user: user} do
      SearchFixtures.enable_languages!(["en", "de"])
      mail_to_shop!()
      {:ok, "de"} = OrderEmails.set_shop_email_language("de")
      SearchFixtures.enable_languages!(["en"])

      order = order(user)

      assert OrderEmails.shop_email_language() == "en"
      assert delivered("shop", order).subject == "New order #{order.order_number}"
    end

    test "goes nowhere without an address", %{user: user} do
      assert :ok = OrderEmails.deliver("shop", order(user))

      refute_received {:email, _}
    end

    test "is one per order, placed and paid together", %{user: user} do
      mail_to_shop!()
      order = order(user)

      assert :ok = OrderEmails.deliver("shop", order)
      assert_received {:email, _}

      assert :ok = OrderEmails.deliver("shop", Billing.get_order(order.uuid))
      refute_received {:email, _}
    end
  end

  describe "the copies of the buyer's emails" do
    defp copy_to!(addresses \\ "owner@example.com") do
      {:ok, _} = OrderEmails.set_copy_recipients(addresses)
    end

    test "go to every copy address, as the buyer got it", %{user: user} do
      SearchFixtures.enable_languages!(["en", "de"])
      copy_to!("owner@example.com, sales@example.com")

      order =
        order(user, %{
          "metadata" => %{"source" => "shop_checkout", "checkout_language" => "de"}
        })

      assert :ok = OrderEmails.deliver("buyer_placed", order)

      assert_received {:email, buyer}
      assert_received {:email, copy}

      assert buyer.to == [{"", "jane@example.com"}]
      assert copy.to == [{"", "owner@example.com"}, {"", "sales@example.com"}]
      assert copy.reply_to == {"", "jane@example.com"}
      assert copy.subject == buyer.subject
      assert copy.subject == "Ihre Bestellung #{order.order_number}"
      assert copy.text_body == buyer.text_body
    end

    test "come with the paid email too", %{user: user} do
      copy_to!()

      assert :ok = OrderEmails.deliver("buyer_paid", order(user))

      assert_received {:email, %{to: [{"", "jane@example.com"}]}}

      assert_received {:email,
                       %{to: [{"", "owner@example.com"}], subject: "Payment received" <> _}}
    end

    test "are not sent for an email the buyer did not get", %{user: user} do
      copy_to!()
      {:ok, false} = OrderEmails.set_buyer_emails_enabled(false)

      assert :ok = OrderEmails.deliver("buyer_placed", order(user))

      refute_received {:email, _}
    end

    test "none without an address", %{user: user} do
      assert OrderEmails.copy_recipients() == []

      assert :ok = OrderEmails.deliver("buyer_placed", order(user))

      assert_received {:email, %{to: [{"", "jane@example.com"}]}}
      refute_received {:email, _}
    end

    test "are sent once, with a mark of their own", %{user: user} do
      copy_to!()
      order = order(user)

      assert :ok = OrderEmails.deliver("buyer_placed", order)
      assert_received {:email, _}
      assert_received {:email, _}

      assert Billing.get_order(order.uuid).metadata["_shop_emails"] ==
               %{"buyer_placed" => true, "buyer_placed_copy" => true}

      assert :ok = OrderEmails.deliver("buyer_placed", Billing.get_order(order.uuid))
      refute_received {:email, _}
    end

    test "a copy still owed goes without mailing the buyer again", %{user: user} do
      order = order(user)
      delivered("buyer_placed", order)
      copy_to!()

      assert :ok = OrderEmails.deliver("buyer_placed", Billing.get_order(order.uuid))

      assert_received {:email, %{to: [{"", "owner@example.com"}]}}
      refute_received {:email, _}
    end

    test "their addresses are stored like the shop's" do
      assert {:ok, ["a@example.com", "b@example.com"]} =
               OrderEmails.set_copy_recipients("a@example.com;b@example.com")

      assert OrderEmails.copy_recipients() == ["a@example.com", "b@example.com"]

      assert {:error, {:invalid_order_email_addresses, ["nonsense"]}} =
               OrderEmails.set_copy_recipients("nonsense")

      assert {:ok, []} = OrderEmails.set_copy_recipients("")
    end
  end

  describe "the language of the shop's email" do
    test "is the site's until one is chosen" do
      assert OrderEmails.chosen_shop_email_language() == nil
      assert OrderEmails.shop_email_language() == "en"
    end

    test "can only be one the site serves" do
      SearchFixtures.enable_languages!(["en", "ru"])

      assert {:error, :unsupported_language} = OrderEmails.set_shop_email_language("de")
      assert {:ok, "ru"} = OrderEmails.set_shop_email_language("ru")
      assert OrderEmails.shop_email_language() == "ru"

      assert {:ok, nil} = OrderEmails.set_shop_email_language("")
      assert OrderEmails.chosen_shop_email_language() == nil
    end
  end

  describe "once per order" do
    test "a second delivery sends nothing", %{user: user} do
      order = order(user)
      delivered("buyer_paid", order)

      assert :ok = OrderEmails.deliver("buyer_paid", Billing.get_order(order.uuid))

      refute_received {:email, _}
    end

    test "each email has its own mark", %{user: user} do
      order = order(user)

      delivered("buyer_placed", order)
      delivered("buyer_paid", order)
    end

    test "the mark is no edit of the order", %{user: user} do
      order = order(user)
      before = Billing.get_order(order.uuid)

      delivered("buyer_placed", order)

      marked = Billing.get_order(order.uuid)
      assert marked.metadata["_shop_emails"] == %{"buyer_placed" => true}
      assert marked.updated_at == before.updated_at
      assert Billing.Order.revision(marked) == Billing.Order.revision(before)
    end

    test "a failed send is not marked, so the job retries it", %{user: user} do
      previous = Application.get_env(:phoenix_kit, :email_provider)
      Application.put_env(:phoenix_kit, :email_provider, RaisingProvider)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:phoenix_kit, :email_provider, previous),
          else: Application.delete_env(:phoenix_kit, :email_provider)
      end)

      order = order(user)
      job = %Oban.Job{args: %{"order_uuid" => order.uuid, "email" => "buyer_placed"}}

      capture_log(fn ->
        assert_raise RuntimeError, fn -> OrderEmailWorker.perform(job) end
      end)

      assert Billing.get_order(order.uuid).metadata["_shop_emails"] == nil
    end
  end

  describe "the worker" do
    test "sends what the job names", %{user: user} do
      order = order(user)
      job = %Oban.Job{args: %{"order_uuid" => order.uuid, "email" => "buyer_placed"}}

      assert :ok = OrderEmailWorker.perform(job)

      assert_email_sent(to: "jane@example.com")
    end

    test "gives up on an order that is gone" do
      job = %Oban.Job{args: %{"order_uuid" => Ecto.UUID.generate(), "email" => "buyer_placed"}}

      assert {:cancel, :order_not_found} = OrderEmailWorker.perform(job)
    end
  end

  describe "the shop's addresses" do
    test "are stored from what a person typed" do
      assert {:ok, ["a@example.com", "b@example.com", "c@example.com"]} =
               OrderEmails.set_shop_recipients(" a@example.com, b@example.com;c@example.com\n")

      assert OrderEmails.shop_recipients() == ["a@example.com", "b@example.com", "c@example.com"]
    end

    test "are all refused if one is not an address" do
      assert {:error, {:invalid_order_email_addresses, ["nonsense"]}} =
               OrderEmails.set_shop_recipients("a@example.com, nonsense")

      assert OrderEmails.shop_recipients() == []
    end

    test "can be cleared" do
      mail_to_shop!()

      assert {:ok, []} = OrderEmails.set_shop_recipients("")
      assert OrderEmails.shop_recipients() == []
    end

    test "a stored value that is not an address is left out" do
      Settings.update_setting_with_module(
        "shop_order_email_recipients",
        "x, a@example.com",
        "shop"
      )

      assert OrderEmails.shop_recipients() == ["a@example.com"]
    end
  end

  describe "core's email preview" do
    test "lists the three emails, in the shop's layout group" do
      entries = PhoenixKitEcommerce.email_templates()

      assert Enum.map(entries, & &1.name) == OrderEmailDefaults.template_names()
      assert Enum.all?(entries, &(&1.layout == OrderEmailDefaults.layout_group()))
    end

    test "every placeholder has a sample" do
      for entry <- PhoenixKitEcommerce.email_templates() do
        assert {:ok, %{missing: missing}} = Catalog.preview(entry, "en", [])
        assert missing |> Map.values() |> List.flatten() == [], entry.name
      end
    end
  end

  defp digital_product do
    Shop.create_product(%{
      "title" => %{"en" => "Mail Widget #{System.unique_integer([:positive])}"},
      "price" => Decimal.new("10.00"),
      "status" => "active",
      "currency" => "USD",
      "product_type" => "digital",
      "requires_shipping" => false,
      "weight_grams" => 0
    })
  end

  # Guest checkout makes an unconfirmed account; `fixture_user/1`'s is confirmed.
  defp guest(user) do
    user
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.force_change(:confirmed_at, nil)
    |> Repo.update!()
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
