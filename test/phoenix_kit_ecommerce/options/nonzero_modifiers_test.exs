defmodule PhoenixKitEcommerce.Options.NonzeroModifiersTest do
  @moduledoc """
  `Options.has_nonzero_modifiers?/1`: an amount is a binary or `%{"value" => binary}`;
  a blank or non-numeric amount counts as zero. Pure, no database.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.Options

  test "a non-zero amount, plain or wrapped, makes the group price-affecting" do
    assert Options.has_nonzero_modifiers?(%{"large" => "1.50"})
    assert Options.has_nonzero_modifiers?(%{"large" => %{"value" => "-2"}})
    assert Options.has_nonzero_modifiers?(%{"small" => "0", "large" => "0.01"})
  end

  test "zero, blank, non-numeric and malformed amounts count as zero" do
    refute Options.has_nonzero_modifiers?(%{"a" => "0", "b" => "0.00", "c" => %{"value" => "0"}})
    refute Options.has_nonzero_modifiers?(%{"a" => "", "b" => "abc", "c" => "1x", "d" => nil})
    refute Options.has_nonzero_modifiers?(%{"a" => %{"value" => 5}, "b" => 5, "c" => %{}})
    refute Options.has_nonzero_modifiers?(%{})
  end

  test "anything that is not a map is false" do
    refute Options.has_nonzero_modifiers?(nil)
    refute Options.has_nonzero_modifiers?("1.00")
    refute Options.has_nonzero_modifiers?([{"a", "1"}])
  end
end
