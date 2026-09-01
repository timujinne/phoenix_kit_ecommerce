defmodule PhoenixKitEcommerce.Shopify.TextDiff do
  @moduledoc """
  Word-level diff between two versions of a text field.

  Built on `List.myers_difference/2` over whitespace-preserving tokens, so
  no diff dependency is needed and rejoining the fragments reproduces the
  inputs exactly — the view relies on that to render "before" and "after"
  from one pass.

  Both functions are pure. `summary/2` needs an exact changed-fragment
  count, which means it runs the same `List.myers_difference/2` pass as
  `words/2` internally — it is not a cheap approximation, just a smaller
  return value.

  Myers is O(N*D), so the cost tracks how DIFFERENT the two texts are, not
  how long they are. Measured on a 1.7 KB `body_html`:

      small edit          0.55 ms
      half the text       2.33 ms
      wholly rewritten   12.0  ms

  A caller listing many rows must bound how many it renders at once: 529
  rows of the last kind is 6.3 seconds inside the LiveView process. Page
  the rows and call this only for the page being shown.
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
  Small-payload shape of the change: how many changed regions, and how
  much longer or shorter the text became. Getting an exact count still
  requires running the full diff (see the module doc) — this is smaller
  to return and to render, not cheaper to compute.
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
    Regex.split(~r/(\s+)/u, text, include_captures: true, trim: true)
  end
end
