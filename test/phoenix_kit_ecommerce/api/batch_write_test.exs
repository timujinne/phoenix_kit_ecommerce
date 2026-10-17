defmodule PhoenixKitEcommerce.API.BatchWriteTest do
  @moduledoc """
  `Batch.write/3` against a real catalogue: the rows that change are written
  in one catalogue batch, the answer says `updated` or `unchanged` as the
  catalogue does, and only a write that changed something clears the
  storefront's cache.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :catalogue_api

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.PubSub, as: CataloguePubSub
  alias PhoenixKitEcommerce.API.{Batch, PricePlan}
  alias PhoenixKitEcommerce.APIFixtures, as: F
  alias PhoenixKitEcommerce.StorefrontCache

  setup do
    start_supervised!(PhoenixKit.Cache.Registry)
    [spec] = StorefrontCache.children()
    start_supervised!(spec)

    catalogue = F.shop_catalogue!()
    %{catalogue: catalogue, ctx: F.ctx(F.user!())}
  end

  defp write_price(catalogue, item, price, ctx) do
    [row] = Batch.load([%{"ref" => %{"id" => item.uuid}}], catalogue.uuid)

    [row] =
      Batch.plan([row], fn _row ->
        {:ok,
         %{
           from: %{price: item.base_price},
           changes: %{"price" => %{"from" => "100.00", "to" => Decimal.to_string(price)}},
           changed?: true,
           dangerous?: false,
           warnings: [],
           attrs: %{base_price: price},
           owned_paths: []
         }}
      end)

    [written] = Batch.write([row], ctx, "ecommerce.set_prices")
    written
  end

  test "a changed row is stored, answered as updated and clears the storefront cache",
       %{catalogue: catalogue, ctx: ctx} do
    item = F.item!(catalogue)
    :stale = StorefrontCache.fetch(:probe, fn -> :stale end)

    row = write_price(catalogue, item, Decimal.new("120.00"), ctx)

    assert {:ok, _item} = row.result
    assert %{"results" => [%{"action" => "updated"}]} = Batch.render([row])
    assert Decimal.equal?(F.reload!(item).base_price, Decimal.new("120.00"))
    assert StorefrontCache.fetch(:probe, fn -> :fresh end) == :fresh
  end

  test "a row the catalogue finds already up to date is unchanged and leaves the cache",
       %{catalogue: catalogue, ctx: ctx} do
    item = F.item!(catalogue)
    :stale = StorefrontCache.fetch(:probe, fn -> :stale end)

    row = write_price(catalogue, item, Decimal.new("100.00"), ctx)

    assert {:unchanged, _item} = row.result
    assert %{"results" => [%{"action" => "unchanged"}]} = Batch.render([row])
    assert StorefrontCache.fetch(:probe, fn -> :fresh end) == :stale
  end

  describe "a row that owns one data path" do
    @shop_status_path ["ecommerce", "shop_status"]

    defp shop_status_item(catalogue) do
      F.item!(catalogue, %{
        data: %{
          "_primary_language" => "en",
          "ecommerce" => %{
            "shop_status" => "active",
            "shopify" => %{"product_id" => "100"},
            "price_modifiers" => %{"Size" => %{"S" => "1.00"}}
          }
        }
      })
    end

    # The plan of a row that sets `shop_status` to "hidden" and owns only that path.
    defp hide_plan do
      %{
        from: %{visibility: "active"},
        changes: %{"visibility" => %{"from" => "active", "to" => "hidden"}},
        changed?: true,
        dangerous?: false,
        warnings: [],
        attrs: %{data: %{"ecommerce" => %{"shop_status" => "hidden"}}},
        owned_paths: [@shop_status_path]
      }
    end

    defp planned_hide_row(catalogue, item) do
      [row] = Batch.load([%{"ref" => %{"id" => item.uuid}}], catalogue.uuid)
      [row] = Batch.plan([row], fn _row -> {:ok, hide_plan()} end)
      row
    end

    test "the values another writer stored since the row was read survive", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = shop_status_item(catalogue)
      row = planned_hide_row(catalogue, item)

      # A foreign writer (the Shopify sync) stores while the row is planned.
      {:ok, _} =
        Catalogue.update_item(F.reload!(item), %{
          data: %{
            "_primary_language" => "en",
            "ecommerce" => %{
              "shop_status" => "active",
              "shopify" => %{"product_id" => "200"},
              "price_modifiers" => %{"Size" => %{"S" => "1.00", "M" => "5.00"}}
            }
          }
        })

      assert [%{result: {:ok, _item}}] = Batch.write([row], ctx, "ecommerce.set_availability")

      ecommerce = F.reload!(item).data["ecommerce"]
      assert ecommerce["shop_status"] == "hidden"
      assert ecommerce["shopify"] == %{"product_id" => "200"}
      assert ecommerce["price_modifiers"] == %{"Size" => %{"S" => "1.00", "M" => "5.00"}}
    end

    test "the change log names the key owner, the tool and the request, as an automatic change",
         %{catalogue: catalogue, ctx: ctx} do
      item = shop_status_item(catalogue)
      row = planned_hide_row(catalogue, item)

      assert [%{result: {:ok, _item}}] = Batch.write([row], ctx, "ecommerce.set_availability")

      entry =
        assert_activity_logged("item.updated",
          resource_uuid: item.uuid,
          actor_uuid: ctx.actor.user_uuid,
          metadata_has: %{
            "via" => "api",
            "tool" => "ecommerce.set_availability",
            "key_prefix" => "a1b2c3d4",
            "request_id" => "req-test"
          }
        )

      assert entry.mode == "auto"

      assert entry.metadata["changes"]["data.ecommerce.shop_status"] ==
               %{"from" => "active", "to" => "hidden"}
    end
  end

  describe "option and value names with dots" do
    test "the preview and the result agree and the write lands on the right leaf",
         %{catalogue: catalogue, ctx: ctx} do
      item =
        F.item!(catalogue, %{
          data: %{
            "_primary_language" => "en",
            "ecommerce" => %{
              "shop_status" => "active",
              "price_modifiers" => %{"a.b" => %{"c" => "1.00"}, "a" => %{"b.c" => "2.00"}}
            }
          }
        })

      [row] = Batch.load([%{"ref" => %{"id" => item.uuid}}], catalogue.uuid)

      [row] =
        Batch.plan([row], fn row ->
          PricePlan.plan(
            %{"price_modifiers" => %{"a.b" => %{"c" => "3.00"}, "a" => %{"b.c" => nil}}},
            row.item,
            pct: 30,
            sets: nil
          )
        end)

      assert %{"rows" => [%{"action" => "update"}]} = Batch.preview([row])

      [written] = Batch.write([row], ctx, "ecommerce.set_prices")

      assert %{"results" => [%{"action" => "updated"}]} = Batch.render([written])
      modifiers = F.reload!(item).data["ecommerce"]["price_modifiers"]
      assert modifiers == %{"a.b" => %{"c" => "3.00"}}
    end
  end

  describe "write_if_unchanged/4" do
    # Plans a price change from the item as it is read; the planner can be
    # called again on a fresher item and answers the values it reads there.
    defp price_planner(price) do
      fn %{item: item} ->
        {:ok,
         %{
           from: %{price: item.base_price},
           changes: %{"price" => %{"from" => "?", "to" => Decimal.to_string(price)}},
           changed?: true,
           dangerous?: false,
           warnings: [],
           attrs: %{base_price: price},
           owned_paths: []
         }}
      end
    end

    defp planned(catalogue, item, planner) do
      [row] = Batch.load([%{"ref" => %{"id" => item.uuid}}], catalogue.uuid)
      [row] = Batch.plan([row], planner)
      row
    end

    test "writes a row whose values are still the ones it was planned from",
         %{catalogue: catalogue, ctx: ctx} do
      item = F.item!(catalogue)
      planner = price_planner(Decimal.new("120.00"))
      row = planned(catalogue, item, planner)

      assert [%{result: {:ok, _item}}] =
               Batch.write_if_unchanged([row], ctx, "ecommerce.set_prices", planner)

      assert Decimal.equal?(F.reload!(item).base_price, Decimal.new("120.00"))
    end

    test "announces the catalogue change once, after the commit and not before it",
         %{catalogue: catalogue, ctx: ctx} do
      first = F.item!(catalogue)
      second = F.item!(catalogue)
      unchanged = F.item!(catalogue, %{base_price: Decimal.new("120.00")})
      planner = price_planner(Decimal.new("120.00"))

      rows =
        Batch.load(
          for(item <- [first, second, unchanged], do: %{"ref" => %{"id" => item.uuid}}),
          catalogue.uuid
        )
        |> Batch.plan(planner)

      CataloguePubSub.subscribe()
      test_pid = self()
      handler_id = {:batch_write_timeline, make_ref()}

      :telemetry.attach(
        handler_id,
        [:phoenix_kit_ecommerce, :test, :repo, :query],
        fn _event, _measurements, %{query: query}, _config ->
          if query in ["begin", "commit"], do: send(test_pid, {:transaction, query})
        end,
        nil
      )

      try do
        Batch.write_if_unchanged(rows, ctx, "ecommerce.set_prices", planner)
      after
        :telemetry.detach(handler_id)
      end

      timeline =
        Enum.reverse(drain_timeline([]))

      assert [{:transaction, "begin"}, {:transaction, "commit"}, {:bulk, uuids}, :data_changed] =
               timeline

      assert Enum.sort(uuids) == Enum.sort([first.uuid, second.uuid])
    end

    test "an announcement that raises after the commit leaves the write and its answer intact",
         %{catalogue: catalogue, ctx: ctx} do
      item = F.item!(catalogue)
      planner = price_planner(Decimal.new("120.00"))
      row = planned(catalogue, item, planner)

      previous = Application.get_env(:phoenix_kit, :pubsub)
      Application.put_env(:phoenix_kit, :pubsub, PhoenixKitEcommerce.NoSuchPubSub)

      log =
        try do
          ExUnit.CaptureLog.capture_log(fn ->
            send(
              self(),
              {:rows, Batch.write_if_unchanged([row], ctx, "ecommerce.set_prices", planner)}
            )
          end)
        after
          if previous,
            do: Application.put_env(:phoenix_kit, :pubsub, previous),
            else: Application.delete_env(:phoenix_kit, :pubsub)
        end

      assert_received {:rows, [%{result: {:ok, _item}, error: nil}]}
      assert Decimal.equal?(F.reload!(item).base_price, Decimal.new("120.00"))
      assert log =~ "announcing the update failed: ArgumentError"
    end

    test "does not write a row another writer changed after the plan, and leaves its value",
         %{catalogue: catalogue, ctx: ctx} do
      changed = F.item!(catalogue)
      untouched = F.item!(catalogue)
      planner = price_planner(Decimal.new("120.00"))

      rows =
        Batch.load(
          [%{"ref" => %{"id" => changed.uuid}}, %{"ref" => %{"id" => untouched.uuid}}],
          catalogue.uuid
        )
        |> Batch.plan(planner)

      {:ok, _} = Catalogue.update_item(changed, %{base_price: Decimal.new("1000.00")})

      assert [failed, written] =
               Batch.write_if_unchanged(rows, ctx, "ecommerce.set_prices", planner)

      assert %{error: %{"code" => "validation_failed", "context" => %{"reason" => reason}}} =
               failed

      assert reason == "changed_since_planned"
      assert %{result: {:ok, _item}} = written
      assert Decimal.equal?(F.reload!(changed).base_price, Decimal.new("1000.00"))
      assert Decimal.equal?(F.reload!(untouched).base_price, Decimal.new("120.00"))
    end

    test "a plan that names what it read (guard) is compared on that, not on all of `from`",
         %{catalogue: catalogue, ctx: ctx} do
      item = F.item!(catalogue)
      base = price_planner(Decimal.new("120.00"))

      # `from` also carries something the plan does not depend on, which changes
      # between the plan and the write; the guard does not.
      planner = fn row ->
        {:ok, plan} = base.(row)

        {:ok,
         Map.merge(plan, %{
           from: %{price: row.item.base_price, noise: make_ref()},
           guard: %{price: row.item.base_price}
         })}
      end

      row = planned(catalogue, item, planner)

      assert [%{result: {:ok, _item}}] =
               Batch.write_if_unchanged([row], ctx, "ecommerce.set_prices", planner)

      assert Decimal.equal?(F.reload!(item).base_price, Decimal.new("120.00"))
    end

    test "a row whose product is gone fails with not_found", %{catalogue: catalogue, ctx: ctx} do
      item = F.item!(catalogue)
      planner = price_planner(Decimal.new("120.00"))
      row = planned(catalogue, item, planner)

      {:ok, _} = Catalogue.permanently_delete_item(item)

      assert [%{error: %{"code" => "not_found"}}] =
               Batch.write_if_unchanged([row], ctx, "ecommerce.set_prices", planner)
    end

    test "a row whose product was trashed or moved to another catalogue fails with not_found",
         %{catalogue: catalogue, ctx: ctx} do
      trashed = F.item!(catalogue)
      moved = F.item!(catalogue)
      planner = price_planner(Decimal.new("120.00"))

      rows =
        Batch.load(
          [%{"ref" => %{"id" => trashed.uuid}}, %{"ref" => %{"id" => moved.uuid}}],
          catalogue.uuid
        )
        |> Batch.plan(planner)

      {:ok, _} = Catalogue.trash_item(trashed)
      {:ok, _} = Catalogue.update_item(moved, %{catalogue_uuid: F.other_catalogue!().uuid})

      assert [%{error: %{"code" => "not_found"}}, %{error: %{"code" => "not_found"}}] =
               Batch.write_if_unchanged(rows, ctx, "ecommerce.set_prices", planner)

      assert Decimal.equal?(F.reload!(trashed).base_price, Decimal.new("100.00"))
      assert Decimal.equal?(F.reload!(moved).base_price, Decimal.new("100.00"))
    end

    test "a transaction that cannot commit fails the row to write and writes nothing",
         %{catalogue: catalogue, ctx: ctx} do
      repo = PhoenixKit.Config.get_repo()
      item = F.item!(catalogue)
      plain = price_planner(Decimal.new("120.00"))

      # Inside the lock's transaction a nested rollback (what a catalogue
      # write that fails its validation does) dooms the transaction around
      # it. The plan then differs, so nothing is written after the doom.
      doomed = fn row ->
        {:ok, plan} = plain.(row)

        if repo.in_transaction?() do
          repo.transaction(fn -> repo.rollback(:nested) end)
          {:ok, %{plan | from: %{price: :moved}}}
        else
          {:ok, plan}
        end
      end

      row = planned(catalogue, item, doomed)

      assert [%{error: error}] =
               Batch.write_if_unchanged([row], ctx, "ecommerce.set_prices", doomed)

      assert error["code"] == "validation_failed"
      assert error["context"]["reason"] == "database_error"
      assert Decimal.equal?(F.reload!(item).base_price, Decimal.new("100.00"))
    end

    defp drain_timeline(acc) do
      receive do
        {:transaction, _} = step ->
          drain_timeline([step | acc])

        {:catalogue_bulk_change, _catalogue, :updated, uuids, _from} ->
          drain_timeline([{:bulk, uuids} | acc])

        {:catalogue_data_changed, :item, nil, _catalogue} ->
          drain_timeline([:data_changed | acc])
      after
        0 -> acc
      end
    end

    test "writes nothing and opens no transaction when no row changes", %{ctx: ctx} do
      assert [] ==
               Batch.write_if_unchanged([], ctx, "ecommerce.set_prices", fn _ -> raise "no" end)
    end
  end
end
