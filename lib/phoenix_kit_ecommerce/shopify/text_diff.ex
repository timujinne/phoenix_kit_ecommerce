defmodule PhoenixKitEcommerce.Shopify.TextDiff do
  @moduledoc """
  Word-level diff between two versions of a text field.

  Built on `List.myers_difference/2` over whitespace-preserving tokens, so
  no diff dependency is needed and rejoining the fragments reproduces the
  inputs exactly — the view relies on that to render "before" and "after"
  from one pass.

  Both functions are pure. `summary/2` is cheap enough to call for every
  row a section renders; `words/2` is only called for the one row an
  operator expanded (a 1.6 KB body_html times 500 products is not
  something to compute, or send to a browser, up front).
  """

  @type fragment :: {:eq | :del | :ins, String.t()}

  @doc """
  Returns the diff as ordered fragments. `nil` is treated as an empty string.
  """
  @spec words(String.t() | nil, String.t() | nil) :: [fragment()]
  def words(current, incoming) do
    current = current || ""
    incoming = incoming || ""

    fragments =
      current
      |> tokenize()
      |> List.myers_difference(tokenize(incoming))
      |> Enum.map(fn {op, tokens} -> {op, Enum.join(tokens)} end)
      # tokenize("") is [""], so diffing an empty side against a non-empty
      # one yields a spurious empty-text fragment alongside the real one.
      |> Enum.reject(fn {_op, text} -> text == "" end)

    case fragments do
      # Both sides empty: nothing survived the filter above, but the view
      # always needs at least one fragment to render.
      [] -> [{:eq, ""}]
      _ -> fragments
    end
  end

  @doc """
  Cheap shape of the change: how many non-equal fragments, and how much
  longer or shorter the text became.
  """
  @spec summary(String.t() | nil, String.t() | nil) :: %{
          fragments: non_neg_integer(),
          length_delta: integer()
        }
  def summary(current, incoming) do
    current = current || ""
    incoming = incoming || ""

    fragments =
      current
      |> words(incoming)
      # A word replacement is a :del next to an :ins - two raw fragments
      # but one changed region, so count consecutive non-eq runs, not
      # individual entries.
      |> Enum.chunk_by(fn {op, _text} -> op == :eq end)
      |> Enum.count(fn [{op, _text} | _] -> op != :eq end)

    %{fragments: fragments, length_delta: String.length(incoming) - String.length(current)}
  end

  # Keeps whitespace as its own token so joining fragments is lossless.
  defp tokenize(""), do: [""]

  defp tokenize(text) do
    ~r/(\s+)/u
    |> Regex.split(text, include_captures: true, trim: false)
    |> Enum.reject(&(&1 == ""))
  end
end
