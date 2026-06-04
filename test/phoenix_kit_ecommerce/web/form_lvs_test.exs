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
end
