defmodule PhoenixKitEcommerce.Catalogue.ShopifyAttributionTest do
  @moduledoc """
  Attribution and write scope of the Shopify sync's catalogue writes: the
  paths found by comparing the `data` an item has with the `data` a writer
  built, and what is sent to the catalogue because of them. Pure.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.Catalogue.ShopifyAttribution, as: Attribution

  @old %{
    "_primary_language" => "en",
    "en" => %{"_name" => "Old", "_description" => "d"},
    "ecommerce" => %{
      "vendor" => "v",
      "tags" => ["a"],
      "compare_at_price" => "9.00",
      "shopify" => %{
        "handle" => "h",
        "image_ids" => %{"1" => "u"},
        "price_fit" => %{"rule" => "x"}
      },
      "price_modifiers" => %{"c" => %{"b" => "1.00"}}
    }
  }

  describe "changed_paths/2" do
    test "finds exactly the changed leaves, sorted, down to three levels, and one further under price_modifiers" do
      new =
        @old
        |> put_in(["en", "_name"], "New")
        |> put_in(["ecommerce", "vendor"], "w")
        |> update_in(["ecommerce", "shopify"], &Map.delete(&1, "price_fit"))
        |> put_in(["ecommerce", "shopify", "image_ids"], %{"1" => "u", "2" => "v"})
        |> put_in(["ecommerce", "price_modifiers", "c", "z"], "2.00")

      assert Attribution.changed_paths(@old, new) == [
               ["ecommerce", "price_modifiers", "c", "z"],
               ["ecommerce", "shopify", "image_ids"],
               ["ecommerce", "shopify", "price_fit"],
               ["ecommerce", "vendor"],
               ["en", "_name"]
             ]
    end

    test "nothing changed, nothing listed" do
      assert Attribution.changed_paths(@old, @old) == []
    end

    test "a key that is new is listed as a whole" do
      assert Attribution.changed_paths(%{}, %{"a" => %{"b" => 1}}) == [["a"]]
    end

    test "price_modifiers that are new are listed option price by option price" do
      old = %{"ecommerce" => %{"vendor" => "v"}}

      new = %{
        "ecommerce" => %{"vendor" => "v", "price_modifiers" => %{"size" => %{"s" => "0.00"}}}
      }

      assert Attribution.changed_paths(old, new) == [
               ["ecommerce", "price_modifiers", "size", "s"]
             ]
    end
  end

  describe "prepare/3 with a catalogue that honours owned paths" do
    test "names the sync, scopes the write, and writes a removed path as an explicit nil" do
      new =
        @old
        |> update_in(["ecommerce", "shopify"], &Map.delete(&1, "price_fit"))
        |> update_in(["ecommerce"], &Map.delete(&1, "vendor"))
        |> put_in(["en", "_name"], "New")

      assert {data, opts} = Attribution.prepare(@old, new, actor_uuid: "u-1", owned?: true)

      assert data["ecommerce"]["vendor"] == nil
      assert Map.has_key?(data["ecommerce"], "vendor")
      assert data["ecommerce"]["shopify"]["price_fit"] == nil
      assert data["en"]["_name"] == "New"

      assert opts[:actor_uuid] == "u-1"
      assert opts[:log_metadata] == %{"via" => "shopify_sync"}

      assert opts[:data_owned_paths] == [
               ["ecommerce", "shopify", "price_fit"],
               ["ecommerce", "vendor"],
               ["en", "_name"]
             ]

      # only the shop namespace is shown in the change log
      assert opts[:logged_data_paths] == [
               ["ecommerce", "shopify", "price_fit"],
               ["ecommerce", "vendor"]
             ]
    end

    test "a default the writer filled in is passed along but not owned, so the catalogue does not store it" do
      old = %{"ecommerce" => %{"vendor" => "v"}}
      intended = put_in(old, ["ecommerce", "vendor"], "w")
      new = put_in(intended, ["ecommerce", "made_to_order"], false)

      assert {data, opts} = Attribution.prepare(old, new, intended: intended, owned?: true)

      assert data["ecommerce"]["made_to_order"] == false
      assert opts[:data_owned_paths] == [["ecommerce", "vendor"]]
      assert opts[:logged_data_paths] == [["ecommerce", "vendor"]]
    end

    test "a write that changes no data path owns nothing: an empty list is sent, never no option" do
      assert {data, opts} = Attribution.prepare(@old, @old, owned?: true)

      assert data == @old
      assert Keyword.fetch!(opts, :data_owned_paths) == []
      assert opts[:logged_data_paths] == []
      assert opts[:log_metadata] == %{"via" => "shopify_sync"}
    end
  end

  describe "prepare/3 with a catalogue that does not" do
    test "leaves the data exactly as built and sends only the options it ignores" do
      new = update_in(@old, ["ecommerce"], &Map.delete(&1, "vendor"))

      assert {data, opts} = Attribution.prepare(@old, new, owned?: false)

      assert data == new
      refute Keyword.has_key?(opts, :data_owned_paths)
      assert opts[:log_metadata] == %{"via" => "shopify_sync"}
    end
  end

  test "metadata_opts/1 names the sync for a write that has no data change" do
    assert Attribution.metadata_opts() == [log_metadata: %{"via" => "shopify_sync"}]

    assert Attribution.metadata_opts(actor_uuid: "u") ==
             [log_metadata: %{"via" => "shopify_sync"}, actor_uuid: "u"]
  end
end
