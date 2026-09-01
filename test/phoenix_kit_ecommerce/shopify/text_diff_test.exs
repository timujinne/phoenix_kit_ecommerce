defmodule PhoenixKitEcommerce.Shopify.TextDiffTest do
  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.Shopify.TextDiff

  describe "words/2" do
    test "identical text is one equal run" do
      assert TextDiff.words("a b c", "a b c") == [{:eq, "a b c"}]
    end

    test "nil is treated as empty string" do
      assert TextDiff.words(nil, "hello") == [{:ins, "hello"}]
      assert TextDiff.words("hello", nil) == [{:del, "hello"}]
    end

    test "both nil is a single empty equal run" do
      assert TextDiff.words(nil, nil) == [{:eq, ""}]
    end

    test "a replaced word is a del next to an ins, whitespace preserved" do
      assert TextDiff.words("red big box", "red small box") == [
               {:eq, "red "},
               {:del, "big"},
               {:ins, "small"},
               {:eq, " box"}
             ]
    end

    test "rejoining fragments reproduces the inputs across adversarial pairs" do
      pairs = [
        {nil, nil},
        {"", ""},
        {" a", "a "},
        {"a  b", "a b"},
        {"\n\n", "\n"},
        {"   ", ""},
        {"ёлка синяя", "ёлка красная"},
        {"The 3D printed <b>snowflake</b> pack, 10 pieces.",
         "The 3D printed <b>snowflake</b> set, 12 pieces."}
      ]

      for {current, incoming} = pair <- pairs do
        fragments = TextDiff.words(current, incoming)

        rebuilt_current =
          fragments |> Enum.reject(&(elem(&1, 0) == :ins)) |> Enum.map_join(&elem(&1, 1))

        rebuilt_incoming =
          fragments |> Enum.reject(&(elem(&1, 0) == :del)) |> Enum.map_join(&elem(&1, 1))

        assert rebuilt_current == (current || ""), "current mismatch for #{inspect(pair)}"
        assert rebuilt_incoming == (incoming || ""), "incoming mismatch for #{inspect(pair)}"
      end
    end

    test "handles multi-byte unicode text" do
      assert TextDiff.words("ёлка синяя", "ёлка красная") == [
               {:eq, "ёлка "},
               {:del, "синяя"},
               {:ins, "красная"}
             ]
    end

    test "does not split a multi-codepoint grapheme cluster (emoji ZWJ sequence)" do
      family = "👨‍👩‍👧‍👦"

      assert TextDiff.words("before " <> family <> " after", "before " <> family <> " later") ==
               [{:eq, "before " <> family <> " "}, {:del, "after"}, {:ins, "later"}]
    end

    test "treats a non-breaking space as whitespace" do
      # Shopify body_html routinely uses &nbsp; (U+00A0), which plain ASCII
      # \s does not match without the /u regex flag.
      nbsp = "\u00A0"

      assert TextDiff.words("a#{nbsp}b", "a#{nbsp}c") == [
               {:eq, "a#{nbsp}"},
               {:del, "b"},
               {:ins, "c"}
             ]
    end

    test "keeps a common whitespace run and the del-before-ins order" do
      # Pins the tokenizer's `trim: true`. Round-trip cannot catch this:
      # BOTH the correct and the degraded tokenizer rejoin correctly, yet the
      # degraded one loses the shared "\n\t" run and emits [ins, del] instead
      # of [del, ins] — flipping which side the sync page renders first.
      assert TextDiff.words("b\n\t", "\n\ta") == [
               {:del, "b"},
               {:eq, "\n\t"},
               {:ins, "a"}
             ]
    end
  end

  describe "summary/2" do
    test "identical text has no changed fragments and no length change" do
      assert TextDiff.summary("a b c", "a b c") == %{fragments: 0, length_delta: 0}
    end

    test "counts changed fragments and the signed length delta" do
      assert TextDiff.summary("one two three", "one TWO three four") == %{
               fragments: 2,
               length_delta: 5
             }
    end

    test "nil current counts as an insertion of the whole incoming text" do
      assert TextDiff.summary(nil, "abc") == %{fragments: 1, length_delta: 3}
    end

    test "length_delta counts graphemes, not bytes" do
      # "ёлка" is 4 graphemes but 8 bytes in UTF-8 - byte_size/1 here would
      # give -8, not -4. Most of this shop's product text is Cyrillic.
      assert TextDiff.summary("ёлка", "") == %{fragments: 1, length_delta: -4}
    end
  end
end
