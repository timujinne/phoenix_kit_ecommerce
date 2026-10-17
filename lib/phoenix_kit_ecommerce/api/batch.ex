defmodule PhoenixKitEcommerce.API.Batch do
  @moduledoc """
  The steps every batch write tool shares: resolve the references, plan each
  row, write the rows that change, and shape the answer.

  A row is a map:

      %{index: 0, input: %{...}, ref: %{"sku" => "A"}, item: item | nil,
        plan: plan | nil, error: row_error | nil, result: nil | {:ok, item} | {:error, row_error},
        extra: %{}}

  A plan is whatever the tool's planner returns, with at least `:from`
  (the current values of the fields the row touches), `:changes`
  (`field => %{"from" => _, "to" => _}`), `:changed?`, `:dangerous?`,
  `:warnings`, `:attrs` and `:owned_paths`, and optionally `:guard`: the part
  of `:from` the plan depends on, compared by `write_if_unchanged/4` instead of
  all of it.
  """

  @compile {:no_warn_undefined, PhoenixKit.API.FlowConfig}

  require Logger

  alias PhoenixKit.API.FlowConfig
  alias PhoenixKitEcommerce.API.{CatalogueWrites, Fingerprint, Meta, Refs, Rows}
  alias PhoenixKitEcommerce.StorefrontCache

  @type row :: %{
          index: non_neg_integer(),
          input: map(),
          ref: term(),
          item: struct() | nil,
          plan: map() | nil,
          error: Rows.t() | nil,
          result: nil | {:ok, struct()} | {:unchanged, struct()} | {:error, Rows.t()},
          extra: map()
        }

  @doc "Resolves the `\"ref\"` of every item."
  @spec load([map()], String.t()) :: [row()]
  def load(items, catalogue_uuid) when is_list(items) do
    refs = Enum.map(items, &Map.get(&1, "ref"))

    items
    |> Enum.zip(Refs.resolve(refs, catalogue_uuid))
    |> Enum.with_index()
    |> Enum.map(fn {{input, answer}, index} -> row(index, input, answer) end)
  end

  defp row(index, input, {:ok, item}),
    do: %{
      index: index,
      input: input,
      ref: input["ref"],
      item: item,
      plan: nil,
      error: nil,
      result: nil,
      extra: %{}
    }

  defp row(index, input, {:error, error}),
    do: %{
      index: index,
      input: input,
      ref: input["ref"],
      item: nil,
      plan: nil,
      error: error,
      result: nil,
      extra: %{}
    }

  @doc "Marks a row as failed."
  @spec fail(row(), Rows.t()) :: row()
  def fail(row, error), do: %{row | error: error, plan: nil}

  @doc """
  Whether `item`, as read now, is still a product of the shop: in the catalogue
  `catalogue_uuid` and not in the trash. A product resolved at planning time
  can be trashed or moved out of the catalogue before a slow write.
  """
  @spec available?(struct(), String.t()) :: boolean()
  def available?(item, catalogue_uuid),
    do: item.catalogue_uuid == catalogue_uuid and item.status != "deleted"

  @doc """
  Plans every row that resolved. `planner` takes the row and returns
  `{:ok, plan}` or `{:error, row_error}`. A product named again after a row
  of it was planned successfully fails with `duplicate_line` and is not
  planned; a row that failed does not claim its product, so a later valid
  row of it still goes through.
  """
  @spec plan([row()], (row() -> {:ok, map()} | {:error, Rows.t()})) :: [row()]
  def plan(rows, planner) do
    {rows, _planned} =
      Enum.map_reduce(rows, %{}, fn
        %{error: nil, item: item} = row, planned ->
          plan_once(row, Map.fetch(planned, item.uuid), planner, planned)

        row, planned ->
          {row, planned}
      end)

    rows
  end

  defp plan_once(row, {:ok, first}, _planner, planned) do
    error =
      Rows.error(:duplicate_line, "This product is already given in items[#{first}].", %{
        "first_index" => first
      })

    {fail(row, error), planned}
  end

  defp plan_once(row, :error, planner, planned) do
    case planner.(row) do
      {:ok, plan} -> {%{row | plan: plan}, Map.put(planned, row.item.uuid, row.index)}
      {:error, error} -> {fail(row, error), planned}
    end
  end

  @doc """
  Whether any planned row is dangerous by its own value (a price moving past
  the threshold). The size of the batch is not asked here: core's executor
  holds every admin write tool whose longest list passes `api_confirm_batch_over`.
  """
  @spec dangerous?([row()]) :: boolean()
  def dangerous?(rows) do
    Enum.any?(rows, fn
      %{plan: %{dangerous?: true}} -> true
      _row -> false
    end)
  end

  @doc """
  The danger check ran on one read of the products and this plan is another.
  A call that went through without a confirmation was judged on the first; if
  something moved in between so that the same call is now dangerous, it must
  not be written as if it had been confirmed. `:ok`, or the refusal to answer
  with, carrying `message`.
  """
  @spec ensure_not_newly_dangerous([row()], map(), String.t()) ::
          :ok | {:error, :validation_failed, String.t(), map()}
  def ensure_not_newly_dangerous(rows, ctx, message) do
    if is_nil(Map.get(ctx, :confirmation_uuid)) and dangerous?(rows) do
      {:error, :validation_failed, message,
       %{
         errors: [
           %{
             path: "items",
             message: "changed while the call was checked",
             limit: nil,
             allowed: nil
           }
         ]
       }}
    else
      :ok
    end
  end

  @doc """
  Adds to a dry run's `preview` whether the real call would be held for
  confirmation: `"requires_confirmation"`, true when `dangerous?/1` is (the
  tool's own rule, the one its `danger` check answers) or when core's executor
  holds the call for its length (more rows than `api_confirm_batch_over`).
  `"confirmation_rules"` carries the thresholds that applied: `rules` of the
  tool, and `"confirm_batch_over"` where core has the setting. A dry run only
  reports; it never issues a confirmation code.
  """
  @spec with_confirmation(map(), [row()], map()) :: map()
  def with_confirmation(preview, rows, rules \\ %{}) do
    batch_over = confirm_batch_over()
    rules = if batch_over, do: Map.put(rules, "confirm_batch_over", batch_over), else: rules

    preview
    |> Map.put("requires_confirmation", held?(rows, batch_over))
    |> Map.put("confirmation_rules", rules)
  end

  # `length(rows)` is core's count only while `items` is the one top-level
  # list of the tool's input (core counts the longest); a second list would
  # have to be counted here too.
  defp held?(rows, batch_over),
    do: dangerous?(rows) or (is_integer(batch_over) and length(rows) > batch_over)

  # Core's `api_confirm_batch_over`; none on a core that has no such setting
  # (the write tools are not offered there at all).
  defp confirm_batch_over do
    if Code.ensure_loaded?(FlowConfig) and function_exported?(FlowConfig, :confirm_batch_over, 0),
      do: FlowConfig.confirm_batch_over()
  end

  @doc "The value fingerprint of the rows that were planned."
  @spec fingerprint([row()]) :: String.t()
  def fingerprint(rows) do
    Fingerprint.compute(for %{item: item, plan: %{from: from}} <- rows, do: {item.uuid, from})
  end

  @doc """
  Writes every row whose plan changes something, in one catalogue batch, and
  records the result on the row. Each row owns exactly the `data` paths its
  plan lists (`row_opts`), so a row that does not touch a path keeps the fresh
  value of it, and a price-only row owns no path at all. `mode: "auto"` marks
  the log entries as not made by hand; `skip_derive: true` because no tool
  here moves a product between categories.
  """
  @spec write([row()], map(), String.t()) :: [row()]
  def write(rows, ctx, tool) do
    written = write_rows(rows, ctx, tool)
    clear_storefront_cache(written)
    written
  end

  defp write_rows(rows, ctx, tool, extra_opts \\ []) do
    pending = for %{plan: %{changed?: true}} = row <- rows, do: row

    entries =
      Enum.map(pending, fn row ->
        paths = row.plan.owned_paths
        {row.item, row.plan.attrs, data_owned_paths: paths, logged_data_paths: paths}
      end)

    opts =
      [
        actor_uuid: Meta.actor_uuid(ctx),
        log_metadata: Meta.log_metadata(ctx, tool),
        mode: "auto",
        skip_derive: true
      ] ++ extra_opts

    results =
      pending
      |> Enum.map(& &1.index)
      |> Enum.zip(CatalogueWrites.update_rows(entries, opts))
      |> Map.new()

    Enum.map(rows, fn row ->
      case Map.fetch(results, row.index) do
        {:ok, {:ok, item}} -> %{row | item: item, result: {:ok, item}}
        {:ok, {:unchanged, item}} -> %{row | item: item, result: {:unchanged, item}}
        {:ok, {:error, error}} -> %{row | result: {:error, error}}
        :error -> row
      end
    end)
  end

  @doc """
  `write/3` for rows whose plan must still hold: inside one transaction the
  items are locked and read again, `planner` plans each row against the fresh
  item, and a row whose current values (`plan.from`) are no longer the ones it
  was planned from is not written but fails alone (`validation_failed`, reason
  `changed_since_planned`; `not_found` when the product is gone). A plan is made
  from a read; between that read and the write another writer (the Shopify sync,
  an editor) can change the same values, and the write would then replace them
  with a figure that was judged against the old ones.

  The catalogue event is announced after the commit. If that announcement
  raises, the committed rows keep their answer and the failure is logged; the
  nightly search rebuild is the backstop for an event that was lost.
  """
  @spec write_if_unchanged(
          [row()],
          map(),
          String.t(),
          (row() -> {:ok, map()} | {:error, Rows.t()})
        ) :: [row()]
  def write_if_unchanged(rows, ctx, tool, planner) do
    case for(%{plan: %{changed?: true}, item: item} <- rows, do: item) do
      [] ->
        rows

      items ->
        locked_result =
          CatalogueWrites.with_locked_items(items, fn locked ->
            rows
            |> Enum.map(&still_planned(&1, locked, planner))
            |> write_rows(ctx, tool, broadcast: false)
          end)

        case locked_result do
          {:ok, written} ->
            # After the commit: a page rendered before it would put the old
            # prices back into the cache, and a listener told of the change
            # earlier could read the old values (or hear of a change that a
            # rollback then took back).
            clear_storefront_cache(written)
            announce_updated(written)
            written

          # The transaction did not commit: no row of it was written.
          {:error, error} ->
            Enum.map(rows, &fail_pending(&1, error))
        end
    end
  end

  # The rows are committed: a failing broadcast must not turn them into errors.
  defp announce_updated(rows) do
    CatalogueWrites.announce_updated(for %{result: {:ok, item}} <- rows, do: item)
  rescue
    error -> log_announce_failed(error.__struct__)
  catch
    :exit, _reason -> log_announce_failed(:exit)
  end

  defp log_announce_failed(class),
    do: Logger.error("[API.Batch] announcing the update failed: #{inspect(class)}")

  defp fail_pending(%{plan: %{changed?: true}} = row, error), do: fail(row, error)
  defp fail_pending(row, _error), do: row

  defp still_planned(%{plan: %{changed?: true}, item: item} = row, locked, planner) do
    with {:ok, fresh} <- fetch_available(locked, item),
         {:ok, plan} <- planner.(%{row | item: fresh}),
         true <- same_values?(item.uuid, row.plan, plan) do
      row
    else
      :error ->
        fail(row, Rows.error(:not_found, "The product no longer exists."))

      _changed ->
        fail(row, changed_since_planned())
    end
  end

  defp still_planned(row, _locked, _planner), do: row

  @doc "The row error of a product whose values are no longer the ones its row was planned from."
  @spec changed_since_planned() :: Rows.t()
  def changed_since_planned do
    Rows.error(
      :validation_failed,
      "The product changed while the call was being checked. Read it again and repeat the call.",
      %{"reason" => "changed_since_planned"}
    )
  end

  defp fetch_available(locked, item) do
    case Map.fetch(locked, item.uuid) do
      {:ok, fresh} -> if available?(fresh, item.catalogue_uuid), do: {:ok, fresh}, else: :error
      :error -> :error
    end
  end

  defp same_values?(uuid, planned, fresh),
    do:
      Fingerprint.compute([{uuid, guard(planned)}]) == Fingerprint.compute([{uuid, guard(fresh)}])

  # What a plan says it read (`:guard`), else everything it carries as `:from`.
  defp guard(plan), do: Map.get(plan, :guard, plan.from)

  # The storefront caches its category list and facets for about a minute
  # (`StorefrontCache`); a write of this package must show on the next page
  # view, as the Shopify sync's catalogue writes do. Only a row that changed.
  defp clear_storefront_cache(rows) do
    if Enum.any?(rows, &match?(%{result: {:ok, _item}}, &1)), do: StorefrontCache.clear()
    :ok
  end

  @doc "The `results` list and the `summary` (`updated`, `unchanged` and `error`, zero when none) of a finished batch."
  @spec render([row()]) :: map()
  def render(rows) do
    results = Enum.map(rows, &result/1)
    counts = Enum.frequencies_by(results, & &1["action"])

    summary =
      Map.new(["updated", "unchanged", "error"], fn action ->
        {action, Map.get(counts, action, 0)}
      end)

    %{"results" => results, "summary" => summary}
  end

  defp result(%{error: error} = row) when not is_nil(error),
    do: %{"ref" => row.ref, "action" => "error", "error" => error}

  defp result(%{result: {:error, error}} = row),
    do: %{"ref" => row.ref, "action" => "error", "error" => error}

  defp result(%{result: {:unchanged, item}, plan: plan} = row) do
    Map.merge(
      %{
        "ref" => row.ref,
        "action" => "unchanged",
        "id" => item.uuid,
        "warnings" => plan.warnings
      },
      row.extra
    )
  end

  defp result(%{result: {:ok, item}, plan: plan} = row) do
    Map.merge(
      %{
        "ref" => row.ref,
        "action" => "updated",
        "id" => item.uuid,
        "changes" => plan.changes,
        "warnings" => plan.warnings
      },
      row.extra
    )
  end

  defp result(%{plan: plan, item: item} = row) do
    Map.merge(
      %{
        "ref" => row.ref,
        "action" => "unchanged",
        "id" => item.uuid,
        "warnings" => plan.warnings
      },
      row.extra
    )
  end

  @doc "The preview of a dry run: what each row would do, and the totals."
  @spec preview([row()], map()) :: map()
  def preview(rows, extra_totals \\ %{}) do
    preview_rows = Enum.map(rows, &preview_row/1)
    counts = Enum.frequencies_by(preview_rows, & &1["action"])

    totals =
      %{
        "rows" => length(rows),
        "update" => Map.get(counts, "update", 0),
        "unchanged" => Map.get(counts, "unchanged", 0),
        "error" => Map.get(counts, "error", 0)
      }
      |> Map.merge(extra_totals)

    %{"rows" => preview_rows, "totals" => totals}
  end

  defp preview_row(%{error: error} = row) when not is_nil(error),
    do: %{"ref" => row.ref, "action" => "error", "error" => error}

  defp preview_row(%{plan: %{changed?: true} = plan, item: item} = row) do
    Map.merge(
      %{
        "ref" => row.ref,
        "action" => "update",
        "id" => item.uuid,
        "changes" => plan.changes,
        "warnings" => plan.warnings
      },
      row.extra
    )
  end

  defp preview_row(%{plan: plan, item: item} = row),
    do:
      Map.merge(
        %{
          "ref" => row.ref,
          "action" => "unchanged",
          "id" => item.uuid,
          "warnings" => plan.warnings
        },
        row.extra
      )
end
