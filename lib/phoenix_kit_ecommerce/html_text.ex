defmodule PhoenixKitEcommerce.HtmlText do
  @moduledoc """
  Plain-text extraction from HTML.

  Shared between the Shopify CSV importer (`Import.ProductTransformer`) and
  the Shopify Admin API sync (`Shopify.ProductDiff`), so both derive a
  product's `description` from `body_html` the same way.
  """

  @default_limit 500

  @doc """
  Strips tags from `html`, collapses whitespace, and truncates to `limit`
  characters (default #{@default_limit}). Returns `nil` for `nil`/`""` input.
  """
  @spec extract_description(String.t() | nil, pos_integer()) :: String.t() | nil
  def extract_description(html, limit \\ @default_limit)
  def extract_description(nil, _limit), do: nil
  def extract_description("", _limit), do: nil

  def extract_description(html, limit) when is_binary(html) do
    html
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, limit)
  end
end
