defmodule PhoenixKitEcommerce.Workers.ApiCartPruneWorker do
  @moduledoc """
  Daily deletion of the carts the sweep abandoned and of the ones a buyer's
  "add these items" choice merged away: `api:` carts in status `abandoned` or
  `merged`, with or without lines, not touched for 30 days. Anyone can
  create such carts without signing in, so they must not pile up for good;
  they hold no address, e-mail or payment data. Lines and claims of a deleted
  cart go with it (foreign keys). Does nothing while the shop module is
  disabled.
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  import Ecto.Query, warn: false
  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKitEcommerce.Cart

  @retention_days 30
  @batch 500

  @impl Oban.Worker
  def perform(_job) do
    if PhoenixKitEcommerce.enabled?() do
      {:ok, count} = prune()
      if count > 0, do: Logger.info("[Shop] deleted #{count} abandoned assistant carts")
    end

    :ok
  end

  @doc "Deletes the abandoned `api:` carts untouched since 30 days before `now`."
  @spec prune(DateTime.t()) :: {:ok, non_neg_integer()}
  def prune(now \\ UtilsDate.utc_now()) do
    cutoff = DateTime.add(now, -@retention_days * 86_400, :second)
    {:ok, delete_expired(cutoff, 0)}
  end

  # One statement per batch of at most @batch carts. The conditions are in the
  # subquery that picks the batch and again on the DELETE itself: a cart that
  # an assistant wrote to (or the buyer took over) after it was picked is
  # checked once more on its new row version before it is deleted, so a cart
  # that stopped being expired is kept.
  defp delete_expired(cutoff, deleted_so_far) do
    batch = from(c in Cart, select: c.uuid, limit: ^@batch) |> expired(cutoff)
    query = from(c in Cart, where: c.uuid in subquery(batch)) |> expired(cutoff)

    {deleted, _} = RepoHelper.repo().delete_all(query)

    # A short batch ends the run, also when rows of the batch changed meanwhile:
    # the rest waits for the next daily run.
    if deleted < @batch,
      do: deleted_so_far + deleted,
      else: delete_expired(cutoff, deleted_so_far + deleted)
  end

  defp expired(query, cutoff) do
    where(
      query,
      [c],
      c.status in ["abandoned", "merged"] and like(c.session_id, "api:%") and
        c.updated_at < ^cutoff
    )
  end
end
