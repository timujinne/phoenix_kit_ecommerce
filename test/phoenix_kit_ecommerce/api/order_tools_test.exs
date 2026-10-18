defmodule PhoenixKitEcommerce.API.OrderToolsTest do
  @moduledoc """
  The order tools through the handler context core's executor builds, minus
  authentication (see `PhoenixKitEcommerce.APICase`): the feed and its cursor,
  the sync filter, the contacts that need their own scope, the marks and the
  stale revision. `order_tools_executor_test.exs` runs them through the real
  executor with real keys.

  Every order a test cares about is dated 2030 (`updated_since` below), so the
  feed holds only those whatever else the database has.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :core_api
  @moduletag :billing_order_sync

  @compile {:no_warn_undefined, [PhoenixKit.API.ToolLint]}

  import PhoenixKitEcommerce.OrderFixtures

  alias PhoenixKit.API.ToolLint
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Order
  alias PhoenixKitEcommerce.API.ListOrders
  alias PhoenixKitEcommerce.API.OrderTools
  alias PhoenixKitEcommerce.APICase
  alias PhoenixKitEcommerce.APIFixtures, as: F

  @read "ecommerce.orders:read"
  @sync "ecommerce.orders:sync"
  @customer "ecommerce.orders:customer"
  @base ~U[2030-01-01 00:00:00Z]
  @since "2030-01-01T00:00:00Z"

  setup do
    %{user: fixture_user()}
  end

  defp ctx(user, scopes \\ [@read, @sync], extra \\ %{}),
    do: F.ctx(user, Map.merge(%{scopes: scopes}, extra))

  defp call(tool, input, user, scopes \\ [@read, @sync], extra \\ %{}),
    do: APICase.call(tool, input, ctx(user, scopes, extra))

  # An order dated `seconds` after the base of the feed.
  defp dated!(seconds, attrs \\ %{}) do
    order = order!(attrs)
    touch!(order, DateTime.add(@base, seconds))
  end

  defp list(input, user, scopes \\ [@read, @sync]) do
    {:ok, answer} =
      call("ecommerce.list_orders", Map.put_new(input, "updated_since", @since), user, scopes)

    answer
  end

  defp ids(answer), do: Enum.map(answer["orders"], & &1["id"])

  describe "the tools" do
    test "are offered with their scopes and permissions, and core's lint passes" do
      table =
        Map.new(
          OrderTools.tools(true),
          &{&1.name, {&1.scope, &1.permission, &1.annotations.read_only}}
        )

      assert table == %{
               "ecommerce.list_orders" => {@read, "shop", true},
               "ecommerce.get_orders" => {@read, "shop", true},
               "ecommerce.get_order_customers" => {@customer, "shop.manage_orders", true},
               "ecommerce.set_order_sync" => {@sync, "shop.manage_orders", false}
             }

      assert :ok = ToolLint.check_tools(OrderTools.tools(true))
    end

    test "are part of the module's api_tools while billing keeps the order revision" do
      assert OrderTools.available?()

      names = for tool <- PhoenixKitEcommerce.api_tools(), do: tool.name
      assert Enum.all?(OrderTools.tools(true), &(&1.name in names))
    end

    test "are not offered without that billing" do
      assert OrderTools.tools(false) == []
    end

    test "the module declares the manage_orders permission they use" do
      keys = for sub <- PhoenixKitEcommerce.permission_metadata().sub_permissions, do: sub.key
      assert "manage_orders" in keys
    end

    test "the batch tools cap their lists at 100" do
      for name <- [
            "ecommerce.get_orders",
            "ecommerce.get_order_customers",
            "ecommerce.set_order_sync"
          ] do
        assert Enum.find(OrderTools.tools(true), &(&1.name == name)).max_items == 100
      end
    end
  end

  describe "ecommerce.list_orders" do
    test "answers orders oldest change first, without draft ones, with every section", %{
      user: user
    } do
      late = dated!(30)
      early = dated!(10)
      draft = dated!(20, %{"status" => "draft"})

      answer = list(%{}, user)

      assert ids(answer) == [early.uuid, late.uuid]
      refute draft.uuid in ids(answer)
      assert answer["has_more"] == false
      assert answer["next_cursor"] == nil

      [first | _] = answer["orders"]
      assert Map.has_key?(first, "lines") and Map.has_key?(first, "customer")
      assert Map.has_key?(first, "shipping") and Map.has_key?(first, "payment")
    end

    test "statuses can name the draft ones, and narrow", %{user: user} do
      pending = dated!(10)
      draft = dated!(20, %{"status" => "draft"})

      assert ids(list(%{"statuses" => ["draft"]}, user)) == [draft.uuid]
      assert ids(list(%{"statuses" => ["pending", "draft"]}, user)) == [pending.uuid, draft.uuid]
      assert ids(list(%{"statuses" => ["paid"]}, user)) == []
    end

    test "updated_since leaves out what changed before it", %{user: user} do
      old = dated!(10)
      recent = dated!(100)

      answer = list(%{"updated_since" => "2030-01-01T00:01:00Z"}, user)

      assert ids(answer) == [recent.uuid]
      refute old.uuid in ids(answer)
    end

    test "pages by cursor over (updated_at, uuid), ties included, with no gap and no repeat", %{
      user: user
    } do
      orders = [
        dated!(10),
        dated!(10),
        dated!(10),
        dated!(20),
        dated!(20),
        dated!(30),
        dated!(40)
      ]

      expected = orders |> Enum.sort_by(&{&1.updated_at, &1.uuid}) |> Enum.map(& &1.uuid)

      pages = collect_pages(user, %{"limit" => 2}, nil, [])

      assert Enum.map(pages, &length/1) == [2, 2, 2, 1]
      assert List.flatten(pages) == expected
    end

    defp collect_pages(user, input, cursor, acc) do
      answer = list(if(cursor, do: Map.put(input, "cursor", cursor), else: input), user)
      acc = acc ++ [ids(answer)]

      if answer["has_more"] do
        assert is_binary(answer["next_cursor"])
        collect_pages(user, input, answer["next_cursor"], acc)
      else
        assert answer["next_cursor"] == nil
        acc
      end
    end

    test "the same cursor gives the same page", %{user: user} do
      for seconds <- [10, 20, 30, 40], do: dated!(seconds)

      %{"next_cursor" => cursor} = list(%{"limit" => 2}, user)

      assert list(%{"limit" => 2, "cursor" => cursor}, user) ==
               list(%{"limit" => 2, "cursor" => cursor}, user)
    end

    test "a page that ends exactly at the last order has no more", %{user: user} do
      for seconds <- [10, 20], do: dated!(seconds)

      answer = list(%{"limit" => 2}, user)

      assert length(answer["orders"]) == 2
      assert answer["has_more"] == false
      assert answer["next_cursor"] == nil
    end

    test "sync pending, synced and any", %{user: user} do
      fresh = dated!(10)
      taken = dated!(20)
      refused = dated!(30)
      changed = dated!(40)

      {:ok, _} = Billing.put_order_sync(taken, %{state: "synced", external_id: "e-1"})
      {:ok, _} = Billing.put_order_sync(refused, %{state: "failed", error: "unknown item"})
      {:ok, changed} = Billing.put_order_sync(changed, %{state: "synced", external_id: "e-2"})
      {:ok, _} = Billing.update_order(changed, %{"notes" => "edited after the mark"})

      Repo.update_all(from(o in Order, where: o.uuid == ^changed.uuid),
        set: [updated_at: DateTime.add(@base, 50)]
      )

      assert ids(list(%{"sync" => "pending"}, user)) == [fresh.uuid, changed.uuid]
      assert ids(list(%{"sync" => "synced"}, user)) == [taken.uuid]

      assert ids(list(%{"sync" => "any"}, user)) == [
               fresh.uuid,
               taken.uuid,
               refused.uuid,
               changed.uuid
             ]

      assert ids(list(%{}, user)) == ids(list(%{"sync" => "any"}, user))
    end

    test "a mark does not move the order in the feed", %{user: user} do
      a = dated!(10)
      b = dated!(20)

      {:ok, _} = Billing.put_order_sync(a, %{state: "synced"})

      answer = list(%{}, user)
      assert ids(answer) == [a.uuid, b.uuid]
      assert hd(answer["orders"])["updated_at"] == "2030-01-01T00:00:10Z"
    end

    test "an order that changed after a mark is pending again with the ids it already has", %{
      user: user
    } do
      order = dated!(10)

      {:ok, order} =
        Billing.put_order_sync(order, %{
          state: "synced",
          external_id: "e-1",
          external_number: "N-1"
        })

      assert list(%{"sync" => "pending"}, user)["orders"] == []

      {:ok, _} = Billing.cancel_order(order)
      touch!(order, DateTime.add(@base, 10))

      assert [pending] = list(%{"sync" => "pending"}, user)["orders"]
      assert pending["status"] == "cancelled"

      assert %{
               "state" => "pending",
               "external_id" => "e-1",
               "external_number" => "N-1",
               "revision" => 2
             } =
               pending["sync"]
    end

    test "include narrows the sections", %{user: user} do
      dated!(10)

      [order] = list(%{"include" => ["payment"]}, user)["orders"]

      assert Map.has_key?(order, "payment")
      refute Map.has_key?(order, "lines")
      refute Map.has_key?(order, "customer")
    end

    test "the buyer's contacts need ecommerce.orders:customer", %{user: user} do
      dated!(10)

      [without] = list(%{}, user)["orders"]
      assert Map.keys(without["customer"]) |> Enum.sort() == ["id", "type"]

      [with] = list(%{}, user, [@read, @customer])["orders"]

      assert %{"first_name" => "Ivan", "email" => "buyer" <> _, "address" => %{"city" => "Kyiv"}} =
               with["customer"]
    end

    test "refuses a limit above 100 instead of cutting it", %{user: user} do
      assert {:error, :validation_failed, _message, %{errors: [%{path: "limit", limit: 100}]}} =
               call("ecommerce.list_orders", %{"limit" => 101}, user)

      # The handler holds the same line when the schema is not in front of it.
      assert {:error, :validation_failed, _, %{errors: [%{path: "limit"}]}} =
               ListOrders.run(%{"limit" => 101}, ctx(user))

      assert {:ok, %{"orders" => _}} = call("ecommerce.list_orders", %{"limit" => 100}, user)
    end

    test "refuses a limit below 1, a cursor it did not issue and a date it cannot read", %{
      user: user
    } do
      assert {:error, :validation_failed, _, %{errors: [%{path: "limit"}]}} =
               call("ecommerce.list_orders", %{"limit" => 0}, user)

      for cursor <- ["garbage", Base.url_encode64(~s({"t":"x","u":"y"}), padding: false), "e30"] do
        assert {:error, :validation_failed, _, %{errors: [%{path: "cursor"}]}} =
                 call("ecommerce.list_orders", %{"cursor" => cursor}, user)
      end

      assert {:error, :validation_failed, _, %{errors: [%{path: "updated_since"}]}} =
               call("ecommerce.list_orders", %{"updated_since" => "yesterday"}, user)
    end

    test "refuses what the closed schema does not know", %{user: user} do
      assert {:error, :validation_failed, _, %{errors: [_ | _]}} =
               call("ecommerce.list_orders", %{"sync" => "maybe"}, user)

      assert {:error, :validation_failed, _, %{errors: [_ | _]}} =
               call("ecommerce.list_orders", %{"colour" => "red"}, user)
    end
  end

  describe "ecommerce.get_orders" do
    test "reads by id and by number, in the order given, and tells the unknown apart", %{
      user: user
    } do
      a = order!()
      b = order!()
      unknown = Ecto.UUID.generate()

      {:ok, answer} =
        call(
          "ecommerce.get_orders",
          %{
            "refs" => [
              %{"number" => b.order_number},
              %{"id" => a.uuid},
              %{"id" => unknown},
              %{"number" => "ORD-NOPE"},
              %{"id" => a.uuid, "number" => b.order_number}
            ]
          },
          user
        )

      assert [rb, ra, missing_id, missing_number, both] = answer["results"]
      assert rb["order"]["id"] == b.uuid
      assert ra["order"]["id"] == a.uuid
      assert missing_id["error"]["code"] == "not_found"
      assert missing_number["error"]["code"] == "not_found"
      assert both["error"]["code"] == "validation_failed"
      assert answer["summary"] == %{"found" => 2, "error" => 3}
    end

    test "gives the contacts only to a key with the customer scope", %{user: user} do
      order = order!()
      input = %{"refs" => [%{"id" => order.uuid}]}

      {:ok, %{"results" => [plain]}} = call("ecommerce.get_orders", input, user)
      assert Map.keys(plain["order"]["customer"]) |> Enum.sort() == ["id", "type"]

      {:ok, %{"results" => [full]}} =
        call("ecommerce.get_orders", input, user, [@read, @customer])

      assert full["order"]["customer"]["last_name"] == "Petrenko"
    end

    test "narrows the sections", %{user: user} do
      order = order!()

      {:ok, %{"results" => [row]}} =
        call(
          "ecommerce.get_orders",
          %{"refs" => [%{"id" => order.uuid}], "include" => ["lines"]},
          user
        )

      assert Map.has_key?(row["order"], "lines")
      refute Map.has_key?(row["order"], "customer")
    end

    test "refuses more than 100 references and an empty list", %{user: user} do
      refs = for _ <- 1..101, do: %{"number" => "X"}

      assert {:error, :validation_failed, _, _} =
               call("ecommerce.get_orders", %{"refs" => refs}, user)

      assert {:error, :validation_failed, _, _} =
               call("ecommerce.get_orders", %{"refs" => []}, user)
    end
  end

  describe "ecommerce.get_order_customers" do
    test "answers the buyer with contacts", %{user: user} do
      order = order!()

      {:ok, answer} =
        call(
          "ecommerce.get_order_customers",
          %{"refs" => [%{"id" => order.uuid}, %{"number" => "ORD-NOPE"}]},
          user,
          [@customer]
        )

      assert [found, missing] = answer["results"]
      assert found["id"] == order.uuid
      assert found["number"] == order.order_number

      assert %{"first_name" => "Ivan", "phone" => "+380" <> _, "type" => "user"} =
               found["customer"]

      assert missing["error"]["code"] == "not_found"
      assert answer["summary"] == %{"found" => 1, "error" => 1}
    end
  end

  describe "ecommerce.set_order_sync" do
    defp mark(order, extra \\ %{}) do
      Map.merge(
        %{"ref" => %{"number" => order.order_number}, "revision" => 1, "state" => "synced"},
        extra
      )
    end

    test "records the mark and nothing else of the order", %{user: user} do
      order = dated!(10)

      {:ok, answer} =
        call(
          "ecommerce.set_order_sync",
          %{
            "orders" => [
              mark(order, %{
                "external_id" => "GUID-1",
                "external_number" => "N-000123",
                "external_status" => "Not agreed"
              })
            ]
          },
          user
        )

      assert [%{"action" => "marked", "id" => id, "sync" => sync}] = answer["results"]
      assert id == order.uuid
      assert answer["summary"] == %{"marked" => 1, "error" => 0}

      assert %{
               "state" => "synced",
               "external_id" => "GUID-1",
               "external_number" => "N-000123",
               "external_status" => "Not agreed",
               "revision" => 1,
               "error" => nil
             } = sync

      stored = Billing.get_order(order.uuid)
      assert stored.updated_at == order.updated_at
      assert stored.status == order.status
      assert Decimal.equal?(stored.total, order.total)
      assert Order.revision(stored) == 1
      assert stored.metadata["sync"]["external_id"] == "GUID-1"
    end

    test "a failed mark carries its error", %{user: user} do
      order = order!()

      {:ok, %{"results" => [%{"sync" => sync}]}} =
        call(
          "ecommerce.set_order_sync",
          %{
            "orders" => [
              mark(order, %{"state" => "failed", "error" => "item 4820000000000 not found"})
            ]
          },
          user
        )

      assert %{"state" => "failed", "error" => "item 4820000000000 not found"} = sync
    end

    test "answers conflict for a revision the order has moved past, and writes nothing", %{
      user: user
    } do
      order = order!()
      {:ok, order} = Billing.update_order(order, %{"notes" => "edited after the read"})
      assert Order.revision(order) == 2

      {:ok, answer} = call("ecommerce.set_order_sync", %{"orders" => [mark(order)]}, user)

      assert [%{"action" => "error", "error" => error}] = answer["results"]

      assert %{
               "code" => "conflict",
               "context" => %{"reason" => "stale_revision", "current_revision" => 2}
             } = error

      assert answer["summary"] == %{"marked" => 0, "error" => 1}
      refute Map.has_key?(Billing.get_order(order.uuid).metadata, "sync")

      assert order.uuid in ids(
               list(%{"sync" => "pending", "updated_since" => "2000-01-01T00:00:00Z"}, user)
             )
    end

    test "rows are independent: one stale, one unknown, one bad reference, one good", %{
      user: user
    } do
      good = order!()
      stale = order!()
      {:ok, _} = Billing.update_order(stale, %{"notes" => "edited"})

      {:ok, answer} =
        call(
          "ecommerce.set_order_sync",
          %{
            "orders" => [
              mark(stale),
              mark(good),
              mark(good, %{"ref" => %{"number" => "ORD-NOPE"}}),
              mark(good, %{"ref" => %{"id" => good.uuid, "number" => good.order_number}})
            ]
          },
          user
        )

      assert [stale_row, good_row, unknown_row, bad_ref_row] = answer["results"]
      assert stale_row["error"]["code"] == "conflict"
      assert good_row["action"] == "marked"
      assert unknown_row["error"]["code"] == "not_found"
      assert bad_ref_row["error"]["code"] == "validation_failed"
      assert answer["summary"] == %{"marked" => 1, "error" => 3}
    end

    test "repeating a row leaves the mark as it is", %{user: user} do
      order = order!()
      input = %{"orders" => [mark(order, %{"external_id" => "GUID-1"})]}

      {:ok, first} = call("ecommerce.set_order_sync", input, user)
      {:ok, second} = call("ecommerce.set_order_sync", input, user)

      assert first["results"] == second["results"]
    end

    test "a later mark of the same revision replaces the earlier one", %{user: user} do
      order = order!()

      {:ok, _} =
        call(
          "ecommerce.set_order_sync",
          %{"orders" => [mark(order, %{"state" => "failed", "error" => "locked"})]},
          user
        )

      {:ok, %{"results" => [%{"sync" => sync}]}} =
        call(
          "ecommerce.set_order_sync",
          %{"orders" => [mark(order, %{"external_id" => "GUID-1"})]},
          user
        )

      assert %{"state" => "synced", "error" => nil, "external_id" => "GUID-1"} = sync
    end

    test "writes a PII-free entry to the activity log", %{user: user} do
      order = order!()

      {:ok, _} =
        call(
          "ecommerce.set_order_sync",
          %{"orders" => [mark(order, %{"external_number" => "N-1"})]},
          user
        )

      entry = assert_activity_logged("shop.api_order_sync_marked", resource_uuid: order.uuid)
      assert entry.metadata["state"] == "synced"
      assert entry.metadata["revision"] == 1
      assert entry.metadata["tool"] == "ecommerce.set_order_sync"
      refute inspect(entry.metadata) =~ "N-1"
      refute inspect(entry.metadata) =~ order.billing_snapshot["email"]
    end

    test "a dry run reports what it would do and writes nothing", %{user: user} do
      fine = order!()
      stale = order!()
      {:ok, _} = Billing.update_order(stale, %{"notes" => "edited"})

      assert {:preview, preview, fingerprint} =
               call(
                 "ecommerce.set_order_sync",
                 %{"orders" => [mark(fine), mark(stale)]},
                 user,
                 [@read, @sync],
                 %{dry_run?: true}
               )

      assert is_binary(fingerprint)

      assert [%{"action" => "marked"}, %{"action" => "error", "error" => %{"code" => "conflict"}}] =
               preview["rows"]

      assert preview["totals"] == %{"rows" => 2, "marked" => 1, "error" => 1}
      assert preview["requires_confirmation"] == false

      refute Map.has_key?(Billing.get_order(fine.uuid).metadata, "sync")
    end

    test "refuses rows the schema does not accept", %{user: user} do
      order = order!()
      row = mark(order)

      for bad <- [
            Map.delete(row, "revision"),
            Map.delete(row, "state"),
            Map.put(row, "state", "pending"),
            Map.put(row, "revision", 0),
            Map.put(row, "colour", "red"),
            Map.delete(row, "ref")
          ] do
        assert {:error, :validation_failed, _, %{errors: [_ | _]}} =
                 call("ecommerce.set_order_sync", %{"orders" => [bad]}, user)
      end

      too_many = for _ <- 1..101, do: row

      assert {:error, :validation_failed, _, _} =
               call("ecommerce.set_order_sync", %{"orders" => too_many}, user)
    end

    test "end to end: pending, taken, changed, pending again, taken again", %{user: user} do
      order = dated!(10)
      pending = fn -> ids(list(%{"sync" => "pending"}, user)) end

      assert pending.() == [order.uuid]

      {:ok, _} =
        call(
          "ecommerce.set_order_sync",
          %{"orders" => [mark(order, %{"external_id" => "G"})]},
          user
        )

      assert pending.() == []

      {:ok, changed} = Billing.update_order(order, %{"notes" => "customer asked to change"})
      touch!(changed, DateTime.add(@base, 20))
      assert pending.() == [order.uuid]

      {:ok, _} =
        call("ecommerce.set_order_sync", %{"orders" => [mark(order, %{"revision" => 2})]}, user)

      assert pending.() == []
      assert ids(list(%{"sync" => "synced"}, user)) == [order.uuid]
    end
  end
end
