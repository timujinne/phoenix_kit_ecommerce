defmodule PhoenixKitEcommerce.CategoryTreeLockTest do
  @moduledoc """
  A category re-parent holds the shop's category-tree lock through its
  cycle check, so two in opposite directions at once cannot both pass and
  commit a loop. The sandbox runs every test on one connection and cannot
  race, so this holds the lock from a second, real connection and watches
  a re-parent wait. That pins "the lock is taken on a re-parent, a move to
  the top level included, and not on a rename"; the two-writer race itself
  was proved on a live node, not here.
  """
  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Test.Repo

  @key "phoenix_kit_ecommerce:category_tree"

  defp holder do
    opts = Keyword.take(Repo.config(), [:hostname, :port, :username, :password, :database])
    # Linked: it ends with the test, releasing whatever it still holds.
    {:ok, conn} = Postgrex.start_link(opts)
    conn
  end

  defp category!(name) do
    {:ok, category} = Shop.create_category(%{name: %{"en" => name}})
    category
  end

  test "a re-parent waits for the category-tree lock; a rename does not" do
    [a, b] = [category!("A"), category!("B")]
    conn = holder()
    Postgrex.query!(conn, "SELECT pg_advisory_lock(hashtext($1))", [@key])

    assert {:ok, a} = Shop.update_category(a, %{name: %{"en" => "A2"}})

    move = Task.async(fn -> Shop.update_category(a, %{parent_uuid: b.uuid}) end)
    assert Task.yield(move, 300) == nil

    Postgrex.query!(conn, "SELECT pg_advisory_unlock(hashtext($1))", [@key])
    assert {:ok, moved} = Task.await(move)
    assert moved.parent_uuid == b.uuid
  end

  # The child is created under its parent: a re-parent here would hold the
  # transaction-level lock for the rest of this sandboxed test.
  test "a move to the top level waits for the lock too" do
    b = category!("B")
    {:ok, a} = Shop.create_category(%{name: %{"en" => "A"}, parent_uuid: b.uuid})
    conn = holder()
    Postgrex.query!(conn, "SELECT pg_advisory_lock(hashtext($1))", [@key])

    up = Task.async(fn -> Shop.update_category(a, %{"parent_uuid" => ""}) end)
    assert Task.yield(up, 300) == nil

    Postgrex.query!(conn, "SELECT pg_advisory_unlock(hashtext($1))", [@key])
    assert {:ok, moved} = Task.await(up)
    assert moved.parent_uuid == nil
  end

  test "a bulk move to the top level waits for the lock too" do
    b = category!("B")
    {:ok, a} = Shop.create_category(%{name: %{"en" => "A"}, parent_uuid: b.uuid})
    conn = holder()
    Postgrex.query!(conn, "SELECT pg_advisory_lock(hashtext($1))", [@key])

    up = Task.async(fn -> Shop.bulk_update_category_parent([a.uuid], nil) end)
    assert Task.yield(up, 300) == nil

    Postgrex.query!(conn, "SELECT pg_advisory_unlock(hashtext($1))", [@key])
    assert Task.await(up) == 1
    assert Repo.reload(a).parent_uuid == nil
  end

  test "a delete waits for the lock too (the FK re-parents its children)" do
    [a, b] = [category!("A"), category!("B")]
    {:ok, _} = Shop.create_category(%{name: %{"en" => "A child"}, parent_uuid: a.uuid})
    conn = holder()
    Postgrex.query!(conn, "SELECT pg_advisory_lock(hashtext($1))", [@key])

    del = Task.async(fn -> Shop.delete_category(a) end)
    assert Task.yield(del, 300) == nil
    bulk = Task.async(fn -> Shop.bulk_delete_categories([b.uuid]) end)
    assert Task.yield(bulk, 300) == nil

    Postgrex.query!(conn, "SELECT pg_advisory_unlock(hashtext($1))", [@key])
    assert {:ok, _} = Task.await(del)
    assert Task.await(bulk) == 1
  end
end
