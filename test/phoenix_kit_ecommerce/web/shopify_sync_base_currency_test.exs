defmodule PhoenixKitEcommerce.Web.ShopifySyncBaseCurrencyTest do
  @moduledoc """
  The Shopify sync page on a shop with no base currency: a price written
  then would have no currency to mean, so the page says why, links to the
  currency settings, and offers no action that writes one — while every
  non-price action keeps working.

  Tagged `:catalogue` for the "New in Shopify" and media panels (catalogue
  source only). `async: false`: flips the process-wide `shop_product_source`
  key, the currency cache and `Req.default_options/1`.
  """

  use PhoenixKitEcommerce.LiveCase, async: false
  use Oban.Testing, repo: PhoenixKitEcommerce.Test.Repo

  @moduletag :catalogue

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}

  alias PhoenixKit.Integrations
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce.ProductSource.Catalogue.Query, as: CatalogueQuery
  alias PhoenixKitEcommerce.ShopConfig
  alias PhoenixKitEcommerce.Test.Repo
  alias PhoenixKitEcommerce.Workers.ShopifyMediaSyncWorker

  @stub __MODULE__

  defp set_product_source(value) do
    case Repo.get(ShopConfig, "shop_product_source") do
      nil ->
        %ShopConfig{}
        |> ShopConfig.changeset(%{key: "shop_product_source", value: %{"value" => value}})
        |> Repo.insert!()

      config ->
        config
        |> ShopConfig.changeset(%{value: %{"value" => value}})
        |> Repo.update!()
    end
  end

  defp connect_shopify do
    enable_shopify!()

    {:ok, %{uuid: uuid}} =
      Integrations.add_connection("shopify", "Test Shop #{System.unique_integer([:positive])}")

    {:ok, _} =
      Integrations.save_setup(uuid, %{
        "shop_domain" => "test-shop.myshopify.com",
        "access_token" => "shpat_test_token"
      })

    uuid
  end

  defp clear_base_currency do
    PhoenixKit.Cache.clear(:billing_currencies)
    Repo.delete_all(PhoenixKitBilling.Currency)
    :ok
  end

  defp set_base_currency(code) do
    clear_base_currency()

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

  defp json_response(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, JSON.encode!(body))
  end

  # One matched product (title and price both differ) and one unmatched.
  defp stub_products do
    Req.Test.stub(@stub, fn conn ->
      if String.ends_with?(conn.request_path, "/shop.json") do
        json_response(conn, 200, %{"shop" => %{"currency" => "USD"}})
      else
        json_response(conn, 200, %{
          "products" => [
            %{
              "id" => 101,
              "handle" => "known-mug",
              "title" => "Known Mug (renamed)",
              "status" => "active",
              "variants" => [%{"price" => "12.00"}]
            },
            %{
              "id" => 202,
              "handle" => "brand-new-mug",
              "title" => "Brand New Mug",
              "status" => "active",
              "variants" => [%{"price" => "9.00"}]
            }
          ]
        })
      end
    end)
  end

  defp check_and_await(view) do
    view |> element("#check-shopify-changes") |> render_click()
    render_async(view, 500)
  end

  setup %{conn: conn} do
    set_product_source("catalogue")
    on_exit(fn -> set_product_source("legacy") end)

    {:ok, catalogue} = Catalogue.create_catalogue(%{name: "decor3dprint"})

    {:ok, item} =
      Catalogue.create_item(%{
        catalogue_uuid: catalogue.uuid,
        name: "Known Mug",
        base_price: Decimal.new("10.00"),
        status: "active",
        data: %{
          "_primary_language" => "en",
          "ecommerce" => %{"shop_status" => "active", "shopify" => %{"handle" => "known-mug"}}
        }
      })

    connect_shopify()
    Req.default_options(plug: {Req.Test, @stub})
    on_exit(fn -> Req.default_options([]) end)
    stub_products()

    {:ok, conn: put_test_scope(conn, fake_scope()), item: item}
  end

  describe "with a base currency" do
    setup do
      set_base_currency("USD")
    end

    test "no banner, and the price-bearing actions are offered", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync?tab=media")

      refute has_element?(view, "#shopify-no-base-currency")
      refute has_element?(view, "#sync-media-variants[disabled]")

      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync?tab=new")
      check_and_await(view)

      assert has_element?(view, "#add-new-product-brand-new-mug")
      refute has_element?(view, "#add-new-product-brand-new-mug[disabled]")
      refute has_element?(view, "#add-all-new-products[disabled]")
    end
  end

  describe "without a base currency" do
    setup do
      clear_base_currency()
    end

    test "a banner on every tab names the cause and links to the currency settings",
         %{conn: conn} do
      conn = put_test_scope(conn, fake_scope(permissions: shop_permissions() ++ ["billing"]))

      for tab <- ~w(changes new media settings) do
        {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync?tab=#{tab}")

        assert has_element?(view, "#shopify-no-base-currency", "no base currency")

        assert has_element?(
                 view,
                 ~s(#shopify-no-base-currency a[href$="/admin/billing/currencies"])
               )
      end
    end

    # The currency settings are billing's page: a link to it shown to an
    # operator without billing access lands on an access-denied redirect.
    test "without billing access the banner still names the cause, with no link",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync?tab=media")

      assert has_element?(view, "#shopify-no-base-currency", "no base currency")
      refute has_element?(view, "#shopify-no-base-currency a")
    end

    test "the variants sync is disabled and refuses a pushed event; images still start",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync?tab=media")

      assert has_element?(view, "#sync-media-variants[disabled]")
      refute has_element?(view, "#sync-media-images[disabled]")
      refute has_element?(view, "#sync-media-collections[disabled]")

      render_click(view, "run_media_sync", %{"kind" => "variants"})
      refute_enqueued(worker: ShopifyMediaSyncWorker)

      render_click(element(view, "#sync-media-images"))
      assert_enqueued(worker: ShopifyMediaSyncWorker, args: %{"kind" => "images"})
    end

    test "\"New in Shopify\": both add buttons are disabled and a pushed request creates nothing",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync?tab=new")
      check_and_await(view)

      assert has_element?(view, "#add-new-product-brand-new-mug[disabled]")
      assert has_element?(view, "#add-all-new-products[disabled]")

      render_click(view, "request_apply_new_row", %{"handle" => "brand-new-mug"})
      render_click(view, "confirm_apply", %{})
      render_click(view, "request_apply_new_all", %{})
      render_click(view, "confirm_apply", %{})

      refute Catalogue.list_items_for_catalogue(CatalogueQuery.catalogue_uuid())
             |> Enum.any?(&(&1.data["ecommerce"]["shopify"]["handle"] == "brand-new-mug"))
    end

    test "the price section's apply actions are disabled; the title section's are not",
         %{conn: conn, item: item} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync?tab=changes")
      check_and_await(view)

      render_click(element(view, "#toggle-section-price"))
      render_click(element(view, "#toggle-section-title"))

      assert has_element?(view, "#apply-section-price[disabled]")
      assert has_element?(view, "#apply-row-price-#{item.uuid}[disabled]")
      assert has_element?(view, "#apply-selection-price[disabled]")

      refute has_element?(view, "#apply-section-title[disabled]")
      refute has_element?(view, "#apply-row-title-#{item.uuid}[disabled]")

      # A pushed price request opens no confirmation, so nothing can be confirmed.
      render_click(view, "request_apply_row", %{"field" => "price", "uuid" => item.uuid})
      render_click(view, "request_apply_section", %{"field" => "price"})
      render_click(view, "request_apply_selection:price", %{"uuids" => [item.uuid]})
      render_click(view, "confirm_apply", %{})

      assert Decimal.equal?(Catalogue.get_item!(item.uuid).base_price, Decimal.new("10.00"))
    end

    test "\"Apply everything\" writes the title, leaves the price unwritten and still listed",
         %{conn: conn, item: item} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shopify-sync?tab=changes")
      check_and_await(view)

      render_click(element(view, "#apply-everything"))
      html = render_click(view, "confirm_apply", %{})

      assert html =~ "Applied 1 change from Shopify."
      refute html =~ "Could not apply"

      reloaded = Catalogue.get_item!(item.uuid)
      assert reloaded.name == "Known Mug (renamed)"
      assert Decimal.equal?(reloaded.base_price, Decimal.new("10.00"))

      assert has_element?(view, "#field-section-price")
      refute has_element?(view, "#field-section-title")
      assert has_element?(view, "#apply-everything[disabled]")
    end
  end
end
