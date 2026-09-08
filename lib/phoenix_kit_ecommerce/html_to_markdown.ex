defmodule PhoenixKitEcommerce.HtmlToMarkdown do
  @moduledoc """
  Converts HTML (as Shopify's `body_html` product field always is) into
  Markdown.

  The storefront that consumes synced products renders descriptions
  through a Markdown component. By CommonMark rules, a block starting
  with a raw `<p>` tag is treated as opaque raw HTML, so Markdown already
  written inside Shopify's `body_html` (sellers routinely hand-write
  `**bold**`/`- list` text inside `<p>` tags) is emitted byte-for-byte
  instead of rendering. Converting `body_html` to Markdown at sync time
  keeps stored descriptions renderable.

  This is a small hand-rolled HTML -> Markdown transform rather than a
  `LazyHTML`/`Floki`-based one: both are declared `only: :test` in
  `mix.exs`, and this module runs on the Shopify sync write path in
  every environment (not just `:test`) — pulling a test-only parser into
  `:dev`/`:prod` would be a wider dependency-footprint change than this
  fix calls for.

  Supported tags: `p`, `br`, `h1`-`h6`, `ul`/`ol`/`li` (including lists
  nested inside a `<li>`, rendered as an indented sub-list), `table`
  (`thead`/`tbody`/`tfoot`/`tr`/`td`/`th`), `strong`/`b`, `em`/`i`, `a`,
  `img`, plus a transparent `div` wrapper and HTML entity decoding
  (`&amp;`, `&nbsp;`, `&quot;`, `&#39;`, numeric character references).
  `<script>`, `<style>`, `<noscript>` and `<template>` elements are
  dropped entirely, content included, rather than leaking their raw
  text. A bare `<`/`>` that isn't part of a real tag (e.g. "5 < 10") is
  left as plain text instead of being parsed as a tag boundary.
  Text with no HTML tag at all is returned byte-for-byte unchanged, which
  is what makes `convert/1` idempotent — converting an already-converted
  (or always-plain) value is a no-op. Markdown already present in text
  nodes (`**bold**`, `- item`) is never escaped, it is copied through
  verbatim.

  `<table>` becomes a GitHub-Flavored-Markdown pipe table (header row,
  `---` separator, data rows) rather than dropping the structure — a
  naive cell-concatenation would silently glue adjacent cells' text
  together with no separator, which loses information a reader can't
  recover. The header row is whichever row is inside `<thead>`, or the
  first row containing a `<th>`, or — if neither marker is present —
  the table's first row, promoted, so the output is always a valid
  table; any other `<thead>`-tagged rows are folded into the body
  instead of being dropped. Cell text has its own line breaks collapsed
  to spaces and `|` escaped to `\|`, since a table row is a single
  Markdown line.
  """

  # A `<` only starts a tag when followed by `/`, a letter, or `!`
  # (close tag, open tag, or a comment/doctype respectively) — a bare `<`
  # or `>` used as a comparison symbol in prose (e.g. "ratio < 2") is left
  # alone as ordinary text instead of being swallowed as part of a bogus
  # tag match. Inside a real open tag, a quoted attribute value may
  # itself contain `>` (e.g. `title="a > b"`) without ending the tag —
  # the open-tag alternative tracks quotes for that reason; the
  # close-tag/comment alternatives don't need to, since closing tags and
  # comments don't carry quoted attribute values.
  @tag_regex ~r/<(?:\/[a-zA-Z][^>]*|[a-zA-Z](?:[^>"']|"[^"]*"|'[^']*')*|![^>]*)>/
  # Raw-text elements: their content is never markup, even if it contains
  # characters that look like tags (e.g. a JS string literal with
  # `"<img src=x>"` inside it) — stripped whole, before tokenization, so
  # the general tokenizer never sees what's inside them.
  @raw_text_regex ~r/<(script|style|noscript|template)\b[^>]*>.*?<\/\1\s*>/is
  # A raw-text element left unclosed (truncated `body_html`, hand-edited
  # HTML) has no matching `</tag>` for `@raw_text_regex` to anchor on —
  # without this second pass its opening tag would tokenize as an
  # ordinary element and the general tokenizer would render its raw
  # script/style body as visible text.
  @unclosed_raw_text_regex ~r/<(?:script|style|noscript|template)\b[^>]*>.*\z/is
  @indent_marker "\u0001"
  @block_tags ~w(p div h1 h2 h3 h4 h5 h6 ul ol li table)
  @void_tags ~w(br img)
  @heading_tags ~w(h1 h2 h3 h4 h5 h6)
  @bold_tags ~w(strong b)
  @italic_tags ~w(em i)
  @table_container_tags ~w(thead tbody tfoot)
  @table_cell_tags ~w(td th)

  @doc """
  Converts `html` to Markdown. Text that contains no HTML tag at all is
  returned unchanged.
  """
  @spec convert(String.t() | nil) :: String.t() | nil
  def convert(nil), do: nil
  def convert(""), do: ""

  def convert(html) when is_binary(html) do
    stripped = strip_raw_text_elements(html)

    if Regex.match?(@tag_regex, stripped) do
      stripped
      |> tokenize()
      |> parse()
      |> render_blocks()
      |> trim_line_edges()
      |> collapse_blank_lines()
      |> expand_indent_markers()
      |> String.trim()
    else
      stripped
    end
  end

  defp strip_raw_text_elements(html) do
    html
    |> then(&Regex.replace(@raw_text_regex, &1, ""))
    |> then(&Regex.replace(@unclosed_raw_text_regex, &1, ""))
  end

  defp tokenize(html) do
    @tag_regex
    |> Regex.split(html, include_captures: true)
    |> Enum.reject(&(&1 == ""))
  end

  # Recursive-descent parse into `{:element, tag, attrs, children}` /
  # `{:text, string}` nodes. Tolerant of malformed input: an unmatched
  # closing tag is skipped in place rather than raising, and an element
  # left open at the end of input simply closes at end-of-string.
  defp parse(tokens) do
    {nodes, _rest} = parse_until(tokens, nil)
    nodes
  end

  defp parse_until([], _stop_tag), do: {[], []}

  defp parse_until([token | rest], stop_tag) do
    if String.starts_with?(token, "<") do
      parse_tag(token, rest, stop_tag)
    else
      {siblings, final_rest} = parse_until(rest, stop_tag)
      {[{:text, token |> collapse_whitespace() |> decode_entities()} | siblings], final_rest}
    end
  end

  defp parse_tag(token, rest, stop_tag) do
    case classify_tag(token) do
      {:close, name} ->
        if name == stop_tag do
          {[], rest}
        else
          parse_until(rest, stop_tag)
        end

      {:open, "", _attrs, _self_closing?} ->
        parse_until(rest, stop_tag)

      {:open, name, attrs, self_closing?} ->
        if self_closing? or name in @void_tags do
          {siblings, final_rest} = parse_until(rest, stop_tag)
          {[{:element, name, attrs, []} | siblings], final_rest}
        else
          {children, rest_after_children} = parse_until(rest, name)
          {siblings, final_rest} = parse_until(rest_after_children, stop_tag)
          {[{:element, name, attrs, children} | siblings], final_rest}
        end
    end
  end

  defp classify_tag(token) do
    if String.starts_with?(token, "</") do
      classify_close_tag(token)
    else
      classify_open_tag(token)
    end
  end

  defp classify_close_tag(token) do
    case Regex.run(~r/^<\/\s*([a-zA-Z][a-zA-Z0-9]*)/, token) do
      [_, name] -> {:close, String.downcase(name)}
      nil -> {:close, ""}
    end
  end

  defp classify_open_tag(token) do
    case Regex.run(~r/^<([a-zA-Z][a-zA-Z0-9]*)((?:[^>"']|"[^"]*"|'[^']*')*)>$/, token) do
      [_, name, raw_attrs] ->
        {attrs_str, self_closing?} = strip_self_closing_marker(raw_attrs)
        {:open, String.downcase(name), parse_attrs(attrs_str), self_closing?}

      # Not a recognizable start/end tag (e.g. a `<!-- comment -->` or
      # `<!DOCTYPE ...>`) — treat as an inert, childless element.
      nil ->
        {:open, "", %{}, true}
    end
  end

  defp strip_self_closing_marker(attrs_str) do
    trimmed = String.trim(attrs_str)

    if String.ends_with?(trimmed, "/") do
      {String.trim_trailing(trimmed, "/"), true}
    else
      {attrs_str, false}
    end
  end

  # A single alternation, scanned left-to-right, so a quoted value's
  # content (which may itself contain `key=value`-shaped substrings, e.g.
  # a URL query string) is consumed as part of that match and never
  # re-scanned as a stray unquoted attribute. Unquoted values end at
  # whitespace, a quote, or `>` — the same set HTML5 uses.
  @attr_regex ~r/([a-zA-Z_:][a-zA-Z0-9_:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/

  defp parse_attrs(str) do
    @attr_regex
    |> Regex.scan(str)
    |> Enum.reduce(%{}, fn [_full, key | value_groups], acc ->
      # Trailing capture groups that never participated in this match are
      # dropped from the result entirely (not returned as ""), so pad
      # back out to three before picking the one alternative that fired.
      # A non-participating alternative that IS present scans as "" too,
      # so this can't mistake a genuinely empty quoted value (`alt=""`)
      # for a missing one.
      [dq, sq, uq] = value_groups ++ List.duplicate("", 3 - length(value_groups))
      value = Enum.find([dq, sq, uq], "", &(&1 != ""))
      Map.put_new(acc, String.downcase(key), decode_entities(value))
    end)
  end

  # ── block-level rendering ───────────────────────────────────────────

  defp render_blocks(nodes) do
    nodes
    |> group_into_blocks()
    |> Enum.map_join("", &render_block/1)
  end

  # Runs of non-block-level (inline/text) siblings are grouped into an
  # implicit paragraph, e.g. bare text mixed with `<strong>`/`<br>` at the
  # top level of a description that never wraps itself in `<p>`.
  defp group_into_blocks(nodes), do: group_into_blocks(nodes, [], [])

  defp group_into_blocks([], [], acc), do: Enum.reverse(acc)
  defp group_into_blocks([], buf, acc), do: Enum.reverse([{:implicit, Enum.reverse(buf)} | acc])

  defp group_into_blocks([{:element, tag, _, _} = node | rest], buf, acc)
       when tag in @block_tags do
    acc = if buf == [], do: acc, else: [{:implicit, Enum.reverse(buf)} | acc]
    group_into_blocks(rest, [], [node | acc])
  end

  defp group_into_blocks([node | rest], buf, acc) do
    group_into_blocks(rest, [node | buf], acc)
  end

  defp render_block({:implicit, nodes}), do: wrap_paragraph(render_inline(nodes))

  defp render_block({:element, "p", _attrs, children}),
    do: wrap_paragraph(render_inline(children))

  # `<div>` is a transparent container, not a paragraph: it can wrap
  # several block children that must stay separate blocks, not collapse
  # into one.
  defp render_block({:element, "div", _attrs, children}), do: render_blocks(children)

  defp render_block({:element, tag, _attrs, children}) when tag in @heading_tags do
    level = tag |> String.last() |> String.to_integer()

    case render_inline(children) |> String.trim() do
      "" -> ""
      content -> String.duplicate("#", level) <> " " <> content <> "\n\n"
    end
  end

  defp render_block({:element, "ul", _attrs, children}), do: render_list(children, nil)
  defp render_block({:element, "ol", _attrs, children}), do: render_list(children, 1)

  # A stray `<li>` outside `<ul>`/`<ol>` (malformed HTML) still renders as
  # a single-item list rather than being dropped.
  defp render_block({:element, "li", _attrs, children}) do
    wrap_paragraph("- " <> render_inline(children))
  end

  defp render_block({:element, "table", _attrs, children}), do: render_table(children)

  defp render_block({:element, _other, _attrs, children}), do: render_blocks(children)

  defp wrap_paragraph(inline) do
    case String.trim(inline) do
      "" -> ""
      content -> content <> "\n\n"
    end
  end

  defp render_list(children, ordered_start), do: render_list(children, ordered_start, "")

  defp render_list(children, ordered_start, indent) do
    # CommonMark requires a block nested inside a list item to be
    # indented to at least that item's content column — the width of
    # that item's own marker ("1. " is 3 wide, "10. " is 4 wide, "- "
    # is 2 wide) — or it re-parses as a sibling block instead of staying
    # part of the item. Ordered markers grow with the item's number, so
    # `child_indent` is computed per item from its actual marker string
    # rather than a fixed width. It's built from placeholder bytes (not
    # literal spaces) so `trim_line_edges/1` doesn't eat it before
    # `expand_indent_markers/1` turns it into real spaces at the very
    # end of the pipeline.
    items =
      children
      |> Enum.filter(&match?({:element, "li", _, _}, &1))
      |> Enum.with_index()
      |> Enum.map(fn {{:element, "li", _attrs, li_children}, index} ->
        marker = if ordered_start, do: "#{ordered_start + index}. ", else: "- "
        child_indent = indent <> String.duplicate(@indent_marker, String.length(marker))
        indent <> marker <> render_li_content(li_children, child_indent)
      end)

    case items do
      [] -> ""
      _ -> Enum.join(items, "\n") <> "\n\n"
    end
  end

  # An `<li>`'s own text/inline content, followed by any `<ul>`/`<ol>`
  # nested directly inside it rendered as an indented sub-list, on its
  # own lines — instead of being unwrapped and concatenated straight onto
  # the parent item's text. `child_indent` (built by the caller) already
  # carries the width this item's own marker requires, so it just gets
  # threaded down to the nested `render_list/3` call.
  defp render_li_content(li_children, child_indent) do
    # Anything that is a block in its own right has to be rendered as
    # one. Splitting only `ul`/`ol` out used to send a `<table>` (or a
    # `<p>`, `<h2>`, …) nested in a list item through `render_inline`'s
    # catch-all, which unwraps tags and joins their children with no
    # separator at all — a size chart under a "Specifications:" bullet
    # came out as `SpecsH1H2ab`, the exact cell-collapse this module
    # documents that it avoids.
    {inline_nodes, block_nodes} =
      Enum.split_with(li_children, fn
        {:element, tag, _attrs, _children} -> tag not in @block_tags
        _other -> true
      end)

    inline_text = String.trim(render_inline(inline_nodes))

    nested_text =
      block_nodes
      |> Enum.map_join("\n", &render_li_block(&1, child_indent))
      |> String.trim_trailing("\n")

    case nested_text do
      "" -> inline_text
      _ -> inline_text <> "\n" <> nested_text
    end
  end

  # A nested list keeps the parent marker's indent; every other block
  # renders the way it would anywhere else, then gets the same indent so
  # it stays inside the item.
  defp render_li_block({:element, tag, _attrs, children}, child_indent)
       when tag in ["ul", "ol"] do
    ordered_start = if tag == "ol", do: 1, else: nil
    render_list(children, ordered_start, child_indent)
  end

  defp render_li_block(node, child_indent) do
    node
    |> render_block()
    |> String.trim()
    |> indent_block(child_indent)
  end

  defp indent_block("", _indent), do: ""

  defp indent_block(text, indent) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn
      "" -> ""
      line -> indent <> line
    end)
  end

  # Renders `<table>` as a GFM pipe table. See the moduledoc for the
  # header-row selection rule and why cells never collapse into one
  # unseparated run of text.
  defp render_table(children) do
    case extract_table_rows(children) do
      [] ->
        ""

      rows ->
        {header_cells, body_rows} = split_header(rows)
        col_count = Enum.max(Enum.map([header_cells | body_rows], &length/1))

        lines =
          [
            render_table_row(header_cells, col_count),
            render_table_row(List.duplicate("---", col_count), col_count)
          ] ++ Enum.map(body_rows, &render_table_row(&1, col_count))

        Enum.join(lines, "\n") <> "\n\n"
    end
  end

  # A row is `is_header?` when it came from inside `<thead>` or contains
  # at least one `<th>`. The first header row found becomes the table
  # header; any further header-marked rows (a malformed multi-row
  # `<thead>`) are folded into the body rather than dropped, since a
  # Markdown table can only have one header row.
  defp split_header(rows) do
    case Enum.split_with(rows, fn {is_header?, _cells} -> is_header? end) do
      {[{_, header_cells} | extra_header_rows], other_rows} ->
        extra = Enum.map(extra_header_rows, fn {_, cells} -> cells end)
        body = Enum.map(other_rows, fn {_, cells} -> cells end)
        {header_cells, extra ++ body}

      {[], [{_, first_cells} | rest]} ->
        body = Enum.map(rest, fn {_, cells} -> cells end)
        {first_cells, body}
    end
  end

  defp render_table_row(cells, col_count) do
    padded = cells ++ List.duplicate("", max(col_count - length(cells), 0))
    "| " <> Enum.join(padded, " | ") <> " |"
  end

  defp extract_table_rows(nodes), do: extract_table_rows(nodes, false)

  defp extract_table_rows(nodes, in_thead?) do
    Enum.flat_map(nodes, &extract_table_row_node(&1, in_thead?))
  end

  defp extract_table_row_node({:element, "thead", _attrs, children}, _in_thead?) do
    extract_table_rows(children, true)
  end

  defp extract_table_row_node({:element, tag, _attrs, children}, in_thead?)
       when tag in @table_container_tags do
    extract_table_rows(children, in_thead?)
  end

  defp extract_table_row_node({:element, "tr", _attrs, cell_nodes}, in_thead?) do
    cells =
      cell_nodes
      |> Enum.filter(&match?({:element, tag, _, _} when tag in @table_cell_tags, &1))

    has_th? = Enum.any?(cells, &match?({:element, "th", _, _}, &1))
    texts = Enum.map(cells, &extract_cell_text/1)

    [{in_thead? or has_th?, texts}]
  end

  defp extract_table_row_node(_other, _in_thead?), do: []

  # A pipe cell is a single line, so block children inside it (a list, a
  # paragraph) are flattened — but flattened with their boundaries kept
  # as spaces. Rendering them inline instead would join "Row" and its
  # nested item into "Rownested".
  defp extract_cell_text({:element, _tag, _attrs, children}) do
    children
    |> Enum.map_join(" ", &cell_fragment/1)
    |> String.trim()
    |> String.replace(~r/\s*\n\s*/, " ")
    |> String.replace(~r/\s{2,}/, " ")
    |> String.replace("|", "\\|")
  end

  defp cell_fragment({:element, tag, _attrs, _children} = node) when tag in @block_tags,
    do: node |> render_block() |> String.trim()

  defp cell_fragment(node), do: render_inline([node])

  # ── inline rendering ─────────────────────────────────────────────────

  defp render_inline(nodes) when is_list(nodes) do
    Enum.map_join(nodes, "", &render_inline_node/1)
  end

  defp render_inline_node({:text, text}), do: text
  defp render_inline_node({:element, "br", _attrs, _children}), do: "\n"

  defp render_inline_node({:element, tag, _attrs, children}) when tag in @bold_tags do
    "**" <> render_inline(children) <> "**"
  end

  defp render_inline_node({:element, tag, _attrs, children}) when tag in @italic_tags do
    "*" <> render_inline(children) <> "*"
  end

  defp render_inline_node({:element, "a", attrs, children}) do
    "[" <> render_inline(children) <> "](" <> Map.get(attrs, "href", "") <> ")"
  end

  defp render_inline_node({:element, "img", attrs, _children}) do
    "![" <> Map.get(attrs, "alt", "") <> "](" <> Map.get(attrs, "src", "") <> ")"
  end

  # Any other/unknown tag (e.g. a stray `<span>`) is unwrapped — its
  # content is kept, the tag itself is dropped.
  defp render_inline_node({:element, _other, _attrs, children}), do: render_inline(children)

  defp collapse_blank_lines(text), do: Regex.replace(~r/\n{3,}/, text, "\n\n")

  # Turns each `@indent_marker` placeholder back into one real space (the
  # caller duplicates it marker_width-many times per level, so the count
  # of markers is already the exact column width needed). Run last, after
  # `trim_line_edges/1` (which would otherwise strip real leading spaces
  # as stray whitespace hugging a newline).
  defp expand_indent_markers(text), do: String.replace(text, @indent_marker, " ")

  # HTML treats runs of whitespace (including literal newlines in the
  # source markup, common right after a `<br>`) as insignificant —
  # collapsed to a single space when rendered. Only an actual `<br>`/block
  # boundary is a real line break, so text nodes must have their own raw
  # whitespace collapsed before those are added, or a `<br>\n` in the
  # source would render as two breaks instead of one.
  defp collapse_whitespace(text), do: Regex.replace(~r/[ \t\r\n]+/, text, " ")

  # Strips the stray leading/trailing space that collapse_whitespace/1
  # can leave hugging a `<br>`- or block-boundary-derived newline.
  defp trim_line_edges(text), do: Regex.replace(~r/[ \t]*\n[ \t]*/, text, "\n")

  defp decode_entities(text) do
    text
    |> String.replace("&nbsp;", " ")
    |> String.replace("&quot;", "\"")
    |> String.replace(~r/&(?:#39|apos);/, "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> decode_numeric_entities()
    |> String.replace("&amp;", "&")
  end

  defp decode_numeric_entities(text) do
    text
    |> then(
      &Regex.replace(~r/&#x([0-9a-fA-F]+);/, &1, fn _, hex ->
        codepoint_to_string(String.to_integer(hex, 16))
      end)
    )
    |> then(
      &Regex.replace(~r/&#(\d+);/, &1, fn _, dec ->
        codepoint_to_string(String.to_integer(dec))
      end)
    )
  end

  defp codepoint_to_string(codepoint), do: <<codepoint::utf8>>
end
