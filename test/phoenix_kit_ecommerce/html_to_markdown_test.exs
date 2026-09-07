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
end
