defmodule PhoenixKitEcommerce.Workers.ApiClaimPruneWorker do
  @moduledoc """
  Daily prune of checkout claims: rows used or expired more than 7
  days ago are deleted. Until then a used claim keeps answering `cart_locked`
  to the old cart token. Does nothing while the shop module is disabled.
  """

  use Oban.Worker, queue: :default, max_attempts: 1

  import Ecto.Query, warn: false
  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Utils.Date, as: UtilsDate
  alias PhoenixKitEcommerce.CartClaim

  @retention_days 7

  @impl Oban.Worker
  def perform(_job) do
    if PhoenixKitEcommerce.enabled?() do
      {:ok, count} = prune()
      if count > 0, do: Logger.info("[Shop] deleted #{count} old checkout claims")
    end

    :ok
  end

  @doc "Deletes claims whose `used_at` or `expires_at` is older than 7 days before `now`."
  @spec prune(DateTime.t()) :: {:ok, non_neg_integer()}
  def prune(now \\ UtilsDate.utc_now()) do
    cutoff = DateTime.add(now, -@retention_days * 86_400, :second)

    {count, _} =
      from(k in CartClaim, where: k.expires_at < ^cutoff or k.used_at < ^cutoff)
      |> RepoHelper.repo().delete_all()

    {:ok, count}
  end
end
