defmodule PhoenixKitEcommerce.Catalogue.ShopStatusColumnTest do
  @moduledoc """
  Level 1 — pure/component tests, no database required.

  `ShopStatusColumn` renders the catalogue admin's "Shop status" column
  — the owner's complaint was that the catalogue's own `status` and the
  shop's `data["ecommerce"]["shop_status"]` are two independent signals
  and only one showed on screen (see `PhoenixKitEcommerce.Catalogue.
  ShopStatusColumn`'s moduledoc for the full rule and the code paths it
  was read from).

  CORRECTION (post-review, measured against the owner's live stand): an
  earlier version of this column warned whenever catalogue-active and
  shop-active disagreed in EITHER direction. That fired on 22.6% of
  items and 90% of categories, almost all of them deliberate states
  (`draft` is the schema default for an item never pushed to the shop;
  `hidden`/`unlisted` categories the owner chose on purpose) — a warning
  that fires on the majority of rows teaches the owner to ignore it.
  The corrected rule (see the module's moduledoc) warns ONLY when the
  shop reports something as active that the catalogue does not — the
  one combination that is reachable by direct URL/link
  (`CatalogProduct.do_mount/3` / `CatalogCategory.do_mount/3`) despite
  being excluded from every listing, count and facet. The reverse
  (catalogue active, shop draft/archived/unlisted/hidden) is how the
  owner deliberately keeps something out of the shop and renders with
  no warning. This file replaces the old (bugged) `active+draft ==
  contradiction` test — see `shop_status_column_test.exs` git history
  for what it said before.

  Assertions read the cell's own `data-catalogue-status="..."` /
  `data-shop-status="..."` / `data-contradiction="..."` attributes
  instead of matching badge text, since two badges' rendered labels can
  otherwise collide in one cell's HTML.
  """

  use ExUnit.Case, async: true

  alias Phoenix.HTML.Safe, as: HtmlSafe
  alias PhoenixKitEcommerce.Catalogue.ShopStatusColumn

  # ============================================================
  # Shape — what `PhoenixKitCatalogue.Extensions.columns/1` accepts
  # (id: binary without ":", label: 0-arity fn, render: 1-arity fn).
  # See `PhoenixKitCatalogue.Extension.column/0`'s typedoc (unreleased
  # branch, read for the contract — not depended on here).
  # ============================================================

  describe "item_columns/0" do
    test "returns exactly one column shaped for the catalogue extension slot" do
      assert [%{id: id, label: label, render: render}] = ShopStatusColumn.item_columns()
      assert is_binary(id)
      refute id == ""
      refute String.contains?(id, ":")
      assert is_function(label, 0)
      assert is_function(render, 1)
    end

    test "label/0 resolves through PhoenixKitEcommerce.Gettext" do
      [%{label: label}] = ShopStatusColumn.item_columns()
      assert label.() == "Shop status"

      Gettext.put_locale(PhoenixKitEcommerce.Gettext, "de")
      assert label.() == "Shop-Status"
    after
      Gettext.put_locale(PhoenixKitEcommerce.Gettext, "en")
    end
  end

  describe "category_columns/0" do
    test "returns exactly one column shaped for the catalogue extension slot" do
      assert [%{id: id, label: label, render: render}] = ShopStatusColumn.category_columns()
      assert is_binary(id)
      refute id == ""
      refute String.contains?(id, ":")
      assert is_function(label, 0)
      assert is_function(render, 1)
    end

    test "label/0 resolves through PhoenixKitEcommerce.Gettext" do
      [%{label: label}] = ShopStatusColumn.category_columns()
      assert label.() == "Shop status"

      Gettext.put_locale(PhoenixKitEcommerce.Gettext, "fr")
      assert label.() == "Statut de la boutique"
    after
      Gettext.put_locale(PhoenixKitEcommerce.Gettext, "en")
    end
  end

  # ============================================================
  # Helpers
  # ============================================================

  defp render_item_cell(record) do
    [%{render: render}] = ShopStatusColumn.item_columns()
    render.(record) |> rendered_to_string()
  end

  defp render_category_cell(record) do
    [%{render: render}] = ShopStatusColumn.category_columns()
    render.(record) |> rendered_to_string()
  end

  defp catalogue_status_attr(html) do
    [_, value] = Regex.run(~r/data-catalogue-status="([^"]*)"/, html)
    value
  end

  defp shop_status_attr(html) do
    [_, value] = Regex.run(~r/data-shop-status="([^"]*)"/, html)
    value
  end

  defp contradiction_attr(html) do
    [_, value] = Regex.run(~r/data-contradiction="([^"]*)"/, html)
    value
  end

  # ============================================================
  # Items — defensive reads of data["ecommerce"]["shop_status"]
  # ============================================================

  describe "items: defensive reads — none may raise, none render a misleading active" do
    test "absent data entirely (bare struct-like map with no :data key)" do
      html = render_item_cell(%{status: "active"})
      assert shop_status_attr(html) == "default"
    end

    test "data present but nil" do
      html = render_item_cell(%{status: "active", data: nil})
      assert shop_status_attr(html) == "default"
    end

    test "data present, absent ecommerce key" do
      html = render_item_cell(%{status: "active", data: %{}})
      assert shop_status_attr(html) == "default"
    end

    test "ecommerce key present but not a map" do
      html = render_item_cell(%{status: "active", data: %{"ecommerce" => "not-a-map"}})
      assert shop_status_attr(html) == "default"
    end

    test "ecommerce map present, absent shop_status key" do
      html = render_item_cell(%{status: "active", data: %{"ecommerce" => %{}}})
      assert shop_status_attr(html) == "default"
    end

    test "shop_status present but non-binary (integer)" do
      html =
        render_item_cell(%{status: "active", data: %{"ecommerce" => %{"shop_status" => 123}}})

      assert shop_status_attr(html) == "default"
    end

    test "shop_status present but non-binary (map)" do
      html =
        render_item_cell(%{status: "active", data: %{"ecommerce" => %{"shop_status" => %{}}}})

      assert shop_status_attr(html) == "default"
    end

    test "shop_status present but non-binary (nil)" do
      html =
        render_item_cell(%{status: "active", data: %{"ecommerce" => %{"shop_status" => nil}}})

      assert shop_status_attr(html) == "default"
    end

    test "shop_status an unrecognized string value is treated like absent (default), not a crash" do
      html =
        render_item_cell(%{status: "active", data: %{"ecommerce" => %{"shop_status" => "bogus"}}})

      assert shop_status_attr(html) == "default"
      assert html =~ "Active"
      assert html =~ "(default)"
    end

    test "catalogue status itself absent/nil normalizes to unknown, never a bare crash" do
      html =
        render_item_cell(%{status: nil, data: %{"ecommerce" => %{"shop_status" => "active"}}})

      assert catalogue_status_attr(html) == "unknown"
      assert shop_status_attr(html) == "active"
    end

    test "catalogue status non-binary normalizes to unknown, does not raise" do
      html =
        render_item_cell(%{status: 42, data: %{"ecommerce" => %{"shop_status" => "active"}}})

      assert catalogue_status_attr(html) == "unknown"
    end
  end

  # ============================================================
  # Items — the corrected warning rule
  # ============================================================

  describe "items: only 'shop explicit active, catalogue not active' warns" do
    test "active/active — agree, visible, no warning" do
      html =
        render_item_cell(%{
          status: "active",
          data: %{"ecommerce" => %{"shop_status" => "active"}}
        })

      refute html =~ "hero-exclamation-triangle"
      assert contradiction_attr(html) == "false"
    end

    test "active/draft — deliberate hold-back, renders plainly, NO warning (was the old bug)" do
      html =
        render_item_cell(%{
          status: "active",
          data: %{"ecommerce" => %{"shop_status" => "draft"}}
        })

      refute html =~ "hero-exclamation-triangle"
      assert contradiction_attr(html) == "false"
      assert shop_status_attr(html) == "draft"
    end

    test "active/archived — deliberate hold-back, no warning" do
      html =
        render_item_cell(%{
          status: "active",
          data: %{"ecommerce" => %{"shop_status" => "archived"}}
        })

      refute html =~ "hero-exclamation-triangle"
      assert contradiction_attr(html) == "false"
    end

    test "active/absent — absent defaults to active (matches catalogue), no warning" do
      html = render_item_cell(%{status: "active", data: %{}})

      refute html =~ "hero-exclamation-triangle"
      assert contradiction_attr(html) == "false"
      assert shop_status_attr(html) == "default"
    end

    test "inactive/draft — agree (both not visible), no warning" do
      html =
        render_item_cell(%{
          status: "inactive",
          data: %{"ecommerce" => %{"shop_status" => "draft"}}
        })

      refute html =~ "hero-exclamation-triangle"
      assert contradiction_attr(html) == "false"
    end

    test "inactive/absent — absent defaults to archived (matches catalogue), no warning" do
      html = render_item_cell(%{status: "inactive", data: %{}})

      refute html =~ "hero-exclamation-triangle"
      assert contradiction_attr(html) == "false"
      assert shop_status_attr(html) == "default"
    end

    test "discontinued/active — WARNS: excluded from listings, reachable by direct link" do
      html =
        render_item_cell(%{
          status: "discontinued",
          data: %{"ecommerce" => %{"shop_status" => "active"}}
        })

      assert html =~ "hero-exclamation-triangle"
      assert contradiction_attr(html) == "true"
    end

    test "inactive/active — WARNS (the other catalogue-non-active value)" do
      html =
        render_item_cell(%{
          status: "inactive",
          data: %{"ecommerce" => %{"shop_status" => "active"}}
        })

      assert html =~ "hero-exclamation-triangle"
      assert contradiction_attr(html) == "true"
    end
  end

  describe "items: exhaustive matrix over the real value sets" do
    # 4 catalogue statuses × 4 shop-status values (nil = absent) = 16
    # rows — every value either domain can actually hold
    # (`ItemCommerce.@statuses`, `Schemas.Item.@statuses`), not a
    # hand-picked subset. Catches the exact class of gap the category
    # side had: a rule modelled on the wrong page's gate silently
    # missing one row.
    test "contradiction fires exactly on shop==active with catalogue!=active, never otherwise" do
      for catalogue_status <- ~w(active inactive discontinued deleted),
          shop_raw <- [nil, "draft", "active", "archived"] do
        data = if shop_raw, do: %{"ecommerce" => %{"shop_status" => shop_raw}}, else: %{}
        html = render_item_cell(%{status: catalogue_status, data: data})

        expected = shop_raw == "active" and catalogue_status != "active"

        assert contradiction_attr(html) == to_string(expected),
               "catalogue=#{inspect(catalogue_status)} shop=#{inspect(shop_raw)}: " <>
                 "expected contradiction=#{expected}, got #{contradiction_attr(html)}"
      end
    end
  end

  # ============================================================
  # Categories — defensive reads
  # ============================================================

  describe "categories: defensive reads — none may raise" do
    test "absent shop_status entirely defaults unconditionally to active" do
      html = render_category_cell(%{status: "active", data: %{}})
      assert shop_status_attr(html) == "default"
      assert html =~ "Active"
      assert html =~ "(default)"
    end

    test "shop_status non-binary is treated like absent" do
      html =
        render_category_cell(%{
          status: "active",
          data: %{"ecommerce" => %{"shop_status" => 1}}
        })

      assert shop_status_attr(html) == "default"
    end

    test "catalogue status non-binary normalizes to unknown, does not raise" do
      html =
        render_category_cell(%{status: nil, data: %{"ecommerce" => %{"shop_status" => "active"}}})

      assert catalogue_status_attr(html) == "unknown"
    end
  end

  # ============================================================
  # Categories — the corrected warning rule
  # ============================================================

  describe "categories: only 'shop active, catalogue deleted' warns" do
    test "active/active — agree, no warning" do
      html =
        render_category_cell(%{
          status: "active",
          data: %{"ecommerce" => %{"shop_status" => "active"}}
        })

      refute html =~ "hero-exclamation-triangle"
      assert contradiction_attr(html) == "false"
    end

    test "active/hidden — deliberate hold-back (owner merged this away), no warning" do
      html =
        render_category_cell(%{
          status: "active",
          data: %{"ecommerce" => %{"shop_status" => "hidden"}}
        })

      refute html =~ "hero-exclamation-triangle"
      assert contradiction_attr(html) == "false"
      assert shop_status_attr(html) == "hidden"
    end

    test "active/unlisted — deliberate (nav hidden, page/items still reachable), no warning" do
      html =
        render_category_cell(%{
          status: "active",
          data: %{"ecommerce" => %{"shop_status" => "unlisted"}}
        })

      refute html =~ "hero-exclamation-triangle"
      assert contradiction_attr(html) == "false"
    end

    test "active/absent — absent defaults to active, agrees with catalogue, no warning" do
      html = render_category_cell(%{status: "active", data: %{}})

      refute html =~ "hero-exclamation-triangle"
      assert contradiction_attr(html) == "false"
    end

    test "deleted/active — WARNS: excluded from listings, reachable by direct link" do
      html =
        render_category_cell(%{
          status: "deleted",
          data: %{"ecommerce" => %{"shop_status" => "active"}}
        })

      assert html =~ "hero-exclamation-triangle"
      assert contradiction_attr(html) == "true"
    end

    test "deleted/absent — WARNS: shop defaults to active unconditionally, catalogue is deleted" do
      html = render_category_cell(%{status: "deleted", data: %{}})

      assert html =~ "hero-exclamation-triangle"
      assert contradiction_attr(html) == "true"
      assert shop_status_attr(html) == "default"
    end

    test "deleted/hidden — agree (both not visible), no warning" do
      html =
        render_category_cell(%{
          status: "deleted",
          data: %{"ecommerce" => %{"shop_status" => "hidden"}}
        })

      refute html =~ "hero-exclamation-triangle"
      assert contradiction_attr(html) == "false"
    end

    test "deleted/unlisted — WARNS: the category page's gate is a block-list of just \"hidden\", so this soft-deleted category is still reachable" do
      # `CatalogCategory.do_mount/3` only redirects on the resolved
      # status literally being "hidden" — "unlisted" (and "active")
      # both fall through to rendering the page. A category rule
      # modelled on the item page's ALLOW-list gate (only "active"
      # passes) missed this: "unlisted" isn't "active" either, so an
      # allow-list-shaped predicate wrongly said "no warning" here.
      html =
        render_category_cell(%{
          status: "deleted",
          data: %{"ecommerce" => %{"shop_status" => "unlisted"}}
        })

      assert html =~ "hero-exclamation-triangle"
      assert contradiction_attr(html) == "true"
    end
  end

  describe "categories: exhaustive matrix over the real value sets" do
    # 2 catalogue statuses × 4 shop-status values (nil = absent) = 8
    # rows — every value either domain can actually hold
    # (`Schemas.Category.@statuses`, `CategoryCommerce.@statuses`).
    test "contradiction fires exactly on shop!=hidden with catalogue==deleted, never otherwise" do
      for catalogue_status <- ~w(active deleted),
          shop_raw <- [nil, "active", "unlisted", "hidden"] do
        data = if shop_raw, do: %{"ecommerce" => %{"shop_status" => shop_raw}}, else: %{}
        html = render_category_cell(%{status: catalogue_status, data: data})

        effective_shop = shop_raw || "active"
        expected = effective_shop != "hidden" and catalogue_status == "deleted"

        assert contradiction_attr(html) == to_string(expected),
               "catalogue=#{inspect(catalogue_status)} shop=#{inspect(shop_raw)}: " <>
                 "expected contradiction=#{expected}, got #{contradiction_attr(html)}"
      end
    end
  end

  # ============================================================
  # Badge colours (MINOR review note: core's status_badge/1 collapses
  # unlisted/hidden/unknown to the same grey — this column picks its
  # own explicit classes instead of editing core)
  # ============================================================

  describe "badge colours are distinct per status, not all grey" do
    test "unlisted and hidden render different badge classes from each other" do
      unlisted =
        render_category_cell(%{
          status: "active",
          data: %{"ecommerce" => %{"shop_status" => "unlisted"}}
        })

      hidden =
        render_category_cell(%{
          status: "active",
          data: %{"ecommerce" => %{"shop_status" => "hidden"}}
        })

      assert unlisted =~ "badge-warning"
      assert hidden =~ "badge-error"
      refute unlisted =~ "badge-error"
      refute hidden =~ "badge-warning"
    end
  end

  # ============================================================
  # Contradiction hint translation
  # ============================================================

  describe "the contradiction hint" do
    test "resolves through PhoenixKitEcommerce.Gettext" do
      record = %{status: "discontinued", data: %{"ecommerce" => %{"shop_status" => "active"}}}

      Gettext.put_locale(PhoenixKitEcommerce.Gettext, "de")
      html = render_item_cell(record)
      assert html =~ ~s(title="Der Shop meldet diesen Eintrag als aktiv)
    after
      Gettext.put_locale(PhoenixKitEcommerce.Gettext, "en")
    end
  end

  # ============================================================
  # No record-scoped id attribute
  # ============================================================

  describe "no record-scoped id attribute (renders in table AND card DOM in one page load)" do
    test "the item cell never carries an id= attribute" do
      html =
        render_item_cell(%{
          status: "discontinued",
          data: %{"ecommerce" => %{"shop_status" => "active"}}
        })

      refute html =~ ~s( id=")
    end

    test "the category cell never carries an id= attribute" do
      html =
        render_category_cell(%{
          status: "deleted",
          data: %{"ecommerce" => %{"shop_status" => "active"}}
        })

      refute html =~ ~s( id=")
    end
  end

  defp rendered_to_string(%Phoenix.LiveView.Rendered{} = rendered) do
    rendered |> HtmlSafe.to_iodata() |> IO.iodata_to_binary()
  end
end
