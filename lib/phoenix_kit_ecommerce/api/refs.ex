defmodule PhoenixKitEcommerce.API.Refs do
  @moduledoc """
  Product references of the admin tools: `{"id": uuid}`,
  `{"sku": "..."}` or `{"external_id": "..."}`, resolved inside the shop's
  catalogue by the catalogue's own resolver
  (`PhoenixKitCatalogue.API.resolve_refs/2`). One answer per
  reference, in the order given; a bad reference is a row error, and the
  rows after it are still resolved.
  """

  @compile {:no_warn_undefined, PhoenixKitCatalogue.API}

  require Logger

  alias PhoenixKitEcommerce.API.{Meta, Rows}

  @keys ["id", "sku", "external_id"]

  @type answer :: {:ok, struct()} | {:error, Rows.t()}

  @doc "Resolves `refs` (decoded JSON maps) inside `catalogue_uuid`."
  @spec resolve([term()], String.t()) :: [answer()]
  def resolve(refs, catalogue_uuid) when is_list(refs) and is_binary(catalogue_uuid) do
    checked = Enum.map(refs, &check/1)
    valid = for {ref, :ok} <- Enum.zip(refs, checked), do: ref
    answers = lookup(valid, catalogue_uuid)

    {merged, []} =
      Enum.map_reduce(Enum.zip(refs, checked), answers, fn
        {ref, :ok}, [answer | rest] ->
          {translate(answer, ref), rest}

        {_ref, :ok}, [] ->
          {{:error, Rows.error(:validation_failed, "The reference was not resolved.")}, []}

        {_ref, {:error, message}}, rest ->
          {{:error, Rows.error(:validation_failed, message)}, rest}
      end)

    merged
  end

  defp lookup([], _catalogue_uuid), do: []

  defp lookup(valid, catalogue_uuid) do
    valid
    |> PhoenixKitCatalogue.API.resolve_refs(catalogue_uuid: catalogue_uuid)
    |> Enum.map(fn {_ref, answer} -> answer end)
  end

  defp check(%{} = ref) do
    given = for key <- @keys, value = Map.get(ref, key), not is_nil(value), do: {key, value}

    case given do
      [{"id", id}] when is_binary(id) ->
        if match?({:ok, _}, Ecto.UUID.cast(id)), do: :ok, else: {:error, "id must be a UUID"}

      [{key, value}] when key in ["sku", "external_id"] and is_binary(value) ->
        if String.trim(value) == "", do: {:error, "#{key} must not be empty"}, else: :ok

      _ ->
        {:error, "give exactly one of id, sku or external_id"}
    end
  end

  defp check(_other), do: {:error, "a reference must be an object"}

  defp translate({:ok, item}, _ref), do: {:ok, item}

  defp translate({:error, :not_found}, ref),
    do: {:error, Rows.error(:not_found, "No product matches this reference.", %{"ref" => ref})}

  defp translate({:error, {:ambiguous_ref, ids}}, ref) do
    {:error,
     Rows.error(:ambiguous_ref, "More than one product matches this reference.", %{
       "ref" => ref,
       "candidates" => ids
     })}
  end

  defp translate({:error, :invalid_ref}, ref) do
    {:error, Rows.error(:validation_failed, "The reference is not valid.", %{"ref" => ref})}
  end

  # Not an answer the catalogue's resolver documents. The term can carry
  # driver text and submitted values, so the caller gets a fixed sentence and
  # the log only the term's class.
  defp translate({:error, other}, ref) do
    Logger.error("[API.Refs] unexpected resolve_refs answer: " <> Meta.term_class(other))

    {:error,
     Rows.error(:validation_failed, "The reference could not be resolved.", %{
       "ref" => ref,
       "reason" => "unexpected"
     })}
  end
end
