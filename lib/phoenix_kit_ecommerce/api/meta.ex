defmodule PhoenixKitEcommerce.API.Meta do
  @moduledoc """
  Who made an API call, as the catalogue's change log wants to record it:
  the key's owner is the actor, and the metadata names the tool,
  the key prefix and the request. `approved_by_uuid` is added when core's
  approval flow ran the call.
  """

  @doc "Metadata for `:log_metadata` of a catalogue write."
  @spec log_metadata(map(), String.t()) :: %{String.t() => term()}
  def log_metadata(ctx, tool) do
    actor = Map.get(ctx, :actor) || %{}

    %{
      "via" => "api",
      "tool" => tool,
      "key_prefix" => Map.get(actor, :key_prefix),
      "request_id" => Map.get(ctx, :request_id)
    }
    |> put_present("approved_by_uuid", Map.get(ctx, :approved_by_uuid))
  end

  @doc "The key owner's user uuid: the actor of every write."
  @spec actor_uuid(map()) :: String.t() | nil
  def actor_uuid(ctx), do: (Map.get(ctx, :actor) || %{}) |> Map.get(:user_uuid)

  @doc """
  The shape of a term for a log line: an atom, a tuple's tag, a struct's
  module. Never the term itself, which can carry submitted values or driver text.
  """
  @spec term_class(term()) :: String.t()
  def term_class(term) when is_atom(term), do: inspect(term)
  def term_class(%module{}), do: inspect(module)
  def term_class({tag, _rest}) when is_atom(tag), do: "{" <> inspect(tag) <> ", _}"
  def term_class(term) when is_tuple(term), do: "tuple"
  def term_class(_term), do: "other"

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
