defmodule PhoenixKitEcommerce.HtmlTextTest do
  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.HtmlText

  describe "extract_description/2" do
    test "returns nil for nil input" do
      assert HtmlText.extract_description(nil) == nil
    end

    test "returns nil for empty string" do
      assert HtmlText.extract_description("") == nil
    end

    test "strips HTML tags" do
      assert HtmlText.extract_description("<p>Hello <b>world</b></p>") == "Hello world"
    end

    test "collapses repeated whitespace" do
      assert HtmlText.extract_description("<p>Hello   \n\n  world</p>") == "Hello world"
    end

    test "trims leading and trailing whitespace" do
      assert HtmlText.extract_description("  <p>Hello</p>  ") == "Hello"
    end

    test "truncates to the default 500-character limit" do
      long_text = String.duplicate("a", 600)
      result = HtmlText.extract_description("<p>#{long_text}</p>")

      assert String.length(result) == 500
    end

    test "accepts a custom limit" do
      assert HtmlText.extract_description("<p>Hello world</p>", 5) == "Hello"
    end
  end
end
