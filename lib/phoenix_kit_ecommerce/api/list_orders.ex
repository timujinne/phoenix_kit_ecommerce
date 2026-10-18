defmodule PhoenixKitEcommerce.API.ListOrders do
  @moduledoc """
  `ecommerce.list_orders`: the orders a caller has not seen yet, by cursor.

  Orders come in the order of `(updated_at, uuid)`; the cursor is the position
  after the last order of a page and is opaque to the caller. Asking again with
  the same cursor gives the same page, as long as no order moved past it.
  Marking an order (`ecommerce.set_order_sync`) does not change `updated_at`, so
  a mark never puts an order back into the feed.

  `sync` narrows the feed to the orders the external system must take
  (`pending`: no mark yet, or changed after it), the ones it has taken
  (`synced`), or all (`any`, the default). A caller that wants "what is
  outstanding" asks for `pending` and needs no cursor of its own. Orders in
  `draft` are left out unless `statuses` names them. `limit` is 1 to 100
  (default 50) and is never cut silently: a larger one is `validation_failed`.

  Personal data of the buyer is part of an answer only when the key also holds
  `ecommerce.orders:customer`.
  """

  import Ecto.Query, warn: false

  # A billing older than `Order.where_sync/2` has no order revision; the tools
  # are not offered there (`OrderTools.available?/0`).
  @compile {:no_warn_undefined, {PhoenixKitBilling.Order, :where_sync, 2}}

  alias PhoenixKit.RepoHelper
  alias PhoenixKitBilling.Order
  alias PhoenixKitEcommerce.API.{OrderExport, OrderTools}

  @default_limit 50
  @max_limit 100
  @statuses ~w(draft pending confirmed paid cancelled refunded)
  @default_statuses @statuses -- ["draft"]

  @doc "The most orders one call returns."
  @spec max_limit() :: pos_integer()
  def max_limit, do: @max_limit

  @doc "The order statuses `statuses` can name."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "Handler of the tool."
  @spec run(map(), map()) :: {:ok, map()} | {:error, :validation_failed, String.t(), map()}
  def run(input, ctx) do
    with {:ok, limit} <- limit(input["limit"]),
         {:ok, since} <- since(input["updated_since"]),
         {:ok, after_position} <- position(input["cursor"]) do
      orders = page(input, limit, since, after_position)
      {page, rest} = Enum.split(orders, limit)

      {:ok,
       %{
         "orders" =>
           OrderExport.serialize_many(page,
             include: OrderTools.include(input["include"]),
             contacts: OrderTools.contacts?(ctx)
           ),
         "next_cursor" => if(rest != [] and page != [], do: cursor(List.last(page))),
         "has_more" => rest != []
       }}
    end
  end

  defp page(input, limit, since, after_position) do
    from(o in Order,
      where: o.status in ^(input["statuses"] || @default_statuses),
      order_by: [asc: o.updated_at, asc: o.uuid],
      limit: ^(limit + 1)
    )
    |> Order.where_sync(sync(input["sync"]))
    |> since_filter(since)
    |> after_filter(after_position)
    |> RepoHelper.repo().all()
  end

  defp sync("pending"), do: :pending
  defp sync("synced"), do: :synced
  defp sync(_any), do: :any

  defp since_filter(query, nil), do: query
  defp since_filter(query, since), do: from(o in query, where: o.updated_at >= ^since)

  defp after_filter(query, nil), do: query

  defp after_filter(query, {updated_at, uuid}) do
    from(o in query,
      where: o.updated_at > ^updated_at or (o.updated_at == ^updated_at and o.uuid > ^uuid)
    )
  end

  # -- input ------------------------------------------------------------------

  defp limit(nil), do: {:ok, @default_limit}
  defp limit(limit) when is_integer(limit) and limit in 1..@max_limit, do: {:ok, limit}

  defp limit(_other),
    do: refuse("limit", "must be an integer from 1 to #{@max_limit}", @max_limit)

  defp since(nil), do: {:ok, nil}

  defp since(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, DateTime.truncate(datetime, :second)}
      {:error, _reason} -> refuse("updated_since", "must be an ISO 8601 date and time")
    end
  end

  defp since(_other), do: refuse("updated_since", "must be an ISO 8601 date and time")

  # -- cursor -----------------------------------------------------------------

  defp cursor(%Order{updated_at: updated_at, uuid: uuid}) do
    %{"t" => DateTime.to_iso8601(updated_at), "u" => uuid}
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp position(nil), do: {:ok, nil}

  defp position(cursor) when is_binary(cursor) do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, %{"t" => time, "u" => uuid}} <- Jason.decode(json),
         {:ok, updated_at, _offset} <- DateTime.from_iso8601(time),
         {:ok, uuid} <- Ecto.UUID.cast(uuid) do
      {:ok, {updated_at, uuid}}
    else
      _ -> bad_cursor()
    end
  end

  defp position(_other), do: bad_cursor()

  defp bad_cursor, do: refuse("cursor", "is not a cursor this tool returned")

  defp refuse(path, message, limit \\ nil) do
    {:error, :validation_failed, "The input does not match the schema of ecommerce.list_orders.",
     %{errors: [%{path: path, message: message, limit: limit, allowed: nil}]}}
  end
end
