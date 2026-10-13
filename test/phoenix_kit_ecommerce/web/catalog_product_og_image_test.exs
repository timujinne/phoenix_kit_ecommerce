defmodule PhoenixKitEcommerce.Web.CatalogProductOgImageTest do
  @moduledoc """
  The product page hands core's root layout an `og.image`: the layout
  renders `og:image` / `twitter:image` and switches `twitter:card` to
  `summary_large_image` from that one key, so the assign is the contract.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitEcommerce, as: Shop

  defp lang do
    PhoenixKitEcommerce.SlugResolver.normalize_language_public(
      PhoenixKitEcommerce.Translations.default_language()
    )
  end

  defp t(text), do: %{"en" => text, lang() => text}

  defp stored_image do
    {:ok, file} =
      Storage.create_file(%{
        original_file_name: "probe.png",
        file_name: "probe.png",
        mime_type: "image/png",
        file_type: "image",
        ext: "png",
        file_checksum: "c#{System.unique_integer([:positive])}",
        user_file_checksum: "u#{System.unique_integer([:positive])}",
        size: 100,
        status: "active",
        user_uuid: PhoenixKitEcommerce.DataCase.fixture_user().uuid
      })

    {:ok, _} =
      Storage.create_file_instance(%{
        file_uuid: file.uuid,
        variant_name: "large",
        file_name: "probe-large.png",
        mime_type: "image/png",
        ext: "png",
        checksum: "i#{System.unique_integer([:positive])}",
        size: 100
      })

    file.uuid
  end

  defp create_product(attrs) do
    {:ok, product} =
      Shop.create_product(
        Map.merge(
          %{
            "title" => t("OG Probe"),
            "slug" => %{lang() => "og-probe-#{System.unique_integer([:positive])}"},
            "price" => Decimal.new("10.00"),
            "status" => "active",
            "currency" => "USD",
            "requires_shipping" => false
          },
          attrs
        )
      )

    product
  end

  defp og(view), do: :sys.get_state(view.pid).socket.assigns.og

  test "the product page assigns the featured image as an absolute og image", %{conn: conn} do
    image = stored_image()
    product = create_product(%{"featured_image_uuid" => image})

    {:ok, view, _html} = live(conn, "/shop/product/#{product.slug[lang()]}")

    assert og(view).image ==
             Routes.base_url() <> URLSigner.signed_url(image, "large")

    assert og(view).image_alt == "OG Probe"
  end

  test "a product without images assigns no og image", %{conn: conn} do
    product = create_product(%{})

    {:ok, view, _html} = live(conn, "/shop/product/#{product.slug[lang()]}")

    refute Map.has_key?(og(view), :image)
  end
end
