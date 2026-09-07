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

  Supported tags: `p`, `br`, `h1`-`h6`, `ul`/`ol`/`li`, `strong`/`b`,
  `em`/`i`, `a`, `img`, plus a transparent `div` wrapper and HTML entity
  decoding (`&amp;`, `&nbsp;`, `&quot;`, `&#39;`, numeric character
  references). Text with no HTML tag at all is returned byte-for-byte
  unchanged, which is what makes `convert/1` idempotent — converting an
  already-converted (or always-plain) value is a no-op. Markdown already
  present in text nodes (`**bold**`, `- item`) is never escaped, it is
  copied through verbatim.
  """

  @tag_regex ~r/<[^>]+>/
  @block_tags ~w(p div h1 h2 h3 h4 h5 h6 ul ol li)
  @void_tags ~w(br img)
  @heading_tags ~w(h1 h2 h3 h4 h5 h6)
  @bold_tags ~w(strong b)
  @italic_tags ~w(em i)

  @doc """
  Converts `html` to Markdown. Text that contains no HTML tag at all is
  returned unchanged.
  """
  @spec convert(String.t() | nil) :: String.t() | nil
  def convert(nil), do: nil
  def convert(""), do: ""

  def convert(html) when is_binary(html) do
    if Regex.match?(@tag_regex, html) do
      html
      |> tokenize()
      |> parse()
      |> render_blocks()
      |> trim_line_edges()
      |> collapse_blank_lines()
      |> String.trim()
    else
      html
    end
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
    case Regex.run(~r/^<([a-zA-Z][a-zA-Z0-9]*)([^>]*)>$/, token) do
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

  defp parse_attrs(str) do
    double = Regex.scan(~r/([a-zA-Z_:][a-zA-Z0-9_:.-]*)\s*=\s*"([^"]*)"/, str) |> Enum.map(&tl/1)
    single = Regex.scan(~r/([a-zA-Z_:][a-zA-Z0-9_:.-]*)\s*=\s*'([^']*)'/, str) |> Enum.map(&tl/1)

    (double ++ single)
    |> Enum.reduce(%{}, fn [k, v], acc -> Map.put(acc, String.downcase(k), decode_entities(v)) end)
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

  defp render_block({:element, _other, _attrs, children}), do: render_blocks(children)

  defp wrap_paragraph(inline) do
    case String.trim(inline) do
      "" -> ""
      content -> content <> "\n\n"
    end
  end

  defp render_list(children, ordered_start) do
    items =
      children
      |> Enum.filter(&match?({:element, "li", _, _}, &1))
      |> Enum.with_index()
      |> Enum.map(fn {{:element, "li", _attrs, li_children}, index} ->
        marker = if ordered_start, do: "#{ordered_start + index}. ", else: "- "
        marker <> String.trim(render_inline(li_children))
      end)

    case items do
      [] -> ""
      _ -> Enum.join(items, "\n") <> "\n\n"
    end
  end

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
