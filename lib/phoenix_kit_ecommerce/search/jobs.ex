defmodule PhoenixKitEcommerce.Search.Jobs do
  @moduledoc """
  The one place that puts search jobs on the Oban queue.

  Item and category jobs run five seconds after the event and are unique on
  `(kind, uuid)` for a minute while they are still waiting, so the many writes
  of one edit (a sync writes a product field by field) become one reindex.
  Rebuild requests are made unique by `Workers.SearchRebuildWorker` itself.
  Uniqueness covers waiting jobs only: a job that is already running does not
  absorb the next write, which queues a new job, so the last write is never lost.

  An Oban or database failure does not raise: it is logged and returned, and
  the nightly rebuild repairs the index. (The functions that take a uuid still
  require a binary.)
  """

  require Logger

  alias PhoenixKitEcommerce.Workers.SearchRebuildWorker
  alias PhoenixKitEcommerce.Workers.SearchReindexWorker

  @delay_seconds 5
  @rebuild_delay_seconds 10
  @unique_seconds 60
  @items_per_job 200

  @doc "Re-index one product."
  @spec enqueue_item(String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_item(uuid) when is_binary(uuid) do
    %{"kind" => "item", "uuid" => uuid}
    |> SearchReindexWorker.new(schedule_in: @delay_seconds, unique: unique())
    |> insert()
  end

  @doc "Re-index many products, 200 per job."
  @spec enqueue_items([String.t()]) :: :ok | {:error, term()}
  def enqueue_items(uuids) when is_list(uuids) do
    uuids
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.chunk_every(@items_per_job)
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      job =
        %{"kind" => "items", "uuids" => chunk}
        |> SearchReindexWorker.new(schedule_in: @delay_seconds)
        |> insert()

      case job do
        {:ok, _job} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @doc "Re-index every product in a category's subtree (a rename, a move, a status change)."
  @spec enqueue_category(String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_category(uuid) when is_binary(uuid) do
    %{"kind" => "category", "uuid" => uuid}
    |> SearchReindexWorker.new(schedule_in: @delay_seconds, unique: unique())
    |> insert()
  end

  @doc """
  Rebuild the whole index. With a catalogue uuid the worker rebuilds only if
  that is the shop's catalogue (events of the install's other catalogues are
  ignored).
  """
  @spec enqueue_rebuild(String.t() | nil) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_rebuild(catalogue_uuid \\ nil) do
    args = if is_binary(catalogue_uuid), do: %{"catalogue_uuid" => catalogue_uuid}, else: %{}

    args
    |> SearchRebuildWorker.new(schedule_in: @rebuild_delay_seconds)
    |> insert()
  end

  defp unique do
    [
      period: @unique_seconds,
      fields: [:worker, :args],
      keys: [:kind, :uuid],
      states: [:available, :scheduled]
    ]
  end

  # Only the exception module is logged and returned: a changeset or connection
  # error can embed the job arguments.
  defp insert(changeset) do
    Oban.insert(changeset)
  rescue
    error ->
      Logger.warning("[Search] could not enqueue a search job: #{inspect(error.__struct__)}")
      {:error, error.__struct__}
  catch
    :exit, _reason ->
      Logger.warning("[Search] could not enqueue a search job: the Oban call exited")
      {:error, :oban_unavailable}
  end
end
