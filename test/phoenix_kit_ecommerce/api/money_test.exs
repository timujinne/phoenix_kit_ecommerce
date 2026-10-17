defmodule PhoenixKitEcommerce.API.MoneyTest do
  @moduledoc """
  The decimal strings of the admin API: what is accepted as a price, what is
  refused instead of being rounded or misread, and how amounts are shown.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.API.Money

  describe "parse/1" do
    test "accepts a plain decimal with at most two decimals" do
      for input <- ["0", "12", "12.5", "12.50", "0.01", "9999999999.99"] do
        assert {:ok, decimal} = Money.parse(input)
        assert Decimal.equal?(decimal, Decimal.new(input))
      end
    end

    test "refuses what would be rounded, misread or smuggled in" do
      bad = [
        "12.505",
        "12,50",
        "1e3",
        " 12.50",
        "12.50 ",
        "12.50\n",
        "-1",
        "+1",
        "007",
        "",
        ".5",
        "5.",
        "99999999999",
        "NaN",
        "Infinity"
      ]

      for input <- bad do
        assert {:error, message} = Money.parse(input), "#{inspect(input)} must be refused"
        assert message =~ "decimal string"
      end
    end

    test "refuses everything that is not a string" do
      for input <- [12.5, 12, nil, true, %{}, ["1"]] do
        assert {:error, "must be a decimal string"} = Money.parse(input)
      end
    end
  end

  describe "parse_delta/1" do
    test "accepts a negative amount and turns minus zero into zero" do
      assert {:ok, minus} = Money.parse_delta("-5.00")
      assert Decimal.equal?(minus, Decimal.new("-5"))

      assert {:ok, zero} = Money.parse_delta("-0")
      assert Money.format(zero) == "0.00"
    end

    test "refuses a double sign and a third decimal" do
      assert {:error, _} = Money.parse_delta("--1")
      assert {:error, _} = Money.parse_delta("-1.001")
    end
  end

  describe "the JSON Schema patterns" do
    test "agree with the parsers on the cases that matter" do
      amount = Regex.compile!(Money.amount_pattern())
      delta = Regex.compile!(Money.delta_pattern())

      for input <- ["12.50", "0", "12.505", "12,50", "-1", "007"] do
        assert Regex.match?(amount, input) == match?({:ok, _}, Money.parse(input)),
               "amount pattern and parser disagree on #{inspect(input)}"
      end

      for input <- ["-5.00", "5", "--1", "-1.001"] do
        assert Regex.match?(delta, input) == match?({:ok, _}, Money.parse_delta(input)),
               "delta pattern and parser disagree on #{inspect(input)}"
      end
    end

    test "the pattern lets a trailing newline through, so the parser is the authority" do
      assert Regex.match?(Regex.compile!(Money.amount_pattern()), "12.50\n")
      assert {:error, _} = Money.parse("12.50\n")
    end
  end

  describe "format/1, money/2, to_decimal/1" do
    test "formats with two decimals and keeps nil" do
      assert Money.format(Decimal.new("12.5")) == "12.50"
      assert Money.format(Decimal.new("12")) == "12.00"
      assert Money.format(nil) == nil
    end

    test "builds a money object, or nil without an amount" do
      assert Money.money(Decimal.new("3"), "EUR") == %{"amount" => "3.00", "currency" => "EUR"}
      assert Money.money(nil, "EUR") == nil
    end

    test "reads stored values leniently and returns nil for what is not a number" do
      assert Decimal.equal?(Money.to_decimal("5.00"), Decimal.new(5))
      assert Decimal.equal?(Money.to_decimal(5), Decimal.new(5))
      assert Decimal.equal?(Money.to_decimal(1.5), Decimal.new("1.5"))
      assert Money.to_decimal("abc") == nil
      assert Money.to_decimal(%{"type" => "fixed"}) == nil
      assert Money.to_decimal(nil) == nil
    end

    test "a non-finite number is not a number" do
      for value <- ["NaN", "Infinity", "-Infinity", "inf", " -inf "] do
        assert Money.to_decimal(value) == nil, inspect(value)
      end

      for value <- [Decimal.new("NaN"), Decimal.new("Infinity"), Decimal.new("-Infinity")] do
        assert Money.to_decimal(value) == nil, inspect(value)
      end
    end
  end
end
