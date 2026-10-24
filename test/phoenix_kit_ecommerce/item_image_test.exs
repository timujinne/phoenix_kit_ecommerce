defmodule PhoenixKitEcommerce.ItemImageTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PhoenixKitEcommerce.ItemImage

  defmodule Art do
    def item_url(%{metadata: %{"catalogue_item_uuid" => uuid}}, prefix),
      do: "#{prefix}/#{uuid}.svg"

    def item_url(_item, _prefix), do: nil
    def broken(_item), do: raise("no art")
    def stuck(_item), do: exit(:timeout)
    def thrown(_item), do: throw(:no_art)
    def junk(_item), do: :not_a_url
    def blank(_item), do: ""
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

  test "a fallback that raises, exits or throws leaves the icon and logs a warning" do
    for {function, fragment} <- [
          broken: "no art",
          stuck: "exit: :timeout",
          thrown: "throw: :no_art"
        ] do
      Application.put_env(:phoenix_kit_ecommerce, :item_image_fallback, {Art, function, []})

      log = capture_log(fn -> assert ItemImage.url(line(nil)) == nil end)

      assert log =~ "[Shop] item image fallback"
      assert log =~ "#{inspect(Art)}.#{function}"
      assert log =~ fragment
    end
  end

  test "a fallback that answers junk or an empty string leaves the icon" do
    Application.put_env(:phoenix_kit_ecommerce, :item_image_fallback, {Art, :junk, []})
    assert ItemImage.url(line(nil)) == nil

    Application.put_env(:phoenix_kit_ecommerce, :item_image_fallback, {Art, :blank, []})
    assert ItemImage.url(line(nil)) == nil
  end

  test "a missing module or function leaves the icon" do
    Application.put_env(:phoenix_kit_ecommerce, :item_image_fallback, {Art, :no_such_fun, []})
    capture_log(fn -> assert ItemImage.url(line(nil)) == nil end)

    Application.put_env(
      :phoenix_kit_ecommerce,
      :item_image_fallback,
      {PhoenixKitEcommerce.NoSuchArt, :item_url, []}
    )

    capture_log(fn -> assert ItemImage.url(line(nil)) == nil end)
  end

  test "a malformed configuration leaves the icon" do
    for config <- [
          :not_an_mfa,
          {Art, :item_url},
          {Art, :item_url, "/art"},
          {"Art", :item_url, []}
        ] do
      Application.put_env(:phoenix_kit_ecommerce, :item_image_fallback, config)
      assert ItemImage.url(line(nil)) == nil
    end
  end

  test "a value that is not a cart line has no picture" do
    assert ItemImage.url(nil) == nil
  end
end
