defmodule PhoenixKitEcommerce.API.OrderRefs do
  @moduledoc """
  Order references of the order tools: `{"id": uuid}` or `{"number": "ORD-..."}`.
  One answer per reference, in the order given; a bad or unknown reference is a
  row error and the rows after it are still resolved.
  """

  import Ecto.Query, warn: false

  alias PhoenixKit.RepoHelper
  alias PhoenixKitBilling.Order
  alias PhoenixKitEcommerce.API.Rows

  @type answer :: {:ok, struct()} | {:error, Rows.t()}

  @doc "Resolves `refs` (decoded JSON maps) to orders."
  @spec resolve([term()]) :: [answer()]
  def resolve(refs) when is_list(refs) do
    checked = Enum.map(refs, &check/1)
    orders = load(for {:ok, key} <- checked, do: key)

    Enum.zip_with(refs, checked, fn
      ref, {:ok, key} -> found(orders, key, ref)
      _ref, {:error, message} -> {:error, Rows.error(:validation_failed, message)}
    end)
  end

  defp check(%{} = ref) do
    given =
      for key <- ["id", "number"], value = Map.get(ref, key), not is_nil(value), do: {key, value}

    case given do
      [{"id", id}] when is_binary(id) -> check_id(id)
      [{"number", number}] when is_binary(number) -> check_number(number)
      _ -> {:error, "give exactly one of id or number"}
    end
  end

  defp check(_other), do: {:error, "a reference must be an object"}

  defp check_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, {:id, uuid}}
      :error -> {:error, "id must be a UUID"}
    end
  end

  defp check_number(number) do
    cond do
      String.trim(number) == "" -> {:error, "number must not be empty"}
      # Postgres text cannot hold a NUL byte; the query would fail for the whole batch.
      String.contains?(number, <<0>>) -> {:error, "number must not contain a NUL byte"}
      true -> {:ok, {:number, number}}
    end
  end

  defp load([]), do: %{}

  defp load(keys) do
    ids = for {:id, id} <- keys, do: id
    numbers = for {:number, number} <- keys, do: number

    from(o in Order, where: o.uuid in ^ids or o.order_number in ^numbers)
    |> RepoHelper.repo().all()
    |> Enum.flat_map(&[{{:id, &1.uuid}, &1}, {{:number, &1.order_number}, &1}])
    |> Map.new()
  end

  defp found(orders, key, ref) do
    case Map.fetch(orders, key) do
      {:ok, order} ->
        {:ok, order}

      :error ->
        {:error, Rows.error(:not_found, "No order matches this reference.", %{"ref" => ref})}
    end
  end
end
