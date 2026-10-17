defmodule PhoenixKitEcommerce.API.CartWriterTest do
  @moduledoc """
  `shop.set_cart_items` at the writer level (the handler and the executor are
  tested apart): final quantities, per-line errors that do not stop the other lines,
  revisions, the currency lock, dry runs, effects, and the one signal per call.
  """

  # async: false - settings and the Hammer counters are shared.
  use PhoenixKitEcommerce.DataCase, async: false
  @moduletag :requires_core_api

  import ExUnit.CaptureLog
  import PhoenixKitEcommerce.CartApiFixtures

  alias PhoenixKit.Cache
  alias PhoenixKit.Settings
  alias PhoenixKitBilling.Currency
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.API.CartStore
  alias PhoenixKitEcommerce.API.CartToken
  alias PhoenixKitEcommerce.API.CartView
  alias PhoenixKitEcommerce.API.CartWriter
  alias PhoenixKitEcommerce.Cart
  alias PhoenixKitEcommerce.CartClaim
  alias PhoenixKitEcommerce.CartItem

  setup do
    put_secret!()
    ensure_currencies!()
    token = new_token!()
    {:ok, hash} = CartToken.verify(token)
    %{token: token, hash: hash, p1: product!(), p2: product!(), p3: product!()}
  end

  defp line(product, quantity, options \\ []),
    do: %{"product_id" => product.uuid, "quantity" => quantity, "options" => options}

  defp opt(key, value), do: %{"attribute_key" => key, "value_key" => value}

  defp set(token, items, opts \\ []) do
    {:ok, hash} = CartToken.verify(token)
    input = Map.merge(%{"items" => items}, Keyword.get(opts, :extra, %{}))
    ctx = Keyword.get_lazy(opts, :ctx, fn -> ctx_for(token) end)
    CartWriter.set_items(hash, input, ctx)
  end

  defp actions(result), do: Enum.map(result.results, & &1.action)
  defp error_codes(result), do: Enum.map(result.results, &get_in(&1, [:error, :code]))

  defp cart_of(hash) do
    {:ok, cart} = CartStore.resolve(hash)
    cart
  end

  defp cart_lines(token) do
    {:ok, hash} = CartToken.verify(token)
    CartView.build(cart_of(hash)).lines
  end

  defp toggles(first, every) do
    {:ok, _} =
      Settings.update_setting_with_module("shop_notify_cart_first_item", to_string(first), "shop")

    {:ok, _} =
      Settings.update_setting_with_module("shop_notify_cart_item", to_string(every), "shop")
  end

  describe "the first write" do
    test "creates the cart lazily and reports what it did", %{token: token, hash: hash, p1: p1} do
      assert CartStore.resolve(hash) == :empty

      assert {:ok, result} = set(token, [line(p1, 2)])

      assert [%{index: 0, action: "created", id: id, quantity: 2}] = result.results
      assert id == p1.uuid
      assert result.summary == %{"created" => 1}
      assert [%{quantity: 2, status: "ok"}] = result.cart.lines
      assert result.cart.currency == "USD"
      assert result.revision == result.cart.revision
      assert result.before.total == %{amount: "0.00", currency: "USD"}
      assert result.after.subtotal == %{amount: "20.00", currency: "USD"}
      assert [%{product_id: ^id, from: nil, to: 2}] = result.changes.added
      assert %Cart{session_id: "api:" <> _} = cart_of(hash)
    end

    test "only invalid lines create nothing", %{token: token, hash: hash} do
      assert {:ok, result} = set(token, [%{"product_id" => "nope", "quantity" => 1}])

      assert actions(result) == ["error"]
      assert result.summary == %{"error" => 1}
      assert result.cart.lines == []
      assert CartStore.resolve(hash) == :empty
    end

    test "removal lines on a token without a cart are unchanged and create nothing", %{
      token: token,
      hash: hash,
      p1: p1
    } do
      assert {:ok, result} = set(token, [line(p1, 0)])

      assert actions(result) == ["unchanged"]
      assert CartStore.resolve(hash) == :empty
    end

    test "a removal-only request reads the cart under its row lock, not as it first found it", %{
      token: token,
      hash: hash,
      p1: p1,
      p2: p2
    } do
      {:ok, cart} = Shop.create_cart(session_id: CartToken.session_id(hash))

      # another writer adds a line after this request found the cart and before it locked it
      after_first_query("SELECT", "phoenix_kit_shop_cart_items", fn ->
        {:ok, _} = Shop.add_to_cart(cart, p2, 1)
      end)

      assert {:ok, result} = set(token, [line(p1, 0)])

      assert actions(result) == ["unchanged"]
      assert result.before.total == %{amount: "10.00", currency: "USD"}
      assert result.after.total == result.before.total
    end
  end

  describe "final quantities" do
    test "set the quantity, they do not add to it", %{token: token, p1: p1} do
      assert {:ok, r1} = set(token, [line(p1, 2)])
      assert actions(r1) == ["created"]

      assert {:ok, r2} = set(token, [line(p1, 5)])
      assert actions(r2) == ["updated"]
      assert [%{quantity: 5}] = r2.cart.lines
      assert [%{from: 2, to: 5}] = r2.changes.changed

      assert {:ok, r3} = set(token, [line(p1, 5)])
      assert actions(r3) == ["unchanged"]
      assert r3.revision == r2.revision
    end

    test "zero removes the line, and removing what is not there changes nothing", %{
      token: token,
      p1: p1,
      p2: p2
    } do
      {:ok, _} = set(token, [line(p1, 2), line(p2, 1)])

      assert {:ok, removed} = set(token, [line(p1, 0), line(p3 = product!(), 0)])
      assert actions(removed) == ["removed", "unchanged"]
      assert [%{product_id: id}] = removed.cart.lines
      assert id == p2.uuid
      refute p3.uuid == id
    end

    test "lines are applied in product-uuid order, whatever order the request lists them", %{
      token: token
    } do
      # Two writers that name the same Legacy products in opposite orders would lock
      # the product rows crosswise; one fixed order is what keeps them from deadlocking.
      products = for(_ <- 1..5, do: product!()) |> Enum.sort_by(& &1.uuid)
      sorted_ids = Enum.map(products, & &1.uuid)

      applied =
        inserted_item_products(products, fn ->
          assert {:ok, _} = set(token, products |> Enum.reverse() |> Enum.map(&line(&1, 1)))
        end)

      assert applied == sorted_ids
    end

    test "results come back in request order, however the lines are applied", %{token: token} do
      # lines are applied in product-uuid order; the answer must not show it
      lines = for _ <- 1..4, do: line(product!(), 1)

      assert {:ok, result} = set(token, Enum.reverse(lines))

      assert Enum.map(result.results, & &1.index) == [0, 1, 2, 3]

      assert Enum.map(result.results, & &1.id) ==
               lines |> Enum.reverse() |> Enum.map(& &1["product_id"])
    end

    test "lines the request does not name are left alone", %{token: token, p1: p1, p2: p2} do
      {:ok, _} = set(token, [line(p1, 1), line(p2, 1)])

      assert {:ok, result} = set(token, [line(p1, 3)])

      assert Enum.sort(Enum.map(result.cart.lines, & &1.quantity)) == [1, 3]
    end

    test "an existing line keeps its price, and the write says when the product's price moved", %{
      token: token,
      p1: p1
    } do
      {:ok, _} = set(token, [line(p1, 1)])
      {:ok, _} = Shop.update_product(p1, %{"price" => Decimal.new("12.00")})

      assert {:ok, result} = set(token, [line(p1, 2)])

      assert [%{unit_price: %{amount: "10.00"}, quantity: 2}] = result.cart.lines

      assert [%{code: "line_price_changed", kept_unit_price: %{amount: "10.00"}} = effect] =
               result.effects

      assert effect.current_base_price == %{amount: "12.00", currency: "USD"}
    end

    test "reports a selected shipping method that the new subtotal rules out", %{
      token: token,
      hash: hash
    } do
      product = physical_product!(%{"price" => Decimal.new("10.00")})
      {:ok, _} = set(token, [line(product, 1)])

      {:ok, method} =
        Shop.create_shipping_method(%{
          "name" => "Small parcels",
          "price" => Decimal.new("4.00"),
          "active" => true,
          "max_order_amount" => Decimal.new("15.00")
        })

      {:ok, _} = Shop.set_cart_shipping(cart_of(hash), method, "DE")

      assert {:ok, result} = set(token, [line(product, 3)])

      assert [%{code: "shipping_method_unavailable", method: id}] = result.effects
      assert id == method.uuid
    end
  end

  describe "current_base_price/2" do
    test "reads the line's neutral options, so a call in another language prices the same variant" do
      product =
        product!(%{
          "metadata" => %{
            "_option_values" => %{"size" => ["S", "L"]},
            "_price_modifiers" => %{"size" => %{"L" => "10.00"}}
          }
        })

      # the label the line was stored with, in the language it was added in
      item = %CartItem{
        selected_specs: %{"size" => "Gross"},
        metadata: %{"api_options" => [%{"attribute_key" => "size", "value_key" => "l"}]}
      }

      assert Decimal.equal?(CartWriter.current_base_price(item, product), Decimal.new("20.00"))

      # the stored label alone finds no modifier: that is the false line_price_changed it prevents
      assert Decimal.equal?(
               Shop.calculate_product_price(product, item.selected_specs),
               Decimal.new("10.00")
             )
    end
  end

  describe "lines that cannot be applied" do
    test "each bad line is its own error and the good lines still apply", %{token: token, p1: p1} do
      archived = product!()
      {:ok, _} = Shop.update_product(archived, %{"status" => "archived"})
      draft = product!(%{"status" => "draft"})

      bad_quantities =
        for quantity <- ["3", -1, 100, 2.5, 3.0, nil, true], do: line(product!(), quantity)

      items =
        [line(p1, 1)] ++
          bad_quantities ++
          [
            %{"product_id" => product!().uuid},
            %{"product_id" => "not-a-uuid", "quantity" => 1},
            %{"product_id" => Ecto.UUID.generate(), "quantity" => 1},
            line(draft, 1),
            line(archived, 1)
          ]

      assert {:ok, result} = set(token, items)

      assert error_codes(result) ==
               [nil] ++
                 List.duplicate("quantity_invalid", 8) ++
                 ["not_found", "not_found", "not_found", "not_on_sale"]

      assert hd(result.results).action == "created"
      assert [%{quantity: 1}] = result.cart.lines

      quantity_error = Enum.at(result.results, 1).error
      assert quantity_error.allowed == %{min: 0, max: 99}
      assert Enum.at(result.results, 1).ref.product_id == Enum.at(items, 1)["product_id"]
    end

    test "a cart holds at most 50 different lines: more are refused one by one, removals make room",
         %{
           token: token
         } do
      # `extra` has the smallest uuid, so only the removals-first order of the writer
      # (not the uuid order) makes room for it in a request that also removes a line.
      [extra | first_fifty] = for(_ <- 1..51, do: product!()) |> Enum.sort_by(& &1.uuid)
      assert {:ok, filled} = set(token, Enum.map(first_fifty, &line(&1, 1)))
      assert length(filled.cart.lines) == 50

      assert {:ok, over} = set(token, [line(extra, 1)])

      assert [
               %{
                 action: "error",
                 error: %{
                   code: "validation_failed",
                   reason: "cart_lines_limit",
                   allowed: %{max: 50}
                 }
               }
             ] =
               over.results

      assert length(over.cart.lines) == 50

      # an existing line can still change, and a removal in the same request makes room
      assert {:ok, room} =
               set(token, [
                 line(hd(first_fifty), 5),
                 line(extra, 1),
                 line(List.last(first_fifty), 0)
               ])

      assert Enum.sort(actions(room)) == ["created", "removed", "updated"]
      assert length(room.cart.lines) == 50
    end

    test "the boundaries 1 and 99 are accepted", %{token: token, p1: p1, p2: p2} do
      assert {:ok, result} = set(token, [line(p1, 1), line(p2, 99)])

      assert actions(result) == ["created", "created"]
    end

    test "the same product and options twice refuses both occurrences, not the rest", %{
      token: token,
      p1: p1,
      p2: p2
    } do
      assert {:ok, result} = set(token, [line(p1, 1), line(p2, 2), line(p1, 3)])

      assert actions(result) == ["error", "created", "error"]
      assert error_codes(result) == ["duplicate_line", nil, "duplicate_line"]
      assert [%{quantity: 2}] = result.cart.lines
    end

    test "malformed options are a line error", %{token: token, p1: p1} do
      bad = line(p1, 1, [%{"attribute_key" => "", "value_key" => "x"}])

      assert {:ok, result} = set(token, [bad])

      assert error_codes(result) == ["option_invalid"]
    end

    test "a refusal that planning cannot see is that line's error, and the good lines still apply",
         %{
           token: token,
           p1: p1,
           p2: p2
         } do
      # With this setting add_to_cart refuses a product priced in a known foreign currency
      # (deterministic, before its own transaction): the line fails for good, the batch does not
      # become a retryable state_changed.
      put_setting!("shop_enforce_product_currency", true)
      foreign = product!(%{"currency" => "EUR"})

      assert {:ok, result} = set(token, [line(p1, 1), line(foreign, 1), line(p2, 2)])

      assert actions(result) == ["created", "error", "created"]

      assert [
               %{
                 error: %{
                   code: "not_on_sale",
                   reason: "currency_mismatch",
                   message: "This product cannot be sold in this cart."
                 }
               }
             ] = Enum.filter(result.results, &(&1.action == "error"))

      assert Enum.sort(Enum.map(result.cart.lines, & &1.quantity)) == [1, 2]
    end

    test "a product id that is not a UUID is an error, also when the quantity is 0", %{
      token: token
    } do
      assert {:ok, result} =
               set(token, [
                 %{"product_id" => "not-a-uuid", "quantity" => 0},
                 %{"product_id" => 42, "quantity" => 0},
                 %{"product_id" => nil, "quantity" => 1}
               ])

      assert error_codes(result) == ["not_found", "not_found", "not_found"]
      assert Enum.at(result.results, 0).ref.product_id == "not-a-uuid"
    end

    test "a line that is not an object is a line error, not a crash", %{token: token, p1: p1} do
      assert {:ok, result} = set(token, ["nope", 7, line(p1, 1)])

      assert actions(result) == ["error", "error", "created"]
      assert error_codes(result) == ["not_found", "not_found", nil]
    end

    test "a product id in upper case is the same product as in lower case", %{
      token: token,
      p1: p1
    } do
      upper = String.upcase(p1.uuid)

      assert {:ok, first} = set(token, [%{"product_id" => upper, "quantity" => 2}])
      assert [%{action: "created", id: id, ref: %{product_id: ^upper}}] = first.results
      assert id == p1.uuid

      # found again by either spelling: the quantity is set, never added up
      assert {:ok, second} = set(token, [line(p1, 5)])
      assert actions(second) == ["updated"]
      assert [%{quantity: 5}] = second.cart.lines

      assert {:ok, third} = set(token, [%{"product_id" => upper, "quantity" => 7}])
      assert actions(third) == ["updated"]
      assert [%{quantity: 7}] = third.cart.lines
    end

    test "both spellings of one product in one request are a duplicate", %{token: token, p1: p1} do
      assert {:ok, result} =
               set(token, [
                 line(p1, 1),
                 %{"product_id" => String.upcase(p1.uuid), "quantity" => 2}
               ])

      assert error_codes(result) == ["duplicate_line", "duplicate_line"]
    end
  end

  describe "options from the product's category" do
    test "a required option of the category schema is enforced and mapped", %{token: token} do
      n = System.unique_integer([:positive])

      {:ok, category} =
        Shop.create_category(%{
          "name" => %{"en" => "Pots #{n}"},
          "slug" => %{"en" => "pots-#{n}"},
          "option_schema" => [
            %{
              "key" => "size",
              "label" => "Size",
              "type" => "select",
              "options" => ["S", "L"],
              "required" => true,
              "position" => 0
            }
          ]
        })

      pot = product!(%{"category_uuid" => category.uuid})

      assert {:ok, missing} = set(token, [line(pot, 1)])

      assert [%{error: %{code: "option_required", attribute_key: "size", allowed: ["s", "l"]}}] =
               missing.results

      assert {:ok, result} = set(token, [line(pot, 2, [opt("size", "l")])])
      assert [%{action: "created"}] = result.results
      assert [%{options: [%{attribute_key: "size", value_key: "l"}]}] = result.cart.lines
    end
  end

  describe "options" do
    setup do
      %{shirt: product_with_options!(%{"color" => ["Red", "Blue"]})}
    end

    test "a missing required option names the attribute and the allowed values", %{
      token: token,
      shirt: shirt
    } do
      assert {:ok, result} = set(token, [line(shirt, 1)])

      assert [%{action: "error", error: error}] = result.results
      assert error.code == "option_required"
      assert error.attribute_key == "color"
      assert error.allowed == ["red", "blue"]
    end

    test "a value that is not offered is refused with the list that is", %{
      token: token,
      shirt: shirt
    } do
      assert {:ok, result} = set(token, [line(shirt, 1, [opt("color", "green")])])

      assert [%{error: %{code: "option_invalid", allowed: ["red", "blue"]}}] = result.results
    end

    test "different option values are different lines, found again by their options", %{
      token: token,
      hash: hash,
      shirt: shirt
    } do
      assert {:ok, first} = set(token, [line(shirt, 1, [opt("color", "red")])])
      assert [%{options: [%{attribute_key: "color", value_key: "red"}]}] = first.cart.lines

      assert {:ok, second} = set(token, [line(shirt, 2, [opt("color", "blue")])])
      assert actions(second) == ["created"]
      assert length(second.cart.lines) == 2

      assert {:ok, third} = set(token, [line(shirt, 4, [opt("color", "red")])])
      assert actions(third) == ["updated"]

      assert {:ok, fourth} = set(token, [line(shirt, 0, [opt("color", "blue")])])
      assert actions(fourth) == ["removed"]
      assert [%{quantity: 4, options: [%{value_key: "red"}]}] = fourth.cart.lines

      stored = hash |> cart_of() |> Map.fetch!(:items) |> Enum.map(& &1.metadata["api_options"])
      assert stored == [[%{"attribute_key" => "color", "value_key" => "red"}]]
    end
  end

  describe "a product that changed between planning and writing" do
    # The options are planned from one read of the product and checked again by
    # `add_to_cart` under the product's row lock. When they disagree its refusal
    # rolls back its own transaction, which dooms the writer's: the batch must answer
    # the retryable state_changed, not run another statement into a dead transaction.
    for {name, metadata, reason} <- [
          {"an option value that is no longer offered",
           %{"_option_values" => %{"color" => ["Green"]}}, ":invalid_option_value"},
          {"a required option that appeared",
           %{"_option_values" => %{"color" => ["Red", "Blue"], "size" => ["S"]}},
           ":missing_required_option"},
          {"an option that was removed", %{}, ":unknown_option_key"}
        ] do
      test "#{name} rolls the batch back for a retry", %{token: token, hash: hash, p1: p1} do
        shirt = product_with_options!(%{"color" => ["Red", "Blue"]})
        metadata = unquote(Macro.escape(metadata))

        after_first_query("INSERT", "phoenix_kit_shop_carts", fn ->
          {:ok, _} = Shop.update_product(shirt, %{"metadata" => metadata})
        end)

        log =
          capture_log(fn ->
            assert {:error, :validation_failed, _message, context} =
                     set(token, [line(p1, 1), line(shirt, 1, [opt("color", "red")])])

            assert context == %{reason: "state_changed", retry: true}
          end)

        assert log =~ "cart write rolled back: #{unquote(reason)}"
        refute log =~ shirt.uuid

        # nothing of the batch was kept, and the connection is still usable
        assert CartStore.resolve(hash) == :empty
      end
    end
  end

  describe "an answer the writer does not recognise" do
    # `add_to_cart` rolls its own transaction back for most of what it does not
    # name as a line's fault, which dooms the writer's: continuing would raise a
    # DBConnection error (a 500). Anything that is not a known permanent refusal
    # rolls the batch back for a retry.
    test "a rollback inside the cart rebase rolls the batch back for a retry", %{
      token: token,
      p1: p1,
      p2: p2
    } do
      {:ok, _} = set(token, [line(p1, 1)])
      Repo.update_all(CartItem, set: [base_unit_price: nil])

      assert {:ok, %{old_base: "USD"}} =
               PhoenixKitBilling.change_base_currency("EUR",
                 catalog_size: 1,
                 reprice: &Shop.reprice_for_base_change/3
               )

      log =
        capture_log(fn ->
          assert {:error, :validation_failed, _message, context} = set(token, [line(p2, 1)])
          assert context == %{reason: "state_changed", retry: true}
        end)

      assert log =~ "cart write rolled back: :no_base_price"
      assert [%{quantity: 1}] = cart_lines(token)
    end

    test "only the shape of the answer is logged, never the product it names", %{
      token: token,
      hash: hash,
      p1: p1
    } do
      # The product is archived between planning and the locked read: `add_to_cart`
      # answers with a tuple that carries the product's uuid.
      after_first_query("INSERT", "phoenix_kit_shop_carts", fn ->
        {:ok, _} = Shop.update_product(p1, %{"status" => "archived"})
      end)

      log =
        capture_log(fn ->
          assert {:error, :validation_failed, _message, %{retry: true}} =
                   set(token, [line(p1, 1)])
        end)

      assert log =~ "cart write rolled back: {:error, {:product_not_available, term}}"
      refute log =~ p1.uuid
      assert CartStore.resolve(hash) == :empty
    end
  end

  describe "a deadlock the database resolves against the writer" do
    # A trigger raises what Postgres raises for the aborted side of a deadlock
    # (SQLSTATE 40P01). The DDL rolls back with the test's transaction.
    test "is the retryable state_changed, not a 500, and keeps nothing", %{
      token: token,
      hash: hash,
      p1: p1
    } do
      Repo.query!("""
      CREATE FUNCTION pk_test_raise_deadlock() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN RAISE EXCEPTION 'simulated deadlock' USING ERRCODE = '40P01'; END
      $$
      """)

      Repo.query!("""
      CREATE TRIGGER pk_test_raise_deadlock BEFORE INSERT ON phoenix_kit_shop_cart_items
      FOR EACH ROW EXECUTE FUNCTION pk_test_raise_deadlock()
      """)

      log =
        capture_log(fn ->
          assert {:error, :validation_failed, _message, context} = set(token, [line(p1, 1)])
          assert context == %{reason: "state_changed", retry: true}
        end)

      assert log =~ "cart write rolled back: :deadlock"
      assert CartStore.resolve(hash) == :empty
    end
  end

  describe "a refusal add_to_cart makes for good" do
    # A cart frozen against a base currency that was replaced and whose row is gone:
    # every add is refused, always. It is the line's error; a retry would never succeed.
    test "is the line's error with its reason, never the retryable state_changed", %{
      token: token,
      p1: p1,
      p2: p2
    } do
      {:ok, _} = set(token, [line(p1, 1)])

      assert {:ok, %{old_base: "USD"}} =
               PhoenixKitBilling.change_base_currency("EUR",
                 catalog_size: 1,
                 reprice: &Shop.reprice_for_base_change/3
               )

      Repo.delete_all(from(c in Currency, where: c.code == "USD"))
      Cache.clear(:billing_currencies)

      assert {:ok, result} = set(token, [line(p2, 1)])

      assert [%{action: "error", error: %{code: "not_on_sale", reason: "cart_base_unavailable"}}] =
               result.results

      assert [%{quantity: 1}] = result.cart.lines
    end
  end

  describe "a line whose product left the shop" do
    test "can still be removed", %{token: token, p1: p1} do
      {:ok, _} = set(token, [line(p1, 1)])
      {:ok, _} = Shop.update_product(p1, %{"status" => "archived"})

      assert {:ok, view} = set(token, [line(p1, 0)])

      assert actions(view) == ["removed"]
      assert view.cart.lines == []
    end
  end

  describe "expected_revision" do
    test "a matching revision passes, the empty cart's revision works for the first write", %{
      token: token,
      p1: p1,
      p2: p2
    } do
      assert {:ok, first} =
               set(token, [line(p1, 1)], extra: %{"expected_revision" => CartView.revision(nil)})

      assert {:ok, _second} =
               set(token, [line(p2, 1)], extra: %{"expected_revision" => first.revision})
    end

    test "a stale revision is a 409 with what changed since", %{token: token, p1: p1, p2: p2} do
      {:ok, first} = set(token, [line(p1, 1)])
      {:ok, second} = set(token, [line(p2, 1)])

      assert {:error, :revision_mismatch, _message, context} =
               set(token, [line(p1, 9)], extra: %{"expected_revision" => first.revision})

      assert context.current_revision == second.revision
      assert context.expected_revision == first.revision
      assert [%{product_id: id, to: 1}] = context.changes_since.added
      assert id == p2.uuid
      refute Map.has_key?(context, :cart)

      assert [%{quantity: 1}, %{quantity: 1}] = cart_lines(token)
    end

    test "a revision that is not remembered returns the whole cart instead", %{
      token: token,
      p1: p1
    } do
      {:ok, first} = set(token, [line(p1, 1)])
      for quantity <- 2..12, do: {:ok, _} = set(token, [line(p1, quantity)])

      assert {:error, :revision_mismatch, _message, context} =
               set(token, [line(p1, 1)], extra: %{"expected_revision" => first.revision})

      refute Map.has_key?(context, :changes_since)
      assert [%{quantity: 12}] = context.cart.lines
    end

    test "a wrong revision does not spend a row slot of the network", %{token: token, p1: p1} do
      put_setting!("api_public_cart_rows_per_ip_hour", 1)
      ctx = ctx_for(token)

      assert {:error, :revision_mismatch, _message, _context} =
               set(token, [line(p1, 1)], ctx: ctx, extra: %{"expected_revision" => "bad"})

      assert {:ok, _} = set(token, [line(p1, 1)], ctx: ctx)
    end

    test "a removal-only request on a token without a cart still checks the revision", %{
      token: token,
      hash: hash,
      p1: p1
    } do
      assert {:error, :revision_mismatch, _message, context} =
               set(token, [line(p1, 0)], extra: %{"expected_revision" => "0000000000000000"})

      assert context.cart.lines == []

      assert {:ok, _} =
               set(token, [line(p1, 0)], extra: %{"expected_revision" => CartView.revision(nil)})

      assert CartStore.resolve(hash) == :empty
    end

    test "a wrong revision on a token without a cart creates no cart", %{
      token: token,
      hash: hash,
      p1: p1
    } do
      assert {:error, :revision_mismatch, _message, context} =
               set(token, [line(p1, 1)], extra: %{"expected_revision" => "0000000000000000"})

      assert context.cart.lines == []
      assert CartStore.resolve(hash) == :empty
    end
  end

  describe "the cart's currency is fixed at its first write" do
    test "a different currency override is refused, the same one or none is fine", %{
      token: token,
      p1: p1
    } do
      {:ok, _} = set(token, [line(p1, 1)])

      assert {:error, :validation_failed, _message, context} =
               set(token, [line(p1, 2)], extra: %{"currency" => "EUR"})

      assert context.reason == "cart_currency_fixed"
      assert [%{path: "currency", allowed: ["USD"]}] = context.errors

      assert {:ok, _} = set(token, [line(p1, 2)], extra: %{"currency" => "USD"})
      assert {:ok, _} = set(token, [line(p1, 3)], extra: %{"currency" => "usd"})
      assert {:ok, _} = set(token, [line(p1, 4)])
    end

    test "the first write creates the cart in the call's currency", %{
      token: token,
      hash: hash,
      p1: p1
    } do
      assert {:ok, result} = set(token, [line(p1, 1)], ctx: ctx_for(token, %{currency: "EUR"}))

      assert result.cart.currency == "EUR"
      assert cart_of(hash).currency == "EUR"
    end
  end

  describe "dry runs" do
    test "answer what the write would, change nothing, and charge nothing", %{
      token: token,
      hash: hash,
      p1: p1
    } do
      put_setting!("api_public_cart_rows_per_ip_hour", 1)
      dry = ctx_for(token, %{dry_run?: true})

      assert {:preview, result, fingerprint} = set(token, [line(p1, 2)], ctx: dry)

      assert actions(result) == ["created"]
      assert fingerprint == result.revision
      assert CartStore.resolve(hash) == :empty

      # the row limit of 1 is still unspent for this address
      assert {:ok, real} = set(token, [line(p1, 2)], ctx: %{dry | dry_run?: false})
      assert real.revision == result.revision
    end

    test "on an existing cart leave the lines as they were", %{token: token, hash: hash, p1: p1} do
      {:ok, _} = set(token, [line(p1, 2)])

      assert {:preview, result, _} =
               set(token, [line(p1, 7)], ctx: ctx_for(token, %{dry_run?: true}))

      assert [%{quantity: 7}] = result.cart.lines
      assert [%{quantity: 2}] = hash |> cart_of() |> Map.fetch!(:items)
    end

    # Core's executor accepts only {:preview, preview, fingerprint} for a dry run and
    # answers 500 to anything else: every path of a dry run must preview, also the one that
    # would not have written a cart anyway.
    test "on a token without a cart and with nothing to write are still a preview", %{
      token: token,
      hash: hash,
      p1: p1
    } do
      dry = ctx_for(token, %{dry_run?: true})

      assert {:preview, result, fingerprint} =
               set(token, [line(p1, 0), %{"product_id" => "nope", "quantity" => 1}], ctx: dry)

      assert actions(result) == ["unchanged", "error"]
      assert fingerprint == result.revision
      assert CartStore.resolve(hash) == :empty
    end
  end

  describe "tokens that cannot be written to" do
    test "a swept cart is not found", %{token: token, hash: hash, p1: p1} do
      {:ok, _} = set(token, [line(p1, 1)])
      hash |> cart_of() |> Cart.status_changeset("abandoned") |> Repo.update!()

      assert {:error, :cart_not_found, _message, %{}} = set(token, [line(p1, 1)])
    end

    test "a claimed cart is locked", %{token: token, hash: hash, p1: p1} do
      {:ok, _} = set(token, [line(p1, 1)])
      cart = cart_of(hash)

      cart
      |> Cart.changeset(%{session_id: "browser-#{System.unique_integer([:positive])}"})
      |> Repo.update!()

      {:ok, _} =
        %CartClaim{}
        |> CartClaim.changeset(%{
          token_hash: "th-#{System.unique_integer([:positive])}",
          cart_uuid: cart.uuid,
          cart_token_hash: hash,
          language: "en",
          expires_at:
            DateTime.utc_now() |> DateTime.add(600, :second) |> DateTime.truncate(:second),
          used_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.insert()

      assert {:error, :cart_locked, _message, %{}} = set(token, [line(p1, 1)])
    end

    test "the row limit answers rate_limited with a retry time", %{token: token, p1: p1} do
      put_setting!("api_public_cart_rows_per_ip_hour", 1)
      shared = ctx()
      other = new_token!()

      assert {:ok, _} =
               set(other, [line(p1, 1)],
                 ctx:
                   Map.put(shared, :actor, %{
                     shared.actor
                     | cart_token_hash: CartToken.digest(other)
                   })
               )

      assert {:error, :rate_limited, _message, %{retry_after: retry}} =
               set(token, [line(p1, 1)],
                 ctx:
                   Map.put(shared, :actor, %{
                     shared.actor
                     | cart_token_hash: CartToken.digest(token)
                   })
               )

      assert is_integer(retry) and retry > 0
    end
  end

  describe "the notification" do
    setup do
      _owner = fixture_user()
      reset_signal_counters!()
      :ok
    end

    test "one message per write, none for removals, dry runs or per line", %{
      token: token,
      p1: p1,
      p2: p2,
      p3: p3
    } do
      toggles(true, true)

      {:ok, _} = set(token, [line(p1, 1), line(p2, 2), line(p3, 3)])
      assert count_notifications("shop.cart_first_item_added") == 1
      assert count_notifications("shop.cart_item_added") == 0

      [text] = notification_texts_for_action("shop.cart_first_item_added")
      assert text =~ "via assistant"
      assert text =~ "×3"

      {:ok, _} = set(token, [line(p1, 0)])
      assert count_notifications("shop.cart_item_added") == 0

      {:preview, _, _} = set(token, [line(p2, 9)], ctx: ctx_for(token, %{dry_run?: true}))
      assert count_notifications("shop.cart_item_added") == 0

      {:ok, _} = set(token, [line(p2, 3)])
      assert count_notifications("shop.cart_item_added") == 1
    end

    test "a write of 50 real lines sends one message, not 50", %{token: token} do
      toggles(true, true)
      products = for _ <- 1..50, do: product!()

      assert {:ok, result} = set(token, Enum.map(products, &line(&1, 1)))

      assert result.summary == %{"created" => 50}
      assert count_notifications("shop.cart_first_item_added") == 1
      assert count_notifications("shop.cart_item_added") == 0
    end

    test "a write that changed nothing is silent", %{token: token, p1: p1} do
      toggles(true, true)
      {:ok, _} = set(token, [line(p1, 1)])

      before =
        count_notifications("shop.cart_first_item_added") +
          count_notifications("shop.cart_item_added")

      {:ok, _} = set(token, [line(p1, 1)])

      assert count_notifications("shop.cart_first_item_added") +
               count_notifications("shop.cart_item_added") == before
    end
  end
end
