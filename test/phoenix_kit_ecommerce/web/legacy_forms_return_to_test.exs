defmodule PhoenixKitEcommerce.Web.LegacyFormsReturnToTest do
  @moduledoc """
  The storefront's admin Edit link, and the admin lists, open the editor
  with `?return_to=<page the operator came from>` (the catalogue forms
  honour it). The shop's own product and category forms must honour it
  too: save, or cancel, and land back on that page instead of on a fixed
  list. Only a local path counts — anything else is ignored, so the
  parameter can't be turned into an open redirect.
  """

  use PhoenixKitEcommerce.LiveCase, async: true

  alias Phoenix.LiveView.Utils, as: LiveUtils
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Test.Endpoint

  setup %{conn: conn} do
    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  defp category! do
    {:ok, category} = Shop.create_category(%{"name" => %{"en" => "Return Cat"}})
    category
  end

  defp product! do
    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Return Product"},
        "slug" => %{"en" => "return-product-#{System.unique_integer([:positive])}"},
        "price" => Decimal.new("10.00"),
        "status" => "active"
      })

    product
  end

  defp save_category(view) do
    view
    |> form(~s(form.space-y-6), %{"category" => %{"name" => "Renamed"}})
    |> render_submit()
  end

  defp save_product(view) do
    view
    |> form(~s(form.space-y-6), %{"product" => %{"title" => "Renamed"}})
    |> render_submit()
  end

  defp flash_of(token),
    do: LiveUtils.verify_flash(Endpoint, token)

  defp return_to(path), do: "?return_to=" <> URI.encode_www_form(path)

  describe "category form" do
    test "saving lands back on return_to", %{conn: conn} do
      category = category!()

      {:ok, view, _html} =
        live(conn, "/en/admin/shop/categories/#{category.uuid}/edit" <> return_to("/en/shop/x"))

      assert {:error, {:live_redirect, %{to: "/en/shop/x"}}} = save_category(view)
    end

    test "creating a category lands back on return_to", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/categories/new" <> return_to("/en/shop/x"))

      assert {:error, {:live_redirect, %{to: "/en/shop/x"}}} = save_category(view)
    end

    test "creating a category without return_to still lands on the list", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/categories/new")

      list_path = Routes.path("/admin/shop/categories")

      assert {:error, {:live_redirect, %{to: ^list_path}}} =
               save_category(view)
    end

    test "the saved flash rides along on the redirect", %{conn: conn} do
      category = category!()

      {:ok, view, _html} =
        live(conn, "/en/admin/shop/categories/#{category.uuid}/edit" <> return_to("/en/shop/x"))

      assert {:error, {:live_redirect, %{to: "/en/shop/x", flash: token}}} = save_category(view)
      assert flash_of(token)["info"] == "Category updated"
    end

    test "return_to survives validation and a failed submit", %{conn: conn} do
      category = category!()

      {:ok, view, _html} =
        live(conn, "/en/admin/shop/categories/#{category.uuid}/edit" <> return_to("/en/shop/x"))

      html =
        view
        |> form(~s(form.space-y-6), %{"category" => %{"name" => "Typing"}})
        |> render_change()

      assert html =~ ~s(href="/en/shop/x")

      html =
        view
        |> form(~s(form.space-y-6), %{"category" => %{"name" => ""}})
        |> render_submit()

      assert is_binary(html)
      assert html =~ ~s(href="/en/shop/x")
      assert {:error, {:live_redirect, %{to: "/en/shop/x"}}} = save_category(view)
    end

    test "cancel and the header back arrow lead to return_to", %{conn: conn} do
      category = category!()

      {:ok, _view, html} =
        live(conn, "/en/admin/shop/categories/#{category.uuid}/edit" <> return_to("/en/shop/x"))

      assert html =~ ~s(href="/en/shop/x")
      refute html =~ ~s(href="#{Routes.path("/admin/shop/categories")}")
    end

    test "without return_to, saving still lands on the categories list", %{conn: conn} do
      category = category!()
      {:ok, view, html} = live(conn, "/en/admin/shop/categories/#{category.uuid}/edit")

      assert html =~ ~s(href="#{Routes.path("/admin/shop/categories")}")

      list_path = Routes.path("/admin/shop/categories")

      assert {:error, {:live_redirect, %{to: ^list_path}}} =
               save_category(view)
    end

    test "a return_to that is not a local path is ignored", %{conn: conn} do
      category = category!()

      for bad <- [
            "https://evil.example/x",
            "//evil.example/x",
            "/\\evil.example",
            "/ok\\evil.example",
            "/%09/evil.example",
            "javascript:1"
          ] do
        {:ok, view, html} =
          live(conn, "/en/admin/shop/categories/#{category.uuid}/edit" <> return_to(bad))

        refute html =~ "evil.example"

        list_path = Routes.path("/admin/shop/categories")

        assert {:error, {:live_redirect, %{to: ^list_path}}} =
                 save_category(view)
      end
    end
  end

  describe "product form" do
    test "saving an edit lands back on return_to", %{conn: conn} do
      product = product!()

      {:ok, view, _html} =
        live(conn, "/en/admin/shop/products/#{product.uuid}/edit" <> return_to("/en/shop/x"))

      assert {:error, {:live_redirect, %{to: "/en/shop/x"}}} = save_product(view)
    end

    test "the saved flash rides along on the redirect", %{conn: conn} do
      product = product!()

      {:ok, view, _html} =
        live(conn, "/en/admin/shop/products/#{product.uuid}/edit" <> return_to("/en/shop/x"))

      assert {:error, {:live_redirect, %{to: "/en/shop/x", flash: token}}} = save_product(view)
      assert flash_of(token)["info"] == "Product updated"
    end

    test "return_to survives validation and a failed submit", %{conn: conn} do
      product = product!()

      {:ok, view, _html} =
        live(conn, "/en/admin/shop/products/#{product.uuid}/edit" <> return_to("/en/shop/x"))

      html =
        view
        |> form(~s(form.space-y-6), %{"product" => %{"title" => "Typing"}})
        |> render_change()

      assert html =~ ~s(href="/en/shop/x")

      html =
        view
        |> form(~s(form.space-y-6), %{"product" => %{"title" => ""}})
        |> render_submit()

      assert html =~ ~s(href="/en/shop/x")
      assert {:error, {:live_redirect, %{to: "/en/shop/x"}}} = save_product(view)
    end

    test "creating a product is unchanged: it opens the new product, return_to or not",
         %{conn: conn} do
      for query <- ["", return_to("/en/shop/x")] do
        {:ok, view, _html} = live(conn, "/en/admin/shop/products/new" <> query)

        assert {:error, {:live_redirect, %{to: to}}} =
                 view
                 |> form(~s(form.space-y-6), %{
                   "product" => %{
                     "title" => "Fresh #{System.unique_integer([:positive])}",
                     "price" => "5.00"
                   }
                 })
                 |> render_submit()

        assert to =~ ~r|^#{Regex.escape(Routes.path("/admin/shop/products"))}/[0-9a-f-]{36}$|
      end
    end

    test "cancel and the header back arrow lead to return_to", %{conn: conn} do
      product = product!()

      {:ok, _view, html} =
        live(conn, "/en/admin/shop/products/#{product.uuid}/edit" <> return_to("/en/shop/x"))

      assert html =~ ~s(href="/en/shop/x")
      refute html =~ ~s(href="#{Routes.path("/admin/shop/products")}")
    end

    test "without return_to, saving an edit stays on the form", %{conn: conn} do
      product = product!()
      {:ok, view, html} = live(conn, "/en/admin/shop/products/#{product.uuid}/edit")

      assert html =~ ~s(href="#{Routes.path("/admin/shop/products")}")
      assert save_product(view) =~ "Product updated"
    end

    test "a return_to that is not a local path is ignored", %{conn: conn} do
      product = product!()

      for bad <- [
            "https://evil.example/x",
            "//evil.example/x",
            "/\\evil.example",
            "/ok\\evil.example",
            "/%09/evil.example"
          ] do
        {:ok, view, html} =
          live(conn, "/en/admin/shop/products/#{product.uuid}/edit" <> return_to(bad))

        refute html =~ "evil.example"
        assert save_product(view) =~ "Product updated"
      end
    end
  end

  describe "the Edit link's return_to, end to end" do
    alias PhoenixKitEcommerce.Web.Helpers

    # What `admin_edit_path/3` appends is what the form has to accept: the
    # value is query-encoded on the way out and decoded by the router on the
    # way in, and it must come out the other side as the very same path.
    @return_paths ["/en/shop/product/foo", "/en/shop?a=1&b=2", "/shop/category/x y"]

    defp return_to_of(url) do
      %URI{query: query} = URI.parse(url)
      URI.decode_query(query)["return_to"]
    end

    # The test router serves the admin under the default `/en` prefix (and
    # without one), so for another locale the link is checked as built (its
    # prefix, and the `return_to` it carries) and the form is then opened at
    # the `/en` form of the same URL: the query string is what the form reads,
    # whatever locale segment the host's router matched. The prefix is what
    # `Routes.path/1` puts before `/admin/shop` for the locale: none on a core
    # that drops it for a single-language site.
    for locale <- ["en", "ru", "en-US"], kind <- [:item, :category] do
      test "#{kind} form, locale #{locale}: save lands exactly on the original path", %{
        conn: conn
      } do
        locale = unquote(locale)
        Gettext.put_locale(PhoenixKitWeb.Gettext, locale)

        record = if unquote(kind) == :item, do: product!(), else: category!()
        prefix = String.replace_suffix(Routes.path("/admin/shop"), "/admin/shop", "")

        for original <- @return_paths do
          url = Helpers.admin_edit_path(unquote(kind), record, original)

          assert String.starts_with?(url, prefix <> "/admin/shop/")
          assert return_to_of(url) == original
          assert Helpers.safe_return_to(return_to_of(url)) == original

          {:ok, view, _html} = live(conn, String.replace_prefix(url, prefix, "/en"))

          result =
            if unquote(kind) == :item, do: save_product(view), else: save_category(view)

          assert {:error, {:live_redirect, %{to: ^original}}} = result
        end
      end
    end
  end

  describe "Helpers.safe_return_to/1" do
    alias PhoenixKitEcommerce.Web.Helpers

    test "keeps a local path, query included" do
      assert Helpers.safe_return_to("/en/shop/product/x?page=2") == "/en/shop/product/x?page=2"
    end

    test "drops everything that could leave the host or is not a path" do
      for bad <- [
            "https://evil.example",
            "//evil.example",
            "/\\evil.example",
            "javascript:alert(1)",
            "relative/path",
            "/ok\nSet-Cookie: x=1",
            "/\t/evil.example",
            "/ok\r",
            "/ok\\evil.example",
            "/%09/x",
            "/ok/%09/x",
            "/ok\0",
            "/ok\x7F",
            "",
            nil,
            123
          ] do
        assert Helpers.safe_return_to(bad) == nil, "accepted #{inspect(bad)}"
      end
    end
  end
end
