defmodule PhoenixKitEcommerce.Search.LegacyBulkTest do
  @moduledoc """
  On the Legacy source the bulk category change and the bulk delete broadcast
  nothing, so they put the reindex on the queue themselves. Until that job has
  run the index still holds the old rows: the count and the category filter
  lag, and the items, which are read live, never show a deleted product.

  `async: false`: Billing's currency cache is node-global.
  """
  use PhoenixKitEcommerce.DataCase, async: false

  import PhoenixKitEcommerce.SearchFixtures

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.API.Public.Search
  alias PhoenixKitEcommerce.Test.Repo
  alias PhoenixKitEcommerce.Workers.SearchReindexWorker

  setup do
    disable_languages!()
    currencies!()
    shop = sample_shop!()
    Repo.delete_all(Oban.Job)
    shop
  end

  defp jobs do
    from(j in Oban.Job, order_by: [asc: j.id], select: {j.worker, j.args})
    |> Repo.all()
    |> Enum.map(fn {worker, args} -> {worker |> String.split(".") |> List.last(), args} end)
  end

  defp items_job(uuids), do: {"SearchReindexWorker", %{"kind" => "items", "uuids" => uuids}}

  defp search!(input) do
    assert {:ok, out} = Search.search_products(input, public_ctx())
    out
  end

  defp run_queued_jobs do
    for {_worker, args} <- jobs(), do: :ok = SearchReindexWorker.perform(%Oban.Job{args: args})
  end

  test "bulk_update_product_category/2 enqueues a reindex of the products it moved", t do
    assert Shop.bulk_update_product_category([t.a, t.c], t.bowls) == 2

    assert jobs() == [items_job([t.a, t.c])]
  end

  test "a bulk category change that writes nothing enqueues nothing", t do
    assert Shop.bulk_update_product_category([Ecto.UUID.generate()], t.bowls) == 0
    assert Shop.bulk_update_product_category([t.a], Ecto.UUID.generate()) == 0

    assert jobs() == []
  end

  test "bulk_delete_products/1 enqueues a reindex of the products it deleted", t do
    assert Shop.bulk_delete_products([t.b, t.d]) == 2

    assert jobs() == [items_job([t.b, t.d])]
  end

  test "a bulk delete that matches nothing enqueues nothing" do
    assert Shop.bulk_delete_products([Ecto.UUID.generate()]) == 0

    assert jobs() == []
  end

  test "after a bulk delete the items drop the product at once; the count follows the job", t do
    assert Shop.bulk_delete_products([t.b]) == 1

    stale = search!(%{})
    assert stale["count"] == 5
    assert Enum.sort(Enum.map(stale["items"], & &1["id"])) == Enum.sort([t.a, t.c, t.d, t.e])

    run_queued_jobs()

    assert search!(%{})["count"] == 4
  end

  test "after a bulk category change the category filter follows the job", t do
    assert Shop.bulk_update_product_category([t.a], t.bowls) == 1

    assert search!(%{"category_id" => t.bowls})["count"] == 1

    run_queued_jobs()

    assert search!(%{"category_id" => t.bowls})["count"] == 2
    assert search!(%{"category_id" => t.vases})["count"] == 1
  end
end
