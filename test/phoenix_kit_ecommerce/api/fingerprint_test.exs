defmodule PhoenixKitEcommerce.API.FingerprintTest do
  @moduledoc """
  The value fingerprint of a dry run: stable for the same values, different
  for any value that moved, independent of row order and map layout.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.API.Fingerprint

  defp dec(value), do: Decimal.new(value)

  defp rows(price \\ "1.50", leaf \\ "2.00") do
    [
      {"b", %{price: dec(price), mods: %{"x" => %{"y" => leaf, "z" => 3}}}},
      {"a", %{price: nil, mods: %{}}}
    ]
  end

  test "is a 64-character lower-case hex digest" do
    assert Fingerprint.compute(rows()) =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "does not depend on row order, key order or the spelling of a decimal" do
    shuffled = [
      {"a", %{mods: %{}, price: nil}},
      {"b", %{mods: %{"x" => %{"z" => 3, "y" => "2.00"}}, price: dec("1.5")}}
    ]

    assert Fingerprint.compute(rows()) == Fingerprint.compute(shuffled)
  end

  test "changes when a price or a modifier leaf changes, or a row is added" do
    base = Fingerprint.compute(rows())

    refute base == Fingerprint.compute(rows("1.51"))
    refute base == Fingerprint.compute(rows("1.50", "2.01"))
    refute base == Fingerprint.compute(rows() ++ [{"c", %{price: nil, mods: %{}}}])
  end

  test "the same fields under another row id are another fingerprint" do
    refute Fingerprint.compute([{"a", %{price: dec("1")}}]) ==
             Fingerprint.compute([{"b", %{price: dec("1")}}])
  end

  test "an empty list has a fingerprint too" do
    assert Fingerprint.compute([]) =~ ~r/\A[0-9a-f]{64}\z/
  end
end
