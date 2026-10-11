defmodule PhoenixKitEcommerce.StorefrontCacheTest do
  @moduledoc """
  The node-wide, short-TTL cache behind the /shop page's viewer-independent
  parts. `async: false`: the cache is a named, node-global process, so a
  test that starts it must not overlap with a LiveView test that would read
  through it.
  """
  use ExUnit.Case, async: false

  alias PhoenixKitEcommerce.Events
  alias PhoenixKitEcommerce.StorefrontCache

  # Counts how often the "expensive" computation actually ran.
  defp counting_fun(counter, value) do
    fn ->
      Agent.update(counter, &(&1 + 1))
      value
    end
  end

  defp start_cache do
    start_supervised!(PhoenixKit.Cache.Registry)
    [spec] = StorefrontCache.children()
    start_supervised!(spec)
    :ok
  end

  describe "with the cache running" do
    setup do
      start_cache()
      counter = start_supervised!({Agent, fn -> 0 end})
      %{counter: counter}
    end

    test "a second fetch within the TTL does not run the function", %{counter: counter} do
      assert StorefrontCache.fetch(:k, counting_fun(counter, :v)) == :v
      assert StorefrontCache.fetch(:k, counting_fun(counter, :other)) == :v
      assert Agent.get(counter, & &1) == 1
    end

    test "different keys are different entries", %{counter: counter} do
      assert StorefrontCache.fetch({:filters, "en"}, counting_fun(counter, :en)) == :en
      assert StorefrontCache.fetch({:filters, "de"}, counting_fun(counter, :de)) == :de
      assert StorefrontCache.fetch({:filters, "en"}, counting_fun(counter, :x)) == :en
      assert StorefrontCache.fetch({:filters, "de"}, counting_fun(counter, :x)) == :de
      assert Agent.get(counter, & &1) == 2
    end

    test "clear/0 forces a recompute", %{counter: counter} do
      assert StorefrontCache.fetch(:k, counting_fun(counter, 1)) == 1
      assert StorefrontCache.clear() == :ok
      assert StorefrontCache.fetch(:k, counting_fun(counter, 2)) == 2
      assert Agent.get(counter, & &1) == 2
    end

    test "a cached nil is a hit, not a recompute", %{counter: counter} do
      assert StorefrontCache.fetch(:k, counting_fun(counter, nil)) == nil
      assert StorefrontCache.fetch(:k, counting_fun(counter, :other)) == nil
      assert Agent.get(counter, & &1) == 1
    end

    # Each catalog-changing broadcast must drop the cache: a shopper must
    # not keep seeing a category or a facet count the admin just changed.
    test "every product and category broadcast clears the cache", %{counter: counter} do
      broadcasts = [
        product_created: fn -> Events.broadcast_product_created(%{uuid: "p"}) end,
        product_updated: fn -> Events.broadcast_product_updated(%{uuid: "p"}) end,
        product_deleted: fn -> Events.broadcast_product_deleted("p") end,
        products_bulk_status: fn ->
          Events.broadcast_products_bulk_status_changed(["p"], "active")
        end,
        category_created: fn -> Events.broadcast_category_created(%{uuid: "c"}) end,
        category_updated: fn -> Events.broadcast_category_updated(%{uuid: "c"}) end,
        category_deleted: fn -> Events.broadcast_category_deleted("c") end,
        categories_bulk_status: fn ->
          Events.broadcast_categories_bulk_status_changed(["c"], "active")
        end,
        categories_bulk_parent: fn ->
          Events.broadcast_categories_bulk_parent_changed(["c"], nil)
        end,
        categories_bulk_deleted: fn -> Events.broadcast_categories_bulk_deleted(["c"]) end
      ]

      for {name, broadcast} <- broadcasts do
        assert StorefrontCache.fetch(name, counting_fun(counter, 1)) == 1
        assert StorefrontCache.fetch(name, counting_fun(counter, :stale)) == 1

        broadcast.()

        assert StorefrontCache.fetch(name, counting_fun(counter, 2)) == 2,
               "#{name} did not clear the storefront cache"
      end
    end

    test "an inventory broadcast leaves the cache alone", %{counter: counter} do
      # Stock levels are not part of the cached categories or facets.
      assert StorefrontCache.fetch(:k, counting_fun(counter, 1)) == 1
      Events.broadcast_inventory_updated("p", -1)
      assert StorefrontCache.fetch(:k, counting_fun(counter, 2)) == 1
    end
  end

  describe "fail-open" do
    setup do
      counter = start_supervised!({Agent, fn -> 0 end})
      %{counter: counter}
    end

    test "computes directly when neither the registry nor the cache is running", %{
      counter: counter
    } do
      assert StorefrontCache.fetch(:k, counting_fun(counter, :v)) == :v
      assert StorefrontCache.fetch(:k, counting_fun(counter, :v)) == :v
      assert Agent.get(counter, & &1) == 2
      assert StorefrontCache.clear() == :ok
    end

    test "computes directly when the registry runs but the cache does not", %{counter: counter} do
      start_supervised!(PhoenixKit.Cache.Registry)

      assert StorefrontCache.fetch(:k, counting_fun(counter, :v)) == :v
      assert StorefrontCache.fetch(:k, counting_fun(counter, :v)) == :v
      assert Agent.get(counter, & &1) == 2
      assert StorefrontCache.clear() == :ok
    end

    test "computes directly again after the cache process goes away", %{counter: counter} do
      start_cache()
      assert StorefrontCache.fetch(:k, counting_fun(counter, :v)) == :v

      [spec] = StorefrontCache.children()
      :ok = stop_supervised(spec.id)

      assert StorefrontCache.fetch(:k, counting_fun(counter, :v)) == :v
      assert Agent.get(counter, & &1) == 2
    end

    test "an exception in the function still propagates" do
      start_cache()

      assert_raise RuntimeError, "boom", fn ->
        StorefrontCache.fetch(:k, fn -> raise "boom" end)
      end
    end
  end
end
