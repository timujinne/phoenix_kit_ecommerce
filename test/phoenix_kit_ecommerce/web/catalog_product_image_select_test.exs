defmodule PhoenixKitEcommerce.Web.CatalogProductImageSelectTest do
  @moduledoc """
  The gallery events carry a file uuid (or a URL) chosen by an anonymous
  visitor. Only what this product's own gallery rendered may be selected:
  anything else must neither be signed into a storage URL nor crash the page.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  import PhoenixKitEcommerce.DataCase, only: [fixture_user: 0]

  alias PhoenixKit.Modules.Storage
  alias PhoenixKitEcommerce, as: Shop

  defp lang do
    PhoenixKitEcommerce.SlugResolver.normalize_language_public(
      PhoenixKitEcommerce.Translations.default_language()
    )
  end

  defp store(user_uuid) do
    tmp = Path.join(System.tmp_dir!(), "img_select_#{System.unique_integer([:positive])}.png")
    bytes = "not really a png #{System.unique_integer([:positive])}"
    File.write!(tmp, bytes)

    {:ok, file} =
      Storage.store_file(tmp,
        filename: "pic.png",
        content_type: "image/png",
        size_bytes: byte_size(bytes),
        user_uuid: user_uuid
      )

    File.rm(tmp)
    file.uuid
  end

  setup %{conn: conn} do
    user = fixture_user()
    own = store(user.uuid)
    foreign = store(user.uuid)
    n = System.unique_integer([:positive])

    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Shelf #{n}", lang() => "Shelf #{n}"},
        "slug" => %{lang() => "img-select-#{n}"},
        "price" => Decimal.new("40.00"),
        "status" => "active",
        "currency" => "USD",
        "image_uuids" => [own],
        "images" => [%{"src" => "https://cdn.example.com/own-#{n}.png"}]
      })

    {:ok, view, _html} = live(conn, "/shop/product/#{product.slug[lang()]}")
    %{view: view, own: own, foreign: foreign, n: n}
  end

  test "a file outside the product's gallery is never signed", %{view: view, foreign: foreign} do
    html = render_click(view, "select_storage_image", %{"uuid" => foreign})

    refute html =~ foreign
  end

  test "the product's own file is still selectable", %{view: view, own: own} do
    assert render_click(view, "select_storage_image", %{"uuid" => own}) =~ own
  end

  test "a value that is not a uuid, or no value, leaves the page standing", %{view: view} do
    assert render_click(view, "select_storage_image", %{"uuid" => "not-a-uuid"}) =~ "Shelf"
    assert render_click(view, "select_storage_image", %{}) =~ "Shelf"
    assert render_click(view, "select_image", %{}) =~ "Shelf"
  end

  test "a URL the gallery did not render is not put on the page", %{view: view} do
    html = render_click(view, "select_image", %{"url" => "https://evil.example.com/x.png"})

    refute html =~ "evil.example.com"
  end

  test "a URL from the product's own image list is selectable", %{view: view, n: n} do
    url = "https://cdn.example.com/own-#{n}.png"

    refute render(view) =~ url
    assert render_click(view, "select_image", %{"url" => url}) =~ url
  end

  test "a refresh keeps the thumbnail the visitor picked", %{conn: conn} do
    user = fixture_user()
    [first, second] = [store(user.uuid), store(user.uuid)]
    n = System.unique_integer([:positive])

    {:ok, product} =
      Shop.create_product(%{
        "title" => %{"en" => "Gallery #{n}", lang() => "Gallery #{n}"},
        "slug" => %{lang() => "gallery-#{n}"},
        "price" => Decimal.new("40.00"),
        "status" => "active",
        "currency" => "USD",
        "image_uuids" => [first, second]
      })

    {:ok, view, _html} = live(conn, "/shop/product/#{product.slug[lang()]}")
    thumb = fn uuid -> view |> element(~s(button[phx-value-uuid="#{uuid}"])) |> render() end

    assert thumb.(first) =~ "border-primary"
    render_click(view, "select_storage_image", %{"uuid" => second})
    assert thumb.(second) =~ "border-primary"

    # Any product broadcast re-reads the product; the pick must survive it.
    send(view.pid, {:product_updated, %{uuid: product.uuid}})
    _ = render(view)

    assert thumb.(second) =~ "border-primary"
    refute thumb.(first) =~ "border-primary"
  end
end
