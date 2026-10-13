defmodule PhoenixKitEcommerce.Options.TransformGlobalOptionsTest do
  @moduledoc """
  `Options.transform_global_options/1` hands its function the list as it is
  stored under the writers' lock, so a change derived from the WHOLE list
  (the base-currency re-pricing) cannot write back a copy that predates
  someone else's edit.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKitEcommerce.Options
  alias PhoenixKitEcommerce.ShopConfig
  alias PhoenixKitEcommerce.Test.Repo

  defp text(key), do: %{"key" => key, "label" => key, "type" => "text"}
  defp keys, do: Enum.map(Options.get_global_options(), & &1["key"])

  test "the function sees the list as stored now, and what it returns is written" do
    {:ok, _} = Options.update_global_options([text("a")])

    assert {:ok, :seen_a} =
             Options.transform_global_options(fn current ->
               # Another writer got in after any earlier read.
               assert Enum.map(current, & &1["key"]) == ["a"]
               {:ok, current ++ [text("b")], :seen_a}
             end)

    assert keys() == ["a", "b"]
  end

  test "an unchanged answer writes nothing" do
    assert keys() == []
    assert {:ok, 0} = Options.transform_global_options(fn _ -> {:unchanged, 0} end)
    assert keys() == []

    refute Repo.get(ShopConfig, "global_option_schema")
  end

  test "an error rolls back and is returned" do
    {:ok, _} = Options.update_global_options([text("a")])

    assert {:error, :nope} = Options.transform_global_options(fn _ -> {:error, :nope} end)
    assert keys() == ["a"]
  end

  test "a list that fails validation is refused and leaves the stored one alone" do
    {:ok, _} = Options.update_global_options([text("a")])

    assert {:error, _reason} =
             Options.transform_global_options(fn _ -> {:ok, [%{"key" => "x"}], :bad} end)

    assert keys() == ["a"]
  end
end
