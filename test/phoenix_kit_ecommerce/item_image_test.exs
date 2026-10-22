defmodule PhoenixKitEcommerce.ItemImageTest do
  use ExUnit.Case, async: false

  alias PhoenixKitEcommerce.ItemImage

  defmodule Art do
    def item_url(%{metadata: %{"catalogue_item_uuid" => uuid}}, prefix),
      do: "#{prefix}/#{uuid}.svg"

    def item_url(_item, _prefix), do: nil
    def broken(_item), do: raise("no art")
    def junk(_item), do: :not_a_url
  end

  setup do
    previous = Application.get_env(:phoenix_kit_ecommerce, :item_image_fallback)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit_ecommerce, :item_image_fallback, previous),
        else: Application.delete_env(:phoenix_kit_ecommerce, :item_image_fallback)
    end)

    Application.delete_env(:phoenix_kit_ecommerce, :item_image_fallback)
    :ok
  end

  defp line(image), do: %{product_image: image, metadata: %{"catalogue_item_uuid" => "abc"}}

  test "the product photo comes first" do
    Application.put_env(:phoenix_kit_ecommerce, :item_image_fallback, {Art, :item_url, ["/art"]})
    assert ItemImage.url(line("/file/x/medium/t")) == "/file/x/medium/t"
  end

  test "without a photo, the host app's image, or nil when none is configured" do
    assert ItemImage.url(line(nil)) == nil
    assert ItemImage.url(line("")) == nil

    Application.put_env(:phoenix_kit_ecommerce, :item_image_fallback, {Art, :item_url, ["/art"]})
    assert ItemImage.url(line(nil)) == "/art/abc.svg"
    assert ItemImage.url(%{product_image: nil, metadata: %{}}) == nil
  end

  test "a fallback that raises or answers junk leaves the icon" do
    Application.put_env(:phoenix_kit_ecommerce, :item_image_fallback, {Art, :broken, []})
    assert ItemImage.url(line(nil)) == nil

    Application.put_env(:phoenix_kit_ecommerce, :item_image_fallback, {Art, :junk, []})
    assert ItemImage.url(line(nil)) == nil

    Application.put_env(:phoenix_kit_ecommerce, :item_image_fallback, :not_an_mfa)
    assert ItemImage.url(line(nil)) == nil
  end
end
