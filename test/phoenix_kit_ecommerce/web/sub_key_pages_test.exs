defmodule PhoenixKitEcommerce.Web.SubKeyPagesTest do
  @moduledoc """
  Every admin page that does the work of a sub-permission refuses a scope
  holding only the base `"shop"` key at mount — the tabbed list pages and
  the tab-less forms, detail and settings pages behind them — and every
  tab gated on a sub-key names its `live_view:`, so core maps the page to
  that key instead of resolving it through the namespace to `"shop"`.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitEcommerce.Web.Routes

  defp scope_with(permissions), do: fake_scope(roles: ["Employee"], permissions: permissions)

  @missing Ecto.UUID.generate()

  # {path, the sub-key the page needs}
  @pages [
    {"/en/admin/shop/products", "manage_catalog"},
    {"/en/admin/shop/products/new", "manage_catalog"},
    {"/en/admin/shop/products/#{@missing}", "manage_catalog"},
    {"/en/admin/shop/products/#{@missing}/edit", "manage_catalog"},
    {"/en/admin/shop/categories", "manage_catalog"},
    {"/en/admin/shop/categories/new", "manage_catalog"},
    {"/en/admin/shop/categories/#{@missing}/edit", "manage_catalog"},
    {"/en/admin/shop/shipping", "manage_settings"},
    {"/en/admin/shop/shipping/new", "manage_settings"},
    {"/en/admin/shop/shipping/#{@missing}/edit", "manage_settings"},
    {"/en/admin/shop/settings", "manage_settings"},
    {"/en/admin/shop/settings/options", "manage_settings"},
    {"/en/admin/shop/settings/import-configs", "run_imports"},
    {"/en/admin/shop/imports", "run_imports"},
    {"/en/admin/shop/imports/#{@missing}", "run_imports"},
    {"/en/admin/shop/shopify-sync", "run_imports"},
    {"/en/admin/shop/test", "manage_catalog"}
  ]

  describe "a scope without the page's sub-key is refused at mount" do
    for {path, sub} <- @pages do
      @tag :integration
      test "#{path} (needs shop.#{sub})", %{conn: conn} do
        # Every OTHER capability, so only the page's own key is missing.
        others =
          shop_permissions()
          |> List.delete("shop.#{unquote(sub)}")

        conn = put_test_scope(conn, scope_with(others))

        assert {:error, {:live_redirect, %{to: to, flash: flash}}} = live(conn, unquote(path))
        assert to =~ "/admin/shop"
        refute to == unquote(path)
        assert flash["error"] =~ "permission"
      end
    end
  end

  describe "a holder of the sub-key opens the page" do
    for {path, sub} <- @pages, not String.contains?(path, @missing) do
      @tag :integration
      test "#{path} with shop.#{sub}", %{conn: conn} do
        conn = put_test_scope(conn, scope_with(["shop", "shop.#{unquote(sub)}"]))

        case live(conn, unquote(path)) do
          {:ok, _view, _html} ->
            :ok

          # Shopify sync is reachable only while its feature switch is on;
          # that redirect is not a permission refusal.
          {:error, {:live_redirect, %{flash: flash}}} ->
            refute (flash["error"] || "") =~ "permission"
        end
      end
    end
  end

  describe "the tabs map their pages to the sub-key" do
    test "every sub-key tab names its LiveView" do
      tabs = PhoenixKitEcommerce.admin_tabs() ++ PhoenixKitEcommerce.settings_tabs()

      gated = Enum.filter(tabs, &String.starts_with?(&1.permission || "", "shop."))
      assert gated != []

      for tab <- gated do
        assert {mod, :index} = tab.live_view, "tab #{inspect(tab.id)} has no live_view"
        assert Code.ensure_loaded?(mod)
      end
    end

    test "no tab-routed page is declared a second time in the route module" do
      tab_paths =
        (PhoenixKitEcommerce.admin_tabs() ++ PhoenixKitEcommerce.settings_tabs())
        |> Enum.filter(& &1.live_view)
        |> Enum.map(fn tab ->
          case tab.path do
            "/" <> _ = abs -> abs
            rel -> "/admin/" <> rel
          end
        end)

      {_, route_paths} =
        Macro.prewalk(Routes.admin_routes(), [], fn
          {:live, _, [path | _]} = node, acc when is_binary(path) -> {node, [path | acc]}
          node, acc -> {node, acc}
        end)

      assert tab_paths != []
      assert MapSet.disjoint?(MapSet.new(tab_paths), MapSet.new(route_paths))
    end
  end
end
