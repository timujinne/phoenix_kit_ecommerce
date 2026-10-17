defmodule PhoenixKitEcommerce.API.CartViewTest do
  @moduledoc """
  The read model of a cart: what an agent sees, how the revision behaves, and
  what `changes/2` reports between two snapshots.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  import PhoenixKitEcommerce.CartApiFixtures

  import PhoenixKitEcommerce.SearchFixtures,
    only: [
      catalogue_category!: 3,
      catalogue_item!: 2,
      catalogue_item!: 3,
      catalogue_source!: 0,
      legacy_category!: 2,
      shop_data: 1
    ]

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.API.CartView
  alias PhoenixKitEcommerce.CartItem
  alias PhoenixKitEcommerce.Test.Shipping.StubProvider

  # The catalogue is an optional dependency; its calls are only reached from
  # tests tagged :catalogue.
  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}

  setup do
    ensure_currencies!()
    :ok
  end

  defp new_cart(currency \\ nil) do
    PhoenixKitBilling.Currency.put_request_currency(currency)
    {:ok, cart} = Shop.create_cart(session_id: "view-#{System.unique_integer([:positive])}")
    PhoenixKitBilling.Currency.put_request_currency(nil)
    cart
  end

  defp add!(cart, product, quantity, opts \\ []) do
    {:ok, cart} = Shop.add_to_cart(cart, product, quantity, opts ++ [via: :assistant])
    Shop.get_cart(cart.uuid)
  end

  defp line_snapshot(product_id, options, quantity),
    do: %{"product_id" => product_id, "options" => options, "quantity" => quantity}

  defp method!(attrs) do
    {:ok, method} =
      Shop.create_shipping_method(
        Map.merge(
          %{
            "name" => "M#{System.unique_integer([:positive])}",
            "price" => Decimal.new("5.00"),
            "active" => true
          },
          attrs
        )
      )

    method
  end

  describe "build/1" do
    test "refuses a cart whose items or shipping method are not loaded" do
      cart = Shop.get_cart(new_cart().uuid)

      assert_raise ArgumentError, fn ->
        CartView.build(%{cart | items: %Ecto.Association.NotLoaded{}})
      end

      assert_raise ArgumentError, fn ->
        CartView.build(%{cart | shipping_method: %Ecto.Association.NotLoaded{}})
      end
    end
  end

  describe "an empty cart" do
    test "has no lines, zero totals, an open status and the empty revision" do
      view = CartView.build(Shop.get_cart(new_cart().uuid))

      assert view.status == "open"
      assert view.currency == "USD"
      assert view.lines == []
      assert view.totals.subtotal == %{amount: "0.00", currency: "USD"}
      assert view.totals.total == %{amount: "0.00", currency: "USD"}
      assert view.shipping == %{country: nil, method: nil}
      assert view.thresholds == []
      assert view.revision == CartView.revision(nil)
      assert is_binary(view.read_at)
    end

    test "empty/1 and locked/1 are the answers for a token without a row and a claimed one" do
      empty = CartView.empty("EUR")
      assert empty.status == "open" and empty.lines == [] and empty.currency == "EUR"
      assert empty.revision == CartView.revision(nil)
      assert empty.totals.total == %{amount: "0.00", currency: "EUR"}

      locked = CartView.locked("EUR")
      assert locked.status == "checking_out"
      assert locked.lines == []
      refute Map.has_key?(locked, :totals)
    end

    # The declared output schemas have no nullable types, and the public read tools omit nil values: an
    # explicit null would fail a client that validates structuredContent against outputSchema.
    test "compact/1 drops nil values at any depth and keeps empty lists, false and zero" do
      view = %{
        revision: nil,
        lines: [%{product_id: nil, quantity: 0, free: false, options: []}],
        shipping: %{country: nil, method: nil},
        nested: %{a: %{b: nil, c: "x"}}
      }

      assert CartView.compact(view) ==
               %{
                 lines: [%{quantity: 0, free: false, options: []}],
                 shipping: %{},
                 nested: %{a: %{c: "x"}}
               }

      locked = CartView.locked("EUR")

      assert CartView.compact(locked) ==
               %{status: "checking_out", read_at: locked.read_at, currency: "EUR", lines: []}
    end
  end

  describe "lines" do
    test "carry the product id, the title snapshot, two separate prices and a status" do
      product = product!(%{"price" => Decimal.new("10.00")})
      cart = new_cart() |> add!(product, 3)

      assert [line] = CartView.build(cart).lines
      assert line.product_id == product.uuid
      assert line.title =~ "Widget"
      assert line.options == []
      assert line.quantity == 3
      assert line.unit_price == %{amount: "10.00", currency: "USD"}
      assert line.line_total == %{amount: "30.00", currency: "USD"}
      assert line.status == "ok"
      assert CartView.build(cart).totals.subtotal == %{amount: "30.00", currency: "USD"}
    end

    test "show the neutral options of the line" do
      product = product_with_options!(%{"color" => ["Red", "Blue"]})
      cart = new_cart() |> add!(product, 1, selected_specs: %{"color" => "Blue"})

      assert [%{options: [%{attribute_key: "color", value_key: "blue"}]}] =
               CartView.build(cart).lines
    end

    test "are listed in the order they were added" do
      first = product!()
      second = product!()
      cart = new_cart() |> add!(first, 1) |> add!(second, 1)

      assert Enum.map(CartView.build(cart).lines, & &1.product_id) == [first.uuid, second.uuid]
    end

    test "turn unavailable when the product is archived or deleted" do
      archived = product!()
      deleted = product!()
      cart = new_cart() |> add!(archived, 1) |> add!(deleted, 1)

      {:ok, _} = Shop.update_product(archived, %{"status" => "archived"})
      {:ok, _} = Shop.delete_product(deleted)
      lines = CartView.build(Shop.get_cart(cart.uuid)).lines

      assert Enum.all?(lines, &(&1.status == "unavailable"))
      assert Enum.any?(lines, &is_nil(&1.product_id))
    end

    # A line is "ok" exactly when the public read API would list its product,
    # not merely when the product row is active.
    test "turn unavailable when the product's category is hidden" do
      category = legacy_category!(%{"en" => "Cat"}, %{})
      product = product!(%{"category_uuid" => category.uuid})
      cart = new_cart() |> add!(product, 1)

      assert [%{status: "ok"}] = CartView.build(cart).lines

      {:ok, _} = Shop.update_category(category, %{status: "hidden"})

      assert [%{status: "unavailable"}] = CartView.build(Shop.get_cart(cart.uuid)).lines
    end

    test "turn unavailable when the product goes back to draft" do
      product = product!()
      cart = new_cart() |> add!(product, 1)

      assert [%{status: "ok"}] = CartView.build(cart).lines

      {:ok, _} = Shop.update_product(product, %{"status" => "draft"})

      assert [%{status: "unavailable"}] = CartView.build(Shop.get_cart(cart.uuid)).lines
    end

    test "are ordered by the time they were added, not by the order the rows come back in" do
      first = product!()
      second = product!()
      cart = new_cart() |> add!(first, 1) |> add!(second, 1)

      # The lines are inserted first-second; make the first one the newer.
      for {product, hours_ago} <- [{first, 0}, {second, 2}] do
        item = Enum.find(cart.items, &(&1.product_uuid == product.uuid))

        stamp =
          DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-hours_ago * 3600)

        Repo.update_all(from(i in CartItem, where: i.uuid == ^item.uuid),
          set: [inserted_at: stamp]
        )
      end

      assert Enum.map(CartView.build(Shop.get_cart(cart.uuid)).lines, & &1.product_id) ==
               [second.uuid, first.uuid]
    end
  end

  describe "lines that were added in the same second" do
    test "are ordered by their uuid, whatever order the cart hands them over in" do
      cart = new_cart() |> add!(product!(), 1) |> add!(product!(), 1) |> add!(product!(), 1)
      stamp = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.update_all(from(i in CartItem, where: i.cart_uuid == ^cart.uuid),
        set: [inserted_at: stamp]
      )

      cart = Shop.get_cart(cart.uuid)
      expected = cart.items |> Enum.sort_by(& &1.uuid) |> Enum.map(&CartView.line_product_id/1)

      for items <- [cart.items, Enum.reverse(cart.items)] do
        lines = CartView.build(%{cart | items: items}).lines
        assert Enum.map(lines, & &1.product_id) == expected
      end
    end
  end

  describe "a line whose price is on request" do
    setup do
      %{
        quoted: product!(%{"price" => Decimal.new("10.00")}),
        on_request:
          product!(%{
            "price" => Decimal.new("0.00"),
            "metadata" => %{"_price_display" => %{"on_request" => true}}
          })
      }
    end

    test "says so, shows no price, and marks the totals as incomplete", t do
      cart = new_cart() |> add!(t.quoted, 1) |> add!(t.on_request, 1)

      view = CartView.build(cart)
      lines = Map.new(view.lines, &{&1.product_id, &1})

      assert lines[t.on_request.uuid].price_on_request == true
      assert lines[t.on_request.uuid].unit_price == nil
      assert lines[t.on_request.uuid].line_total == nil
      assert lines[t.on_request.uuid].status == "ok"

      assert lines[t.quoted.uuid].price_on_request == false
      assert lines[t.quoted.uuid].unit_price == %{amount: "10.00", currency: "USD"}

      assert view.totals_incomplete == true
      assert view.totals.subtotal == %{amount: "10.00", currency: "USD"}
    end

    test "is absent from a cart of priced lines, and the compacted view carries no null", t do
      priced = new_cart() |> add!(t.quoted, 1) |> CartView.build()
      assert priced.totals_incomplete == false
      assert [%{price_on_request: false}] = priced.lines

      view = new_cart() |> add!(t.on_request, 1) |> CartView.build() |> CartView.compact()
      assert [line] = view.lines
      assert line.price_on_request == true
      refute Map.has_key?(line, :unit_price)
      refute Map.has_key?(line, :line_total)
    end
  end

  describe "lines of a catalogue-backed cart" do
    @describetag :catalogue

    test "carry the catalogue item uuid and turn unavailable when its category is hidden" do
      catalogue = catalogue_source!()
      category = catalogue_category!(catalogue, "Shelf", %{data: shop_data("active")})
      item = catalogue_item!(catalogue, "Catalogue Vase", %{category_uuid: category.uuid})
      product = Shop.get_product(item.uuid)

      cart = new_cart() |> add!(product, 1)

      assert [line] = CartView.build(cart).lines
      assert is_nil(hd(cart.items).product_uuid)
      assert line.product_id == item.uuid
      assert line.status == "ok"

      {:ok, _} =
        Catalogue.update_category(category, %{data: shop_data("hidden")})

      assert [%{product_id: id, status: "unavailable"}] =
               CartView.build(Shop.get_cart(cart.uuid)).lines

      assert id == item.uuid
    end
  end

  describe "revision/1" do
    test "is stable, and changes with quantity, lines and the shipping choice" do
      a = product!()
      b = product!()
      cart = new_cart() |> add!(a, 1)
      rev1 = CartView.revision(cart)

      assert CartView.revision(Shop.get_cart(cart.uuid)) == rev1

      cart = add!(cart, a, 1)
      rev2 = CartView.revision(cart)
      assert rev2 != rev1

      cart = add!(cart, b, 1)
      rev3 = CartView.revision(cart)
      assert rev3 not in [rev1, rev2]

      method = method!(%{})
      {:ok, _} = Shop.set_cart_shipping(cart, method, "DE")
      rev4 = CartView.revision(Shop.get_cart(cart.uuid))
      assert rev4 not in [rev1, rev2, rev3]
    end

    test "ignores the order lines were added in" do
      a = product!(%{"price" => Decimal.new("10.00")})
      b = product!(%{"price" => Decimal.new("20.00")})
      one = new_cart() |> add!(a, 2) |> add!(b, 1)
      two = new_cart() |> add!(b, 1) |> add!(a, 2)

      assert CartView.revision(one) == CartView.revision(two)
    end

    # A cart line keeps the price it was added at, so the price of the line is
    # changed on the row itself.
    test "ignores the prices of the lines" do
      cart = new_cart() |> add!(product!(%{"price" => Decimal.new("10.00")}), 2)
      item = hd(cart.items)

      Repo.update_all(from(i in CartItem, where: i.uuid == ^item.uuid),
        set: [unit_price: Decimal.new("99.00"), line_total: Decimal.new("198.00")]
      )

      repriced = Shop.get_cart(cart.uuid)
      assert Decimal.equal?(hd(repriced.items).unit_price, Decimal.new("99.00"))
      assert CartView.revision(repriced) == CartView.revision(cart)
    end

    test "tells two carts apart that differ only by an option" do
      product = product_with_options!(%{"color" => ["Red", "Blue"]})
      red = new_cart() |> add!(product, 1, selected_specs: %{"color" => "Red"})
      blue = new_cart() |> add!(product, 1, selected_specs: %{"color" => "Blue"})

      assert CartView.revision(red) != CartView.revision(blue)
    end

    test "is 16 lowercase hex characters" do
      assert CartView.revision(nil) =~ ~r/\A[0-9a-f]{16}\z/
    end
  end

  describe "snapshot/1, stamp/1 and changes/2" do
    test "report added, removed and changed lines and a changed shipping choice" do
      a = product!()
      b = product!()
      c = product!()

      before_cart = new_cart() |> add!(a, 1) |> add!(b, 2)
      old = CartView.snapshot(before_cart)

      after_cart = before_cart |> add!(c, 1) |> add!(a, 4)

      {:ok, _} =
        Shop.update_cart_item(Enum.find(after_cart.items, &(&1.product_uuid == b.uuid)), 5)

      after_cart = Shop.get_cart(after_cart.uuid)
      new = CartView.snapshot(after_cart)

      changes = CartView.changes(old, new)

      assert [%{product_id: id, from: nil, to: 1}] = changes.added
      assert id == c.uuid
      assert changes.removed == []

      assert Enum.sort_by(changes.changed, & &1.from) == [
               %{product_id: a.uuid, options: [], from: 1, to: 5},
               %{product_id: b.uuid, options: [], from: 2, to: 5}
             ]

      assert changes.shipping == nil
    end

    test "report a removed line and a shipping change" do
      a = product!()
      b = product!()
      cart = new_cart() |> add!(a, 1) |> add!(b, 1)
      old = CartView.snapshot(cart)

      {:ok, _} = Shop.remove_from_cart(Enum.find(cart.items, &(&1.product_uuid == a.uuid)))
      method = method!(%{})
      cart = Shop.get_cart(cart.uuid)
      {:ok, _} = Shop.set_cart_shipping(cart, method, "DE")
      new = CartView.snapshot(Shop.get_cart(cart.uuid))

      changes = CartView.changes(old, new)

      assert [%{product_id: id, from: 1, to: nil}] = changes.removed
      assert id == a.uuid
      assert changes.added == []
      assert changes.changed == []

      assert changes.shipping == %{
               from: %{method: nil, country: nil},
               to: %{method: method.uuid, country: "DE"}
             }
    end

    test "name the options of a line and tell lines of one product with other options apart" do
      product = product_with_options!(%{"color" => ["Red", "Blue"]})
      cart = new_cart() |> add!(product, 1, selected_specs: %{"color" => "Red"})
      old = CartView.snapshot(cart)

      cart = cart |> add!(product, 1, selected_specs: %{"color" => "Blue"})
      cart = add!(cart, product, 2, selected_specs: %{"color" => "Red"})
      changes = CartView.changes(old, CartView.snapshot(cart))

      assert changes.added == [
               %{
                 product_id: product.uuid,
                 options: [%{attribute_key: "color", value_key: "blue"}],
                 from: nil,
                 to: 1
               }
             ]

      assert changes.changed == [
               %{
                 product_id: product.uuid,
                 options: [%{attribute_key: "color", value_key: "red"}],
                 from: 1,
                 to: 3
               }
             ]

      assert changes.removed == []
    end

    # A map of more than 32 keys iterates in hash order, so only a cart this size
    # shows whether the lists come back in a stable order.
    test "list added, removed and changed lines in the order of product id and options" do
      ids = for n <- 1..40, do: "p" <> String.pad_leading(Integer.to_string(n), 2, "0")
      lines = fn ids, quantity -> Enum.map(ids, &line_snapshot(&1, [["size", "m"]], quantity)) end
      other_options = [line_snapshot("p20", [["size", "l"]], 1)]

      snapshot = fn lines ->
        %{"lines" => lines, "shipping" => %{"method" => nil, "country" => nil}}
      end

      scrambled = Enum.shuffle(ids)

      added = CartView.changes(snapshot.([]), snapshot.(lines.(scrambled, 1) ++ other_options))
      removed = CartView.changes(snapshot.(lines.(scrambled, 1) ++ other_options), snapshot.([]))
      changed = CartView.changes(snapshot.(lines.(scrambled, 1)), snapshot.(lines.(scrambled, 2)))

      expected = Enum.sort(ids ++ ["p20"])

      assert Enum.map(added.added, & &1.product_id) == expected
      assert Enum.map(removed.removed, & &1.product_id) == expected
      assert Enum.map(changed.changed, & &1.product_id) == ids

      # The same product: the options decide ("l" before "m").
      assert added.added |> Enum.slice(19, 2) |> Enum.map(&hd(&1.options).value_key) == ["l", "m"]
      assert added.removed == [] and added.changed == []
    end

    # Lines of deleted products have no product id; two of them with equal
    # options are still two lines.
    test "keep apart the lines of deleted products that have the same options" do
      a = product!()
      b = product!()
      cart = new_cart() |> add!(a, 1) |> add!(b, 2)
      old = CartView.snapshot(nil)

      {:ok, _} = Shop.delete_product(a)
      {:ok, _} = Shop.delete_product(b)
      cart = Shop.get_cart(cart.uuid)

      assert Enum.all?(cart.items, &is_nil(CartView.line_product_id(&1)))
      assert %{added: added} = CartView.changes(old, CartView.snapshot(cart))
      assert added |> Enum.map(& &1.to) |> Enum.sort() == [1, 2]
    end

    test "stamp/1 adds the revision and a timestamp and keeps the lines" do
      snapshot = CartView.snapshot(nil)
      stamped = CartView.stamp(snapshot)

      assert stamped["revision"] == CartView.revision(nil)
      assert is_binary(stamped["at"])
      assert stamped["lines"] == snapshot["lines"]
    end
  end

  describe "totals" do
    test "carry the discount and the tax of the cart under their own names" do
      cart = new_cart() |> add!(product!(%{"price" => Decimal.new("10.00")}), 1)

      Repo.update_all(from(c in Shop.Cart, where: c.uuid == ^cart.uuid),
        set: [discount_amount: Decimal.new("1.50"), tax_amount: Decimal.new("2.25")]
      )

      totals = CartView.totals(Shop.get_cart(cart.uuid))

      assert totals.subtotal == %{amount: "10.00", currency: "USD"}
      assert totals.discount == %{amount: "1.50", currency: "USD"}
      assert totals.tax == %{amount: "2.25", currency: "USD"}
    end

    test "total is the cart's own total: the subtotal plus the shipping" do
      cart = new_cart() |> add!(physical_product!(%{"price" => Decimal.new("10.00")}), 2)
      method = method!(%{"price" => Decimal.new("7.50")})
      {:ok, _} = Shop.set_cart_shipping(cart, method, "DE")

      totals = CartView.build(Shop.get_cart(cart.uuid)).totals

      assert totals.subtotal == %{amount: "20.00", currency: "USD"}
      assert totals.shipping == %{amount: "7.50", currency: "USD"}
      assert totals.total == %{amount: "27.50", currency: "USD"}
    end
  end

  describe "shipping and thresholds" do
    test "show the chosen method with its price and flags" do
      cart = new_cart() |> add!(physical_product!(), 1)
      method = method!(%{"name" => "Courier", "price" => Decimal.new("7.50")})
      {:ok, _} = Shop.set_cart_shipping(cart, method, "DE")

      view = CartView.build(Shop.get_cart(cart.uuid))

      assert view.shipping.country == "DE"

      assert %{
               id: id,
               name: "Courier",
               price: %{amount: "7.50", currency: "USD"},
               free: false,
               pay_on_delivery: false,
               calculated: false,
               quote_status: "not_needed"
             } =
               view.shipping.method

      assert id == method.uuid
      assert view.totals.shipping == %{amount: "7.50", currency: "USD"}
    end

    test "flag a method whose free-shipping limit the subtotal has reached" do
      cart = new_cart() |> add!(physical_product!(%{"price" => Decimal.new("10.00")}), 1)

      method =
        method!(%{"price" => Decimal.new("7.50"), "free_above_amount" => Decimal.new("5.00")})

      {:ok, _} = Shop.set_cart_shipping(cart, method, "DE")

      view = CartView.build(Shop.get_cart(cart.uuid))

      assert view.shipping.method.free == true
      assert view.totals.shipping == %{amount: "0.00", currency: "USD"}
      assert view.totals.total == view.totals.subtotal
      assert [%{type: "free_shipping", remaining: %{amount: "0.00"}}] = view.thresholds
    end

    test "flag a pay-on-delivery method, which is not free and costs the shop's side nothing" do
      cart = new_cart() |> add!(physical_product!(%{"price" => Decimal.new("10.00")}), 1)
      method = method!(%{"price" => Decimal.new("7.50"), "pay_on_delivery" => true})
      {:ok, _} = Shop.set_cart_shipping(cart, method, "DE")

      view = CartView.build(Shop.get_cart(cart.uuid))

      assert view.shipping.method.pay_on_delivery == true
      assert view.shipping.method.free == false
      assert view.shipping.method.price == %{amount: "0.00", currency: "USD"}
      assert view.totals.shipping == %{amount: "0.00", currency: "USD"}
    end

    test "report each limit of the chosen method, in base, current and remaining" do
      cart = new_cart() |> add!(physical_product!(%{"price" => Decimal.new("10.00")}), 1)

      method =
        method!(%{
          "min_order_amount" => Decimal.new("5.00"),
          "max_order_amount" => Decimal.new("500.00"),
          "free_above_amount" => Decimal.new("20.00")
        })

      {:ok, _} = Shop.set_cart_shipping(cart, method, "DE")
      thresholds = CartView.build(Shop.get_cart(cart.uuid)).thresholds |> Map.new(&{&1.type, &1})

      assert Map.keys(thresholds) |> Enum.sort() == ["free_shipping", "max_order", "min_order"]
      assert thresholds["free_shipping"].method == method.uuid
      assert thresholds["free_shipping"].base == %{amount: "20.00", currency: "USD"}
      assert thresholds["free_shipping"].current == %{amount: "10.00", currency: "USD"}
      assert thresholds["free_shipping"].remaining == %{amount: "10.00", currency: "USD"}
      assert thresholds["min_order"].remaining == %{amount: "0.00", currency: "USD"}
      assert thresholds["max_order"].remaining == %{amount: "490.00", currency: "USD"}
    end

    test "without a chosen method the cheapest available one supplies the limits" do
      cart = new_cart() |> add!(physical_product!(), 1)

      _dear =
        method!(%{"price" => Decimal.new("9.00"), "free_above_amount" => Decimal.new("100.00")})

      cheap =
        method!(%{"price" => Decimal.new("2.00"), "free_above_amount" => Decimal.new("40.00")})

      assert [%{type: "free_shipping", method: method_id, base: %{amount: "40.00"}}] =
               CartView.build(Shop.get_cart(cart.uuid)).thresholds

      assert method_id == cheap.uuid
    end

    test "on a cart in another currency, current and remaining are in that currency, base stays base" do
      cart = new_cart("EUR") |> add!(physical_product!(%{"price" => Decimal.new("10.00")}), 1)
      method = method!(%{"free_above_amount" => Decimal.new("20.00")})
      {:ok, _} = Shop.set_cart_shipping(cart, method, "DE")

      assert [threshold] = CartView.build(Shop.get_cart(cart.uuid)).thresholds
      assert threshold.base == %{amount: "20.00", currency: "USD"}
      # 10.00 USD at the 0.909091 rate of `ensure_currencies!/0`; the base
      # limit is in the base currency and the rest is converted back.
      assert threshold.current == %{amount: "9.09", currency: "EUR"}
      assert threshold.remaining == %{amount: "9.09", currency: "EUR"}
    end

    # `current` is the cart's own subtotal and `remaining` is a difference, not a
    # price: neither may go through the currency's rounding rule.
    test "on a currency with a charm rule, current is the subtotal and remaining is not charm-rounded" do
      eur = Repo.get_by!(PhoenixKitBilling.Currency, code: "EUR")
      {:ok, _} = PhoenixKitBilling.update_currency(eur, %{rounding_rule: "charm_99"})
      PhoenixKit.Cache.clear(:billing_currencies)

      cart = new_cart("EUR") |> add!(physical_product!(%{"price" => Decimal.new("10.00")}), 2)
      method = method!(%{"free_above_amount" => Decimal.new("100.00")})
      {:ok, _} = Shop.set_cart_shipping(cart, method, "DE")

      view = CartView.build(Shop.get_cart(cart.uuid))

      assert view.totals.subtotal == %{amount: "17.98", currency: "EUR"}
      assert [threshold] = view.thresholds
      assert threshold.current == view.totals.subtotal
      assert threshold.remaining == %{amount: "72.93", currency: "EUR"}
    end

    # A carrier prices its method once the buyer has chosen a destination on the
    # site; until then the method's own price is only a fallback figure.
    test "do not present the fallback price of a carrier method as its price" do
      previous = Application.get_env(:phoenix_kit_ecommerce, :shipping_providers)
      Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, [StubProvider])

      on_exit(fn ->
        if previous,
          do: Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, previous),
          else: Application.delete_env(:phoenix_kit_ecommerce, :shipping_providers)
      end)

      StubProvider.put(%{})

      method =
        method!(%{
          "price" => Decimal.new("7.00"),
          "shipping_provider" => %{
            "provider" => "stub",
            "service" => "branch",
            "settings" => %{"sender_city" => %{"id" => "c1", "name" => "Springfield"}},
            "pricing" => %{"markup_percent" => "0", "markup_fixed" => "0", "round_to" => "1"}
          }
        })

      cart = new_cart() |> add!(physical_product!(), 1)
      {:ok, _} = Shop.set_cart_shipping(cart, method, "DE")

      view = CartView.build(Shop.get_cart(cart.uuid))

      assert view.shipping.method.id == method.uuid
      assert view.shipping.method.calculated == true
      assert view.shipping.method.quote_status == "needs_destination"
      assert view.shipping.method.price == nil
    end

    test "an empty cart has no thresholds" do
      method!(%{"free_above_amount" => Decimal.new("20.00")})
      assert CartView.build(Shop.get_cart(new_cart().uuid)).thresholds == []
    end
  end

  describe "Shop.cart_amount_to_base/2 and cart_amount_from_base/2" do
    test "are the identity on a base-currency cart and invert each other on a converted one" do
      usd = Shop.get_cart(new_cart().uuid)
      assert Shop.cart_amount_to_base(usd, Decimal.new("10.00")) == Decimal.new("10.00")
      assert Shop.cart_amount_from_base(Decimal.new("10.00"), usd) == Decimal.new("10.00")

      eur = Shop.get_cart(new_cart("EUR").uuid)
      in_eur = Shop.cart_amount_from_base(Decimal.new("10.00"), eur)
      assert Decimal.compare(in_eur, Decimal.new("10.00")) == :lt
      assert Decimal.equal?(Shop.cart_amount_to_base(eur, in_eur), Decimal.new("10.00"))
    end
  end
end
