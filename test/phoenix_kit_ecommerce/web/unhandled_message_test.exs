defmodule PhoenixKitEcommerce.Web.UnhandledMessageTest do
  @moduledoc """
  A LiveView that receives messages (PubSub, a timer, a child component)
  ignores one it has no clause for instead of crashing the session, and what
  it notes about it is the message's shape, never its contents.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKitEcommerce.Web.Helpers

  setup %{conn: conn} do
    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  for {name, path} <- [
        {"the dashboard", "/en/admin/shop"},
        {"the product form", "/en/admin/shop/products/new"},
        {"the category form", "/en/admin/shop/categories/new"},
        {"the Shopify sync page", "/en/admin/shop/shopify-sync"}
      ] do
    test "#{name} survives a message it does not know", %{conn: conn} do
      enable_shopify!()
      {:ok, view, _html} = live(conn, unquote(path))

      send(view.pid, {:something_nobody_handles, %{secret: "value"}})
      send(view.pid, :stray_atom)

      assert is_binary(render(view))
    end
  end

  describe "message_shape/1" do
    test "names a tagged tuple by its tag and arity, without its contents" do
      assert Helpers.message_shape({:cart_updated, %{email: "a@b.c"}}) == "{:cart_updated, _}"
      assert Helpers.message_shape({:item_added, %{}, %{}}) == "{:item_added, _, _}"
      assert Helpers.message_shape(:refresh_stats) == ":refresh_stats"
    end

    test "says only what kind of thing anything else is" do
      assert Helpers.message_shape(%URI{host: "secret.example.com"}) == "%URI{}"
      assert Helpers.message_shape(%{email: "a@b.c"}) == "a map"
      assert Helpers.message_shape(["a@b.c"]) == "a list"
      assert Helpers.message_shape({"a@b.c", 1}) == "a 2-tuple"
      assert Helpers.message_shape("a@b.c") == "a term"
    end
  end
end
