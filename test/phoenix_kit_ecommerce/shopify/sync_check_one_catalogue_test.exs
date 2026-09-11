defmodule PhoenixKitEcommerce.Shopify.SyncCheckOneCatalogueTest do
  @moduledoc """
  `Sync.check_one/3` against a REAL catalogue-backed item — the path the
  live shop actually runs (`ProductSource.Catalogue`, not `Legacy`;
  see the catalogue-as-product-list decision). `SyncCheckOneTest`'s
  legacy-product coverage never touches the piece this file exists to
  pin: `check_one/3` reads `product.metadata["_shopify"]["product_id"]`
  off a catalogue item's VIEW-STRUCT, and that sub-map is not a stored
  column — it's a projection `ProductSource.Catalogue.View.product_view/2`
  builds fresh from `data["ecommerce"]["shopify"]` on every read
  (`maybe_put("_shopify", Map.get(ecommerce, "shopify"))`). If that
  projection is ever renamed or stops being written, `check_one/3`
  degrades silently to `{:error, :not_linked}` on a product that IS
  linked — a wrong answer no legacy-only test can catch, since the
  legacy adapter never builds this projection at all.

  Needs `phoenix_kit_catalogue` loaded (with its own migrations applied
  to the test DB) — excluded via `test_helper.exs`'s `catalogue_exclude`
  whenever the optional dependency isn't present, same as
  `SyncCatalogueTest`, whose fixture setup (`set_product_source/1`, the
  `Catalogue.create_item/1` shape) this file mirrors. `async: false`:
  flips the process-wide `shop_product_source` config key, same reason
  `SyncCatalogueTest` is.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  @moduletag :catalogue

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}

  alias PhoenixKit.Integrations
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce.ShopConfig
  alias PhoenixKitEcommerce.Shopify.Sync
  alias PhoenixKitEcommerce.Test.Repo

  @stub __MODULE__

  setup do
    set_product_source("catalogue")
    on_exit(fn -> set_product_source("legacy") end)

    {:ok, catalogue} = Catalogue.create_catalogue(%{name: "decor3dprint"})

    {:ok, item} =
      Catalogue.create_item(%{
        catalogue_uuid: catalogue.uuid,
        name: "Ceramic Vase",
        base_price: Decimal.new("25.00"),
        status: "active",
        data: %{
          "_primary_language" => "en",
          "en" => %{},
          "ecommerce" => %{
            "shop_status" => "active",
            "shopify" => %{"handle" => "ceramic-vase", "product_id" => 555}
          }
        }
      })

    %{catalogue: catalogue, item: item}
  end

  # Same helper `SyncCatalogueTest` uses — no `update_config/2` setter
  # exists yet, so this writes the `phoenix_kit_shop_config` row directly.
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

  defp check_one_opts(extra \\ []) do
    Keyword.merge([admin_options: [req_options: [plug: {Req.Test, @stub}]]], extra)
  end

  defp json_response(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, JSON.encode!(body))
  end

  describe "check_one/3 against a catalogue-backed item" do
    test "reads product_id off the catalogue view's projected metadata, fetches by id, diffs, and the resulting Change writes through the catalogue Writer via apply_change/3",
         %{item: item} do
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn ->
        assert conn.request_path == "/admin/api/2025-01/products/555.json"

        json_response(conn, 200, %{
          "product" => %{
            "id" => 555,
            "handle" => "ceramic-vase",
            "title" => "Ceramic Vase Deluxe",
            "status" => "active",
            "variants" => [%{"price" => "30.00"}]
          }
        })
      end)

      assert {:ok, %{source: :admin, changes: [change]}} =
               Sync.check_one(uuid, item.uuid, check_one_opts())

      assert change.product_uuid == item.uuid
      assert change.changes.title == %{current: "Ceramic Vase", incoming: "Ceramic Vase Deluxe"}
      assert Decimal.eq?(change.changes.price.incoming, Decimal.new("30.00"))

      # The Change from check_one/3 must be usable exactly like one from
      # check/2 — same catalogue-Writer dispatch inside apply_change/3.
      assert {:ok, updated_view} = Sync.apply_change(change)
      assert updated_view.title["en"] == "Ceramic Vase Deluxe"

      updated_item = Catalogue.get_item!(item.uuid)
      assert updated_item.name == "Ceramic Vase Deluxe"
      assert Decimal.equal?(updated_item.base_price, Decimal.new("30.00"))
      # The shopify identity survives the write untouched — same
      # assertion `SyncCatalogueTest` makes on its own apply path.
      assert updated_item.data["ecommerce"]["shopify"]["handle"] == "ceramic-vase"
    end

    test "a catalogue item with no shopify link at all is :not_linked", %{catalogue: catalogue} do
      {:ok, unlinked_item} =
        Catalogue.create_item(%{
          catalogue_uuid: catalogue.uuid,
          name: "No Link",
          base_price: Decimal.new("10.00"),
          status: "active",
          data: %{"_primary_language" => "en", "en" => %{}}
        })

      uuid = connect_shopify()

      assert {:error, :not_linked} = Sync.check_one(uuid, unlinked_item.uuid, check_one_opts())
    end

    test "the linked product id no longer exists in Shopify", %{item: item} do
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn -> json_response(conn, 404, %{"errors" => "Not Found"}) end)

      assert {:error, :not_found_in_shopify} = Sync.check_one(uuid, item.uuid, check_one_opts())
    end
  end
end
