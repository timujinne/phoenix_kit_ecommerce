defmodule PhoenixKitEcommerce.Search.EntryTest do
  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.Search.Entry

  test "table/0 is the bare table name on an unprefixed install" do
    assert Entry.__schema__(:prefix) == nil
    assert Entry.table() == "phoenix_kit_shop_search_index"
  end
end
