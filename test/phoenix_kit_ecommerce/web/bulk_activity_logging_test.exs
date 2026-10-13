defmodule PhoenixKitEcommerce.Web.BulkActivityLoggingTest do
  @moduledoc """
  Mutations that used to leave no audit row beside siblings that did: the
  bulk category / parent moves, the image migration's start and cancel, and
  a category's own option list. Driven through the LiveViews, since that is
  where the row is written.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitEcommerce, as: Shop

  setup %{conn: conn} do
    scope = fake_scope()
    {:ok, conn: put_test_scope(conn, scope), actor: scope.user.uuid}
  end

  defp product(n) do
    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Audit Widget #{n}"},
        "price" => Decimal.new("12.00"),
        "status" => "active"
      })

    product
  end

  defp category(name) do
    {:ok, category} =
      Shop.create_category(%{
        "name" => %{"en" => "#{name} #{System.unique_integer([:positive])}"}
      })

    category
  end

  test "moving products to a category in bulk is logged with the count", ctx do
    %{conn: conn, actor: actor} = ctx
    target = category("Target")
    uuids = for n <- 1..2, do: product(n).uuid

    {:ok, view, _html} = live(conn, "/en/admin/shop/products")
    render_hook(view, "open_category_modal", %{"uuids" => uuids})
    render_click(view, "bulk_change_category", %{"category_uuid" => target.uuid})

    assert_activity_logged("shop.products_category_changed",
      actor_uuid: actor,
      metadata_has: %{"count" => 2}
    )

    assert Enum.all?(uuids, &(Shop.get_product!(&1).category_uuid == target.uuid))
  end

  test "moving categories under a parent in bulk is logged with the count", ctx do
    %{conn: conn, actor: actor} = ctx
    parent = category("Parent")
    child = category("Child")

    {:ok, view, _html} = live(conn, "/en/admin/shop/categories")
    render_hook(view, "open_parent_modal", %{"uuids" => [child.uuid]})
    render_click(view, "bulk_change_parent", %{"parent_uuid" => parent.uuid})

    assert_activity_logged("shop.categories_parent_changed",
      actor_uuid: actor,
      metadata_has: %{"count" => 1}
    )
  end

  test "starting and cancelling the image migration are logged", %{conn: conn, actor: actor} do
    {:ok, view, _html} = live(conn, "/en/admin/shop/imports")

    render_click(view, "start_image_migration", %{})
    assert_activity_logged("shop.image_migration_started", actor_uuid: actor)

    render_click(view, "cancel_image_migration", %{})
    assert_activity_logged("shop.image_migration_cancelled", actor_uuid: actor)
  end

  test "saving, reordering and deleting a category's options are logged", ctx do
    %{conn: conn, actor: actor} = ctx
    category = category("With Options")

    {:ok, view, _html} = live(conn, "/en/admin/shop/categories/#{category.uuid}/edit")

    for {key, label} <- [{"finish", "Finish"}, {"engraving", "Engraving"}] do
      render_click(view, "show_add_opt_modal", %{})

      render_submit(view, "save_category_option", %{
        "option" => %{"key" => key, "label" => label, "type" => "text"}
      })
    end

    assert_activity_logged("shop.category_option_saved",
      actor_uuid: actor,
      resource_uuid: category.uuid,
      metadata_has: %{"count" => 2}
    )

    render_hook(view, "reorder_category_options", %{"ordered_ids" => ["engraving", "finish"]})

    assert_activity_logged("shop.category_option_reordered",
      actor_uuid: actor,
      resource_uuid: category.uuid,
      metadata_has: %{"count" => 2}
    )

    render_click(view, "delete_category_option", %{"key" => "finish"})

    assert_activity_logged("shop.category_option_deleted",
      actor_uuid: actor,
      resource_uuid: category.uuid,
      metadata_has: %{"key" => "finish"}
    )
  end
end
