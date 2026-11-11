defmodule PhoenixKitEcommerce.Workers.OrderEmailWorker do
  @moduledoc """
  Sends one email of a shop order. See `PhoenixKitEcommerce.OrderEmails`.

  On `default`, a queue every host runs: a buyer's confirmation must not wait
  behind a long import on `shop_imports`, and a send is short. `{:error, _}` or a
  raise retries with Oban's backoff; an order that is gone will not come back.
  `{:snooze, seconds}` is an email another delivery holds: the job comes back
  when that claim has run out, and finds the email marked or sends it.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 10,
    unique: [keys: [:order_uuid, :email], period: :infinity]

  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitEcommerce.OrderEmails

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"order_uuid" => order_uuid, "email" => email}}) do
    case Billing.get_order(order_uuid) do
      nil -> {:cancel, :order_not_found}
      order -> OrderEmails.deliver(email, order)
    end
  end
end
