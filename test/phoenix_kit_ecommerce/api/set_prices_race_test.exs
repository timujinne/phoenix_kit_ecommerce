defmodule PhoenixKitEcommerce.API.SetPricesRaceTest do
  @moduledoc """
  `ecommerce.set_prices` against a price that another writer changes while the
  call is being written, and `ecommerce.set_availability` against a price
  removed while a publish call waits for the item lock.

  The SQL sandbox wraps a test in one transaction, so two writers cannot meet
  there. This test runs both on real connections (`unboxed_run`, as the cart's
  race tests do): an editor locks the product row and moves the price, the
  call plans from the price it can still read and then waits for the row, the
  editor commits, and the call goes on. Without the check inside the write
  the call stores its figure over the editor's, a figure that was judged against
  a price that is no longer there.

  `async: false`: it commits to a shared database. What it creates (a
  catalogue with a product, the shop's product-source rows) is removed or put
  back afterwards.
  """

  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitCatalogue.Schemas.Catalogue, as: CatalogueSchema
  alias PhoenixKitCatalogue.Schemas.Item
  alias PhoenixKitEcommerce.API.SetAvailability
  alias PhoenixKitEcommerce.API.SetPrices
  alias PhoenixKitEcommerce.APIFixtures, as: F
  alias PhoenixKitEcommerce.ShopConfig
  alias PhoenixKitEcommerce.Test.Repo

  @moduletag :integration
  @moduletag :catalogue_api
  @moduletag :core_confirm

  @config_keys ["shop_product_source", "shop_catalogue"]

  setup do
    previous = unboxed(fn -> Map.new(@config_keys, &{&1, Repo.get(ShopConfig, &1)}) end)

    {catalogue, item} =
      unboxed(fn ->
        catalogue = F.shop_catalogue!()
        {catalogue, F.item!(catalogue, %{base_price: Decimal.new("100.00")})}
      end)

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(from(i in Item, where: i.catalogue_uuid == ^catalogue.uuid))
        Repo.delete_all(from(c in CatalogueSchema, where: c.uuid == ^catalogue.uuid))
        Enum.each(previous, &restore_config/1)
      end)
    end)

    %{item: item}
  end

  defp restore_config({key, nil}),
    do: Repo.delete_all(from(c in ShopConfig, where: c.key == ^key))

  defp restore_config({key, %ShopConfig{value: %{"value" => value}}}),
    do: F.put_config!(key, value)

  defp ctx do
    F.ctx(%{uuid: nil})
  end

  defp price(item) do
    unboxed(fn ->
      Repo.one(from(i in Item, where: i.uuid == ^item.uuid, select: i.base_price))
    end)
  end

  # The editor: locks the row, moves the price, and holds the transaction open
  # until told to commit.
  defp editor_changes_price(item, price) do
    editor_changes_item(item, base_price: price)
  end

  defp editor_changes_item(item, changes) do
    parent = self()
    transaction = fn -> Repo.transaction(fn -> hold_row(item, changes, parent) end) end

    Task.async(fn -> unboxed(transaction) end)
  end

  defp hold_row(item, changes, parent) do
    Repo.one(from(i in Item, where: i.uuid == ^item.uuid, lock: "FOR UPDATE", select: i.uuid))
    Repo.update_all(from(i in Item, where: i.uuid == ^item.uuid), set: changes)
    send(parent, :editor_holds_the_row)

    receive do
      :commit -> :ok
    end
  end

  # Whether some connection of the test database waits for a lock.
  defp lock_waiter? do
    unboxed(fn ->
      %{rows: [[waiting]]} =
        Repo.query!("""
        SELECT count(*) FROM pg_stat_activity
        WHERE datname = current_database() AND wait_event_type = 'Lock'
        """)

      waiting > 0
    end)
  end

  defp await_lock_waiter(0), do: flunk("the call never waited for the row")

  defp await_lock_waiter(attempts) do
    if lock_waiter?() do
      :ok
    else
      Process.sleep(50)
      await_lock_waiter(attempts - 1)
    end
  end

  test "a price the editor committed while the call waited for the row is not overwritten",
       %{item: item} do
    input = %{"items" => [%{"ref" => %{"id" => item.uuid}, "price" => "101.00"}]}
    editor = editor_changes_price(item, Decimal.new("1000.00"))
    assert_receive :editor_holds_the_row, 5_000

    # The call reads 100.00 (the editor has not committed), plans a 1 percent
    # move, and waits for the row.
    call = Task.async(fn -> unboxed(fn -> SetPrices.run(input, ctx()) end) end)
    await_lock_waiter(100)

    send(editor.pid, :commit)
    {:ok, :ok} = Task.await(editor, 10_000)

    assert {:ok, %{"results" => [result], "summary" => %{"error" => 1, "updated" => 0}}} =
             Task.await(call, 10_000)

    assert result["error"]["context"]["reason"] == "changed_since_planned"
    assert Decimal.equal?(price(item), Decimal.new("1000.00"))
  end

  test "the call goes through when nobody changed the price", %{item: item} do
    input = %{"items" => [%{"ref" => %{"id" => item.uuid}, "price" => "101.00"}]}

    assert {:ok, %{"summary" => %{"updated" => 1}}} =
             unboxed(fn -> SetPrices.run(input, ctx()) end)

    assert Decimal.equal?(price(item), Decimal.new("101.00"))
  end

  test "availability cannot publish a product whose price was removed while it waited", %{
    item: item
  } do
    draft = put_in(item.data, ["ecommerce", "shop_status"], "draft")

    unboxed(fn ->
      Repo.update_all(from(i in Item, where: i.uuid == ^item.uuid), set: [data: draft])
    end)

    editor = editor_changes_item(item, base_price: nil)
    assert_receive :editor_holds_the_row, 5_000

    input = %{"items" => [%{"ref" => %{"id" => item.uuid}, "visibility" => "active"}]}
    call = Task.async(fn -> unboxed(fn -> SetAvailability.run(input, ctx()) end) end)
    await_lock_waiter(100)

    send(editor.pid, :commit)
    {:ok, :ok} = Task.await(editor, 10_000)

    assert {:ok, %{"results" => [result], "summary" => %{"error" => 1, "updated" => 0}}} =
             Task.await(call, 10_000)

    assert result["error"]["context"]["reason"] == "changed_since_planned"
    assert unboxed(fn -> F.reload!(item).data end) == draft
    assert price(item) == nil
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end
