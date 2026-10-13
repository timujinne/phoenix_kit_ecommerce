defmodule PhoenixKitEcommerce.Web.CategoryOptionsHardeningTest do
  @moduledoc """
  A category's options are one JSON list on the category row. Editing keeps
  an option's key (the form's key input is disabled, so a browser submits
  none), and every action changes the list as it is stored now — never the
  copy the page loaded.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Options

  defp text(key, label \\ nil), do: %{"key" => key, "label" => label || key, "type" => "text"}

  defp keys(category), do: Enum.map(Options.get_category_options(category.uuid), & &1["key"])

  setup %{conn: conn} do
    {:ok, category} =
      Shop.create_category(%{"name" => %{"en" => "Opts #{System.unique_integer([:positive])}"}})

    {:ok, category} =
      Options.update_category_options(category, [text("mounting"), text("finish")])

    {:ok, conn: put_test_scope(conn, fake_scope()), category: category}
  end

  describe "editing in the form" do
    test "the key stays when the browser omits the disabled input", ctx do
      %{conn: conn, category: category} = ctx
      {:ok, view, _html} = live(conn, "/en/admin/shop/categories/#{category.uuid}/edit")

      render_click(view, "show_edit_opt_modal", %{"key" => "mounting"})

      render_submit(view, "save_category_option", %{
        "option" => %{"label" => "Installation", "type" => "text"}
      })

      assert keys(category) == ["mounting", "finish"]

      mounting =
        Enum.find(Options.get_category_options(category.uuid), &(&1["key"] == "mounting"))

      assert mounting["label"] == "Installation"
    end
  end

  describe "a page loaded before someone else changed the options" do
    setup %{conn: conn, category: category} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/categories/#{category.uuid}/edit")

      # A second admin adds an option after this page loaded.
      {:ok, _} = Options.add_category_option(category, text("warranty"))

      %{view: view}
    end

    test "deleting keeps the added option", %{view: view, category: category} do
      render_click(view, "delete_category_option", %{"key" => "finish"})

      assert keys(category) == ["mounting", "warranty"]
    end

    test "reordering keeps it, after the named ones", %{view: view, category: category} do
      render_hook(view, "reorder_category_options", %{"ordered_ids" => ["finish", "mounting"]})

      assert keys(category) == ["finish", "mounting", "warranty"]

      assert Enum.map(Options.get_category_options(category.uuid), & &1["position"]) ==
               [0, 1, 2]
    end

    test "adding keeps it", %{view: view, category: category} do
      render_click(view, "show_add_opt_modal", %{})

      render_submit(view, "save_category_option", %{
        "option" => %{"key" => "engraving", "label" => "Engraving", "type" => "text"}
      })

      assert keys(category) == ["mounting", "finish", "warranty", "engraving"]
    end
  end

  describe "Options.transform_category_options/2" do
    test "hands the function the stored list and writes what it returns", %{category: category} do
      stale = %{category | option_schema: []}

      assert {:ok, 2} =
               Options.transform_category_options(stale, fn current ->
                 {:ok, current ++ [text("extra")], length(current)}
               end)

      assert keys(category) == ["mounting", "finish", "extra"]
    end

    test "an unchanged answer writes nothing and an error rolls back", %{category: category} do
      assert {:ok, :same} =
               Options.transform_category_options(category, fn _ -> {:unchanged, :same} end)

      assert {:error, :nope} =
               Options.transform_category_options(category, fn _ -> {:error, :nope} end)

      assert keys(category) == ["mounting", "finish"]
    end

    test "a list that fails validation is refused", %{category: category} do
      assert {:error, _} =
               Options.transform_category_options(category, fn _ -> {:ok, [%{"key" => "x"}]} end)

      assert keys(category) == ["mounting", "finish"]
    end

    test "a deleted category is reported, not raised", %{category: category} do
      {:ok, _} = Shop.delete_category(category)

      assert {:error, :category_not_found} =
               Options.transform_category_options(category, fn current -> {:ok, current} end)
    end
  end
end
