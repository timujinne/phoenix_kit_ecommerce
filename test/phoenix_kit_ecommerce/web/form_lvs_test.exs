defmodule PhoenixKitEcommerce.Web.FormLvsTest do
  @moduledoc """
  LiveView tests for shop admin form pages that were migrated to the
  PhoenixKit core form components (`<.input>`/`<.select>`/`<.textarea>`).

  The key assertion is that an invalid `validate` event renders the inline
  error inside the core component's `<.error>` — which only happens when the
  LV sets `:action` on the changeset and keeps `:form` in sync via
  `assign_form/2`. This proves the wiring, not just that the template
  compiles.
  """

  use PhoenixKitEcommerce.LiveCase, async: true

  alias PhoenixKitEcommerce, as: Shop

  setup %{conn: conn} do
    scope = fake_scope()
    {:ok, conn: put_test_scope(conn, scope)}
  end

  describe "ShippingMethodForm validate errors" do
    test "renders inline error for blank required name on validate", %{conn: conn} do
      {:ok, view, html} = live(conn, "/en/admin/shop/shipping/new")

      # No errors on a fresh form (changeset has no :action yet).
      refute html =~ "can&#39;t be blank"

      rendered =
        view
        |> form("form", %{"shipping_method" => %{"name" => "", "price" => "5.00"}})
        |> render_change()

      # Core <.input> renders the translated changeset error inline once
      # :action is set on the changeset by the validate handler.
      assert rendered =~ "can&#39;t be blank"
    end
  end

  describe "CategoryForm validate errors" do
    test "renders inline error for negative position on validate", %{conn: conn} do
      {:ok, view, html} = live(conn, "/en/admin/shop/categories/new")

      refute html =~ "must be greater than or equal to"

      rendered =
        view
        |> form(~s(form.space-y-6), %{
          "category" => %{"name" => "Tools", "position" => "-1"}
        })
        |> render_change()

      # `position` is a non-translatable scalar migrated to core <.input>;
      # the inline error proves @form is kept in sync via assign_form/2 and
      # :action is set on validate.
      assert rendered =~ "must be greater than or equal to"
    end
  end

  describe "CategoryForm parent_uuid select (migrated to core <.select>)" do
    test "renders prompt and changeset-backed options", %{conn: conn} do
      {:ok, _parent} = Shop.create_category(%{"name" => %{"en" => "Furniture"}})

      {:ok, _view, html} = live(conn, "/en/admin/shop/categories/new")

      # core <.select> emits name="category[parent_uuid]" and keeps the prompt
      assert html =~ ~s(name="category[parent_uuid]")
      assert html =~ "No parent (root category)"
      # options built from Shop.category_options() still render
      assert html =~ "Furniture"
    end

    test "preserves the current selection on edit", %{conn: conn} do
      {:ok, parent} = Shop.create_category(%{"name" => %{"en" => "Parent Cat"}})

      {:ok, child} =
        Shop.create_category(%{"name" => %{"en" => "Child Cat"}, "parent_uuid" => parent.uuid})

      {:ok, _view, html} = live(conn, "/en/admin/shop/categories/#{child.uuid}/edit")

      # options_for_select marks the persisted parent_uuid as selected
      assert html =~ ~r/<option[^>]*selected[^>]*value="#{parent.uuid}"/
    end
  end

  describe "ProductForm category_uuid select (migrated to core <.select>)" do
    test "renders prompt and changeset-backed category options", %{conn: conn} do
      {:ok, _cat} = Shop.create_category(%{"name" => %{"en" => "Gadgets"}})

      {:ok, _view, html} = live(conn, "/en/admin/shop/products/new")

      assert html =~ ~s(name="product[category_uuid]")
      assert html =~ "No category"
      assert html =~ "Gadgets"
    end
  end

  describe "ProductForm validate errors" do
    test "renders inline error for negative compare-at price on validate", %{conn: conn} do
      {:ok, view, html} = live(conn, "/en/admin/shop/products/new")

      refute html =~ "must be greater than or equal to"

      rendered =
        view
        |> form(~s(form.space-y-6), %{
          "product" => %{"title" => "Widget", "price" => "10.00", "compare_at_price" => "-1"}
        })
        |> render_change()

      # `compare_at_price` is a non-translatable scalar migrated to core
      # <.input>; the inline error proves @form is kept in sync via
      # assign_form/2 and :action is set on validate.
      assert rendered =~ "must be greater than or equal to"
    end
  end
end
