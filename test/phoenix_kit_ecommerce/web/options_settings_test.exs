defmodule PhoenixKitEcommerce.Web.OptionsSettingsTest do
  @moduledoc """
  The global options are one JSON list in one row. Every action on the
  settings page changes exactly one thing in the list as it is stored at
  that moment — never the list the page loaded — and leaves an audit row.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitEcommerce.Options

  @page "/en/admin/shop/settings/options"

  # `color` carries plain values (what a CSV import auto-adds to); `size`
  # prices its values; `note` is the bystander the page acts on.
  defp plain(key),
    do: %{"key" => key, "label" => key, "type" => "select", "options" => ["a", "b"]}

  defp priced(key, modifiers) do
    %{
      "key" => key,
      "label" => key,
      "type" => "select",
      "options" => Map.keys(modifiers),
      "affects_price" => true,
      "modifier_type" => "fixed",
      "price_modifiers" => modifiers
    }
  end

  defp text(key), do: %{"key" => key, "label" => key, "type" => "text"}

  defp stored(key), do: Options.get_global_option_by_key(key)
  defp keys, do: Enum.map(Options.get_global_options(), & &1["key"])

  setup %{conn: conn} do
    {:ok, _} =
      Options.update_global_options([
        plain("color"),
        priced("size", %{"a" => "0", "b" => "2"}),
        text("note")
      ])

    scope = fake_scope()

    {:ok, conn: put_test_scope(conn, scope), actor: scope.user.uuid}
  end

  defp assert_others_changes_kept do
    assert stored("color")["options"] == ["a", "b", "c"]
    assert stored("size")["options"] == ["a", "b", "c"]
    assert stored("size")["price_modifiers"]["c"] == "9"
    assert "finish" in keys()
  end

  describe "a page loaded before someone else changed the list" do
    setup %{conn: conn} do
      {:ok, view, _html} = live(conn, @page)

      # What a CSV import with auto-add and a second admin do meanwhile.
      {:ok, _} = Options.add_value_to_global_option("color", "c")

      {:ok, _} =
        Options.update_global_option(
          "size",
          priced("size", %{"a" => "0", "b" => "2", "c" => "9"})
        )

      {:ok, _} = Options.add_global_option(text("finish"))

      %{view: view}
    end

    test "toggling keeps the added values, their modifier and the added option", %{view: view} do
      render_click(view, "toggle_enabled", %{"key" => "note"})

      assert stored("note")["enabled"] == false
      assert_others_changes_kept()
    end

    test "reordering keeps them too, the unseen option after the named ones", %{view: view} do
      render_hook(view, "reorder_options", %{"ordered_ids" => ["note", "size", "color"]})

      assert keys() == ["note", "size", "color", "finish"]
      assert Enum.map(Options.get_global_options(), & &1["position"]) == [0, 1, 2, 3]
      assert_others_changes_kept()
    end

    test "deleting another option keeps them", %{view: view} do
      render_click(view, "delete_option", %{"key" => "note"})

      refute "note" in keys()
      assert_others_changes_kept()
    end

    test "editing the very option that gained a value keeps that value", %{view: view} do
      render_click(view, "show_edit_modal", %{"key" => "size"})

      render_submit(view, "save_option", %{
        "option" => %{
          "key" => "size",
          "label" => "Size",
          "type" => "select",
          "options" => %{"0" => "a", "1" => "b"},
          "affects_price" => "true",
          "modifier_type" => "fixed",
          "price_modifiers" => %{"a" => "1", "b" => "2"}
        }
      })

      size = stored("size")
      assert size["label"] == "Size"
      assert size["price_modifiers"] == %{"a" => "1", "b" => "2", "c" => "9"}
      assert_others_changes_kept()
    end
  end

  describe "editing a page-fresh option" do
    test "the key stays: a browser does not submit the disabled key input", %{conn: conn} do
      {:ok, view, _html} = live(conn, @page)
      render_click(view, "show_edit_modal", %{"key" => "color"})

      # No "key" in the payload, and a label that slugifies onto another key.
      render_submit(view, "save_option", %{
        "option" => %{"label" => "Note", "type" => "select", "options" => %{"0" => "a"}}
      })

      assert stored("color")["label"] == "Note"
      assert Enum.count(keys(), &(&1 == "note")) == 1
      assert "color" in keys()
    end

    test "a value the editor removed stays removed", %{conn: conn} do
      {:ok, view, _html} = live(conn, @page)
      render_click(view, "show_edit_modal", %{"key" => "color"})

      render_submit(view, "save_option", %{
        "option" => %{
          "key" => "color",
          "label" => "color",
          "type" => "select",
          "options" => %{"0" => "a"}
        }
      })

      assert stored("color")["options"] == ["a"]
    end
  end

  describe "two pages open at once" do
    test "each one's change lands; neither erases the other's", %{conn: conn} do
      {:ok, first, _html} = live(conn, @page)
      {:ok, second, _html} = live(conn, @page)

      render_click(first, "toggle_enabled", %{"key" => "color"})
      render_click(second, "toggle_enabled", %{"key" => "size"})

      assert stored("color")["enabled"] == false
      assert stored("size")["enabled"] == false
    end
  end

  describe "the audit trail" do
    test "create, update, toggle, reorder and delete each leave a row", ctx do
      %{conn: conn, actor: actor} = ctx
      {:ok, view, _html} = live(conn, @page)

      render_click(view, "show_add_modal", %{})

      render_submit(view, "save_option", %{
        "option" => %{"key" => "finish", "label" => "Finish", "type" => "text"}
      })

      assert_activity_logged("shop.global_option_created",
        actor_uuid: actor,
        metadata_has: %{"key" => "finish"}
      )

      render_click(view, "show_edit_modal", %{"key" => "finish"})

      render_submit(view, "save_option", %{
        "option" => %{"key" => "finish", "label" => "Surface", "type" => "text"}
      })

      assert_activity_logged("shop.global_option_updated",
        actor_uuid: actor,
        metadata_has: %{"key" => "finish"}
      )

      render_click(view, "toggle_enabled", %{"key" => "finish"})

      assert_activity_logged("shop.global_option_toggled",
        actor_uuid: actor,
        metadata_has: %{"key" => "finish", "enabled" => false}
      )

      render_hook(view, "reorder_options", %{
        "ordered_ids" => ["finish", "color", "size", "note"]
      })

      assert_activity_logged("shop.global_options_reordered",
        actor_uuid: actor,
        metadata_has: %{"count" => 4}
      )

      render_click(view, "delete_option", %{"key" => "finish"})

      assert_activity_logged("shop.global_option_deleted",
        actor_uuid: actor,
        metadata_has: %{"key" => "finish"}
      )
    end

    test "a refused save is recorded as an attempt and shown as a message", ctx do
      %{conn: conn, actor: actor} = ctx
      {:ok, view, _html} = live(conn, @page)

      render_click(view, "show_add_modal", %{})

      html =
        render_submit(view, "save_option", %{
          "option" => %{"key" => "color", "label" => "Again", "type" => "text"}
        })

      assert html =~ "already exists"

      assert_activity_logged("shop.global_option_created",
        actor_uuid: actor,
        metadata_has: %{"key" => "color", "db_pending" => true}
      )
    end

    test "toggling an option deleted elsewhere says so instead of crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, @page)
      {:ok, _} = Options.remove_global_option("size")

      assert render_click(view, "toggle_enabled", %{"key" => "size"}) =~
               "That option no longer exists."
    end
  end
end
