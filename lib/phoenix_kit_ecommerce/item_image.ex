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
  returns an image URL or `nil`. Without it, or when it returns anything
  else or raises, the line shows the module's own icon.
  """

  require Logger

  @doc "The URL of the line's picture, or `nil` for the module's icon."
  @spec url(map()) :: String.t() | nil
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
      Logger.warning("Shop: item image fallback failed: #{Exception.message(error)}")
      nil
  end
end
