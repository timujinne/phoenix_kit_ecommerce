defmodule PhoenixKitEcommerce.API.Rows do
  @moduledoc """
  The error of one row of a batch tool: `%{"code", "message",
  "context"}`. The codes are the row-level codes of the API
  (`not_found`, `ambiguous_ref`, `duplicate_line`, `validation_failed`). A
  row's error never stops the other rows.
  """

  @type t :: %{String.t() => term()}

  @doc "Builds a row error."
  @spec error(atom(), String.t(), map()) :: t()
  def error(code, message, context \\ %{}) when is_atom(code) and is_binary(message) do
    %{"code" => Atom.to_string(code), "message" => message, "context" => context}
  end

  @doc "A `validation_failed` row error carrying the `errors` of a plan."
  @spec invalid([map()]) :: t()
  def invalid(errors) when is_list(errors) do
    error(:validation_failed, "The row does not pass validation.", %{
      "errors" => Enum.map(errors, &stringify/1)
    })
  end

  @doc "A `validation_failed` row error from a changeset."
  @spec from_changeset(Ecto.Changeset.t()) :: t()
  def from_changeset(%Ecto.Changeset{} = changeset) do
    errors =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
        Regex.replace(~r"%{(\w+)}", message, fn _, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)
      end)
      |> Enum.flat_map(fn {field, messages} ->
        Enum.map(
          List.flatten(messages),
          &%{"path" => to_string(field), "message" => to_string(&1)}
        )
      end)

    error(:validation_failed, "The product could not be saved.", %{"errors" => errors})
  end

  defp stringify(%{} = error) do
    error
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end
end
