defmodule PhoenixKitEcommerce.API.VisibilityTest do
  @moduledoc """
  The visibility rule, row by row and in order. Pure: no database.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.API.Facts
  alias PhoenixKitEcommerce.API.Visibility

  defp facts(overrides \\ []) do
    struct!(
      Facts,
      Keyword.merge(
        [
          item_status: "active",
          shop_status: "active",
          category_status: "active",
          catalogue_listed?: true
        ],
        overrides
      )
    )
  end

  defp state(overrides), do: overrides |> facts() |> Visibility.classify()

  test "rule 3: an active item with an active shop status in an active category is listed" do
    assert state([]) == :listed
  end

  test "rule 3 needs no category at all" do
    assert state(category_status: nil) == :listed
  end

  test "rule 1: a deleted or inactive item is hidden even with an active shop status" do
    assert state(item_status: "deleted") == :hidden
    assert state(item_status: "inactive") == :hidden
  end

  test "rule 1: a draft shop status hides an otherwise active item" do
    assert state(shop_status: "draft") == :hidden
  end

  test "rule 1: a hidden, archived or deleted category hides its products" do
    for status <- ["hidden", "archived", "deleted"] do
      assert state(category_status: status) == :hidden, "category #{status}"
    end
  end

  test "an unlisted category keeps its products listed" do
    assert state(category_status: "unlisted") == :listed
  end

  test "rule 1: a catalogue that is not active hides everything" do
    assert state(catalogue_listed?: false) == :hidden
    assert state(catalogue_listed?: nil) == :hidden
  end

  test "rule 2: a discontinued item is a stub" do
    assert state(item_status: "discontinued") == :discontinued
  end

  test "rule 2: an archived shop status is a stub" do
    assert state(shop_status: "archived") == :discontinued
  end

  test "rule 1 beats rule 2" do
    assert state(item_status: "discontinued", shop_status: "draft") == :hidden
    assert state(item_status: "discontinued", category_status: "hidden") == :hidden
    assert state(shop_status: "archived", category_status: "deleted") == :hidden
    assert state(item_status: "discontinued", catalogue_listed?: false) == :hidden
    assert state(item_status: "inactive", shop_status: "archived") == :hidden
    assert state(item_status: "deleted", shop_status: "archived") == :hidden
  end

  test "values nobody defined fail closed" do
    assert state(item_status: "something_new") == :hidden
    assert state(shop_status: "something_new") == :hidden
    assert state(item_status: nil) == :hidden
    assert state(category_status: "something_new") == :hidden
    assert state(category_status: "Hidden") == :hidden
  end

  test "listed?/1 is true only for rule 3" do
    assert Visibility.listed?(facts())
    refute Visibility.listed?(facts(item_status: "discontinued"))
    refute Visibility.listed?(facts(shop_status: "draft"))
  end
end
