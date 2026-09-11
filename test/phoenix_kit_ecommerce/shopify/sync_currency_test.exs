defmodule PhoenixKitEcommerce.Shopify.SyncCurrencyTest do
  @moduledoc """
  The per-domain-currency design's sync-side requirements (§4.6, §7.5):
  the sync WRITES `product.currency` as the base currency label on a
  newly-created product, and REFUSES to write a PRICE field
  (`:price`/`:compare_at_price`) when the connected Shopify store's own
  currency no longer matches the base — while still applying whatever
  non-price fields the same change carries. A shop lookup that fails
  (no connection, network, bad credentials) must never block a sync
  that was otherwise working.

  Uses the legacy product path for the mismatch/lookup-failure
  scenarios (`Sync.apply_change/3`'s currency guard runs before the
  legacy/catalogue branch, so it's exercised identically either way,
  and the legacy path needs no optional dependency). The "created
  product carries the base label" scenario is Task 2's own write path
  (`PhoenixKitEcommerce.Catalogue.Writer.create_from_shopify/2`), which
  does need `phoenix_kit_catalogue` — that one describe block alone
  carries `@describetag :catalogue` (`test/test_helper.exs` excludes it
  automatically when the optional dependency isn't declared).
  """

  use PhoenixKitEcommerce.DataCase, async: false

  import ExUnit.CaptureLog

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}

  alias PhoenixKit.Integrations
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Shopify.ProductDiff.Change
  alias PhoenixKitEcommerce.Shopify.Sync

  @stub __MODULE__

  defp create_product(attrs) do
    defaults = %{"title" => %{"en" => "Old Title"}, "price" => "10.00", "vendor" => "Old Co"}
    {:ok, product} = Shop.create_product(Map.merge(defaults, attrs))
    product
  end

  defp build_change(product, changes, base_locale \\ "en") do
    %Change{
      product_uuid: product.uuid,
      handle: "handle",
      title: "Old Title",
      base_locale: base_locale,
      changes: changes
    }
  end

  defp connect_shopify(attrs \\ %{}) do
    {:ok, %{uuid: uuid}} =
      Integrations.add_connection("shopify", "Test Shop #{System.unique_integer([:positive])}")

    {:ok, _} =
      Integrations.save_setup(
        uuid,
        Map.merge(
          %{"shop_domain" => "test-shop.myshopify.com", "access_token" => "shpat_test_token"},
          attrs
        )
      )

    uuid
  end

  defp json_response(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, JSON.encode!(body))
  end

  defp stub_shop_currency(currency) do
    Req.Test.stub(@stub, fn conn ->
      json_response(conn, 200, %{
        "shop" => %{
          "currency" => currency,
          "name" => "Test Shop",
          "myshopify_domain" => "test-shop.myshopify.com"
        }
      })
    end)
  end

  defp admin_options, do: [admin_options: [req_options: [plug: {Req.Test, @stub}]]]

  # Same pattern `CartFxDriftTest`/`CartCurrencyEnforceTest` use: the
  # cache is ETS-backed and outlives the DB sandbox's per-test rollback,
  # so it must be cleared before every currency change or a later test
  # can read a previous test's now-rolled-back "base" currency.
  defp set_base_currency(code) do
    PhoenixKit.Cache.clear(:billing_currencies)
    Repo.delete_all(PhoenixKitBilling.Currency)

    {:ok, _} =
      PhoenixKitBilling.create_currency(%{
        code: code,
        name: code,
        symbol: code,
        is_default: true,
        exchange_rate: "1.0"
      })

    :ok
  end

  describe "currency guard — shop currency differs from base" do
    test "refuses the price field but still applies a title change on the same call, logging both currencies" do
      set_base_currency("USD")
      connect_shopify()
      stub_shop_currency("EUR")

      product = create_product(%{"title" => %{"en" => "Old Title"}, "price" => "10.00"})

      change =
        build_change(product, %{
          price: %{current: Decimal.new("10.00"), incoming: Decimal.new("12.00")},
          title: %{current: "Old Title", incoming: "New Title"}
        })

      log =
        capture_log(fn ->
          assert {:ok, updated} = Sync.apply_change(change, :all, admin_options())
          assert updated.title["en"] == "New Title"
          assert Decimal.eq?(updated.price, Decimal.new("10.00"))
        end)

      assert log =~ "EUR"
      assert log =~ "USD"
    end

    test "a price-only apply is refused outright, the error naming both currencies" do
      set_base_currency("USD")
      connect_shopify()
      stub_shop_currency("EUR")

      product = create_product(%{"price" => "10.00"})

      change =
        build_change(product, %{
          price: %{current: Decimal.new("10.00"), incoming: Decimal.new("12.00")}
        })

      assert {:error, {:currency_mismatch, "EUR", "USD"}} =
               Sync.apply_change(change, [:price], admin_options())

      assert Decimal.eq?(Shop.get_product!(product.uuid).price, Decimal.new("10.00"))
    end

    test "compare_at_price is refused the same way as price" do
      set_base_currency("USD")
      connect_shopify()
      stub_shop_currency("EUR")

      product = create_product(%{"compare_at_price" => "15.00"})

      change =
        build_change(product, %{
          compare_at_price: %{current: Decimal.new("15.00"), incoming: Decimal.new("18.00")}
        })

      assert {:error, {:currency_mismatch, "EUR", "USD"}} =
               Sync.apply_change(change, [:compare_at_price], admin_options())
    end

    test "apply_changes/3 looks up the shop currency once for a whole batch, not once per product" do
      set_base_currency("USD")
      connect_shopify()

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(@stub, fn conn ->
        Agent.update(counter, &(&1 + 1))
        json_response(conn, 200, %{"shop" => %{"currency" => "EUR"}})
      end)

      p1 = create_product(%{"title" => %{"en" => "First"}, "price" => "10.00"})
      p2 = create_product(%{"title" => %{"en" => "Second"}, "price" => "10.00"})

      c1 =
        build_change(p1, %{
          price: %{current: Decimal.new("10.00"), incoming: Decimal.new("11.00")}
        })

      c2 =
        build_change(p2, %{
          price: %{current: Decimal.new("10.00"), incoming: Decimal.new("12.00")}
        })

      assert %{succeeded: [], failed: [_c1, _c2]} =
               Sync.apply_changes([c1, c2], [:price], admin_options())

      assert Agent.get(counter, & &1) == 1
    end
  end

  describe "currency guard — shop lookup fails" do
    test "an unreachable Shopify does not block the sync; the failure logs at error" do
      set_base_currency("USD")
      connect_shopify()

      Req.Test.stub(@stub, fn conn -> Req.Test.transport_error(conn, :closed) end)

      product = create_product(%{"price" => "10.00"})

      change =
        build_change(product, %{
          price: %{current: Decimal.new("10.00"), incoming: Decimal.new("12.00")}
        })

      log =
        capture_log(fn ->
          assert {:ok, updated} = Sync.apply_change(change, [:price], admin_options())
          assert Decimal.eq?(updated.price, Decimal.new("12.00"))
        end)

      # A lookup failure is not the same kind of event as a mismatch: the
      # mismatch is an admin's own decision (logged at warning), while a
      # dead connection means this guard is checking nothing at all, for
      # every price write, until someone fixes it. It has to be loud
      # enough that an operator ignoring currency-guard warnings still
      # hears it.
      assert log =~ "could not reach the shop to verify its currency"
      assert log =~ "[error]"
    end

    test "no Shopify connection at all behaves exactly as before the guard existed" do
      set_base_currency("USD")

      product = create_product(%{"price" => "10.00"})

      change =
        build_change(product, %{
          price: %{current: Decimal.new("10.00"), incoming: Decimal.new("12.00")}
        })

      assert {:ok, updated} = Sync.apply_change(change, [:price])
      assert Decimal.eq?(updated.price, Decimal.new("12.00"))
    end
  end

  describe "currency guard — precomputed verdict passed by the caller" do
    # A per-product panel applying several fields as separate
    # `apply_change/3` calls within one operator action can call
    # `Sync.currency_verdict/1` ONCE up front and hand the result to
    # every `apply_change/3` via `opts[:currency_verdict]` — this proves
    # no Shopify request happens per call when it's given, by making the
    # stub itself fail the test if it's ever hit.
    defp explode_stub do
      Req.Test.stub(@stub, fn _conn -> flunk("apply_change/3 must not call the shop") end)
    end

    test ":match precomputed — a price field is applied, no shop lookup happens" do
      set_base_currency("USD")
      connect_shopify()
      explode_stub()

      product = create_product(%{"price" => "10.00"})

      change =
        build_change(product, %{
          price: %{current: Decimal.new("10.00"), incoming: Decimal.new("12.00")}
        })

      assert {:ok, updated} =
               Sync.apply_change(change, [:price], currency_verdict: :match)

      assert Decimal.eq?(updated.price, Decimal.new("12.00"))
    end

    test "a precomputed mismatch refuses the price field exactly like a freshly-looked-up one, no shop lookup happens" do
      set_base_currency("USD")
      connect_shopify()
      explode_stub()

      product = create_product(%{"price" => "10.00"})

      change =
        build_change(product, %{
          price: %{current: Decimal.new("10.00"), incoming: Decimal.new("12.00")},
          title: %{current: "Old Title", incoming: "New Title"}
        })

      assert {:ok, updated} =
               Sync.apply_change(change, :all, currency_verdict: {:mismatch, "EUR", "USD"})

      assert updated.title["en"] == "New Title"
      assert Decimal.eq?(updated.price, Decimal.new("10.00"))
    end

    test "apply_changes/3 accepts the same precomputed verdict, still applied once across the whole batch" do
      set_base_currency("USD")
      connect_shopify()
      explode_stub()

      p1 = create_product(%{"title" => %{"en" => "First"}, "price" => "10.00"})
      p2 = create_product(%{"title" => %{"en" => "Second"}, "price" => "10.00"})

      c1 =
        build_change(p1, %{
          price: %{current: Decimal.new("10.00"), incoming: Decimal.new("11.00")}
        })

      c2 =
        build_change(p2, %{
          price: %{current: Decimal.new("10.00"), incoming: Decimal.new("12.00")}
        })

      assert %{succeeded: [], failed: [_c1, _c2]} =
               Sync.apply_changes([c1, c2], [:price], currency_verdict: {:mismatch, "EUR", "USD"})
    end

    test "omitting :currency_verdict still falls back to a fresh lookup (default unchanged)" do
      set_base_currency("USD")
      connect_shopify()
      stub_shop_currency("EUR")

      product = create_product(%{"price" => "10.00"})

      change =
        build_change(product, %{
          price: %{current: Decimal.new("10.00"), incoming: Decimal.new("12.00")}
        })

      assert {:error, {:currency_mismatch, "EUR", "USD"}} =
               Sync.apply_change(change, [:price], admin_options())
    end
  end

  describe "currency guard — create path" do
    @describetag :catalogue

    defp new_product_change(overrides \\ %{}) do
      shopify_product =
        Map.merge(
          %{
            "handle" => "currency-mug",
            "title" => "Currency Mug",
            "id" => 4242,
            "status" => "active",
            "variants" => [%{"price" => "9.00"}]
          },
          overrides
        )

      %Change{
        product_uuid: nil,
        handle: shopify_product["handle"],
        title: shopify_product["title"],
        base_locale: "en",
        shopify_product: shopify_product,
        product_id: shopify_product["id"],
        create?: true
      }
    end

    # "decor3dprint" is `Query.catalogue_uuid/0`'s own default name
    # (`shop_catalogue` config unset) — `create_from_shopify/2` looks up
    # the catalogue by that name, not by any catalogue existing.
    setup do
      {:ok, _catalogue} = Catalogue.create_catalogue(%{name: "decor3dprint"})
      :ok
    end

    test "shop currency matches base: a newly-created product's ecommerce data carries the base currency label" do
      set_base_currency("USD")

      assert {:ok, created_view} = Sync.apply_change(new_product_change())

      item = Catalogue.get_item!(created_view.uuid)
      assert item.data["ecommerce"]["currency"] == "USD"
      assert Decimal.equal?(item.base_price, Decimal.new("9.00"))
    end

    # `Writer.base_currency_code/0`'s "USD" fallback is right (it matches
    # `ProductSource.Catalogue.View`'s own read-side fallback), but §4.9
    # warns this is exactly the edge case that hurts when it's silently
    # wrong — it should not be the one branch nothing exercises. No
    # currency row exists at all here (not even a non-default one), so
    # `PhoenixKitEcommerce.get_base_currency/0` returns `nil` and
    # `Sync.currency_verdict/1`'s own `compare_currency/1` falls back to
    # `:match` for the same reason — this create is never refused, it's
    # just labelled "USD" by default.
    test "no base currency configured at all: falls back to USD" do
      PhoenixKit.Cache.clear(:billing_currencies)
      Repo.delete_all(PhoenixKitBilling.Currency)

      assert {:ok, created_view} = Sync.apply_change(new_product_change())

      item = Catalogue.get_item!(created_view.uuid)
      assert item.data["ecommerce"]["currency"] == "USD"
    end

    # A create is the WORSE case, not a safer one: an update at least
    # leaves an existing, correct price alone, while a create would mint
    # a brand-new record whose price is wrong from the moment it exists
    # (labelled with the base currency unconditionally by
    # create_ecommerce_params/1), with no prior value anywhere to reveal
    # the mistake. So the whole create is refused, not created without a
    # price or with a wrong one.
    test "shop currency differs from base: the create is refused outright, nothing is created" do
      set_base_currency("USD")
      connect_shopify()
      stub_shop_currency("EUR")

      assert {:error, {:currency_mismatch, "EUR", "USD"}} =
               Sync.apply_change(new_product_change(), :all, admin_options())

      assert Catalogue.list_items() == []
    end
  end
end
