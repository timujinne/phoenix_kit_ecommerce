defmodule PhoenixKitEcommerce.Web.Components.CatalogSidebarTest do
  @moduledoc """
  Render tests for the storefront sidebar `filter_section/1` component,
  focused on the text `search` filter type. Level 1 — no database required.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKitEcommerce.Web.Components.CatalogSidebar

  @search_filter %{
    "key" => "search",
    "type" => "search",
    "label" => "Search",
    "enabled" => true,
    "position" => 0
  }

  describe "filter_section/1 for the search type" do
    test "renders a submit form with a text input named after the filter key" do
      html =
        render_component(&CatalogSidebar.filter_section/1,
          filter: @search_filter,
          values: %{},
          active: nil
        )

      assert html =~ ~s(phx-submit="filter_search")
      assert html =~ ~s(name="filter_key")
      assert html =~ ~s(value="search")
      assert html =~ ~s(name="search")
      assert html =~ "Search"
    end

    test "shows the active search term in the input" do
      html =
        render_component(&CatalogSidebar.filter_section/1,
          filter: @search_filter,
          values: %{},
          active: "wall mask"
        )

      assert html =~ ~s(value="wall mask")
    end
  end
end
