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

    test "rejoining every fragment reproduces the inputs" do
      current = "The 3D printed <b>snowflake</b> pack, 10 pieces."
      incoming = "The 3D printed <b>snowflake</b> set, 12 pieces."
      fragments = TextDiff.words(current, incoming)

      rebuilt_current =
        fragments |> Enum.reject(&(elem(&1, 0) == :ins)) |> Enum.map_join(&elem(&1, 1))

      rebuilt_incoming =
        fragments |> Enum.reject(&(elem(&1, 0) == :del)) |> Enum.map_join(&elem(&1, 1))

      assert rebuilt_current == current
      assert rebuilt_incoming == incoming
    end

    test "handles unicode without splitting graphemes" do
      assert TextDiff.words("ёлка синяя", "ёлка красная") == [
               {:eq, "ёлка "},
               {:del, "синяя"},
               {:ins, "красная"}
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
  end
end
