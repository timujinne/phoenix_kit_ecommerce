defmodule PhoenixKitEcommerce.Catalogue.ShopStatusColumnCatalogueIntegrationTest do
  @moduledoc """
  Integration-style coverage: does `ShopStatusColumn`'s `item_columns/0`/
  `category_columns/0` actually reach a rendered catalogue admin list
  through the REAL `PhoenixKitCatalogue.Extensions.columns/1` discovery
  pipeline (namespacing under `ecommerce:`, the per-cell raise/throw/exit
  guard) — not just conform to the shape in isolation, which
  `ShopStatusColumnTest` already covers.

  Needs `phoenix_kit_catalogue` loaded (with its own migrations applied)
  — excluded via `test_helper.exs`'s `:catalogue` tag whenever the
  optional dependency isn't present, same as every other `:catalogue`
  test in this fork. Bridge in via
  `PHOENIX_KIT_CATALOGUE_PATH`/`PHOENIX_KIT_ENTITIES_PATH` (see
  `mix.exs`'s `catalogue_test_deps/0`) to run it locally; it also runs
  automatically once a host declares the dependency for real.

  `PhoenixKitEcommerce.Catalogue.Extension` is discovered exactly the
  way production does it: `PhoenixKitEcommerce` is already registered
  with `PhoenixKit.ModuleRegistry` by `test_helper.exs` (mirrors the
  host app booting it), and `DataCase`'s `setup` already flips
  `shop_enabled` on — nothing here registers or enables anything itself.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :catalogue

  # Quiets the compiler's static xref check for `mix test` runs where the
  # optional `phoenix_kit_catalogue` dependency isn't declared — every
  # test in this module is excluded in that case (see `test_helper.exs`),
  # so the calls below are never actually reached. Real catalogue structs
  # below are built via `struct!/2` rather than `%Module{...}` literals
  # on purpose: the `%Module{...}` syntax needs the struct's fields at
  # COMPILE time (a hard `CompileError`, not a warning, when the module
  # is absent) — `struct!/2` is a plain function call the compiler
  # doesn't need to resolve until it actually runs.
  @compile {:no_warn_undefined, PhoenixKitCatalogue.Extensions}

  alias Phoenix.HTML.Safe, as: HtmlSafe
  alias PhoenixKitEcommerce.Catalogue.Extension

  defp find_column(columns), do: Enum.find(columns, &(&1.id == "ecommerce:shop_status"))

  test "PhoenixKitEcommerce.Catalogue.Extension is discovered as an enabled catalogue extension" do
    assert Extension in PhoenixKitCatalogue.Extensions.all()
  end

  test "the item column is namespaced ecommerce:shop_status and shaped correctly" do
    columns = PhoenixKitCatalogue.Extensions.columns(:detail_items)
    assert %{id: "ecommerce:shop_status", label: label, render: render} = find_column(columns)
    assert is_function(label, 0)
    assert is_function(render, 1)
  end

  test "the category column is namespaced ecommerce:shop_status and shaped correctly" do
    columns = PhoenixKitCatalogue.Extensions.columns(:detail_categories)
    assert %{id: "ecommerce:shop_status", label: label, render: render} = find_column(columns)
    assert is_function(label, 0)
    assert is_function(render, 1)
  end

  test "the label survives the extension slot's own guard and resolves to the translated header" do
    %{label: label} = PhoenixKitCatalogue.Extensions.columns(:detail_items) |> find_column()
    assert label.() == "Shop status"
  end

  test "render/1 against a real PhoenixKitCatalogue.Schemas.Item shows the disagreement, no warning" do
    %{render: render} = PhoenixKitCatalogue.Extensions.columns(:detail_items) |> find_column()

    # Since PR #53, `View.product_status/2` defers to `item.status`
    # first and forces "archived" on any non-active catalogue status
    # regardless of `shop_status` — so this combination is shown as a
    # disagreement (both raw values render) but is no longer a
    # reachability hazard, and never warns (see ShopStatusColumn
    # moduledoc / ShopStatusColumnTest).
    item =
      struct!(PhoenixKitCatalogue.Schemas.Item,
        status: "discontinued",
        data: %{"ecommerce" => %{"shop_status" => "active"}}
      )

    html = render.(item) |> HtmlSafe.to_iodata() |> IO.iodata_to_binary()

    assert html =~ ~s(data-catalogue-status="discontinued")
    assert html =~ ~s(data-shop-status="active")
    assert html =~ ~s(data-contradiction="false")
    refute html =~ "hero-exclamation-triangle"
    refute html =~ ~s( id=")
  end

  test "render/1 against a real item with a deliberate hold-back (active/draft) renders no warning" do
    %{render: render} = PhoenixKitCatalogue.Extensions.columns(:detail_items) |> find_column()

    item =
      struct!(PhoenixKitCatalogue.Schemas.Item,
        status: "active",
        data: %{"ecommerce" => %{"shop_status" => "draft"}}
      )

    html = render.(item) |> HtmlSafe.to_iodata() |> IO.iodata_to_binary()

    assert html =~ ~s(data-contradiction="false")
    refute html =~ "hero-exclamation-triangle"
  end

  test "render/1 against a real PhoenixKitCatalogue.Schemas.Category renders the agreement cell" do
    %{render: render} =
      PhoenixKitCatalogue.Extensions.columns(:detail_categories) |> find_column()

    category =
      struct!(PhoenixKitCatalogue.Schemas.Category,
        status: "active",
        data: %{"ecommerce" => %{"shop_status" => "active"}}
      )

    html = render.(category) |> HtmlSafe.to_iodata() |> IO.iodata_to_binary()

    assert html =~ ~s(data-contradiction="false")
    refute html =~ "hero-exclamation-triangle"
  end

  test "render/1 against a real deleted/unlisted category WARNS — the category gate is a block-list of just \"hidden\"" do
    %{render: render} =
      PhoenixKitCatalogue.Extensions.columns(:detail_categories) |> find_column()

    # Regression coverage for the gap a prior review found: a category
    # rule modelled on the item page's ALLOW-list (only "active"
    # passes) wrongly said "no warning" here, because "unlisted" isn't
    # "active" either. `CatalogCategory.do_mount/3` is a BLOCK-list —
    # it only redirects on "hidden" — so this soft-deleted category is
    # still reachable by direct link.
    category =
      struct!(PhoenixKitCatalogue.Schemas.Category,
        status: "deleted",
        data: %{"ecommerce" => %{"shop_status" => "unlisted"}}
      )

    html = render.(category) |> HtmlSafe.to_iodata() |> IO.iodata_to_binary()

    assert html =~ ~s(data-contradiction="true")
    assert html =~ "hero-exclamation-triangle"
  end

  test "a real item with no ecommerce namespace at all (never touched by the Shop section) does not raise" do
    %{render: render} = PhoenixKitCatalogue.Extensions.columns(:detail_items) |> find_column()

    item = struct!(PhoenixKitCatalogue.Schemas.Item, status: "active", data: %{})

    html = render.(item) |> HtmlSafe.to_iodata() |> IO.iodata_to_binary()

    assert html =~ ~s(data-shop-status="default")
    assert html =~ ~s(data-contradiction="false")
  end
end
