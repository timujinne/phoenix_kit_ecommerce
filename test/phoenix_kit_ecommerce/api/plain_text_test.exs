defmodule PhoenixKitEcommerce.API.PlainTextTest do
  @moduledoc """
  Descriptions as plain text from both stored forms: HTML (Legacy source,
  Shopify CSV) and Markdown (Catalogue source: the Shopify sync stores
  `HtmlToMarkdown.convert/1` output in `body_html`). Pure, no database.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.API.PlainText

  defp text(raw), do: PlainText.convert(raw, 4_000)

  # Cost is counted in reductions of this process, not in milliseconds: the same
  # input costs the same on a loaded machine, and a pattern that went quadratic
  # costs orders of magnitude more. The bounds are about four times what the
  # inputs cost today (at most 10.7 million, and 1.8 million, reductions).
  defp assert_cheap(input, limit_reductions, label) do
    {:reductions, before} = Process.info(self(), :reductions)
    PlainText.convert(input, 4_000)
    {:reductions, after_} = Process.info(self(), :reductions)

    assert after_ - before < limit_reductions,
           "#{inspect(label)} took #{after_ - before} reductions"
  end

  test "Markdown syntax is removed and the words stay" do
    assert text("A **bold** vase\n\n- item one\n- item two") == "A bold vase item one item two"

    assert text("# Title\n\nSome *italic* and _more_ text with `code`.") ==
             "Title Some italic and more text with code."

    assert text("> quoted\n\n1. first\n2. second") == "quoted first second"
    assert text("~~old~~ new __strong__") == "old new strong"
    assert text("---\nText\n***") == "Text"
  end

  test "links and images keep their text and lose their address" do
    assert text("See [the guide](https://x.test/a_b) and ![alt text](https://x.test/i.png)") ==
             "See the guide and alt text"
  end

  test "tables lose their pipes and their separator row" do
    assert text("| Size | Price |\n|------|-------|\n| S | 5 |") == "Size Price S 5"
  end

  test "HTML is still stripped" do
    assert text("<p>Plain <b>HTML</b> stays</p>") == "Plain HTML stays"
  end

  test "characters that only look like Markdown stay" do
    assert text("5 * 3 * 2 and snake_case_name and 2 > 1") ==
             "5 * 3 * 2 and snake_case_name and 2 > 1"

    assert text("Ceramic vase with *rim*: handmade") == "Ceramic vase with rim: handmade"
  end

  test "blank input is nil, and the limit applies" do
    assert PlainText.convert(nil, 10) == nil
    assert PlainText.convert("", 10) == nil
    assert PlainText.convert("  \n ", 10) == nil
    assert PlainText.convert(42, 10) == nil
    assert PlainText.convert(String.duplicate("a", 30), 10) == String.duplicate("a", 10)
  end

  test "HTML entities are decoded once, after the tags are gone" do
    assert text("Salt &amp; pepper &lt;b&gt; &nbsp; &quot;q&quot; &#39;x&#39; &#x41;") ==
             ~s|Salt & pepper <b> "q" 'x' A|

    assert text("&amp;lt;") == "&lt;"
    assert text("<p>Fish &amp; chips</p>") == "Fish & chips"
    assert text("caf&#233; &#x1F600;") == "café 😀"
  end

  test "an unknown or invalid reference stays, and a control character becomes a space" do
    assert text("&bogus; &#1114112; &#xD800; AT&T") == "&bogus; &#1114112; &#xD800; AT&T"
    assert text("a&#0;b") == "a b"
    refute text("a&#0;b") =~ <<0>>
    assert text("a&#x85;b") == "a b"
    assert text("a&#9;b") == "a b"
    assert text("a&#10;b") == "a b"
  end

  test "an uppercase hex marker is decoded" do
    assert text("a&#X41;b") == "aAb"
  end

  test "Latin-1 and common named entities are decoded, in any case where HTML allows" do
    assert text("caf&eacute; &auml;&ouml;&uuml; &szlig; &euro;5 &deg;C &times; 2") ==
             "café äöü ß €5 °C × 2"

    assert text("&Eacute;t&eacute; &frac12; &sup3; &thorn; &yuml; &divide;") == "Été ½ ³ þ ÿ ÷"
    assert text("a &AMP; b &NBSP; c &LT;") == "a & b c <"
    assert text("&AUML; &Eacutee;") == "&AUML; &Eacutee;"
  end

  test "a bare angle bracket is text, only a real tag is removed" do
    assert text("Ratio 5 < 10 and 7 > 3 are fine") == "Ratio 5 < 10 and 7 > 3 are fine"
    assert text("a < b and c > d") == "a < b and c > d"
    assert text("a <b>bold</b> < c > d <!-- x --> e") == "a bold < c > d e"
    assert text("x <y") == "x <y"
  end

  test "the result is text: an encoded tag is decoded and left alone" do
    assert text("&lt;script&gt;alert(1)&lt;/script&gt;") == "<script>alert(1)</script>"
  end

  test "a tag that spans lines does not lose the text after its closing bracket" do
    assert text("<a href=\"x\"\n>link</a> and more") == "link and more"
  end

  test "a link target with parentheses is removed whole" do
    assert text("[a](http://en.wikipedia.org/wiki/Foo_(bar)) tail") == "a tail"
  end

  test "a table cell loses the backslash before its pipe" do
    assert text("| a\\|b | c |\n|---|---|\n| d | e |") == "a b c d e"
    assert text("x\\|y") == "x|y"
  end

  test "script and style blocks are dropped, closed or not" do
    assert text(
             "<style>a{color:red}</style>Hi <script>alert(1)</script>text<SCRIPT\n>x</SCRIPT >!"
           ) ==
             "Hi text !"

    assert text("Before <script>unclosed") == "Before"
    assert text("<scripts>kept</scripts>") == "kept"
  end

  test "a code fence loses its fence lines and keeps the code" do
    assert text("Before\n```elixir\nlet x = 1\n```\nafter") == "Before let x = 1 after"
  end

  test "an underscore or an asterisk inside a word is not emphasis" do
    assert text("foo_bar_ baz") == "foo_bar_ baz"
    assert text("foo*bar* baz") == "foo*bar* baz"
  end

  test "markup around tags is still removed" do
    assert text("**<b>bold</b>** here") == "bold here"
  end

  test "unclosed markers in a huge value stay cheap" do
    for unit <- ["**a ", "__a ", "~~a ", "<a ", "[a ", "< ", "&a", "&#"] do
      assert_cheap(String.duplicate(unit, 200_000), 40_000_000, unit)
    end
  end

  test "runs of blank lines in a huge value stay cheap, whatever follows them" do
    for unit <- ["\n", " \n", "  \n", "\t\n"], tail <- ["", "-", "`", "|", "x", "1.", ">"] do
      assert_cheap(String.duplicate(unit, 100_000) <> tail, 8_000_000, {unit, tail})
    end
  end

  test "a long block of markup before the text does not wipe the text out" do
    blob = String.duplicate("A", 150_000)

    assert text("Hello <img src=\"data:image/png;base64," <> blob <> "\"> tail text") ==
             "Hello tail text"

    assert text("Hello ![](data:image/png;base64," <> blob <> ") tail text") ==
             "Hello tail text"

    assert text("<style>" <> String.duplicate("a{b:c}", 100_000) <> "</style>Body text") ==
             "Body text"

    assert text("Hello <img src=\"data:image/svg+xml;charset=utf-8;base64," <> blob <> "\"> tail") ==
             "Hello tail"

    # Past the cut, the rest of the value is gone, and so is the tag it cut through.
    open_tag = "Hello <svg viewBox=\"" <> String.duplicate("M0 0 ", 40_000)
    assert text(open_tag <> "\"> tail text") == "Hello"

    assert text("Hello <p>kept</p> world " <> String.duplicate("x ", 60_000)) =~
             "Hello kept world x"
  end

  test "the limit applies to the decoded text and the result has no trailing space" do
    assert PlainText.convert("aaaa &amp; bbbb", 6) == "aaaa &"
    assert PlainText.convert("aaaa bbbb", 5) == "aaaa"
  end
end
