defmodule PhoenixKitEcommerce.Options.ModifierParseTest do
  @moduledoc """
  Override values that are not numeric must not raise out of
  `Decimal.new/1` on the charged path — the range/catalog path already
  safe-parses via `parse_decimal/1`.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.Options

  @opt %{
    "key" => "material",
    "allow_override" => true,
    "modifier_type" => "fixed",
    "affects_price" => true,
    "price_modifiers" => %{"PLA" => "0"}
  }

  test "a non-numeric override value is treated as zero, not raised" do
    metadata = %{"_price_modifiers" => %{"material" => %{"PLA" => "not-a-number"}}}

    assert {"fixed", %Decimal{}} =
             Options.get_effective_modifier_info(@opt, "PLA", metadata)

    assert Decimal.equal?(
             Options.get_custom_price_modifier(metadata, "material", "PLA"),
             Decimal.new("0")
           )
  end

  test "a numeric override still applies" do
    metadata = %{"_price_modifiers" => %{"material" => %{"PLA" => "15.00"}}}

    assert {"fixed", value} = Options.get_effective_modifier_info(@opt, "PLA", metadata)
    assert Decimal.equal?(value, Decimal.new("15.00"))
  end
end
