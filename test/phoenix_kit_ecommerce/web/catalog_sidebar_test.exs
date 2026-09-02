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

  setup do
    original = Gettext.get_locale(PhoenixKitEcommerce.Gettext)
    on_exit(fn -> Gettext.put_locale(PhoenixKitEcommerce.Gettext, original) end)
    :ok
  end

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

    test "the built-in search label resolves to the active locale" do
      Gettext.put_locale(PhoenixKitEcommerce.Gettext, "de")

      html =
        render_component(&CatalogSidebar.filter_section/1,
          filter: @search_filter,
          values: %{},
          active: nil
        )

      assert html =~ ~s(placeholder="Suche")
      refute html =~ ~s(placeholder="Search")
    end

    test "an admin-entered label is never translated, even when it collides with a msgid" do
      Gettext.put_locale(PhoenixKitEcommerce.Gettext, "de")

      html =
        render_component(&CatalogSidebar.filter_section/1,
          filter: %{"key" => "price", "type" => "price_range", "label" => "Cost"},
          values: %{min: Decimal.new(1), max: Decimal.new(9)},
          active: nil
        )

      assert html =~ "Cost"
      refute html =~ "Kosten"
    end
  end
end
