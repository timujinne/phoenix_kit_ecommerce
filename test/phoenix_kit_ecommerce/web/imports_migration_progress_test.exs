defmodule PhoenixKitEcommerce.Web.ImportsMigrationProgressTest do
  @moduledoc """
  The image migration announces itself from `Services.ImageMigration` and
  its worker; the imports page listens. These go through the real publishing
  functions, so a publisher and a subscriber on different PubSub servers —
  which leaves the page frozen until a manual refresh — fails here.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitEcommerce.Events
  alias PhoenixKitEcommerce.Services.ImageMigration

  @page "/en/admin/shop/imports"

  setup %{conn: conn} do
    scope = fake_scope()
    {:ok, conn: put_test_scope(conn, scope), user_uuid: scope.user.uuid}
  end

  test "starting and cancelling the migration reach the open page", ctx do
    {:ok, view, html} = live(ctx.conn, @page)
    refute html =~ "Cancel Migration"

    {:ok, _queued} = ImageMigration.queue_all_migrations(ctx.user_uuid)
    assert render(view) =~ "Cancel Migration"

    {:ok, _cancelled} = ImageMigration.cancel_pending_migrations()
    refute render(view) =~ "Cancel Migration"
  end

  test "a burst of per-product messages refreshes the stats once, after the interval", ctx do
    {:ok, view, _html} = live(ctx.conn, @page)
    message = {:product_migrated, %{product_uuid: Ecto.UUID.generate(), images_migrated: 1}}

    for _ <- 1..5, do: send(view.pid, message)
    _ = render(view)

    assigns = fn -> :sys.get_state(view.pid).socket.assigns end
    assert assigns.().migration_stats_refresh_pending

    Process.sleep(1_200)
    _ = render(view)
    refute assigns.().migration_stats_refresh_pending
  end

  test "the topics the pages subscribe to are the ones the workers publish on" do
    uuid = Ecto.UUID.generate()

    Events.subscribe_imports()
    Events.subscribe_import(uuid)
    Events.subscribe_image_migration()

    Events.broadcast_imports({:import_complete, %{import_log_uuid: uuid}})
    Events.broadcast_import(uuid, {:import_started, %{total: 3}})
    Events.broadcast_image_migration_batch({:migration_started, %{total: 1}})

    assert_receive {:import_complete, %{import_log_uuid: ^uuid}}
    assert_receive {:import_started, %{total: 3}}
    assert_receive {:migration_started, %{total: 1}}
  end
end
