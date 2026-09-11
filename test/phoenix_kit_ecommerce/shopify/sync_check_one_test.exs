defmodule PhoenixKitEcommerce.Shopify.SyncCheckOneTest do
  @moduledoc """
  `Sync.check_one/3` — the single-product counterpart to `check/2`: given
  an already-linked local product, fetch and diff exactly that ONE
  Shopify product instead of pulling the whole catalog.

  Uses the legacy product path throughout (`metadata` is a plain,
  directly-castable field on `PhoenixKitEcommerce.Product`, so a test can
  set `metadata["_shopify"]["product_id"]`/`["handle"]` itself without a
  real catalogue item) — the same convention `ProductDiff`'s own
  `metadata["_shopify"]` handle-matching tests use. `check_one/3` reads
  the link off whatever `Shop.get_product/2` returns, so it works
  identically against a catalogue-backed view-struct in production; no
  source-specific behavior lives in `check_one/3` itself worth
  duplicating this coverage for.
  """

  use PhoenixKitEcommerce.DataCase, async: true

  alias PhoenixKit.Integrations
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Shopify.Sync

  @stub __MODULE__

  defp create_product(attrs) do
    defaults = %{"title" => %{"en" => "Old Title"}, "price" => "10.00", "vendor" => "Old Co"}
    {:ok, product} = Shop.create_product(Map.merge(defaults, attrs))
    product
  end

  defp create_linked_product(attrs \\ %{}, shopify_link \\ %{}) do
    link = Map.merge(%{"product_id" => "555", "handle" => "ceramic-vase"}, shopify_link)
    metadata = %{"_shopify" => link}
    create_product(Map.merge(%{"metadata" => metadata}, attrs))
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

  describe "check_one/3 — happy path" do
    test "fetches by the linked product id and reports a diff, matching check/2's Change shape" do
      uuid = connect_shopify()

      product =
        create_linked_product(%{
          "title" => %{"en" => "Old Title"},
          "vendor" => "Old Co",
          "price" => "10.00"
        })

      Req.Test.stub(@stub, fn conn ->
        assert conn.request_path == "/admin/api/2025-01/products/555.json"

        json_response(conn, 200, %{
          "product" => %{
            "id" => 555,
            "handle" => "ceramic-vase",
            "title" => "New Title",
            "vendor" => "New Co",
            "status" => "draft",
            "variants" => [%{"price" => "15.00"}]
          }
        })
      end)

      assert {:ok, %{source: :admin, changes: [change]}} =
               Sync.check_one(uuid, product.uuid, check_one_opts())

      assert change.product_uuid == product.uuid
      assert change.base_locale == "en"
      assert Map.keys(change.changes) |> Enum.sort() == [:price, :title, :vendor]
      assert change.changes.title == %{current: "Old Title", incoming: "New Title"}
      assert Decimal.eq?(change.changes.price.incoming, Decimal.new("15.00"))

      # A `Change` from check_one/3 must be usable exactly like one from
      # check/2 — same struct, same apply_change/3 entry point.
      assert {:ok, updated} = Sync.apply_change(change, [:vendor])
      assert updated.vendor == "New Co"
    end

    test "reports no changes when nothing differs" do
      uuid = connect_shopify()
      product = create_linked_product(%{"vendor" => "Old Co", "price" => "10.00"})

      Req.Test.stub(@stub, fn conn ->
        json_response(conn, 200, %{
          "product" => %{
            "id" => 555,
            "handle" => "ceramic-vase",
            "title" => "Old Title",
            "vendor" => "Old Co",
            "status" => "draft",
            "variants" => [%{"price" => "10.00"}]
          }
        })
      end)

      assert {:ok, %{source: :admin, changes: []}} =
               Sync.check_one(uuid, product.uuid, check_one_opts())
    end

    test "respects the given :base_locale for matching and diffing" do
      uuid = connect_shopify()

      product =
        create_linked_product(%{
          "title" => %{"en" => "Old Title", "ru" => "Старое название"}
        })

      Req.Test.stub(@stub, fn conn ->
        json_response(conn, 200, %{
          "product" => %{
            "id" => 555,
            "handle" => "ceramic-vase",
            "title" => "Новое название",
            "status" => "draft"
          }
        })
      end)

      assert {:ok, %{changes: [change]}} =
               Sync.check_one(uuid, product.uuid, check_one_opts(base_locale: "ru"))

      assert change.changes.title == %{
               current: "Старое название",
               incoming: "Новое название"
             }
    end
  end

  describe "check_one/3 — not linked" do
    test "a product with no shopify link at all" do
      uuid = connect_shopify()
      product = create_product(%{})

      assert {:error, :not_linked} = Sync.check_one(uuid, product.uuid, check_one_opts())
    end

    test "a product whose metadata carries a handle but no product_id" do
      uuid = connect_shopify()
      product = create_product(%{"metadata" => %{"_shopify" => %{"handle" => "ceramic-vase"}}})

      assert {:error, :not_linked} = Sync.check_one(uuid, product.uuid, check_one_opts())
    end
  end

  describe "check_one/3 — local product not found" do
    test "an unknown uuid" do
      uuid = connect_shopify()

      assert {:error, :not_found} =
               Sync.check_one(uuid, Ecto.UUID.generate(), check_one_opts())
    end
  end

  describe "check_one/3 — remote lookup failures" do
    test "the linked product id no longer exists in Shopify" do
      uuid = connect_shopify()
      product = create_linked_product()

      Req.Test.stub(@stub, fn conn -> json_response(conn, 404, %{"errors" => "Not Found"}) end)

      assert {:error, :not_found_in_shopify} =
               Sync.check_one(uuid, product.uuid, check_one_opts())
    end

    test "an Admin API failure (e.g. a rejected token) is returned as-is, not disguised as a diff result" do
      uuid = connect_shopify()
      product = create_linked_product()

      Req.Test.stub(@stub, fn conn ->
        json_response(conn, 401, %{"errors" => "Invalid API key"})
      end)

      assert {:error, :unauthorized} = Sync.check_one(uuid, product.uuid, check_one_opts())
    end
  end

  describe "check_one/3 — handle mismatch" do
    # `diff/4` (reused here, unmodified — see `Sync.check_one/3`'s own
    # moduledoc) matches strictly by handle. A product renamed on
    # Shopify's side (fetched correctly, by id) no longer matches the
    # local `metadata["_shopify"]["handle"]`, so this reports NO changes
    # even though the title/handle plainly differ — a known limitation
    # inherited from reusing `diff/4` unchanged, not a bug in
    # `check_one/3` itself.
    test "a renamed Shopify handle is fetched but not matched, and reports no changes" do
      uuid = connect_shopify()
      product = create_linked_product(%{"title" => %{"en" => "Old Title"}})

      Req.Test.stub(@stub, fn conn ->
        json_response(conn, 200, %{
          "product" => %{
            "id" => 555,
            "handle" => "renamed-handle",
            "title" => "New Title",
            "status" => "draft"
          }
        })
      end)

      assert {:ok, %{source: :admin, changes: []}} =
               Sync.check_one(uuid, product.uuid, check_one_opts())
    end
  end
end
