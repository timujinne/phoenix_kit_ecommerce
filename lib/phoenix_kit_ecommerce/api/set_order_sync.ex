defmodule PhoenixKitEcommerce.API.SetOrderSync do
  @moduledoc """
  `ecommerce.set_order_sync`: the external system's mark on orders, up to 100
  rows, each independent of the others.

  A row names the order (`ref`), the `revision` the external system took and the
  `state` it reached: `synced` with the ids the system gave the order, or
  `failed` with the reason. The mark is stored by
  `PhoenixKitBilling.put_order_sync/2`, which touches nothing else of the order.

  A row whose `revision` is no longer the order's current one is answered with
  the row error `conflict` (`context.reason` is `stale_revision`,
  `context.current_revision` the revision to read again), writes nothing and
  leaves the order `pending`: the order changed after the system read it.

  Repeating a row is safe. A batch longer than `api_confirm_batch_over` rows is
  held for confirmation by core like any admin write.
  """

  # A billing older than `put_order_sync/2` has no order revision; the tools are
  # not offered there (`OrderTools.available?/0`).
  @compile {:no_warn_undefined,
            [
              {PhoenixKitBilling, :put_order_sync, 2},
              {PhoenixKitBilling.Order, :sync, 1},
              {PhoenixKitBilling.Order, :revision, 1}
            ]}

  alias PhoenixKitBilling.Order
  alias PhoenixKitEcommerce.API.{Batch, Fingerprint, Meta, OrderRefs, Rows}

  @tool "ecommerce.set_order_sync"
  @mark_keys ~w(state external_id external_number external_status error)

  @doc "Handler of the tool."
  @spec run(map(), map()) :: {:ok, map()} | {:preview, map(), String.t()}
  def run(input, ctx) do
    rows = input["orders"]
    answers = OrderRefs.resolve(Enum.map(rows, & &1["ref"]))

    if Map.get(ctx, :dry_run?, false),
      do: preview(rows, answers),
      else: {:ok, write(rows, answers, ctx)}
  end

  # -- write ------------------------------------------------------------------

  defp write(rows, answers, ctx) do
    results =
      rows
      |> Enum.zip(answers)
      |> Enum.map(fn
        {row, {:ok, order}} -> mark(row, order, ctx)
        {row, {:error, error}} -> %{"ref" => row["ref"], "action" => "error", "error" => error}
      end)

    %{"results" => results, "summary" => summary(results)}
  end

  defp mark(row, order, ctx) do
    attrs = row |> Map.take(@mark_keys) |> Map.put("revision", row["revision"])

    case PhoenixKitBilling.put_order_sync(order, attrs) do
      {:ok, marked} ->
        log(marked, row, ctx)
        ok(row, marked)

      {:error, :stale_revision} ->
        error(row, stale(order))

      {:error, :not_found} ->
        error(
          row,
          Rows.error(:not_found, "No order matches this reference.", %{"ref" => row["ref"]})
        )

      {:error, %Ecto.Changeset{} = changeset} ->
        error(row, Rows.invalid(changeset_errors(changeset)))
    end
  end

  defp ok(row, order) do
    %{
      "ref" => row["ref"],
      "action" => "marked",
      "id" => order.uuid,
      "number" => order.order_number,
      "sync" => Order.sync(order)
    }
  end

  defp error(row, error), do: %{"ref" => row["ref"], "action" => "error", "error" => error}

  defp stale(order) do
    Rows.error(
      :conflict,
      "The order changed after it was read; read it again.",
      %{"reason" => "stale_revision", "current_revision" => current_revision(order)}
    )
  end

  # The order as it was resolved is as old as the batch; a row refused for its
  # revision reports the revision stored now.
  defp current_revision(order) do
    order.uuid |> PhoenixKitBilling.get_order() |> Order.revision()
  end

  defp changeset_errors(changeset) do
    for {field, messages} <-
          Ecto.Changeset.traverse_errors(changeset, fn {message, _} -> message end),
        message <- List.flatten(messages) do
      %{"path" => to_string(field), "message" => message}
    end
  end

  defp summary(results) do
    counts = Enum.frequencies_by(results, & &1["action"])
    %{"marked" => Map.get(counts, "marked", 0), "error" => Map.get(counts, "error", 0)}
  end

  defp log(order, row, ctx) do
    PhoenixKitEcommerce.Activity.log("shop.api_order_sync_marked",
      actor_uuid: Meta.actor_uuid(ctx),
      mode: "auto",
      resource_type: "order",
      resource_uuid: order.uuid,
      metadata:
        Map.merge(Meta.log_metadata(ctx, @tool), %{
          "state" => row["state"],
          "revision" => row["revision"]
        })
    )
  end

  # -- dry run ----------------------------------------------------------------

  defp preview(rows, answers) do
    previewed =
      rows
      |> Enum.zip(answers)
      |> Enum.map(fn
        {row, {:ok, order}} ->
          preview_row(row, order)

        {row, {:error, error}} ->
          {%{"ref" => row["ref"], "action" => "error", "error" => error}, nil}
      end)

    results = Enum.map(previewed, &elem(&1, 0))
    seen = for {_result, {uuid, fields}} <- previewed, do: {uuid, fields}

    preview =
      %{"rows" => results, "totals" => Map.put(summary(results), "rows", length(rows))}
      |> Batch.with_confirmation(rows)

    {:preview, preview, Fingerprint.compute(seen)}
  end

  defp preview_row(row, order) do
    current = Order.revision(order)
    seen = {order.uuid, %{"revision" => current, "state" => Order.sync(order)["state"]}}

    if row["revision"] == current do
      {%{"ref" => row["ref"], "action" => "marked", "id" => order.uuid}, seen}
    else
      {error(row, stale(order)), seen}
    end
  end
end
