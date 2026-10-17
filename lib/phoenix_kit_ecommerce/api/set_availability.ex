defmodule PhoenixKitEcommerce.API.SetAvailability do
  @moduledoc """
  `ecommerce.set_availability`: the visibility and the made-to-order flag of
  products by reference. Same shape as `ecommerce.set_prices`: the catalogue
  source only, a batch write limited to the paths a row changes, a preview
  with `ctx.dry_run?`. The write locks the items and plans each row again
  (`Batch.write_if_unchanged/4`), so a product trashed, moved out of the shop
  catalogue or changed since it was read is not written.

  It has no `danger` function: no value it writes is dangerous by itself
  (publishing is refused without a price instead), and a batch with more rows
  than `api_confirm_batch_over` is held by core's executor for every admin
  write tool. Its dry run says so: `requires_confirmation` is that row
  threshold alone.
  """

  alias PhoenixKitEcommerce.API.{AvailabilityPlan, Batch, Gate, Rows}

  @tool "ecommerce.set_availability"

  @doc "Handler of the tool."
  @spec run(map(), map()) ::
          {:ok, map()} | {:preview, map(), String.t()} | Gate.refusal()
  def run(input, ctx) do
    with {:ok, rows, planner} <- plan_rows(input) do
      if Map.get(ctx, :dry_run?, false) do
        {:preview, rows |> Batch.preview() |> Batch.with_confirmation(rows),
         Batch.fingerprint(rows)}
      else
        {:ok, rows |> Batch.write_if_unchanged(ctx, @tool, planner) |> Batch.render()}
      end
    end
  end

  defp plan_rows(input) do
    with {:ok, catalogue_uuid} <- Gate.check(input) do
      shopify? = PhoenixKitEcommerce.shopify_enabled?()
      planner = &plan_row(&1, shopify?)

      {:ok, input["items"] |> Batch.load(catalogue_uuid) |> Batch.plan(planner), planner}
    end
  end

  defp plan_row(%{item: item, input: input}, shopify?) do
    case AvailabilityPlan.plan(input, item, shopify_enabled?: shopify?) do
      {:ok, plan} -> {:ok, plan}
      {:error, errors} -> {:error, Rows.invalid(errors)}
    end
  end
end
