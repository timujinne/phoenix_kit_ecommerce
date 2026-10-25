defmodule PhoenixKitEcommerce.ItemImage do
  @moduledoc """
  The picture of a cart line: its product photo, or, when the product has
  none, the image the host app offers in its place.

  A host app with placeholder art of its own (one per product kind, say)
  points the module at a function that builds its URL:

      config :phoenix_kit_ecommerce, :item_image_fallback, {MyAppWeb.Art, :item_url, []}

  It is called with the line (a `PhoenixKitEcommerce.CartItem`, with
  `product_uuid` and `metadata`; a catalogue-backed product's uuid is
  `metadata["catalogue_item_uuid"]`) followed by the extra arguments, and
  returns an image URL or `nil`. Without it, when the configuration is not
  an `{module, function, args}` tuple, or when the function returns anything
  else, raises, exits or throws, the line shows the module's own icon.

  The function runs during render, once for every line without a photo, so
  it should be a quick, pure URL builder: no queries, no calls to other
  processes. The URL it returns is placed in `<img src>` as it is, so it must
  be one the host trusts or builds itself, as with the `product_image`
  snapshot it stands in for.
  """

  require Logger

  @doc "The URL of the line's picture, or `nil` for the module's icon."
  @spec url(term()) :: String.t() | nil
  def url(%{product_image: url}) when is_binary(url) and url != "", do: url
  def url(item) when is_map(item), do: fallback(item)
  def url(_item), do: nil

  defp fallback(item) do
    case Application.get_env(:phoenix_kit_ecommerce, :item_image_fallback) do
      {module, function, args} when is_atom(module) and is_atom(function) and is_list(args) ->
        call(module, function, [item | args])

      _ ->
        nil
    end
  end

  defp call(module, function, args) do
    case apply(module, function, args) do
      url when is_binary(url) and url != "" -> url
      _ -> nil
    end
  rescue
    error ->
      Logger.warning(
        "[Shop] item image fallback #{inspect(module)}.#{function} failed: " <>
          Exception.message(error)
      )

      nil
  catch
    kind, reason ->
      Logger.warning(
        "[Shop] item image fallback #{inspect(module)}.#{function} #{kind}: " <>
          inspect(reason, limit: 5)
      )

      nil
  end
end
