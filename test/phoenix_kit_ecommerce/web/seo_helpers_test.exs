defmodule PhoenixKitEcommerce.Web.SEOHelpersResolverStub do
  @moduledoc false
  def host("fr"), do: "shop.example.fr"
  def host("fr-FR"), do: "shop.example.fr"
  def host(_), do: nil
end

defmodule PhoenixKitEcommerce.Web.SEOHelpersTest do
  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitEcommerce.Category
  alias PhoenixKitEcommerce.Product
  alias PhoenixKitEcommerce.ProductSource.Catalogue.View
  alias PhoenixKitEcommerce.Web.SEOHelpers
  alias PhoenixKitEcommerce.Web.SEOHelpersResolverStub

  setup do
    Settings.update_setting("languages_enabled", "true")

    Settings.update_json_setting("languages_config", %{
      "languages" => [
        %{"code" => "en-US", "name" => "English", "is_default" => true, "is_enabled" => true},
        %{"code" => "fr", "name" => "French", "is_default" => false, "is_enabled" => true},
        %{"code" => "de", "name" => "German", "is_default" => false, "is_enabled" => true}
      ]
    })

    on_exit(fn ->
      Application.delete_env(:phoenix_kit, :canonical_host_resolver)
      Settings.update_setting("languages_enabled", "false")
    end)

    :ok
  end

  defp product(slug_map) do
    %Product{
      slug: slug_map,
      title: %{"en-US" => "Vase", "fr" => "Le Vase"},
      seo_title: %{},
      seo_description: %{},
      description: %{}
    }
  end

  test "hreflang only includes languages present in the RAW slug map" do
    # de has no slug — SlugResolver would silently fall back, hreflang must not
    p = product(%{"en-US" => "vase", "fr" => "le-vase"})

    codes = SEOHelpers.product_seo(p, "en-US").hreflang_links |> Enum.map(& &1.code)

    assert "en" in codes
    assert "fr" in codes
    refute "de" in codes
  end

  test "hreflang is empty for a single-language slug map" do
    p = product(%{"en-US" => "vase"})
    assert SEOHelpers.product_seo(p, "en-US").hreflang_links == []
  end

  test "resolver host lands the language on its home domain, prefix stripped" do
    Application.put_env(
      :phoenix_kit,
      :canonical_host_resolver,
      {SEOHelpersResolverStub, :host}
    )

    p = product(%{"en-US" => "vase", "fr" => "le-vase"})
    links = SEOHelpers.product_seo(p, "en-US").hreflang_links
    fr = Enum.find(links, &(&1.code == "fr"))

    assert fr.url =~ "https://shop.example.fr/"
    refute fr.url =~ "/fr/"
  end

  test "resolver-nil canonical never doubles the locale prefix" do
    p = product(%{"en-US" => "vase", "fr" => "le-vase"})
    seo = SEOHelpers.product_seo(p, "fr")

    refute seo.canonical_url =~ "/fr/fr/"
  end

  test "seo_title wins over title for page_title and og" do
    p = %{product(%{"en-US" => "vase"}) | seo_title: %{"en-US" => "Buy Vase Online"}}
    seo = SEOHelpers.product_seo(p, "en-US")

    assert seo.page_title == "Buy Vase Online"
    assert seo.og.title == "Buy Vase Online"
  end

  describe "share image" do
    setup do
      %{user: fixture_user()}
    end

    # A Storage file carrying exactly the named variants — the URL scheme
    # only asks which instances exist, so no real bytes are needed.
    defp stored_image(user, variants) do
      {:ok, file} =
        Storage.create_file(%{
          original_file_name: "vase.png",
          file_name: "vase.png",
          mime_type: "image/png",
          file_type: "image",
          ext: "png",
          file_checksum: "c#{System.unique_integer([:positive])}",
          user_file_checksum: "u#{System.unique_integer([:positive])}",
          size: 100,
          status: "active",
          user_uuid: user.uuid
        })

      for variant <- variants do
        {:ok, _} =
          Storage.create_file_instance(%{
            file_uuid: file.uuid,
            variant_name: variant,
            file_name: "vase-#{variant}.png",
            mime_type: "image/png",
            ext: "png",
            checksum: "i#{System.unique_integer([:positive])}",
            size: 100
          })
      end

      file.uuid
    end

    defp with_images(featured, gallery) do
      %{product(%{"en-US" => "vase"}) | featured_image_uuid: featured, image_uuids: gallery}
    end

    defp absolute(path), do: Routes.base_url() <> path

    test "the featured image's large variant, absolute, with the title as alt", %{user: user} do
      featured = stored_image(user, ["original", "large"])
      other = stored_image(user, ["original", "large"])

      og = SEOHelpers.product_seo(with_images(featured, [other, featured]), "en-US").og

      assert og.image == absolute(URLSigner.signed_url(featured, "large"))
      assert og.image =~ ~r{^https?://}
      assert og.image_alt == "Vase"
    end

    test "falls back to the first gallery image without a featured one", %{user: user} do
      first = stored_image(user, ["original", "large"])
      second = stored_image(user, ["original", "large"])

      og = SEOHelpers.product_seo(with_images(nil, [first, second]), "en-US").og

      assert og.image == absolute(URLSigner.signed_url(first, "large"))
    end

    test "falls back to the original variant when no large one exists", %{user: user} do
      featured = stored_image(user, ["original"])

      og = SEOHelpers.product_seo(with_images(featured, []), "en-US").og

      assert og.image == absolute(URLSigner.signed_url(featured, "original"))
    end

    test "a product without images keeps an og map with no image" do
      og = SEOHelpers.product_seo(with_images(nil, []), "en-US").og

      refute Map.has_key?(og, :image)
      refute Map.has_key?(og, :image_alt)
    end

    test "a uuid with no stored file, or a malformed one, yields no image" do
      og = SEOHelpers.product_seo(with_images(Ecto.UUID.generate(), []), "en-US").og
      refute Map.has_key?(og, :image)

      og = SEOHelpers.product_seo(with_images("not-a-uuid", []), "en-US").og
      refute Map.has_key?(og, :image)
    end

    test "the image sits on the language's canonical host, path untouched", %{user: user} do
      Application.put_env(
        :phoenix_kit,
        :canonical_host_resolver,
        {SEOHelpersResolverStub, :host}
      )

      featured = stored_image(user, ["original", "large"])
      p = %{with_images(featured, []) | slug: %{"en-US" => "vase", "fr" => "le-vase"}}

      og = SEOHelpers.product_seo(p, "fr").og

      assert og.image == "https://shop.example.fr" <> URLSigner.signed_url(featured, "large")
      assert og.image_alt == "Le Vase"
    end

    # The catalogue adapter maps `data["featured_image_uuid"]` and
    # `data["media_order"]` onto the same two fields, so a catalogue product
    # reaches the share image through the same path as a legacy one.
    @tag :catalogue
    test "a catalogue-sourced product: featured, else first of media_order", %{user: user} do
      featured = stored_image(user, ["original", "large"])
      first = stored_image(user, ["original", "large"])

      item = fn data ->
        struct(PhoenixKitCatalogue.Schemas.Item, %{
          uuid: Ecto.UUID.generate(),
          name: "Vase",
          description: nil,
          base_price: Decimal.new("10.00"),
          status: "active",
          category_uuid: nil,
          slug: %{"en-US" => "vase"},
          data:
            Map.merge(%{"_primary_language" => "en-US", "en-US" => %{"_name" => "Vase"}}, data)
        })
      end

      view = fn data ->
        View.product_view(item.(data),
          base_currency: "USD",
          languages: ["en-US"]
        )
      end

      og =
        SEOHelpers.product_seo(
          view.(%{"featured_image_uuid" => featured, "media_order" => [first]}),
          "en-US"
        ).og

      assert og.image == absolute(URLSigner.signed_url(featured, "large"))

      og = SEOHelpers.product_seo(view.(%{"media_order" => [first, featured]}), "en-US").og
      assert og.image == absolute(URLSigner.signed_url(first, "large"))
    end

    test "a category's own image, else its featured product's", %{user: user} do
      own = stored_image(user, ["original", "large"])
      featured = stored_image(user, ["original", "large"])

      category = %Category{
        slug: %{"en-US" => "vases"},
        name: %{"en-US" => "Vases"},
        image_uuid: own,
        featured_product: %Product{featured_image_uuid: featured}
      }

      og = SEOHelpers.category_seo(category, "en-US").og
      assert og.image == absolute(URLSigner.signed_url(own, "large"))
      assert og.image_alt == "Vases"

      og = SEOHelpers.category_seo(%{category | image_uuid: nil}, "en-US").og
      assert og.image == absolute(URLSigner.signed_url(featured, "large"))
    end

    test "a category without an image keeps an og map with no image" do
      category = %Category{
        slug: %{"en-US" => "vases"},
        name: %{"en-US" => "Vases"},
        image_uuid: nil,
        featured_product: nil
      }

      refute Map.has_key?(SEOHelpers.category_seo(category, "en-US").og, :image)
    end
  end
end
