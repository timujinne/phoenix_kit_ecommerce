defmodule PhoenixKitEcommerce.API.SetPricesTest do
  @moduledoc """
  `ecommerce.set_prices` against a real catalogue: the write, the rows that
  fail alone, the change log, the dry run and its fingerprint, and the
  danger check at its boundaries.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :catalogue_api
  @moduletag :core_confirm

  alias PhoenixKit.Settings
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce.API.{CatalogueWrites, PricePlan, SetPrices}
  alias PhoenixKitEcommerce.APICase
  alias PhoenixKitEcommerce.APIFixtures, as: F
  alias PhoenixKitEcommerce.StorefrontCache

  setup do
    catalogue = F.shop_catalogue!()
    user = F.user!()
    %{catalogue: catalogue, user: user, ctx: F.ctx(user)}
  end

  defp set_prices(items, ctx),
    do: APICase.call("ecommerce.set_prices", %{"items" => items}, ctx)

  # The handler without the schema in front of it: for the tests that pin the
  # planner's own second line of defence (a malformed price a client's schema
  # would already have refused).
  defp set_prices_raw(items, ctx), do: SetPrices.run(%{"items" => items}, ctx)

  defp ecommerce(item), do: F.reload!(item).data["ecommerce"]

  # The context of a call that ran under a confirmation code: core's executor
  # sets `confirmation_uuid` only then.
  defp confirmed(ctx), do: Map.put(ctx, :confirmation_uuid, Ecto.UUID.generate())

  defp dangerous?(item, price, ctx),
    do:
      SetPrices.dangerous?(
        %{"items" => [%{"ref" => %{"id" => item.uuid}, "price" => price}]},
        ctx
      )

  describe "the write" do
    test "sets price, compare_at and an option price in one call", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = F.item!(catalogue, %{sku: "SP-1"})
      F.attach_set!(item, "Liquid Color", "liquid_color", [{"Black", "black"}, {"Blue", "blue"}])

      row = %{
        "ref" => %{"sku" => "SP-1"},
        "price" => "110.00",
        "compare_at" => "150.00",
        "price_modifiers" => %{"liquid_color" => %{"black" => "32.00"}}
      }

      # a 32.00 option price on a 100.00 product is a dangerous change
      assert {:ok, %{"results" => [result], "summary" => %{"updated" => 1}}} =
               set_prices([row], confirmed(ctx))

      assert result["action"] == "updated"
      assert result["id"] == item.uuid
      assert result["changes"]["price"] == %{"from" => "100.00", "to" => "110.00"}
      assert result["ref"] == %{"sku" => "SP-1"}

      reloaded = F.reload!(item)
      assert Decimal.equal?(reloaded.base_price, Decimal.new("110.00"))
      assert reloaded.data["ecommerce"]["compare_at_price"] == "150.00"

      assert reloaded.data["ecommerce"]["price_modifiers"] == %{
               "liquid_color" => %{"black" => "32.00"}
             }
    end

    test "option prices of several products are checked against each product's own sets",
         %{catalogue: catalogue, ctx: ctx} do
      one = F.item!(catalogue)
      two = F.item!(catalogue)
      three = F.item!(catalogue)
      F.attach_set!(one, "Liquid Color", "liquid_color", [{"Black", "black"}])
      F.attach_set!(two, "Size", "size", [{"Large", "large"}])
      F.attach_set!(three, "Finish", "finish", [{"Matte", "matte"}])

      rows = [
        %{
          "ref" => %{"id" => one.uuid},
          "price_modifiers" => %{"liquid_color" => %{"black" => "3.00"}}
        },
        %{"ref" => %{"id" => two.uuid}, "price_modifiers" => %{"size" => %{"large" => "4.00"}}},
        %{
          "ref" => %{"id" => three.uuid},
          "price_modifiers" => %{"liquid_color" => %{"black" => "1.00"}}
        }
      ]

      assert {:ok, %{"results" => [first, second, third]}} = set_prices(rows, ctx)

      assert first["action"] == "updated"
      assert second["action"] == "updated"
      assert third["action"] == "error"

      assert [%{"path" => "price_modifiers.liquid_color", "allowed" => ["finish"]}] =
               third["error"]["context"]["errors"]

      assert ecommerce(one)["price_modifiers"] == %{"liquid_color" => %{"black" => "3.00"}}
      assert ecommerce(two)["price_modifiers"] == %{"size" => %{"large" => "4.00"}}
    end

    test "touches nothing it was not asked to: other shop fields, the Shopify sub-map, translations",
         %{catalogue: catalogue, ctx: ctx} do
      item =
        F.item!(catalogue, %{
          data: %{
            "_primary_language" => "en",
            "en" => %{"_name" => "Mug"},
            "ecommerce" => %{
              "shop_status" => "active",
              "tags" => ["a", "b"],
              "vendor" => "V",
              "shopify" => %{"product_id" => "9001", "handle" => "mug"}
            }
          }
        })

      assert {:ok, _} =
               set_prices([%{"ref" => %{"id" => item.uuid}, "compare_at" => "20.00"}], ctx)

      reloaded = F.reload!(item)
      assert reloaded.data["ecommerce"]["tags"] == ["a", "b"]
      assert reloaded.data["ecommerce"]["vendor"] == "V"
      assert reloaded.data["ecommerce"]["shop_status"] == "active"
      assert reloaded.data["ecommerce"]["shopify"] == %{"product_id" => "9001", "handle" => "mug"}
      assert reloaded.data["en"] == %{"_name" => "Mug"}
      assert reloaded.data["ecommerce"]["compare_at_price"] == "20.00"
    end

    test "null clears compare_at and removes one option price", %{catalogue: catalogue, ctx: ctx} do
      item =
        F.item!(catalogue, %{
          data: %{
            "_primary_language" => "en",
            "ecommerce" => %{
              "shop_status" => "active",
              "compare_at_price" => "30.00",
              "price_modifiers" => %{"c" => %{"x" => "1.00", "y" => "2.00"}}
            }
          }
        })

      F.attach_set!(item, "Option C", "c", [{"X", "x"}, {"Y", "y"}])

      row = %{
        "ref" => %{"id" => item.uuid},
        "compare_at" => nil,
        "price_modifiers" => %{"c" => %{"x" => nil}}
      }

      assert {:ok, %{"summary" => %{"updated" => 1}}} = set_prices([row], confirmed(ctx))

      assert ecommerce(item)["compare_at_price"] == nil
      assert ecommerce(item)["price_modifiers"] == %{"c" => %{"y" => "2.00"}}
    end

    test "an unchanged row writes nothing and logs nothing", %{catalogue: catalogue, ctx: ctx} do
      item = F.item!(catalogue)
      before = F.reload!(item)

      assert {:ok, %{"results" => [%{"action" => "unchanged"}], "summary" => %{"unchanged" => 1}}} =
               set_prices([%{"ref" => %{"id" => item.uuid}, "price" => "100.00"}], ctx)

      assert F.reload!(item).updated_at == before.updated_at
      refute_activity_logged("item.updated", resource_uuid: item.uuid)
    end
  end

  describe "a shop with no base currency" do
    setup do
      PhoenixKit.Cache.clear(:billing_currencies)
      Repo.delete_all(PhoenixKitBilling.Currency)
      :ok
    end

    # An amount stored with no currency is read as whatever the base later
    # becomes, which is the rule the Shopify sync keeps.
    test "refuses a price for a product that names no currency either", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = F.item!(catalogue, %{sku: "SP-NOCUR"})

      assert {:ok, %{"results" => [%{"error" => error}], "summary" => %{"error" => 1}}} =
               set_prices([%{"ref" => %{"sku" => "SP-NOCUR"}, "price" => "101.00"}], ctx)

      assert error["code"] == "validation_failed"
      assert Decimal.equal?(F.reload!(item).base_price, Decimal.new("100.00"))
    end

    test "prices a product that carries its own currency", %{catalogue: catalogue, ctx: ctx} do
      item =
        F.item!(catalogue, %{
          sku: "SP-OWNCUR",
          data: %{
            "_primary_language" => "en",
            "ecommerce" => %{"shop_status" => "active", "currency" => "USD"}
          }
        })

      assert {:ok, %{"summary" => %{"updated" => 1}}} =
               set_prices([%{"ref" => %{"sku" => "SP-OWNCUR"}, "price" => "101.00"}], ctx)

      assert Decimal.equal?(F.reload!(item).base_price, Decimal.new("101.00"))
    end
  end

  describe "rows are independent" do
    test "a missing product, an ambiguous sku, a duplicate and a bad price do not stop the good row",
         %{catalogue: catalogue, ctx: ctx} do
      good = F.item!(catalogue, %{sku: "SP-GOOD"})
      F.item!(catalogue, %{sku: "SP-TWICE"})
      F.item!(catalogue, %{sku: "SP-TWICE"})
      priced = F.item!(catalogue, %{sku: "SP-BADPRICE"})

      rows = [
        %{"ref" => %{"sku" => "SP-MISSING"}, "price" => "5.00"},
        %{"ref" => %{"sku" => "SP-TWICE"}, "price" => "5.00"},
        %{"ref" => %{"sku" => "SP-GOOD"}, "price" => "105.00"},
        %{"ref" => %{"id" => good.uuid}, "price" => "106.00"},
        %{"ref" => %{"sku" => "SP-BADPRICE"}, "price" => "12,5"}
      ]

      # `"12,5"` is refused by the schema in production (the executor's 422, pinned
      # in `tools_test.exs` and `executor_test.exs`); this is the planner's own
      # second line of defence, reached directly.
      assert {:ok, %{"results" => results, "summary" => summary}} = set_prices_raw(rows, ctx)

      assert Enum.map(results, & &1["action"]) == ["error", "error", "updated", "error", "error"]

      assert Enum.map(results, &(&1["error"] && &1["error"]["code"])) ==
               ["not_found", "ambiguous_ref", nil, "duplicate_line", "validation_failed"]

      assert summary == %{"error" => 4, "unchanged" => 0, "updated" => 1}
      assert Decimal.equal?(F.reload!(good).base_price, Decimal.new("105.00"))
      assert Decimal.equal?(F.reload!(priced).base_price, Decimal.new("100.00"))
    end

    test "an unknown option and an unknown value fail their rows with the allowed names",
         %{catalogue: catalogue, ctx: ctx} do
      with_set = F.item!(catalogue)
      F.attach_set!(with_set, "Liquid Color", "liquid_color", [{"Black", "black"}])
      other = F.item!(catalogue)

      rows = [
        %{"ref" => %{"id" => with_set.uuid}, "price_modifiers" => %{"size" => %{"l" => "3.00"}}},
        %{
          "ref" => %{"id" => other.uuid},
          "price_modifiers" => %{"liquid_color" => %{"green" => "3.00"}}
        }
      ]

      assert {:ok, %{"results" => [first, second]}} = set_prices(rows, ctx)

      assert first["error"]["code"] == "validation_failed"

      assert [%{"path" => "price_modifiers.size", "allowed" => ["liquid_color"]}] =
               first["error"]["context"]["errors"]

      # the second item has no option sets at all, so every option is unknown to it
      assert second["error"]["code"] == "validation_failed"

      assert [%{"path" => "price_modifiers.liquid_color", "allowed" => []}] =
               second["error"]["context"]["errors"]
    end
  end

  describe "concurrent writes" do
    test "a plan made before another writer stored a different option price keeps that price",
         %{catalogue: catalogue, ctx: ctx} do
      item = F.item!(catalogue)
      F.attach_set!(item, "Liquid Color", "liquid_color", [{"Black", "black"}])
      F.attach_set!(item, "Size", "size", [{"Large", "large"}])
      stale = F.reload!(item)

      # the plan is made from the item as it was ...
      row = %{"price_modifiers" => %{"size" => %{"large" => "4.00"}}}
      assert {:ok, plan} = PricePlan.plan(row, stale, pct: 30, sets: nil)
      assert plan.owned_paths == [["ecommerce", "price_modifiers", "size", "large"]]

      # ... another API call stores a different option before it is written ...
      other = %{"liquid_color" => %{"black" => "3.00"}}

      assert {:ok, %{"summary" => %{"updated" => 1}}} =
               set_prices([%{"ref" => %{"id" => item.uuid}, "price_modifiers" => other}], ctx)

      # ... and the stale plan is written afterwards
      paths = plan.owned_paths
      entry = {stale, plan.attrs, data_owned_paths: paths, logged_data_paths: paths}
      opts = [actor_uuid: ctx.actor.user_uuid, mode: "auto"]
      assert [{:ok, _}] = CatalogueWrites.update_rows([entry], opts)

      assert ecommerce(item)["price_modifiers"] == %{
               "liquid_color" => %{"black" => "3.00"},
               "size" => %{"large" => "4.00"}
             }
    end
  end

  describe "a price that moves between the danger check and the plan" do
    test "an unconfirmed call is not written once its plan has become dangerous", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = F.item!(catalogue)
      row = %{"ref" => %{"id" => item.uuid}, "price" => "101.00"}

      # The danger check reads 100.00 and sees a 1 percent move ...
      refute SetPrices.dangerous?(%{"items" => [row]}, ctx)

      # ... then an editor sets the price to 1000.00 before the call is planned.
      {:ok, _} = Catalogue.update_item(item, %{base_price: Decimal.new("1000.00")})

      assert {:error, :validation_failed, _message, %{errors: [%{path: "items"}]}} =
               set_prices([row], ctx)

      assert Decimal.equal?(F.reload!(item).base_price, Decimal.new("1000.00"))
    end

    test "the same call under a confirmation code is written", %{catalogue: catalogue, ctx: ctx} do
      item = F.item!(catalogue)
      {:ok, _} = Catalogue.update_item(item, %{base_price: Decimal.new("1000.00")})

      assert {:ok, %{"summary" => %{"updated" => 1}}} =
               set_prices([%{"ref" => %{"id" => item.uuid}, "price" => "101.00"}], confirmed(ctx))

      assert Decimal.equal?(F.reload!(item).base_price, Decimal.new("101.00"))
    end
  end

  describe "the change log" do
    test "names the key's owner, the API, the tool and the key prefix", %{
      catalogue: catalogue,
      user: user,
      ctx: ctx
    } do
      item = F.item!(catalogue)

      assert {:ok, _} = set_prices([%{"ref" => %{"id" => item.uuid}, "price" => "101.00"}], ctx)

      assert_activity_logged("item.updated",
        resource_uuid: item.uuid,
        actor_uuid: user.uuid,
        metadata_has: %{
          "via" => "api",
          "tool" => "ecommerce.set_prices",
          "key_prefix" => "a1b2c3d4",
          "request_id" => "req-test"
        }
      )
    end

    test "an approved call names who approved it", %{catalogue: catalogue, ctx: ctx} do
      item = F.item!(catalogue)
      approver = Ecto.UUID.generate()

      assert {:ok, _} =
               set_prices(
                 [%{"ref" => %{"id" => item.uuid}, "price" => "101.00"}],
                 Map.put(ctx, :approved_by_uuid, approver)
               )

      assert_activity_logged("item.updated",
        resource_uuid: item.uuid,
        metadata_has: %{"approved_by_uuid" => approver}
      )
    end
  end

  describe "dry run" do
    test "returns a preview and a fingerprint and writes nothing", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = F.item!(catalogue, %{sku: "SP-DRY"})
      logged = length(list_activities())

      rows = [
        %{"ref" => %{"sku" => "SP-DRY"}, "price" => "150.00"},
        %{"ref" => %{"sku" => "SP-NONE"}, "price" => "1.00"}
      ]

      assert {:preview, preview, fingerprint} = set_prices(rows, %{ctx | dry_run?: true})

      assert fingerprint =~ ~r/\A[0-9a-f]{64}\z/
      assert preview["totals"]["update"] == 1
      assert preview["totals"]["error"] == 1
      assert preview["totals"]["largest_price_change_pct"] == "50.0"

      assert [
               %{"action" => "update", "changes" => %{"price" => %{"to" => "150.00"}}},
               %{"action" => "error"}
             ] = preview["rows"]

      assert Decimal.equal?(F.reload!(item).base_price, Decimal.new("100.00"))
      refute_activity_logged("item.updated", resource_uuid: item.uuid)
      assert length(list_activities()) == logged
    end

    test "says whether the real call would be held, with the thresholds that applied", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = F.item!(catalogue)
      dry = %{ctx | dry_run?: true}

      preview = fn price ->
        {:preview, preview, _} =
          set_prices([%{"ref" => %{"id" => item.uuid}, "price" => price}], dry)

        preview
      end

      assert %{"requires_confirmation" => false} = preview.("110.00")
      assert %{"requires_confirmation" => true} = preview.("0")
      assert %{"requires_confirmation" => true} = preview.("1000.00")
      assert %{"requires_confirmation" => true} = preview.("69.99")

      assert preview.("110.00")["confirmation_rules"] == %{
               "max_price_change_pct" => 30,
               "confirm_batch_over" => 50
             }
    end

    test "the preview agrees with the danger check of the tool for every row it holds", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      small = F.item!(catalogue)
      big = F.item!(catalogue)
      dry = %{ctx | dry_run?: true}

      for rows <- [
            [%{"ref" => %{"id" => small.uuid}, "price" => "101.00"}],
            [
              %{"ref" => %{"id" => small.uuid}, "price" => "101.00"},
              %{"ref" => %{"id" => big.uuid}, "price" => "500.00"}
            ]
          ] do
        input = %{"items" => rows}
        assert {:preview, preview, _} = set_prices(rows, dry)
        assert preview["requires_confirmation"] == SetPrices.dangerous?(input, ctx)
      end
    end

    test "a batch over core's row threshold is held whatever the prices do", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      previous = Settings.get_setting("api_confirm_batch_over")
      {:ok, _} = Settings.update_setting("api_confirm_batch_over", "2")
      on_exit(fn -> Settings.update_setting("api_confirm_batch_over", previous || "50") end)

      rows =
        for _ <- 1..3, do: %{"ref" => %{"id" => F.item!(catalogue).uuid}, "price" => "101.00"}

      assert {:preview, preview, _} = set_prices(rows, %{ctx | dry_run?: true})
      assert preview["requires_confirmation"] == true
      assert preview["confirmation_rules"]["confirm_batch_over"] == 2

      assert {:preview, two, _} = set_prices(Enum.take(rows, 2), %{ctx | dry_run?: true})
      assert two["requires_confirmation"] == false
    end

    test "the fingerprint moves when a value the call reads changes in between", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = F.item!(catalogue)
      dry = %{ctx | dry_run?: true}
      rows = [%{"ref" => %{"id" => item.uuid}, "price" => "150.00"}]

      assert {:preview, _, before} = set_prices(rows, dry)
      assert {:preview, _, same} = set_prices(rows, dry)
      assert before == same

      assert {:ok, _} = set_prices([%{"ref" => %{"id" => item.uuid}, "price" => "101.00"}], ctx)

      assert {:preview, _, after_change} = set_prices(rows, dry)
      refute before == after_change
    end
  end

  describe "dangerous?/2" do
    test "exactly the threshold is not dangerous, one cent past it is", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = F.item!(catalogue)

      refute dangerous?(item, "130.00", ctx)
      assert dangerous?(item, "130.01", ctx)
      refute dangerous?(item, "70.00", ctx)
      assert dangerous?(item, "69.99", ctx)
    end

    test "the threshold is the stored setting, and a garbage setting falls back to 30", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = F.item!(catalogue)

      Settings.update_setting_with_module("api_confirm_price_change_pct", "5", "shop")
      assert dangerous?(item, "106.00", ctx)

      Settings.update_setting_with_module("api_confirm_price_change_pct", "lots", "shop")
      refute dangerous?(item, "130.00", ctx)
      assert dangerous?(item, "130.01", ctx)
    end

    test "a first price is never held back", %{catalogue: catalogue, ctx: ctx} do
      for current <- [nil, Decimal.new("0.00")] do
        item = F.item!(catalogue, %{base_price: current})
        refute dangerous?(item, "9999.00", ctx)
      end
    end

    test "a price of zero is held, a first price included", %{catalogue: catalogue, ctx: ctx} do
      for current <- [nil, Decimal.new("0.00"), Decimal.new("20.00")] do
        item = F.item!(catalogue, %{base_price: current})

        assert dangerous?(item, "0.00", ctx) == (current != Decimal.new("0.00"))
      end
    end

    test "a new option price is held by the size of the move against the product's price", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = F.item!(catalogue)
      F.attach_set!(item, "Size", "size", [{"XL", "xl"}])

      modifier = fn amount ->
        SetPrices.dangerous?(
          %{
            "items" => [
              %{
                "ref" => %{"id" => item.uuid},
                "price_modifiers" => %{"size" => %{"xl" => amount}}
              }
            ]
          },
          ctx
        )
      end

      assert modifier.("-99.00")
      assert modifier.("9999999999.00")
      refute modifier.("30.00")
      assert modifier.("30.01")
    end

    test "the size of the batch is core's rule, not this tool's", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      items = for _ <- 1..3, do: F.item!(catalogue)
      rows = Enum.map(items, &%{"ref" => %{"id" => &1.uuid}, "price" => "101.00"})

      Settings.update_setting_with_module("api_confirm_batch_over", "2", "api")
      refute SetPrices.dangerous?(%{"items" => rows}, ctx)
    end

    test "a refusal is not dangerous: the handler answers it itself", %{ctx: ctx} do
      F.put_config!("shop_product_source", "legacy")

      refute SetPrices.dangerous?(
               %{"items" => [%{"ref" => %{"sku" => "X"}, "price" => "1.00"}]},
               ctx
             )
    end
  end

  describe "warnings" do
    test "the Shopify warning only for a linked product, only while the sync is on", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      shopify = PhoenixKitEcommerce.shopify_enabled?()

      on_exit(fn ->
        Settings.update_boolean_setting_with_module("shop_shopify_enabled", shopify, "shop")
      end)

      linked =
        F.item!(catalogue, %{
          data: %{
            "_primary_language" => "en",
            "ecommerce" => %{"shop_status" => "active", "shopify" => %{"product_id" => "7"}}
          }
        })

      by_handle =
        F.item!(catalogue, %{
          data: %{
            "_primary_language" => "en",
            "ecommerce" => %{"shop_status" => "active", "shopify" => %{"handle" => "mug"}}
          }
        })

      plain = F.item!(catalogue)

      Settings.update_boolean_setting_with_module("shop_shopify_enabled", true, "shop")

      assert {:ok, %{"results" => [a, b, h]}} =
               set_prices(
                 [
                   %{"ref" => %{"id" => linked.uuid}, "price" => "101.00"},
                   %{"ref" => %{"id" => plain.uuid}, "price" => "101.00"},
                   %{"ref" => %{"id" => by_handle.uuid}, "price" => "101.00"}
                 ],
                 ctx
               )

      assert a["warnings"] == ["shopify_sync_may_overwrite"]
      assert b["warnings"] == []
      assert h["warnings"] == ["shopify_sync_may_overwrite"]

      Settings.update_boolean_setting_with_module("shop_shopify_enabled", false, "shop")

      assert {:ok, %{"results" => [c]}} =
               set_prices([%{"ref" => %{"id" => linked.uuid}, "price" => "102.00"}], ctx)

      assert c["warnings"] == []
    end
  end

  describe "the storefront cache" do
    setup do
      start_supervised!(PhoenixKit.Cache.Registry)
      [spec] = StorefrontCache.children()
      start_supervised!(spec)
      :ok
    end

    test "a write clears it; a dry run and an unchanged row leave it", %{
      catalogue: catalogue,
      ctx: ctx
    } do
      item = F.item!(catalogue)
      row = %{"ref" => %{"id" => item.uuid}, "price" => "101.00"}

      :stale = StorefrontCache.fetch(:probe, fn -> :stale end)

      assert {:preview, _preview, _fingerprint} = set_prices([row], %{ctx | dry_run?: true})
      assert StorefrontCache.fetch(:probe, fn -> :fresh end) == :stale

      assert {:ok, %{"summary" => %{"updated" => 1}}} = set_prices([row], ctx)
      assert StorefrontCache.fetch(:probe, fn -> :fresh end) == :fresh

      StorefrontCache.clear()
      :stale = StorefrontCache.fetch(:probe, fn -> :stale end)
      assert {:ok, %{"summary" => %{"unchanged" => 1}}} = set_prices([row], ctx)
      assert StorefrontCache.fetch(:probe, fn -> :fresh end) == :stale
    end
  end

  test "the legacy source is refused and nothing is written", %{catalogue: catalogue, ctx: ctx} do
    item = F.item!(catalogue)
    F.put_config!("shop_product_source", "legacy")

    assert {:error, :unsupported_source, _detail, %{reason: "legacy_source"}} =
             set_prices([%{"ref" => %{"id" => item.uuid}, "price" => "5.00"}], ctx)

    assert Decimal.equal?(F.reload!(item).base_price, Decimal.new("100.00"))
  end
end
