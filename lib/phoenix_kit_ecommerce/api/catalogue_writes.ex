defmodule PhoenixKitEcommerce.API.CatalogueWrites do
  @moduledoc """
  The one place the admin tools write catalogue items through the catalogue's
  batch update (`Catalogue.update_items/2`). The rest of the API
  code does not know the catalogue's argument or return shape: if it
  differs from what is assumed here, this module is the only one to change.

  The catalogue takes `{item_uuid, attrs, row_opts}` and answers
  `{:ok, [{item_uuid, {:updated, item} | {:unchanged, item} | {:error, why}}]}`
  in the order given; `row_opts` override the call's options for that row,
  which is how each row owns exactly the `data` paths it writes.
  """

  @compile {:no_warn_undefined,
            [
              PhoenixKitCatalogue.Catalogue,
              PhoenixKitCatalogue.Schemas.Category,
              PhoenixKitCatalogue.Schemas.Item
            ]}

  import Ecto.Query, only: [from: 2]

  require Logger

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Schemas.Category
  alias PhoenixKitCatalogue.Schemas.Item
  alias PhoenixKitEcommerce.API.{Meta, Rows}

  @type answer :: {:ok, struct()} | {:unchanged, struct()} | {:error, Rows.t()}

  @doc """
  Runs `fun` in a transaction that holds the lock of every item in `items`,
  and answers `{:ok, what_fun_answers}`. If the transaction does not commit
  (a write inside it rolled the transaction back, as a nested rollback does to
  the one around it, or the database refused), nothing of it is kept and the
  answer is `{:error, row_error}`, a `Rows` error (`database_error`) fit to
  stand for each row that was to be written. `fun` gets the locked rows as read
  now, `%{uuid => item}` (an item that is gone is absent), so it can check them
  against what a plan was made from and have `update_rows/2` write in the same
  transaction. The locks are taken in the catalogue's own order (the
  categories involved `FOR SHARE`, then the items `FOR UPDATE`, each sorted by
  uuid), so this cannot deadlock with a batch of the catalogue or a category
  trash. The caller must only write fields whose rows `update_items` leaves
  alone outside the transaction: price and availability rows move no folder,
  which is what the catalogue asks a caller inside its transaction to be sure of.
  `attach_images` and `detach_images` are the exception to that rule: they write
  the gallery (`data["media_order"]` and the featured pointer) with
  `Catalogue.update_item/3` inside this transaction, together with the files
  they place or release. That is safe because a gallery write changes neither
  the name nor the category of the product, so the catalogue's pass that makes
  the media folders follow a save has no folder to move, and doing it here is
  what lets a gallery that could not be saved give the files back.
  """
  @spec with_locked_items([struct()], (%{String.t() => struct()} -> result)) ::
          {:ok, result} | {:error, Rows.t()}
        when result: term()
  def with_locked_items(items, fun) when is_list(items) and is_function(fun, 1) do
    repo = PhoenixKit.Config.get_repo()
    uuids = items |> Enum.map(& &1.uuid) |> Enum.uniq() |> Enum.sort()

    case repo.transaction(fn -> repo |> lock(uuids) |> fun.() end) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        Logger.error(
          "[API.CatalogueWrites] with_locked_items failed: " <> Meta.term_class(reason)
        )

        {:error,
         Rows.error(:validation_failed, "The product could not be saved.", %{
           "reason" => "database_error"
         })}
    end
  end

  defp lock(repo, uuids) do
    repo.all(
      from(c in Category,
        where:
          c.uuid in subquery(
            from(i in Item,
              where: i.uuid in ^uuids and not is_nil(i.category_uuid),
              select: i.category_uuid
            )
          ),
        order_by: c.uuid,
        lock: "FOR SHARE",
        select: c.uuid
      )
    )

    from(i in Item, where: i.uuid in ^uuids, order_by: i.uuid, lock: "FOR UPDATE")
    |> repo.all()
    |> Map.new(&{&1.uuid, &1})
  end

  @doc """
  Tells the catalogue's listeners about items `update_rows/2` wrote with
  `broadcast: false`, once per catalogue. The catalogue sends these events
  itself after its own statements, which inside a caller's transaction is
  before the caller commits; a caller that writes in one passes
  `broadcast: false` and calls this after the commit.
  """
  @spec announce_updated([struct()]) :: :ok
  def announce_updated(items) do
    items
    |> Enum.group_by(& &1.catalogue_uuid, & &1.uuid)
    |> Enum.each(fn {catalogue_uuid, uuids} ->
      Catalogue.broadcast_item_batch_change(catalogue_uuid, :updated, uuids)
    end)
  end

  @doc """
  Updates `entries` (`[{item, attrs, row_opts}]`) in one batch and answers one
  result per entry, in order. `opts` go to the catalogue unchanged
  (`:actor_uuid`, `:log_metadata`, `:mode`, `:skip_derive`, `:broadcast`); `row_opts` are
  `:data_owned_paths` and `:logged_data_paths`.
  """
  @spec update_rows([{struct(), map(), keyword()}], keyword()) :: [answer()]
  def update_rows([], _opts), do: []

  def update_rows(entries, opts) when is_list(entries) do
    rows = Enum.map(entries, fn {item, attrs, row_opts} -> {item.uuid, attrs, row_opts} end)

    case Catalogue.update_items(rows, opts) do
      {:ok, outcomes} when is_list(outcomes) ->
        by_uuid = Map.new(outcomes)

        Enum.map(entries, fn {item, _attrs, _row_opts} ->
          normalize(Map.get(by_uuid, item.uuid), opts)
        end)

      {:error, reason} ->
        # The term can carry SQL fragments, constraint names or driver text,
        # and submitted values: log and answer get only a class.
        log_failure("update_items", opts, reason)
        failed(entries, "The batch could not be saved.", reason_class(reason))
    end
  end

  # A failure of the whole batch (`failed/3`) or of one row (`normalize/2`) that
  # is not a changeset or `:not_found` is answered with the code
  # `validation_failed` and `context.reason` set to the class of the cause
  # (`database_error`, `duplicate_row`, ... or `unexpected`). The code is shared
  # with real validation errors on purpose (one row-level code set), but a
  # `database_error` or `unexpected` reason is not the client's fault and is
  # worth a retry.
  defp normalize({:updated, item}, _opts), do: {:ok, item}
  defp normalize({:unchanged, item}, _opts), do: {:unchanged, item}

  defp normalize({:error, %Ecto.Changeset{} = changeset}, _opts),
    do: {:error, Rows.from_changeset(changeset)}

  defp normalize({:error, :not_found}, _opts),
    do: {:error, Rows.error(:not_found, "The product no longer exists.")}

  defp normalize({:error, other}, opts) do
    log_failure("a row of update_items", opts, other)

    {:error,
     Rows.error(:validation_failed, "The product could not be saved.", %{
       "reason" => reason_class(other)
     })}
  end

  defp normalize(nil, _opts),
    do: {:error, Rows.error(:validation_failed, "The catalogue gave no answer for this row.")}

  defp failed(entries, message, class) do
    Enum.map(entries, fn _entry ->
      {:error, Rows.error(:validation_failed, message, %{"reason" => class})}
    end)
  end

  # A short stable class for the answer; the term itself never leaves the log.
  defp reason_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_class(_reason), do: "unexpected"

  defp log_failure(what, opts, reason) do
    request_id = get_in(Keyword.get(opts, :log_metadata, %{}), ["request_id"])

    Logger.error(
      "[API.CatalogueWrites] request #{request_id}: #{what} failed: " <> Meta.term_class(reason)
    )
  end
end
