defmodule PhoenixKitEcommerce.Web.StorefrontCachePagesTest do
  @moduledoc """
  The storefront's cached categories and filter data
  (`PhoenixKitEcommerce.StorefrontCache`) as the pages and the write paths
  see them. A write that BYPASSES this package (a direct `Repo` call, which
  is what a catalogue-side edit looks like from here) must stay invisible
  until the entry is cleared or expires - that is how the tests tell a
  cache hit from a recomputation. `async: false`: the cache is a named,
  node-global process.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Category
  alias PhoenixKitEcommerce.Events
  alias PhoenixKitEcommerce.ProductSource
  alias PhoenixKitEcommerce.ShopConfig
  alias PhoenixKitEcommerce.StorefrontCache
  alias PhoenixKitEcommerce.Test.Repo
  alias PhoenixKitEcommerce.Web.Components.FilterHelpers
  alias PhoenixKitEcommerce.Web.Helpers

  @cache_name :ecommerce_storefront

  @price %{
    "key" => "price",
    "type" => "price_range",
    "label" => "Price",
    "enabled" => true,
    "position" => 1
  }
  @vendor %{
    "key" => "vendor",
    "type" => "vendor",
    "label" => "Vendor",
    "enabled" => true,
    "position" => 2
  }

  # A filter with a label no other part of the page carries, so its section
  # showing up in the sidebar is unambiguous.
  @brand %{
    "key" => "vendor",
    "type" => "vendor",
    "label" => "Zebra Brands",
    "enabled" => true,
    "position" => 2
  }

  setup do
    # Only an enabled language is cached (the language is client-supplied);
    # "en" and "de" are the ones these tests use.
    Settings.update_setting("languages_enabled", "true")

    Settings.update_json_setting("languages_config", %{
      "languages" => [
        %{"code" => "en", "name" => "English", "is_default" => true, "is_enabled" => true},
        %{"code" => "de", "name" => "German", "is_default" => false, "is_enabled" => true}
      ]
    })

    on_exit(fn -> Settings.update_setting("languages_enabled", "false") end)

    start_supervised!(PhoenixKit.Cache.Registry)
    [spec] = StorefrontCache.children()
    start_supervised!(spec)

    # An empty config row to bypass-update below; nothing is cached yet.
    {:ok, _} = Shop.update_storefront_filters([@price])
    StorefrontCache.clear()
    :ok
  end

  # Writes the filter config straight to the table: no `Events`, no
  # `update_storefront_filters/1`, so nothing clears the cache.
  defp bypass_set_filters!(filters) do
    ShopConfig
    |> Repo.get!("storefront_filters")
    |> ShopConfig.changeset(%{value: %{"filters" => filters}})
    |> Repo.update!()
  end

  defp bypass_create_category!(name) do
    %Category{}
    |> Category.changeset(%{"name" => %{"en" => name}, "status" => "active"})
    |> Repo.insert!()
  end

  defp filter_keys({filters, _values}), do: Enum.map(filters, & &1["key"])

  # Entries written to the cache so far. `put` is a cast and `stats` a call
  # from the same process, so every put made by this process is counted.
  defp puts, do: PhoenixKit.Cache.stats(@cache_name).puts

  describe "load_filter_data_cached/1" do
    test "serves the cached result until it is cleared" do
      opts = [language: "en", exclude_hidden_categories: true]

      assert filter_keys(FilterHelpers.load_filter_data_cached(opts)) == ["price"]

      bypass_set_filters!([@price, @vendor])
      assert filter_keys(FilterHelpers.load_filter_data_cached(opts)) == ["price"]

      StorefrontCache.clear()
      assert filter_keys(FilterHelpers.load_filter_data_cached(opts)) == ["price", "vendor"]
    end

    test "keeps one entry per language" do
      assert filter_keys(FilterHelpers.load_filter_data_cached(language: "en")) == ["price"]

      bypass_set_filters!([@price, @vendor])

      # "en" is still cached, "de" was never computed.
      assert filter_keys(FilterHelpers.load_filter_data_cached(language: "en")) == ["price"]

      assert filter_keys(FilterHelpers.load_filter_data_cached(language: "de")) ==
               ["price", "vendor"]
    end

    test "keeps one entry per category scope" do
      category = %Category{uuid: Ecto.UUID.generate(), storefront_filters: %{}}
      opts = [category_uuid: category.uuid, category: category, language: "en"]

      assert filter_keys(FilterHelpers.load_filter_data_cached(opts)) == ["price"]

      bypass_set_filters!([@price, @vendor])
      assert filter_keys(FilterHelpers.load_filter_data_cached(opts)) == ["price"]

      # Another category was never computed.
      other = %Category{uuid: Ecto.UUID.generate(), storefront_filters: %{}}

      assert filter_keys(
               FilterHelpers.load_filter_data_cached(
                 Keyword.merge(opts, category_uuid: other.uuid, category: other)
               )
             ) == ["price", "vendor"]
    end

    test "a category with edited filter overrides does not get its old entry" do
      category = %Category{uuid: Ecto.UUID.generate(), storefront_filters: %{}}
      opts = [category_uuid: category.uuid, category: category, language: "en"]

      assert filter_keys(FilterHelpers.load_filter_data_cached(opts)) == ["price"]

      # The category now adds a vendor filter of its own.
      edited = %{category | storefront_filters: %{"vendor" => Map.delete(@vendor, "key")}}

      assert filter_keys(
               FilterHelpers.load_filter_data_cached(Keyword.put(opts, :category, edited))
             ) == ["price", "vendor"]
    end

    # The source can be switched at runtime (`shop_product_source`); an entry
    # computed under one adapter must never be served under the other.
    # Needs the catalogue bridge: without `phoenix_kit_catalogue` loaded,
    # `ProductSource.current/0` is always the legacy adapter.
    @tag :catalogue
    test "keeps one entry per product source" do
      opts = [language: "en"]

      assert ProductSource.current() == ProductSource.Legacy
      assert filter_keys(FilterHelpers.load_filter_data_cached(opts)) == ["price"]

      bypass_set_filters!([@price, @vendor])

      Repo.insert!(%ShopConfig{key: "shop_product_source", value: %{"value" => "catalogue"}})
      assert ProductSource.current() == ProductSource.Catalogue

      assert filter_keys(FilterHelpers.load_filter_data_cached(opts)) == ["price", "vendor"]

      Repo.delete!(Repo.get!(ShopConfig, "shop_product_source"))
      assert ProductSource.current() == ProductSource.Legacy
      assert filter_keys(FilterHelpers.load_filter_data_cached(opts)) == ["price"]
    end

    test "keeps one entry per exclude_hidden_categories value" do
      before = puts()

      FilterHelpers.load_filter_data_cached(language: "en", exclude_hidden_categories: true)
      FilterHelpers.load_filter_data_cached(language: "en", exclude_hidden_categories: false)
      FilterHelpers.load_filter_data_cached(language: "en")

      assert puts() - before == 3
    end

    # The language comes from the URL: only a language the shop has enabled
    # may become part of a key, or a client could mint entries at will.
    test "does not cache a language the shop has not enabled" do
      before = puts()

      assert filter_keys(FilterHelpers.load_filter_data_cached(language: "junk0")) == ["price"]
      bypass_set_filters!([@price, @vendor])

      # Recomputed every time, so the bypass write is visible at once.
      assert filter_keys(FilterHelpers.load_filter_data_cached(language: "junk0")) ==
               ["price", "vendor"]

      for n <- 1..50, do: FilterHelpers.load_filter_data_cached(language: "junk#{n}")

      assert puts() == before
    end

    test "caches the default dialect of an enabled base language" do
      opts = [language: "de-DE"]

      assert filter_keys(FilterHelpers.load_filter_data_cached(opts)) == ["price"]
      bypass_set_filters!([@price, @vendor])
      assert filter_keys(FilterHelpers.load_filter_data_cached(opts)) == ["price"]
    end

    test "a saved filter configuration shows on the next call" do
      assert filter_keys(FilterHelpers.load_filter_data_cached(language: "en")) == ["price"]

      {:ok, _} = Shop.update_storefront_filters([@price, @vendor])

      assert filter_keys(FilterHelpers.load_filter_data_cached(language: "en")) ==
               ["price", "vendor"]
    end
  end

  describe "list_active_categories_cached/1" do
    test "serves the cached list until a category write clears it" do
      bypass_create_category!("First Cat")

      assert [%{uuid: _}] = Helpers.list_active_categories_cached()

      bypass_create_category!("Second Cat")
      assert [_] = Helpers.list_active_categories_cached()

      # A write through the package announces itself and drops the cache.
      {:ok, _} = Shop.create_category(%{"name" => %{"en" => "Third Cat"}, "status" => "active"})
      assert length(Helpers.list_active_categories_cached()) == 3
    end

    test "keeps one entry per options" do
      bypass_create_category!("First Cat")
      assert [_] = Helpers.list_active_categories_cached()
      assert [_] = Helpers.list_active_categories_cached(preload: [:featured_product])

      bypass_create_category!("Second Cat")

      assert [_] = Helpers.list_active_categories_cached()
      assert [_] = Helpers.list_active_categories_cached(preload: [:featured_product])
      assert length(Helpers.list_active_categories_cached(preload: [:parent])) == 2
    end
  end

  describe "list_active_categories_cached/1 keys" do
    @tag :catalogue
    test "keeps one entry per product source" do
      bypass_create_category!("Legacy Cat")

      assert ProductSource.current() == ProductSource.Legacy
      assert [%{name: _}] = Helpers.list_active_categories_cached()

      Repo.insert!(%ShopConfig{key: "shop_product_source", value: %{"value" => "catalogue"}})
      assert ProductSource.current() == ProductSource.Catalogue

      # Not the legacy list that is still cached under the other source.
      assert Helpers.list_active_categories_cached() == Shop.list_active_categories([])

      Repo.delete!(Repo.get!(ShopConfig, "shop_product_source"))
    end
  end

  # `PhoenixKitEcommerce.bulk_update_product_category/2` and
  # `bulk_delete_products/1` never broadcast, so `Events` does not see them:
  # the clear is in the functions themselves.
  describe "bulk writes that do not broadcast" do
    setup do
      {:ok, product} =
        Shop.create_product(%{"title" => %{"en" => "Plain Vase"}, "price" => "10.00"})

      category = bypass_create_category!("Target Cat")
      %{product: product, category: category}
    end

    # Fetched after the setup writes, which clear the cache themselves.
    defp prefill_probe, do: :stale = StorefrontCache.fetch(:probe, fn -> :stale end)
    defp probe_cleared?, do: StorefrontCache.fetch(:probe, fn -> :fresh end) == :fresh

    test "bulk_update_product_category/2 clears the cache once it has written", ctx do
      prefill_probe()

      assert Shop.bulk_update_product_category([ctx.product.uuid], ctx.category.uuid) == 1

      assert probe_cleared?()
    end

    test "bulk_update_product_category/2 leaves the cache alone when it writes nothing", ctx do
      prefill_probe()

      # No product matches, or the requested category does not exist:
      # nothing is written either way.
      assert Shop.bulk_update_product_category([Ecto.UUID.generate()], ctx.category.uuid) == 0
      assert Shop.bulk_update_product_category([ctx.product.uuid], Ecto.UUID.generate()) == 0

      refute probe_cleared?()
    end

    test "bulk_delete_products/1 clears the cache once it has deleted", ctx do
      prefill_probe()

      assert Shop.bulk_delete_products([ctx.product.uuid]) == 1

      assert probe_cleared?()
    end

    test "bulk_delete_products/1 leaves the cache alone when nothing matches" do
      prefill_probe()

      assert Shop.bulk_delete_products([Ecto.UUID.generate()]) == 0

      refute probe_cleared?()
    end

    # The catalogue source refuses both (`0`, no write), so there is nothing
    # to refresh.
    @tag :catalogue
    test "the catalogue source's early return leaves the cache alone", ctx do
      Repo.insert!(%ShopConfig{key: "shop_product_source", value: %{"value" => "catalogue"}})
      prefill_probe()

      assert Shop.bulk_update_product_category([ctx.product.uuid], ctx.category.uuid) == 0
      assert Shop.bulk_delete_products([ctx.product.uuid]) == 0

      refute probe_cleared?()

      Repo.delete!(Repo.get!(ShopConfig, "shop_product_source"))
    end
  end

  describe "wiring" do
    test "the module contributes the cache to the host's supervision tree" do
      assert PhoenixKitEcommerce.children() == StorefrontCache.children()
    end

    # Catalogue-side edits and the background Shopify jobs do not clear the
    # cache, so the TTL is the only freshness mechanism for them: an entry
    # that never expires would freeze the storefront until a restart.
    # `max_size` is the backstop for the key space. The spec is what the
    # host starts, so it is the place to pin both.
    test "the cache process is started with a 60 second TTL and a size bound" do
      assert [%{start: {PhoenixKit.Cache, :start_link, [opts]}}] = StorefrontCache.children()

      assert opts[:name] == :ecommerce_storefront
      assert opts[:ttl] == 60_000
      assert is_integer(opts[:max_size]) and opts[:max_size] > 0
    end

    # A LiveView reacting to the broadcast re-reads at once; it must find the
    # cache already empty. The subscriber is a separate process that reads
    # the moment the message lands.
    test "a product broadcast has cleared the cache by the time subscribers hear it" do
      for {name, broadcast} <- [
            {:products, fn -> Events.broadcast_product_updated(%{uuid: "p"}) end},
            {:categories, fn -> Events.broadcast_category_updated(%{uuid: "c"}) end}
          ] do
        test_pid = self()

        subscriber =
          spawn_link(fn ->
            if name == :products,
              do: Events.subscribe_products(),
              else: Events.subscribe_categories()

            send(test_pid, :subscribed)

            receive do
              _message ->
                send(test_pid, {:seen, StorefrontCache.fetch(name, fn -> :recomputed end)})
            end
          end)

        assert_receive :subscribed
        assert StorefrontCache.fetch(name, fn -> :stale end) == :stale

        broadcast.()

        assert_receive {:seen, seen}
        assert seen == :recomputed, "#{name}: a subscriber still read the old entry"
        Process.unlink(subscriber)
      end
    end
  end

  describe "the /shop page" do
    test "shows the cached category list, then the fresh one after a clear", %{conn: conn} do
      bypass_create_category!("Alpha Garden")

      {:ok, _view, html} = live(conn, "/shop")
      assert html =~ "Alpha Garden"

      bypass_create_category!("Beta Terrace")

      {:ok, _view, html} = live(conn, "/shop")
      assert html =~ "Alpha Garden"
      refute html =~ "Beta Terrace"

      StorefrontCache.clear()

      {:ok, _view, html} = live(conn, "/shop")
      assert html =~ "Beta Terrace"
    end

    # The facet aggregates are the expensive part of the page: the mount must
    # read the filter data through the cache, not recompute it.
    test "shows the cached filter section, then the fresh one after a clear", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/shop")
      refute has_element?(view, "summary", "Zebra Brands")

      bypass_set_filters!([@price, @brand])

      {:ok, view, _html} = live(conn, "/shop")
      refute has_element?(view, "summary", "Zebra Brands")

      StorefrontCache.clear()

      {:ok, view, _html} = live(conn, "/shop")
      assert has_element?(view, "summary", "Zebra Brands")
    end

    # The category list is language-independent: its one entry is shared by
    # every language, so a language that is not enabled adds nothing to it
    # and the filter data of such a language is never stored.
    test "an unknown locale in the path costs no cache entries beyond the shared list",
         %{conn: conn} do
      before = puts()

      assert {:ok, _view, _html} = live(conn, "/junk0/shop")
      assert puts() - before == 1

      for n <- 1..5, do: assert({:ok, _view, _html} = live(conn, "/junk#{n}/shop"))

      assert puts() - before == 1
    end

    test "serves one category list to every language", %{conn: conn} do
      bypass_create_category!("Alpha Garden")

      {:ok, _view, html} = live(conn, "/shop")
      assert html =~ "Alpha Garden"

      bypass_create_category!("Beta Terrace")

      # A per-language entry would be a cold miss here and show Beta.
      {:ok, _view, html} = live(conn, "/de/shop")
      assert html =~ "Alpha Garden"
      refute html =~ "Beta Terrace"
    end
  end

  describe "the /shop/category/:slug page" do
    test "shows the cached category list, then the fresh one after a clear", %{conn: conn} do
      alpha = bypass_create_category!("Alpha Garden")
      path = "/shop/category/#{alpha.slug["en"]}"

      {:ok, _view, html} = live(conn, path)
      assert html =~ "Alpha Garden"

      bypass_create_category!("Beta Terrace")

      {:ok, _view, html} = live(conn, path)
      refute html =~ "Beta Terrace"

      StorefrontCache.clear()

      {:ok, _view, html} = live(conn, path)
      assert html =~ "Beta Terrace"
    end

    test "shows the cached filter section, then the fresh one after a clear", %{conn: conn} do
      alpha = bypass_create_category!("Alpha Garden")
      path = "/shop/category/#{alpha.slug["en"]}"

      {:ok, view, _html} = live(conn, path)
      refute has_element?(view, "summary", "Zebra Brands")

      bypass_set_filters!([@price, @brand])

      {:ok, view, _html} = live(conn, path)
      refute has_element?(view, "summary", "Zebra Brands")

      StorefrontCache.clear()

      {:ok, view, _html} = live(conn, path)
      assert has_element?(view, "summary", "Zebra Brands")
    end
  end
end
