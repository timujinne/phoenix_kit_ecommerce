defmodule PhoenixKitEcommerce.Search.JobsTest do
  use PhoenixKitEcommerce.DataCase, async: true

  alias PhoenixKitEcommerce.Search.Jobs
  alias PhoenixKitEcommerce.Test.Repo

  @reindex "PhoenixKitEcommerce.Workers.SearchReindexWorker"
  @rebuild "PhoenixKitEcommerce.Workers.SearchRebuildWorker"

  defp jobs(worker) do
    Repo.all(
      from(j in Oban.Job,
        where: j.worker == ^worker,
        order_by: [asc: j.id],
        select: %{args: j.args, state: j.state, queue: j.queue, scheduled_at: j.scheduled_at}
      )
    )
  end

  test "enqueue_item/1 schedules one reindex job a few seconds ahead on the shop_search queue" do
    uuid = Ecto.UUID.generate()

    assert {:ok, %Oban.Job{conflict?: false}} = Jobs.enqueue_item(uuid)

    assert [%{args: args, state: "scheduled", queue: "shop_search", scheduled_at: at}] =
             jobs(@reindex)

    assert args == %{"kind" => "item", "uuid" => uuid}
    assert DateTime.diff(at, DateTime.utc_now()) in 2..6
  end

  test "the same item enqueued twice inside the window is one job" do
    uuid = Ecto.UUID.generate()

    assert {:ok, %Oban.Job{conflict?: false}} = Jobs.enqueue_item(uuid)
    assert {:ok, %Oban.Job{conflict?: true}} = Jobs.enqueue_item(uuid)

    assert length(jobs(@reindex)) == 1
  end

  test "different items are different jobs" do
    {:ok, _} = Jobs.enqueue_item(Ecto.UUID.generate())
    {:ok, _} = Jobs.enqueue_item(Ecto.UUID.generate())

    assert length(jobs(@reindex)) == 2
  end

  test "enqueue_items/1 splits a long list into jobs of at most 200 ids and drops duplicates" do
    uuids = for _ <- 1..450, do: Ecto.UUID.generate()

    assert :ok = Jobs.enqueue_items(uuids ++ Enum.take(uuids, 10))

    sizes = jobs(@reindex) |> Enum.map(&length(&1.args["uuids"]))
    assert Enum.sort(sizes) == [50, 200, 200]
    assert Enum.all?(jobs(@reindex), &(&1.args["kind"] == "items"))
  end

  test "enqueue_items/1 with nothing to do enqueues nothing" do
    assert :ok = Jobs.enqueue_items([])
    assert jobs(@reindex) == []
  end

  test "enqueue_category/1 and enqueue_rebuild/1 carry what the workers read" do
    category = Ecto.UUID.generate()
    catalogue = Ecto.UUID.generate()

    {:ok, _} = Jobs.enqueue_category(category)
    {:ok, _} = Jobs.enqueue_rebuild(nil)
    {:ok, _} = Jobs.enqueue_rebuild(catalogue)

    assert [%{args: %{"kind" => "category", "uuid" => ^category}}] = jobs(@reindex)

    assert jobs(@rebuild) |> Enum.map(& &1.args) |> Enum.sort() ==
             Enum.sort([%{}, %{"catalogue_uuid" => catalogue}])
  end

  test "enabling the shop asks for a rebuild: products changed while it was off were not indexed" do
    assert jobs(@rebuild) == []

    {:ok, _setting} = PhoenixKitEcommerce.enable_system()

    assert [%{args: %{}, queue: "shop_search"}] = jobs(@rebuild)
  end

  test "a rebuild is scheduled about ten seconds ahead" do
    {:ok, _} = Jobs.enqueue_rebuild(nil)

    assert [%{scheduled_at: at}] = jobs(@rebuild)
    assert DateTime.diff(at, DateTime.utc_now()) in 7..11
  end

  test "an item job that is already executing does not absorb the next write" do
    uuid = Ecto.UUID.generate()
    {:ok, first} = Jobs.enqueue_item(uuid)

    Repo.update_all(from(j in Oban.Job, where: j.id == ^first.id), set: [state: "executing"])

    assert {:ok, %Oban.Job{conflict?: false, id: id}} = Jobs.enqueue_item(uuid)
    assert id != first.id
    assert length(jobs(@reindex)) == 2
  end

  test "the same category enqueued twice inside the window is one job" do
    uuid = Ecto.UUID.generate()

    assert {:ok, %Oban.Job{conflict?: false}} = Jobs.enqueue_category(uuid)
    assert {:ok, %Oban.Job{conflict?: true}} = Jobs.enqueue_category(uuid)

    assert length(jobs(@reindex)) == 1
  end

  test "an item job and a category job with the same uuid are different jobs" do
    uuid = Ecto.UUID.generate()

    assert {:ok, %Oban.Job{conflict?: false}} = Jobs.enqueue_item(uuid)
    assert {:ok, %Oban.Job{conflict?: false}} = Jobs.enqueue_category(uuid)

    assert jobs(@reindex) |> Enum.map(& &1.args["kind"]) |> Enum.sort() == ["category", "item"]
  end

  test "a second rebuild request with the same args is not a second job" do
    assert {:ok, %Oban.Job{conflict?: false}} = Jobs.enqueue_rebuild(nil)
    assert {:ok, %Oban.Job{conflict?: true}} = Jobs.enqueue_rebuild(nil)
    assert length(jobs(@rebuild)) == 1
  end
end
