defmodule PhoenixKitEcommerce.NotificationAssertions do
  @moduledoc """
  Helpers for querying `phoenix_kit_notifications` rows by the shop
  action that produced them.

  `create_many/2` never persists `:action` on the notification row (see
  `PhoenixKitEcommerce.Notifications.notify_shop/1`) — it's stashed under
  `metadata["action"]` instead, so these filter there rather than a bare
  `action` column that does not exist on `phoenix_kit_notifications`.

  Imported into `PhoenixKitEcommerce.DataCase` and
  `PhoenixKitEcommerce.LiveCase` so every DB-backed test can reach them.
  """

  import Ecto.Query, warn: false

  alias PhoenixKitEcommerce.Test.Repo, as: TestRepo

  @doc "Returns the uuids of notification rows recorded for `action`."
  def notifications_for_action(action) do
    "phoenix_kit_notifications"
    |> select([n], %{uuid: n.uuid, metadata: n.metadata})
    |> TestRepo.all()
    |> Enum.filter(&(&1.metadata["action"] == action))
    |> Enum.map(& &1.uuid)
  end

  @doc "Returns how many notification rows were recorded for `action`."
  def count_notifications(action) do
    action
    |> notifications_for_action()
    |> length()
  end

  @doc """
  Returns the rendered text of notification rows recorded for `action`.

  The rendered text lives under `metadata["notification_text"]`
  (`create_many/2` folds the `:text` convenience key in there — see
  `PhoenixKit.Notifications.create_many/2`).
  """
  def notification_texts_for_action(action) do
    "phoenix_kit_notifications"
    |> select([n], %{metadata: n.metadata})
    |> TestRepo.all()
    |> Enum.filter(&(&1.metadata["action"] == action))
    |> Enum.map(& &1.metadata["notification_text"])
  end

  @doc """
  Returns the link of the notification rows whose text mentions `fragment`
  (the metadata's `notification_link`, which `create/1` folds the `:link` key
  into). A standalone `create/1` notification carries no `metadata["action"]`
  — only `create_many/2` stashes it — so a single-recipient one is found by
  its text.
  """
  def notification_links_mentioning(fragment) do
    "phoenix_kit_notifications"
    |> select([n], %{metadata: n.metadata})
    |> TestRepo.all()
    |> Enum.filter(&String.contains?(&1.metadata["notification_text"] || "", fragment))
    |> Enum.map(& &1.metadata["notification_link"])
  end
end
