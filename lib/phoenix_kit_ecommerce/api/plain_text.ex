defmodule PhoenixKitEcommerce.API.PlainText do
  @moduledoc """
  A description as plain text, from either stored form: HTML or Markdown.

  The Catalogue product source keeps a description in `body_html` as Markdown
  (the Shopify sync converts HTML with `PhoenixKitEcommerce.HtmlToMarkdown`),
  the Legacy source and the CSV import keep HTML. `HtmlText.extract_description/2`
  removes tags only, so Markdown syntax (`**`, `- `, `# `, links) would reach
  the search document and the default card. This module takes out script and
  style blocks, then the Markdown (line-based constructs need the line breaks),
  then the tags, decodes the HTML entities (`HtmlToMarkdown` keeps `&amp; &lt;
  &gt;` encoded in the stored Markdown) and collapses the whitespace, then cuts
  to the limit.

  Text that only looks like Markdown stays: `5 * 3 * 2`, `snake_case_name`,
  `2 > 1`, `a < b`.

  The result is text, not HTML: `&lt;b&gt;` comes out as `<b>`, so any HTML
  consumer must escape it. Limits: only the common named entities (the ASCII
  ones and Latin-1) are decoded, others stay as written; backslash escapes,
  reference-style links and closing `#` of headings are not interpreted.
  """

  # A single description is never longer than a few thousand characters. The
  # input is cut before the patterns that cost the most run, so one
  # pathological value cannot stall the caller: first at a hard bound, then,
  # once the blocks that can be tens of thousands of characters of markup
  # (script and style bodies, base64 data) are gone, at a multiple of the
  # limit. Every pattern below runs in time linear in its input.
  @max_input 1_000_000
  @input_factor 8
  @min_input 100_000

  # Longest span the emphasis and link patterns look across. A longer span is
  # left as written: bounded patterns cannot go quadratic on unclosed markers.
  @span 500

  # A link target: anything up to the closing parenthesis, one level of
  # parentheses inside allowed (`/wiki/Foo_(bar)`).
  @target "(?:[^()]|\\([^()]*\\))*"

  # HTML names for U+00A0..U+00FF, in code point order.
  @latin1 ~w(nbsp iexcl cent pound curren yen brvbar sect uml copy ordf laquo not shy reg macr
             deg plusmn sup2 sup3 acute micro para middot cedil sup1 ordm raquo frac14 frac12
             frac34 iquest Agrave Aacute Acirc Atilde Auml Aring AElig Ccedil Egrave Eacute
             Ecirc Euml Igrave Iacute Icirc Iuml ETH Ntilde Ograve Oacute Ocirc Otilde Ouml
             times Oslash Ugrave Uacute Ucirc Uuml Yacute THORN szlig agrave aacute acirc
             atilde auml aring aelig ccedil egrave eacute ecirc euml igrave iacute icirc iuml
             eth ntilde ograve oacute ocirc otilde ouml divide oslash ugrave uacute ucirc uuml
             yacute thorn yuml)

  @entities @latin1
            |> Enum.zip(0xA0..0xFF)
            |> Map.new(fn {name, code} -> {name, <<code::utf8>>} end)
            |> Map.merge(%{
              "amp" => "&",
              "lt" => "<",
              "gt" => ">",
              "quot" => "\"",
              "apos" => "'",
              "nbsp" => " ",
              "shy" => "",
              "ensp" => " ",
              "emsp" => " ",
              "thinsp" => " ",
              "ndash" => "-",
              "mdash" => "-",
              "minus" => "-",
              "hellip" => "...",
              "lsquo" => "'",
              "rsquo" => "'",
              "sbquo" => "'",
              "ldquo" => "\"",
              "rdquo" => "\"",
              "bdquo" => "\"",
              "bull" => "•",
              "euro" => "€",
              "OElig" => "Œ",
              "oelig" => "œ",
              "Scaron" => "Š",
              "scaron" => "š",
              "ne" => "≠",
              "le" => "≤",
              "ge" => "≥",
              "infin" => "∞",
              "larr" => "←",
              "rarr" => "→",
              "copy" => "(c)",
              "reg" => "(R)",
              "trade" => "(TM)"
            })

  # The legacy references HTML also accepts in capitals (`&AMP;`).
  @any_case ~w(amp lt gt quot nbsp copy reg trade)

  @doc """
  `raw` cut to a few times `limit` characters (at a tag boundary), for a
  converter that has no bound of its own: one pathological value cannot then
  stall the caller. Script and style bodies and inline pictures are dropped
  first, as in `convert/2`, so they do not use up the cut; the cut itself stays
  tighter than `convert/2`'s, because the Markdown converter costs more per
  character. Not a string: returned as it is.
  """
  @spec bound(term(), pos_integer()) :: term()
  def bound(raw, limit) when is_binary(raw) and is_integer(limit) do
    raw
    |> String.slice(0, @max_input)
    |> drop_script_and_style()
    |> drop_data_uris()
    |> cut(limit * @input_factor)
  end

  def bound(other, _limit), do: other

  @doc "Plain text of `raw`, at most `limit` characters; `nil` for blank or not a string."
  @spec convert(term(), pos_integer()) :: String.t() | nil
  def convert(raw, limit) when is_binary(raw) and is_integer(limit) do
    text =
      raw
      |> String.slice(0, @max_input)
      |> drop_script_and_style()
      |> drop_data_uris()
      |> cut(max(limit * @input_factor, @min_input))
      |> close_tags_on_one_line()
      |> strip_markdown()
      |> strip_tags()
      |> decode_entities()
      |> collapse_whitespace()
      |> String.slice(0, limit)
      |> String.trim_trailing()

    if text == "", do: nil, else: text
  end

  def convert(_other, _limit), do: nil

  # A script or style body is code, not text. An unclosed one runs to the end,
  # as a browser reads it.
  defp drop_script_and_style(text) do
    replace(text, ~r/<(script|style)\b(?:(?!<\/\1\s*>).)*(?:<\/\1\s*>|\z)/isu, " ")
  end

  # Inline base64 images (`<img src="data:...">`, `![](data:...)`) are the one
  # realistic source of a huge span that is not text.
  defp drop_data_uris(text) do
    replace(
      text,
      ~r/data:[\w.+\/-]{1,100}(?:;[\w=.+-]{1,60}){0,3};base64,[A-Za-z0-9+\/=_-]+/u,
      ""
    )
  end

  # A cut can fall inside a tag; what is left of it is not text.
  defp cut(text, size) do
    if String.length(text) > size do
      {head, tail} = split_at_last_closer(String.slice(text, 0, size))
      [text_before_tag | _rest] = Regex.split(~r/<(?:\/?[a-zA-Z]|!)/, tail, parts: 2)
      head <> text_before_tag
    else
      text
    end
  end

  # The line rules of Markdown must not see the inside of a tag: a `>` that
  # starts a line would read as a quote marker and eat the text after it.
  defp close_tags_on_one_line(text) do
    replace(text, ~r/<[a-zA-Z\/!][^<>]{0,2000}>/u, &String.replace(&1, ~r/\s+/u, " "))
  end

  defp strip_markdown(raw) do
    raw
    |> replace(~r/!\[([^\]]{0,#{@span}})\]\(#{@target}\)/u, "\\1")
    |> replace(~r/\[([^\]]{0,#{@span}})\]\(#{@target}\)/u, "\\1")
    |> replace(~r/^[ \t]*(?:`{3,}|~{3,}).*$/mu, "")
    |> replace(~r/^[ \t]*(?:-{3,}|\*{3,}|_{3,})[ \t\r]*$/mu, "")
    |> replace(~r/\\\|/u, "|")
    |> replace(
      ~r/^[ \t]*\|?[ \t]*:?-{3,}:?[ \t]*(?:\|[ \t]*:?-{3,}:?[ \t]*)*\|?[ \t\r]*$/mu,
      ""
    )
    |> replace(~r/^[ \t]*\|.*$/mu, &String.replace(&1, "|", " "))
    |> replace(~r/^\s{0,3}\#{1,6}\s+/mu, "")
    |> replace(~r/^\s{0,3}>\s?/mu, "")
    |> replace(~r/^[ \t]*(?:[-*+]|\d+[.)])\s+/mu, "")
    |> replace(~r/(\*\*|__)(?=\S)(.{1,#{@span}}?)(?<=\S)\1/u, "\\2")
    |> replace(~r/(?<![\w*])\*(?=\S)([^*\n]+?)(?<=\S)\*(?![\w*])/u, "\\1")
    |> replace(~r/(?<![\w_])_(?=\S)([^_\n]+?)(?<=\S)_(?![\w_])/u, "\\1")
    |> replace(~r/~~(?=\S)(.{1,#{@span}}?)(?<=\S)~~/u, "\\1")
    |> replace(~r/`([^`\n]+)`/u, "\\1")
  end

  # A tag opens with a letter, `/letter` or `!`; a bare `<` is text. Only the
  # part up to the last `>` is searched, so every opener has a closer ahead
  # and the scan for it cannot run to the end of the text again and again.
  defp strip_tags(text) do
    {head, tail} = split_at_last_closer(text)
    replace(head, ~r/<(?:\/?[a-zA-Z]|!)[^>]*>/u, " ") <> tail
  end

  defp split_at_last_closer(text) do
    case Regex.run(~r/\A(.*>)(.*)\z/s, text) do
      [_whole, head, tail] -> {head, tail}
      nil -> {"", text}
    end
  end

  # One pass, so `&amp;lt;` becomes `&lt;` and not `<`. A reference that is not
  # a known name or a valid character stays as written; a control character
  # (a NUL cannot be stored) becomes a space.
  defp decode_entities(text) do
    replace(
      text,
      ~r/&(#[xX][0-9a-fA-F]{1,6}|#\d{1,7}|[a-zA-Z][a-zA-Z0-9]{1,7});/u,
      &decode_entity/2
    )
  end

  defp decode_entity(whole, "#" <> number) do
    parsed =
      case number do
        "x" <> hex -> Integer.parse(hex, 16)
        "X" <> hex -> Integer.parse(hex, 16)
        decimal -> Integer.parse(decimal)
      end

    case parsed do
      {code, ""} -> character(code, whole)
      _other -> whole
    end
  end

  defp decode_entity(whole, name) do
    lower = String.downcase(name)

    cond do
      Map.has_key?(@entities, name) -> Map.fetch!(@entities, name)
      lower in @any_case -> Map.fetch!(@entities, lower)
      true -> whole
    end
  end

  defp character(code, _whole) when code < 0x20 or code in 0x7F..0x9F, do: " "

  defp character(code, whole) when code > 0x10FFFF or code in 0xD800..0xDFFF, do: whole

  defp character(code, _whole), do: <<code::utf8>>

  defp collapse_whitespace(text), do: text |> replace(~r/\s+/u, " ") |> String.trim()

  defp replace(text, regex, replacement), do: Regex.replace(regex, text, replacement)
end
