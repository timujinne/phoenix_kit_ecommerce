defmodule PhoenixKitEcommerce.Web.Components.FilterHelpersTest do
  @moduledoc """
  Unit tests for the pure storefront-filter state helpers: the `search`
  filter type, and the `metadata_option`/`attribute_set` slug-list
  filters (Block 5, 2026-09-06 plan). Level 1 — no database required.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.Web.Components.FilterHelpers

  @search_filter %{
    "key" => "search",
    "type" => "search",
    "label" => "Search",
    "enabled" => true,
    "position" => 0
  }

  @price_filter %{
    "key" => "price",
    "type" => "price_range",
    "label" => "Price",
    "enabled" => true,
    "position" => 1
  }

  @metadata_option_filter %{
    "key" => "size",
    "type" => "metadata_option",
    "option_key" => "size",
    "label" => "Size",
    "enabled" => true,
    "position" => 2
  }

  @attribute_set_filter %{
    "key" => "color",
    "type" => "attribute_set",
    "set_slug" => "color",
    "label" => "Color",
    "enabled" => true,
    "position" => 3
  }

  describe "parse_filter_params/2 with search filter" do
    test "extracts a non-empty search param" do
      active = FilterHelpers.parse_filter_params(%{"search" => "mask"}, [@search_filter])
      assert active == %{"search" => "mask"}
    end

    test "trims surrounding whitespace" do
      active = FilterHelpers.parse_filter_params(%{"search" => "  mask "}, [@search_filter])
      assert active == %{"search" => "mask"}
    end

    test "ignores empty and whitespace-only values" do
      assert FilterHelpers.parse_filter_params(%{"search" => ""}, [@search_filter]) == %{}
      assert FilterHelpers.parse_filter_params(%{"search" => "   "}, [@search_filter]) == %{}
      assert FilterHelpers.parse_filter_params(%{}, [@search_filter]) == %{}
    end
  end

  describe "build_query_opts/2 with search filter" do
    test "maps an active search to the :search opt" do
      opts = FilterHelpers.build_query_opts(%{"search" => "mask"}, [@search_filter])
      assert opts[:search] == "mask"
    end

    test "combines with other filter types" do
      active = %{"search" => "mask", "price" => %{min: Decimal.new(5), max: nil}}
      opts = FilterHelpers.build_query_opts(active, [@search_filter, @price_filter])
      assert opts[:search] == "mask"
      assert Decimal.equal?(opts[:price_min], Decimal.new(5))
    end
  end

  describe "URL round-trip with search filter" do
    test "build_query_string includes the search param" do
      qs = FilterHelpers.build_query_string(%{"search" => "wall mask"}, [@search_filter])
      assert qs == "?search=wall+mask"
    end

    test "build_filter_url appends the search param to the base path" do
      url = FilterHelpers.build_filter_url("/shop", %{"search" => "mask"}, [@search_filter])
      assert url == "/shop?search=mask"
    end

    test "query string round-trips through parse_filter_params" do
      active = %{"search" => "wall mask"}
      qs = FilterHelpers.build_query_string(active, [@search_filter])
      params = URI.decode_query(String.trim_leading(qs, "?"))
      assert FilterHelpers.parse_filter_params(params, [@search_filter]) == active
    end
  end

  describe "active state helpers with search filter" do
    test "has_active_filters?/1 is true for a non-empty search" do
      assert FilterHelpers.has_active_filters?(%{"search" => "mask"})
    end

    test "active_filter_count/1 counts a search term as one" do
      assert FilterHelpers.active_filter_count(%{"search" => "mask"}) == 1
    end
  end

  describe "metadata_option and attribute_set filters (value SLUGS, not labels)" do
    test "parse_filter_params splits a metadata_option filter's comma list into slugs" do
      active = FilterHelpers.parse_filter_params(%{"size" => "a,b"}, [@metadata_option_filter])
      assert active == %{"size" => ["a", "b"]}
    end

    test "parse_filter_params splits an attribute_set filter's comma list the same way" do
      active =
        FilterHelpers.parse_filter_params(%{"color" => "red,blue"}, [@attribute_set_filter])

      assert active == %{"color" => ["red", "blue"]}
    end

    test "build_query_opts maps a metadata_option filter to :metadata_filters keyed by option_key" do
      opts = FilterHelpers.build_query_opts(%{"size" => ["a", "b"]}, [@metadata_option_filter])
      assert opts[:metadata_filters] == [%{key: "size", values: ["a", "b"]}]
    end

    test "build_query_opts maps an attribute_set filter to :metadata_filters keyed by set_slug" do
      opts =
        FilterHelpers.build_query_opts(%{"color" => ["red", "blue"]}, [@attribute_set_filter])

      assert opts[:metadata_filters] == [%{key: "color", values: ["red", "blue"]}]
    end

    test "metadata_option filter values round-trip through the query string" do
      active = %{"size" => ["a", "b"]}
      qs = FilterHelpers.build_query_string(active, [@metadata_option_filter])
      params = URI.decode_query(String.trim_leading(qs, "?"))
      assert FilterHelpers.parse_filter_params(params, [@metadata_option_filter]) == active
    end

    test "attribute_set filter values round-trip through the query string" do
      active = %{"color" => ["red", "blue"]}
      qs = FilterHelpers.build_query_string(active, [@attribute_set_filter])
      params = URI.decode_query(String.trim_leading(qs, "?"))
      assert FilterHelpers.parse_filter_params(params, [@attribute_set_filter]) == active
    end
  end
end
