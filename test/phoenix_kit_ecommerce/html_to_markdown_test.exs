defmodule PhoenixKitEcommerce.HtmlToMarkdownTest do
  @moduledoc """
  Coverage for the HTML -> Markdown conversion used on the Shopify sync
  write path: one case per supported tag, preservation of Markdown
  already embedded in text nodes, and idempotency.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.HtmlToMarkdown

  describe "convert/1 - tag coverage" do
    test "plain text with no HTML tag is returned unchanged" do
      assert HtmlToMarkdown.convert("Just plain text, no markup at all.") ==
               "Just plain text, no markup at all."
    end

    test "nil and empty string pass through" do
      assert HtmlToMarkdown.convert(nil) == nil
      assert HtmlToMarkdown.convert("") == ""
    end

    test "<p> becomes a paragraph, blank line between consecutive paragraphs" do
      assert HtmlToMarkdown.convert("<p>First.</p><p>Second.</p>") == "First.\n\nSecond."
    end

    test "<br> becomes a soft line break inside a paragraph" do
      assert HtmlToMarkdown.convert("<p>Line one<br>Line two</p>") == "Line one\nLine two"
    end

    for n <- 1..6 do
      test "<h#{n}> becomes a level-#{n} ATX heading" do
        tag = "h#{unquote(n)}"

        assert HtmlToMarkdown.convert("<#{tag}>Heading</#{tag}>") ==
                 String.duplicate("#", unquote(n)) <> " Heading"
      end
    end

    test "<ul><li> becomes a dash list" do
      assert HtmlToMarkdown.convert("<ul><li>One</li><li>Two</li></ul>") == "- One\n- Two"
    end

    test "<ol><li> becomes a numbered list" do
      assert HtmlToMarkdown.convert("<ol><li>One</li><li>Two</li></ol>") == "1. One\n2. Two"
    end

    test "<strong> and <b> become bold" do
      assert HtmlToMarkdown.convert("<p><strong>Bold</strong></p>") == "**Bold**"
      assert HtmlToMarkdown.convert("<p><b>Bold</b></p>") == "**Bold**"
    end

    test "<em> and <i> become italic" do
      assert HtmlToMarkdown.convert("<p><em>Italic</em></p>") == "*Italic*"
      assert HtmlToMarkdown.convert("<p><i>Italic</i></p>") == "*Italic*"
    end

    test "<a> becomes a Markdown link" do
      assert HtmlToMarkdown.convert(~s(<p><a href="https://example.com">link</a></p>)) ==
               "[link](https://example.com)"
    end

    test "<img> becomes a Markdown image" do
      assert HtmlToMarkdown.convert(
               ~s(<p><img src="https://example.com/x.png" alt="Alt text"></p>)
             ) ==
               "![Alt text](https://example.com/x.png)"
    end

    test "<div> is a transparent wrapper: its block children stay separate" do
      assert HtmlToMarkdown.convert("<div><h3>Title</h3><p>Body.</p></div>") ==
               "### Title\n\nBody."
    end

    test "HTML entities decode: &amp; &nbsp; &quot; &#39; and numeric refs" do
      assert HtmlToMarkdown.convert("<p>A &amp; B</p>") == "A & B"
      assert HtmlToMarkdown.convert("<p>A&nbsp;B</p>") == "A B"
      assert HtmlToMarkdown.convert("<p>She said &quot;hi&quot;</p>") == ~s(She said "hi")
      assert HtmlToMarkdown.convert("<p>It&#39;s here</p>") == "It's here"
      assert HtmlToMarkdown.convert("<p>Caf&#233;</p>") == "Café"
      assert HtmlToMarkdown.convert("<p>Caf&#xe9;</p>") == "Café"
    end

    test "an invalid numeric entity is dropped rather than crashing convert/1" do
      assert HtmlToMarkdown.convert("<p>Bad &#xD800; entity</p>") == "Bad  entity"
      assert HtmlToMarkdown.convert("<p>Too big &#x110000;</p>") == "Too big"
    end
  end

  describe "convert/1 - <table>" do
    test "a table with a <th> header row and a data row becomes a GFM pipe table" do
      html =
        "<table><tr><th>H1</th><th>H2</th></tr><tr><td>a</td><td>b</td></tr></table>"

      assert HtmlToMarkdown.convert(html) ==
               "| H1 | H2 |\n| --- | --- |\n| a | b |"
    end

    test "cells are never glued together with no separator" do
      assert HtmlToMarkdown.convert("<table><tr><td>Cell 1</td><td>Cell 2</td></tr></table>") ==
               "| Cell 1 | Cell 2 |\n| --- | --- |"
    end

    test "<thead>/<tbody> mark the header row explicitly" do
      html =
        "<table><thead><tr><td>Name</td><td>Price</td></tr></thead>" <>
          "<tbody><tr><td>Widget</td><td>$5</td></tr>" <>
          "<tr><td>Gadget</td><td>$10</td></tr></tbody></table>"

      assert HtmlToMarkdown.convert(html) ==
               "| Name | Price |\n| --- | --- |\n| Widget | $5 |\n| Gadget | $10 |"
    end

    test "a pipe character inside a cell is escaped so it can't be mistaken for a column" do
      assert HtmlToMarkdown.convert("<table><tr><td>A | B</td><td>C</td></tr></table>") ==
               "| A \\| B | C |\n| --- | --- |"
    end

    test "a <br> inside a cell collapses to a space rather than breaking the row" do
      assert HtmlToMarkdown.convert("<table><tr><td>Line one<br>Line two</td></tr></table>") ==
               "| Line one Line two |\n| --- |"
    end

    test "a table converted twice is idempotent" do
      html =
        "<table><tr><th>H1</th><th>H2</th></tr><tr><td>a</td><td>b</td></tr></table>"

      once = HtmlToMarkdown.convert(html)
      twice = HtmlToMarkdown.convert(once)

      assert once == twice
    end
  end

  describe "convert/1 - <script>/<style> stripping" do
    test "<script> content, including embedded < and >, never leaks into the output" do
      html =
        "<p>Before</p>" <>
          "<script>if (1 < 2) { alert('hi > there'); }</script>" <>
          "<p>After</p>"

      assert HtmlToMarkdown.convert(html) == "Before\n\nAfter"
    end

    test "<style> content never leaks into the output" do
      html = "<p>Before</p><style>.a { color: red; }</style><p>After</p>"

      assert HtmlToMarkdown.convert(html) == "Before\n\nAfter"
    end
  end

  describe "convert/1 - attribute value quoting" do
    test "an unquoted href/src value is still parsed, not dropped" do
      assert HtmlToMarkdown.convert(~s(<p><a href=https://example.com>link</a></p>)) ==
               "[link](https://example.com)"

      assert HtmlToMarkdown.convert(~s(<p><img src=https://example.com/x.png alt=Alt></p>)) ==
               "![Alt](https://example.com/x.png)"
    end

    test "a single-quoted href value is parsed" do
      assert HtmlToMarkdown.convert(~s(<p><a href='https://example.com'>link</a></p>)) ==
               "[link](https://example.com)"
    end

    test "an unescaped > inside a quoted attribute value doesn't truncate the tag" do
      assert HtmlToMarkdown.convert(
               ~s(<p><a href="https://example.com?a=1&b=2" title="x > y">link</a></p>)
             ) ==
               "[link](https://example.com?a=1&b=2)"
    end
  end

  describe "convert/1 - Markdown preservation and idempotency" do
    test "existing ** and - Markdown inside text nodes survives unescaped" do
      html = "<p>**Color Disclaimer:**<br>Please note the colors may vary.</p>"

      assert HtmlToMarkdown.convert(html) ==
               "**Color Disclaimer:**\nPlease note the colors may vary."
    end

    test "three or more consecutive blank lines collapse to two" do
      html = "<p>First</p><p></p><p></p><p>Second</p>"

      refute HtmlToMarkdown.convert(html) =~ ~r/\n{3,}/
    end

    test "converting already-converted Markdown is a no-op (idempotent)" do
      html = "<p><strong>Bold</strong> and <em>italic</em>.<br>Second line.</p>"
      once = HtmlToMarkdown.convert(html)
      twice = HtmlToMarkdown.convert(once)

      assert once == twice
    end

    # A realistic Shopify `body_html` payload: hand-written Markdown
    # inside `<p>` tags with `<br>` line breaks and a bullet list written
    # as plain `<br>`-separated text rather than real `<li>` tags — the
    # exact shape a seller's rich-text editor tends to produce.
    test "a Shopify-shaped body_html fragment converts correctly and is idempotent" do
      html =
        "<p>What makes it special?<br>\n" <>
          "* Perfect for plants, crystals, candles, or small decor<br>\n" <>
          "* Customizable width and color options</p>\n" <>
          "<p>**Color Disclaimer:**<br>\n" <>
          "Colors may vary slightly from the images shown.</p>"

      converted = HtmlToMarkdown.convert(html)

      refute converted =~ "<p>"
      refute converted =~ "<br>"

      assert converted =~
               "* Perfect for plants, crystals, candles, or small decor\n* Customizable width and color options"

      assert converted =~ "**Color Disclaimer:**\nColors may vary slightly"
      assert HtmlToMarkdown.convert(converted) == converted
    end
  end

  describe "convert/1 - bare < and > in prose (not a tag)" do
    test "a bare < used as a comparison symbol is preserved, not swallowed" do
      assert HtmlToMarkdown.convert("<p>Sizes: 5in x 10in, ratio < 2 preferred</p>") ==
               "Sizes: 5in x 10in, ratio < 2 preferred"
    end

    test "a bare > used as a comparison symbol is preserved, not swallowed" do
      assert HtmlToMarkdown.convert("<p>Weight > 3kg needs a pallet</p>") ==
               "Weight > 3kg needs a pallet"
    end

    test "&lt; and &gt; decode correctly alongside bare < and >" do
      html = "<p>Fits sizes 5 &lt; x &gt; 12, but also raw 5 < 10 and > 3 here</p>"

      assert HtmlToMarkdown.convert(html) ==
               "Fits sizes 5 < x > 12, but also raw 5 < 10 and > 3 here"
    end

    test "convert/1 is idempotent for text containing bare < and >" do
      html = "<p>Fits sizes 5 &lt; x &gt; 12, but also raw 5 < 10 and > 3 here</p>"
      once = HtmlToMarkdown.convert(html)
      twice = HtmlToMarkdown.convert(once)

      assert once == twice
    end
  end

  describe "convert/1 - script/style are stripped, not leaked as text" do
    test "<script> content is dropped entirely" do
      assert HtmlToMarkdown.convert("<p>Before</p><script>alert(1)</script><p>After</p>") ==
               "Before\n\nAfter"
    end

    test "<style> content is dropped entirely" do
      assert HtmlToMarkdown.convert(~s(<style>body{color: red}</style><p>Text</p>)) == "Text"
    end

    test "a tag-like string inside a <script> body is not parsed as a real tag" do
      html = ~s(<p>Before</p><script>var x = "<img src=x>";</script><p>After</p>)

      assert HtmlToMarkdown.convert(html) == "Before\n\nAfter"
    end

    test "<noscript> content is dropped entirely" do
      assert HtmlToMarkdown.convert(~s(<noscript>Enable JS</noscript><p>Text</p>)) == "Text"
    end

    test "<template> content is dropped entirely" do
      assert HtmlToMarkdown.convert(~s(<template><p>Hidden</p></template><p>Text</p>)) == "Text"
    end
  end

  describe "convert/1 - unclosed raw-text elements" do
    # A truncated `body_html` (or hand-edited HTML) can leave a
    # script/style tag with no matching close tag. `@raw_text_regex`
    # can't anchor on a `</script>` that isn't there, so without a
    # second pass the tag would tokenize as an ordinary element and its
    # raw JS/CSS body would render as visible text.
    test "an unclosed <script> strips to end of string" do
      assert HtmlToMarkdown.convert("<p>Before</p><script>var x = 1;") == "Before"
    end

    test "an unclosed <style> strips to end of string" do
      assert HtmlToMarkdown.convert("<p>Before</p><style>body{color:red}") == "Before"
    end
  end

  describe "convert/1 - nested lists" do
    test "a <ul> nested inside a <li> renders as an indented sub-list" do
      html = "<ul><li>Item1<ul><li>Sub1</li><li>Sub2</li></ul></li><li>Item2</li></ul>"

      assert HtmlToMarkdown.convert(html) ==
               "- Item1\n  - Sub1\n  - Sub2\n- Item2"
    end

    test "three levels of nesting each get their own indent" do
      html = "<ul><li>A<ul><li>B<ul><li>C</li></ul></li></ul></li></ul>"

      assert HtmlToMarkdown.convert(html) == "- A\n  - B\n    - C"
    end

    # An ordered marker's content column is 3 ("1. "), not 2 — indenting
    # a nested sub-list by only 2 spaces (the unordered width) puts it
    # short of that column, so CommonMark re-parses it as a sibling block
    # instead of keeping it nested inside the item.
    test "a <ul> nested inside an <ol> item indents to the ordered marker's content column (3 spaces)" do
      html = "<ol><li>Item<ul><li>Sub</li></ul></li></ol>"

      assert HtmlToMarkdown.convert(html) == "1. Item\n   - Sub"
    end

    test "an <ol> nested inside an <ol> item indents to the ordered marker's content column (3 spaces)" do
      html = "<ol><li>Item<ol><li>Sub</li></ol></li></ol>"

      assert HtmlToMarkdown.convert(html) == "1. Item\n   1. Sub"
    end

    # A double-digit ordered marker ("11. ") is 4 columns wide, one wider
    # than a single-digit one ("1. "). A nested sub-list must indent to
    # that item's own content column, not a fixed width, or it re-parses
    # as a sibling list instead of staying nested (see the MDEx test
    # below for the parse-level consequence).
    test "a double-digit ordered marker indents a nested sub-list to its own (wider) content column" do
      items =
        for n <- 1..11 do
          if n == 11 do
            "<li>Item#{n}<ul><li>Sub</li></ul></li>"
          else
            "<li>Item#{n}</li>"
          end
        end

      html = "<ol>" <> Enum.join(items) <> "</ol>"

      assert HtmlToMarkdown.convert(html) ==
               "1. Item1\n2. Item2\n3. Item3\n4. Item4\n5. Item5\n6. Item6\n7. Item7\n" <>
                 "8. Item8\n9. Item9\n10. Item10\n11. Item11\n    - Sub"
    end

    test "MDEx nests the sub-list under the double-digit item instead of making it a sibling" do
      items =
        for n <- 1..11 do
          if n == 11 do
            "<li>Item#{n}<ul><li>Sub</li></ul></li>"
          else
            "<li>Item#{n}</li>"
          end
        end

      html = "<ol>" <> Enum.join(items) <> "</ol>"
      markdown = HtmlToMarkdown.convert(html)

      rendered = MDEx.to_html!(markdown)

      assert rendered =~ ~r/<li>Item11\s*<ul>/
    end

    test "MDEx renders the ordered-parent nested list as one nested list, not two siblings" do
      html = "<ol><li>Item<ul><li>Sub</li></ul></li></ol>"
      markdown = HtmlToMarkdown.convert(html)

      rendered = MDEx.to_html!(markdown)

      assert rendered =~ ~r/<li>Item\s*<ul>/
    end
  end

  describe "block content nested inside other blocks" do
    test "a table inside a list item keeps its cells apart" do
      # A size chart under a "Specifications:" bullet is ordinary Shopify
      # copy. Rendering it inline used to glue every cell together.
      html =
        "<ul><li>Specs<table><tr><th>H1</th><th>H2</th></tr>" <>
          "<tr><td>a</td><td>b</td></tr></table></li></ul>"

      out = HtmlToMarkdown.convert(html)

      assert out =~ "- Specs"
      assert out =~ "| H1 | H2 |"
      assert out =~ "| a | b |"
      refute out =~ "SpecsH1"
      refute out =~ "ab"
      assert HtmlToMarkdown.convert(out) == out
    end

    test "a paragraph inside a list item stays on its own line" do
      out = HtmlToMarkdown.convert("<ul><li>Intro<p>Second paragraph.</p></li></ul>")

      assert out =~ "- Intro"
      assert out =~ "Second paragraph."
      refute out =~ "IntroSecond"
      assert HtmlToMarkdown.convert(out) == out
    end

    test "a list inside a table cell is flattened with its boundaries kept" do
      # A pipe cell is one line, so the list cannot survive as a list —
      # but its text must not merge into the cell's own words.
      out =
        HtmlToMarkdown.convert(
          "<table><tr><td>Row<ul><li>nested li in cell</li></ul></td></tr></table>"
        )

      assert out =~ "Row - nested li in cell"
      refute out =~ "Rownested"
      assert HtmlToMarkdown.convert(out) == out
    end

    test "two paragraphs in a table cell do not merge into one word" do
      out = HtmlToMarkdown.convert("<table><tr><td><p>One</p><p>Two</p></td></tr></table>")

      assert out =~ "| One Two |"
      refute out =~ "OneTwo"
    end
  end
end
