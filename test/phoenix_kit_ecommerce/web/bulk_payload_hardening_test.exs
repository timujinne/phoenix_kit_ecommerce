defmodule PhoenixKitEcommerce.Web.BulkPayloadHardeningTest do
  @moduledoc """
  The bulk selection and its target arrive from the browser. A payload that
  is not a list of uuids, or a target that is not a uuid, must neither reach
  a query (`Ecto.Query.CastError` takes the LiveView down) nor act.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Web.Helpers

  setup %{conn: conn} do
    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  defp product do
    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Bulk Widget #{System.unique_integer([:positive])}"},
        "price" => Decimal.new("5.00"),
        "status" => "active"
      })

    product
  end

  describe "Helpers.cast_uuids/1 and cast_optional_uuid/1" do
    test "keep only uuids, and treat anything but a list as empty" do
      uuid = Ecto.UUID.generate()
      assert Helpers.cast_uuids([uuid, "junk", 5, nil]) == [uuid]
      assert Helpers.cast_uuids("junk") == []
      assert Helpers.cast_uuids(nil) == []
    end

    test "an optional target is a uuid, nothing, or an error" do
      uuid = Ecto.UUID.generate()
      assert Helpers.cast_optional_uuid(uuid) == {:ok, uuid}
      assert Helpers.cast_optional_uuid("") == {:ok, nil}
      assert Helpers.cast_optional_uuid("junk") == :error
      assert Helpers.cast_optional_uuid(%{}) == :error
    end
  end

  test "the products page survives a junk selection and a junk category", %{conn: conn} do
    keep = product()
    {:ok, view, _html} = live(conn, "/en/admin/shop/products")

    render_hook(view, "open_status_modal", %{"uuids" => ["junk", keep.uuid]})
    render_click(view, "bulk_change_status", %{"status" => "archived"})
    assert Shop.get_product!(keep.uuid).status == "archived"

    render_hook(view, "open_category_modal", %{"uuids" => "not-a-list"})
    assert render(view) =~ "Products"

    render_hook(view, "open_category_modal", %{"uuids" => [keep.uuid]})
    render_click(view, "bulk_change_category", %{"category_uuid" => "junk"})
    assert Shop.get_product!(keep.uuid).category_uuid == nil
    assert Process.alive?(view.pid)
  end

  test "the categories page survives a junk selection and a junk parent", %{conn: conn} do
    {:ok, child} = Shop.create_category(%{"name" => %{"en" => "Child"}})
    {:ok, view, _html} = live(conn, "/en/admin/shop/categories")

    render_hook(view, "open_parent_modal", %{"uuids" => ["junk", child.uuid]})
    render_click(view, "bulk_change_parent", %{"parent_uuid" => "junk"})
    assert Process.alive?(view.pid)
    assert Shop.get_category!(child.uuid).parent_uuid == nil

    render_hook(view, "confirm_bulk_delete", %{"uuids" => 7})
    assert render(view) =~ "Categories"
  end
end
