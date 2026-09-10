defmodule PhoenixKitEcommerce.NamePrefix do
  @moduledoc """
  Hides a redundant vocabulary prefix from storefront-displayed category
  and product names — "3D Printed Costume Masks" -> "Costume Masks" —
  driven by the `shop_name_prefixes` setting: a comma-separated list of
  prefixes (a shop may have more than one), empty by default so no
  existing install changes behaviour.

  ## Display-time only

  No STORED value is ever rewritten — not a product/category's own
  name, and not a cart or order line's snapshotted `product_title`/
  `"name"`. Category and product names in this shop come from Shopify
  collection/product titles and are re-synced from Shopify on every sync
  run — a persisted rename would either be silently overwritten on the
  next sync, or would have to be excluded from sync, which then hides
  real upstream renames. A cart/order line's snapshot exists so a later
  price or catalogue change can't retroactively alter what the shopper
  was shown (the same principle as its snapshotted price); rewriting
  that stored string would defeat the snapshot for no reason, since a
  pure display-time strip achieves the same visible result.

  `strip/1` is a pure string function with no persistence and no
  Shopify reach, called from two places: `PhoenixKitEcommerce.
  Translations.get_display/3` (for a live `%Product{}`/`%Category{}`
  read on a storefront page) and directly, on a cart/order line's
  snapshotted title string, from the storefront pages that render one
  (cart, checkout, order confirmation, the customer's own order
  history) — see `Translations.get_display/3`'s doc for why the
  snapshot itself stays untouched while its on-page rendering doesn't.
  Nothing in the Shopify diff/apply path
  (`PhoenixKitEcommerce.Shopify.ProductDiff`,
  `PhoenixKitEcommerce.Shopify.CollectionSync`), an admin edit form, or
  any write path calls it — all of those read or persist the raw stored
  value exactly as before.

  A library cannot ship one shop's vocabulary, so this is a setting
  rather than a hardcoded literal — read through this wrapper, never
  directly, tolerating a malformed stored value by falling back to the
  safe default (no prefixes, i.e. no stripping) rather than raising.
  """

  alias PhoenixKit.Settings

  @setting "shop_name_prefixes"
  @default ""
  @separators ["-", "–", "—", "|", ":"]

  @doc "The setting key, so the settings UI and tests do not re-spell it."
  @spec setting_key() :: String.t()
  def setting_key, do: @setting

  @doc """
  The separators `strip/1` consumes after a matched prefix, so a test can
  iterate the real list rather than a second, independently-maintained
  copy that could silently drop an entry the source still recognizes.
  """
  @spec separators() :: [String.t()]
  def separators, do: @separators

  @doc "The configured prefixes to hide, trimmed and with blanks dropped."
  @spec prefixes() :: [String.t()]
  def prefixes do
    @setting
    |> read()
    |> parse()
  end

  @doc """
  Strips the LONGEST configured prefix that matches the START of `name`,
  case-insensitively, consuming any following whitespace and then an
  optional `-`/`–`/`—`/`|`/`:` separator plus its whitespace.

  Longest, not first-configured: with `"3D, 3D Printed"` configured, a
  first-match-wins rule would strip only `"3D"` from `"3D Printed Costume
  Masks"` and leave the dangling fragment `"Printed Costume Masks"`. There
  is no shop-visible upside to first-match, so the more specific (longer)
  prefix always wins regardless of configuration order.

  Leaves `name` untouched when:
    * no configured prefix matches
    * the prefix match isn't followed by whitespace, a separator, or the
      end of the string (so "3D Printedstuff" is never mangled into
      "stuff")
    * stripping would leave nothing (a category literally named "3D
      Printed" keeps its full name rather than rendering blank)

  Any non-binary (`nil` included) passes through unchanged.
  """
  @spec strip(any()) :: any()
  def strip(name) when is_binary(name) do
    case prefixes() do
      [] -> name
      configured -> strip_longest(name, configured) || name
    end
  end

  def strip(other), do: other

  defp strip_longest(name, prefixes) do
    prefixes
    |> Enum.map(&{&1, strip_one(name, &1)})
    |> Enum.reject(fn {_prefix, result} -> is_nil(result) end)
    |> case do
      [] ->
        nil

      matches ->
        matches |> Enum.max_by(fn {prefix, _result} -> String.length(prefix) end) |> elem(1)
    end
  end

  defp strip_one(_name, ""), do: nil

  defp strip_one(name, prefix) do
    prefix_len = String.length(prefix)

    if String.starts_with?(String.downcase(name), String.downcase(prefix)) do
      rest = String.slice(name, prefix_len..-1//1)
      if boundary?(rest), do: presence(consume_separator(rest))
    end
  end

  defp boundary?(""), do: true

  defp boundary?(rest) do
    case String.next_grapheme(rest) do
      {char, _} -> whitespace?(char) or char in @separators
      nil -> true
    end
  end

  defp whitespace?(char), do: String.trim(char) == ""

  defp consume_separator(rest) do
    trimmed = String.trim_leading(rest)

    case String.next_grapheme(trimmed) do
      {char, remainder} when char in @separators -> String.trim_leading(remainder)
      _ -> trimmed
    end
  end

  defp presence(stripped) do
    if String.trim(stripped) == "", do: nil, else: stripped
  end

  # Settings reads are ETS-cached but can still fail on a cache miss with
  # an unreachable database. Fail to the SAFE default (no prefixes, i.e.
  # every name renders exactly as stored), never to a guessed stripping.
  defp read(key) do
    Settings.get_setting_cached(key, @default)
  rescue
    _ -> @default
  catch
    :exit, _ -> @default
  end

  defp parse(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse(_), do: []
end
