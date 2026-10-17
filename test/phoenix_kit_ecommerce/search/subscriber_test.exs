defmodule PhoenixKitEcommerce.Search.SubscriberTest do
  @moduledoc """
  Messages in, Oban jobs out. The subscriber runs for the length of one test
  (`start_supervised!/1`); `:sys.get_state/1` is the barrier that makes sure
  it has handled a message before the jobs are read.

  `async: false`: the subscriber listens to global PubSub topics and works in
  the shared sandbox connection.
  """
  use PhoenixKitEcommerce.DataCase, async: false

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue.PubSub}

  alias PhoenixKit.Settings
  alias PhoenixKitCatalogue.Catalogue.PubSub, as: CataloguePubSub
  alias PhoenixKitEcommerce.Events
  alias PhoenixKitEcommerce.Search.Subscriber
  alias PhoenixKitEcommerce.Search.Trigram
  alias PhoenixKitEcommerce.Test.Repo

  import ExUnit.CaptureLog

  setup do
    shop = Ecto.UUID.generate()

    pid =
      start_supervised!(
        {Subscriber,
         name: :search_subscriber_test, boot_check_ms: nil, shop_catalogue: fn -> shop end}
      )

    # The first message the process handles is its own :subscribe; wait for it.
    _ = :sys.get_state(pid)
    %{pid: pid, shop: shop}
  end

  defp deliver(pid, message) do
    send(pid, message)
    _ = :sys.get_state(pid)
    :ok
  end

  defp jobs do
    from(j in Oban.Job, order_by: [asc: j.id], select: {j.worker, j.args})
    |> Repo.all()
    |> Enum.map(fn {worker, args} -> {worker |> String.split(".") |> List.last(), args} end)
  end

  defp item_job(uuid), do: {"SearchReindexWorker", %{"kind" => "item", "uuid" => uuid}}

  test "a product update enqueues one reindex job", %{pid: pid} do
    uuid = Ecto.UUID.generate()

    deliver(pid, {:product_updated, %{uuid: uuid}})
    deliver(pid, {:product_updated, %{uuid: uuid}})

    assert jobs() == [item_job(uuid)]
  end

  test "product created, deleted and bulk status events", %{pid: pid} do
    [a, b, c, d] = for _ <- 1..4, do: Ecto.UUID.generate()

    deliver(pid, {:product_created, %{uuid: a}})
    deliver(pid, {:product_deleted, b})
    deliver(pid, {:products_bulk_status_changed, [c, d], "archived"})

    assert jobs() == [
             item_job(a),
             item_job(b),
             {"SearchReindexWorker", %{"kind" => "items", "uuids" => [c, d]}}
           ]
  end

  test "category events enqueue a subtree job; bulk category events a rebuild", %{pid: pid} do
    [a, b] = for _ <- 1..2, do: Ecto.UUID.generate()

    deliver(pid, {:category_updated, %{uuid: a}})
    deliver(pid, {:categories_bulk_parent_changed, [a, b], nil})
    deliver(pid, {:categories_bulk_status_changed, [a], "hidden"})

    assert jobs() == [
             {"SearchReindexWorker", %{"kind" => "category", "uuid" => a}},
             {"SearchRebuildWorker", %{}}
           ]
  end

  # The delete sets the products' category to NULL, so a subtree job would
  # find no product to reindex.
  test "a category delete rebuilds the index", %{pid: pid} do
    deliver(pid, {:category_deleted, Ecto.UUID.generate()})

    assert jobs() == [{"SearchRebuildWorker", %{}}]
  end

  # Billing announces a committed base-currency change this way; the index
  # holds base-currency prices.
  test "a currency change rebuilds the index", %{pid: pid} do
    deliver(pid, {:currencies_changed, "EUR"})

    assert jobs() == [{"SearchRebuildWorker", %{}}]
  end

  test "a catalogue item event enqueues that item; one without an id rebuilds", %{
    pid: pid,
    shop: catalogue
  } do
    item = Ecto.UUID.generate()

    deliver(pid, {:catalogue_data_changed, :item, item, catalogue})
    deliver(pid, {:catalogue_data_changed, :item, nil, catalogue})

    assert jobs() == [
             item_job(item),
             {"SearchRebuildWorker", %{"catalogue_uuid" => catalogue}}
           ]
  end

  test "catalogue category events, rebuild kinds, and kinds the index does not care about", %{
    pid: pid,
    shop: catalogue
  } do
    category = Ecto.UUID.generate()

    deliver(pid, {:catalogue_data_changed, :category, category, catalogue})
    deliver(pid, {:catalogue_data_changed, :attribute_set, Ecto.UUID.generate(), catalogue})
    deliver(pid, {:catalogue_data_changed, :manufacturer, Ecto.UUID.generate(), nil})
    deliver(pid, {:catalogue_data_changed, :supplier, Ecto.UUID.generate(), nil})
    deliver(pid, {:catalogue_data_changed, :pdf, Ecto.UUID.generate(), catalogue})

    assert jobs() == [
             {"SearchReindexWorker", %{"kind" => "category", "uuid" => category}},
             {"SearchRebuildWorker", %{"catalogue_uuid" => catalogue}}
           ]
  end

  test "a catalogue bulk change with ids reindexes them, any kind; without ids it rebuilds", %{
    pid: pid,
    shop: catalogue
  } do
    [a, b] = for _ <- 1..2, do: Ecto.UUID.generate()

    deliver(pid, {:catalogue_bulk_change, catalogue, :trashed, [a], self()})
    deliver(pid, {:catalogue_bulk_change, catalogue, :some_future_kind, [b], self()})
    deliver(pid, {:catalogue_bulk_change, catalogue, :moved, nil, self()})

    assert jobs() == [
             {"SearchReindexWorker", %{"kind" => "items", "uuids" => [a]}},
             {"SearchReindexWorker", %{"kind" => "items", "uuids" => [b]}},
             {"SearchRebuildWorker", %{"catalogue_uuid" => catalogue}}
           ]

    # A second rebuild of the same catalogue is the one job already waiting.
    deliver(pid, {:catalogue_bulk_change, catalogue, :restored, [], self()})

    assert length(jobs()) == 3
  end

  test "a bulk category delete rebuilds the index", %{pid: pid} do
    deliver(pid, {:categories_bulk_deleted, [Ecto.UUID.generate()]})

    assert jobs() == [{"SearchRebuildWorker", %{}}]
  end

  test "nothing is enqueued while the shop module is disabled", %{pid: pid} do
    {:ok, _} = Settings.update_setting("shop_enabled", "false")

    deliver(pid, {:product_updated, %{uuid: Ecto.UUID.generate()}})
    deliver(pid, {:catalogue_data_changed, :item, Ecto.UUID.generate(), nil})

    assert jobs() == []
  end

  test "messages it does not know are ignored and the process keeps running", %{pid: pid} do
    ref = Process.monitor(pid)

    deliver(pid, :unexpected)
    deliver(pid, {:catalogue_card_refresh, 1, 2, 3, 4, self()})
    deliver(pid, {:product_updated, :not_a_product})

    refute_received {:DOWN, ^ref, :process, ^pid, _reason}
    assert jobs() == []
  end

  test "events broadcast through Events reach the subscriber", %{pid: pid} do
    uuid = Ecto.UUID.generate()

    Events.broadcast_product_updated(%{uuid: uuid})
    _ = :sys.get_state(pid)

    assert jobs() == [item_job(uuid)]
  end

  @tag :catalogue
  test "events broadcast on the catalogue topic reach the subscriber", %{
    pid: pid,
    shop: catalogue
  } do
    uuid = Ecto.UUID.generate()

    CataloguePubSub.broadcast(:item, uuid, catalogue)
    _ = :sys.get_state(pid)

    assert jobs() == [item_job(uuid)]
  end

  describe "events of another catalogue" do
    test "are dropped, whatever their kind", %{pid: pid} do
      other = Ecto.UUID.generate()
      [a, b] = for _ <- 1..2, do: Ecto.UUID.generate()

      deliver(pid, {:catalogue_data_changed, :item, a, other})
      deliver(pid, {:catalogue_data_changed, :item, nil, other})
      deliver(pid, {:catalogue_data_changed, :category, b, other})
      deliver(pid, {:catalogue_data_changed, :attribute_set, a, other})
      deliver(pid, {:catalogue_bulk_change, other, :trashed, [a, b], self()})
      deliver(pid, {:catalogue_bulk_change, other, :moved, nil, self()})

      assert jobs() == []
    end

    test "are dropped while the shop's own events and those that name no catalogue pass", %{
      pid: pid,
      shop: shop
    } do
      [own, nameless, foreign] = for _ <- 1..3, do: Ecto.UUID.generate()

      deliver(pid, {:catalogue_data_changed, :item, foreign, Ecto.UUID.generate()})
      deliver(pid, {:catalogue_data_changed, :item, own, shop})
      deliver(pid, {:catalogue_data_changed, :item, nameless, nil})

      assert jobs() == [item_job(own), item_job(nameless)]
    end

    test "are all dropped on the Legacy source, which has no shop catalogue" do
      pid =
        start_supervised!({Subscriber, name: :search_subscriber_legacy, boot_check_ms: nil},
          id: :legacy
        )

      _ = :sys.get_state(pid)

      deliver(pid, {:catalogue_data_changed, :item, Ecto.UUID.generate(), Ecto.UUID.generate()})

      deliver(
        pid,
        {:catalogue_bulk_change, Ecto.UUID.generate(), :trashed, [Ecto.UUID.generate()], self()}
      )

      assert jobs() == []
    end
  end

  describe "the shop's catalogue uuid" do
    defp counting_resolver(answer) do
      calls = start_supervised!({Agent, fn -> 0 end}, id: make_ref())

      resolver = fn ->
        Agent.update(calls, &(&1 + 1))
        answer.()
      end

      {resolver, fn -> Agent.get(calls, & &1) end}
    end

    defp start_with(resolver, opts \\ []) do
      pid =
        start_supervised!(
          {Subscriber,
           Keyword.merge(
             [name: :search_subscriber_resolver, boot_check_ms: nil, shop_catalogue: resolver],
             opts
           )},
          id: make_ref()
        )

      _ = :sys.get_state(pid)
      pid
    end

    test "is looked up once and remembered, not read for every event" do
      shop = Ecto.UUID.generate()
      {resolver, calls} = counting_resolver(fn -> shop end)
      pid = start_with(resolver)

      for _ <- 1..3,
          do: deliver(pid, {:catalogue_data_changed, :item, Ecto.UUID.generate(), shop})

      assert length(jobs()) == 3
      assert calls.() == 1
    end

    test "is asked again while there is none, so a catalogue created a moment ago is not missed" do
      {resolver, calls} = counting_resolver(fn -> nil end)
      pid = start_with(resolver)

      for _ <- 1..3,
          do:
            deliver(
              pid,
              {:catalogue_data_changed, :item, Ecto.UUID.generate(), Ecto.UUID.generate()}
            )

      assert jobs() == []
      assert calls.() == 3
    end

    test "is looked up again before an event of another catalogue is dropped: a switch is noticed" do
      [old, new] = for _ <- 1..2, do: Ecto.UUID.generate()
      current = start_supervised!({Agent, fn -> old end}, id: make_ref())
      {resolver, calls} = counting_resolver(fn -> Agent.get(current, & &1) end)
      pid = start_with(resolver, recheck_ms: 0)
      [first, switched, stale] = for _ <- 1..3, do: Ecto.UUID.generate()

      deliver(pid, {:catalogue_data_changed, :item, first, old})
      Agent.update(current, fn _ -> new end)
      deliver(pid, {:catalogue_data_changed, :item, switched, new})
      deliver(pid, {:catalogue_data_changed, :item, stale, old})

      assert jobs() == [item_job(first), item_job(switched)]
      assert calls.() == 3
    end

    test "is looked up again once per window, however many events of another catalogue arrive" do
      shop = Ecto.UUID.generate()
      {resolver, calls} = counting_resolver(fn -> shop end)
      pid = start_with(resolver)

      deliver(pid, {:catalogue_data_changed, :item, Ecto.UUID.generate(), shop})

      for _ <- 1..5,
          do:
            deliver(
              pid,
              {:catalogue_data_changed, :item, Ecto.UUID.generate(), Ecto.UUID.generate()}
            )

      assert length(jobs()) == 1
      assert calls.() == 1

      # a window of no length: each dropped event costs exactly one more lookup
      {resolver, calls} = counting_resolver(fn -> shop end)
      pid = start_with(resolver, recheck_ms: 0, name: :search_subscriber_resolver_open)

      deliver(pid, {:catalogue_data_changed, :item, Ecto.UUID.generate(), shop})

      for _ <- 1..3,
          do:
            deliver(
              pid,
              {:catalogue_data_changed, :item, Ecto.UUID.generate(), Ecto.UUID.generate()}
            )

      assert calls.() == 4
    end

    test "is not looked up a second time for the event that has just caused a lookup" do
      {resolver, calls} = counting_resolver(fn -> Ecto.UUID.generate() end)
      pid = start_with(resolver, recheck_ms: 0)

      deliver(pid, {:catalogue_data_changed, :item, Ecto.UUID.generate(), Ecto.UUID.generate()})

      assert calls.() == 1
    end

    test "that exits lets the events through, with a warning that names no value" do
      pid = start_with(fn -> exit(:boom_secret) end)
      item = Ecto.UUID.generate()

      log =
        capture_log(fn ->
          deliver(pid, {:catalogue_data_changed, :item, item, Ecto.UUID.generate()})
        end)

      assert jobs() == [item_job(item)]
      assert log =~ "could not resolve the shop catalogue"
      refute log =~ "boom_secret"
    end

    test "that cannot be looked up lets the events through, with a warning that names no value" do
      pid = start_with(fn -> raise "boom: secret" end)
      item = Ecto.UUID.generate()

      log =
        capture_log(fn ->
          deliver(pid, {:catalogue_data_changed, :item, item, Ecto.UUID.generate()})
        end)

      assert jobs() == [item_job(item)]
      assert log =~ "could not resolve the shop catalogue: RuntimeError"
      refute log =~ "secret"
    end
  end

  describe "the boot check" do
    setup do
      on_exit(&Trigram.reset_cache/0)
    end

    test "warns once when pg_trgm is missing", %{pid: pid} do
      Trigram.put_cache(false)

      log = capture_log(fn -> deliver(pid, :boot_check) end)

      assert log =~ "pg_trgm is not installed"
    end

    test "stays quiet when pg_trgm is there", %{pid: pid} do
      Trigram.put_cache(true)

      log = capture_log(fn -> deliver(pid, :boot_check) end)

      refute log =~ "pg_trgm"
    end
  end

  test "the boot check enqueues a rebuild when the index is empty", %{pid: pid} do
    deliver(pid, :boot_check)

    assert jobs() == [{"SearchRebuildWorker", %{}}]
  end

  test "the boot check leaves a filled index alone", %{pid: pid} do
    Repo.query!(
      """
      INSERT INTO phoenix_kit_shop_search_index (item_uuid, language, title, title_trgm, document)
      VALUES ($1, 'en', 'A', 'a', to_tsvector('simple', 'a'))
      """,
      [Ecto.UUID.bingenerate()]
    )

    deliver(pid, :boot_check)

    assert jobs() == []
  end
end
