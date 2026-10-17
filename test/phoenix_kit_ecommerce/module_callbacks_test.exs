defmodule PhoenixKitEcommerce.ModuleCallbacksTest do
  @moduledoc """
  Pins the `PhoenixKit.Module` callbacks this module contributes to its host.

  These exist because `css_sources/0` was documented in both README.md and
  AGENTS.md as implemented, and was not. The failure was invisible: core's
  `:phoenix_kit_css_sources` compiler collects the callback from every
  discovered module, and only warns when the TOTAL list is empty — so any
  other installed module masked the absence, while Tailwind quietly purged
  every class used only by this module's templates from the host build.

  A one-line assertion would have caught it, so here is the one line.
  """
  use ExUnit.Case, async: true

  @compile {:no_warn_undefined, PhoenixKit.ObanCrons}

  alias PhoenixKit.Dashboard.Tab

  # The modules that build the tools `api_tools/0` hands over.
  defp groups,
    do: [
      PhoenixKitEcommerce.API,
      PhoenixKitEcommerce.API.PublicTools,
      PhoenixKitEcommerce.API.CartTools
    ]

  test "css_sources/0 contributes this app to the host Tailwind build" do
    assert PhoenixKitEcommerce.css_sources() == [:phoenix_kit_ecommerce]
  end

  test "api_tools/0 hands core the admin, the public read and the cart tools, and nothing on a core without the registry" do
    tools = PhoenixKitEcommerce.api_tools()
    names = Enum.map(tools, & &1.name)

    assert is_list(tools)

    if Code.ensure_loaded?(PhoenixKit.API.Tool) do
      # Each group is whatever its own module offers on this core (the admin
      # write tools only on a core with the confirmation flow, the cart tools
      # that need it likewise), so the expectation is derived, not counted.
      offered = for group <- groups(), tool <- group.tools(), do: tool.name

      assert Enum.sort(names) == Enum.sort(offered)
      assert names == Enum.uniq(names), "a tool name is offered twice"
    else
      assert tools == []
    end
  end

  # The module hands over its tools from one clause. A second `def api_tools`
  # would not be an error: the compiler only warns, the first clause wins and
  # the other group of tools is silently dropped.
  test "api_tools/0 is defined by exactly one clause" do
    {:ok, ast} = "lib/phoenix_kit_ecommerce.ex" |> File.read!() |> Code.string_to_quoted()

    {_ast, clauses} =
      Macro.prewalk(ast, 0, fn
        {:def, _meta, [{:api_tools, _, args} | _]} = node, count when args in [nil, []] ->
          {node, count + 1}

        node, count ->
          {node, count}
      end)

    assert clauses == 1
  end

  @tag :requires_core_api
  test "on a core with the shop API every group of tools is offered" do
    names = Enum.map(PhoenixKitEcommerce.api_tools(), & &1.name)

    for group <- groups() do
      tools = group.tools()
      assert tools != [], "#{inspect(group)} offers no tool"
      assert Enum.all?(tools, &(&1.name in names)), "#{inspect(group)} is missing"
    end

    assert Enum.any?(names, &String.starts_with?(&1, "ecommerce."))
    assert "shop.search_products" in names
    assert "shop.create_cart" in names
  end

  test "warehouse_source_kinds/0 contributes the shop_order kind to Warehouse" do
    assert [%{kind: "shop_order", search: {_, _, _}, resolve: {_, _, _}, build_lines: {_, _, _}}] =
             PhoenixKitEcommerce.warehouse_source_kinds()
  end

  test "module_key/0 matches what the permission and tabs declare" do
    # Every tab guards either the base key or one of THIS module's declared
    # sub-permissions. If a tab's key drifts outside that set, the sidebar
    # and the actual gate disagree: the page hides but stays reachable, or
    # shows and then denies.
    assert PhoenixKitEcommerce.module_key() == "shop"

    valid = valid_permission_keys()

    for tab <- PhoenixKitEcommerce.admin_tabs() do
      assert tab.permission in valid,
             "tab #{inspect(tab.id)} guards #{inspect(tab.permission)}, " <>
               "which is neither the base key nor a declared sub-permission"
    end
  end

  test "every declared sub-permission is actually used by a tab or the Authz layer" do
    # A declared-but-unenforced capability is worse than none: it shows up
    # in the admin permission matrix, an operator grants or withholds it,
    # and nothing changes.
    %{sub_permissions: subs} = PhoenixKitEcommerce.permission_metadata()

    tab_keys = PhoenixKitEcommerce.admin_tabs() |> Enum.map(& &1.permission) |> MapSet.new()

    authz_sources =
      Path.wildcard("lib/phoenix_kit_ecommerce/web/*.ex")
      |> Enum.map_join("\n", &File.read!/1)

    for %{key: key} <- subs do
      full = "shop.#{key}"

      assert MapSet.member?(tab_keys, full) or authz_sources =~ ":#{key}",
             "sub-permission #{inspect(full)} is declared but never enforced"
    end
  end

  defp valid_permission_keys do
    meta = PhoenixKitEcommerce.permission_metadata()

    MapSet.new([meta.key | Enum.map(meta.sub_permissions, &"#{meta.key}.#{&1.key}")])
  end

  test "required_modules/0 names billing, which this module hard-depends on" do
    # Order and invoice creation route through PhoenixKitBilling; declaring it
    # is what stops a host enabling shop without it.
    assert "billing" in PhoenixKitEcommerce.required_modules()
  end

  test "version/0 is single-sourced from mix.exs" do
    assert PhoenixKitEcommerce.version() == Mix.Project.config()[:version]
  end

  # The avatar dropdown carries the shopper's own pages, not the catalogue:
  # "My Cart" sits there beside billing's "My Orders", "Shop" stays in the nav.
  @tag :requires_core_user_menu
  test "user_dashboard_tabs/0 offers My Cart, and only My Cart, in the avatar dropdown" do
    menu_ids =
      for tab <- PhoenixKitEcommerce.user_dashboard_tabs(),
          Tab.user_menu?(tab, nil),
          do: tab.id

    assert menu_ids == [:dashboard_cart]
  end

  test "oban_queues/0 declares the shop_search queue the search workers run on" do
    specs = PhoenixKit.ObanQueues.declared([PhoenixKitEcommerce])

    assert Enum.any?(specs, &(&1.name == :shop_search and &1.limit == 2 and &1.kind == :batch))
  end

  @tag :requires_core_api
  test "oban_crons/0 declares the nightly search rebuild and the three cart jobs, without conflicts" do
    assert {entries, []} = PhoenixKit.ObanCrons.declared([PhoenixKitEcommerce])

    assert {"40 3 * * *", PhoenixKitEcommerce.Workers.SearchRebuildWorker} in entries
    assert {"17 * * * *", PhoenixKitEcommerce.Workers.ApiCartSweepWorker} in entries
    assert {"40 4 * * *", PhoenixKitEcommerce.Workers.ApiCartPruneWorker} in entries
    assert {"50 4 * * *", PhoenixKitEcommerce.Workers.ApiClaimPruneWorker} in entries
  end

  test "children/0 contributes the search subscriber" do
    ids = Enum.map(PhoenixKitEcommerce.children(), &Supervisor.child_spec(&1, []).id)

    assert PhoenixKitEcommerce.Search.Subscriber in ids
  end
end
