defmodule PhoenixKitEcommerce.Catalogue.SetSlug do
  @moduledoc """
  Normalizes a Shopify option name (e.g. `"Cup Color"`, `"Größe"`) into the
  bare attribute-set slug `Writer.sync_variants/2` looks the catalogue set
  up by (`"catalogue_set_" <> slug` is the blueprint's own `:name`).

  Pure, ASCII-folding-free — a SUPERSET of the app's
  `Decor3dprint.CatalogueMigration.Mapping.set_slug/1` algorithm
  (downcase, collapse `_+`, trim `_`), generalized to start from an
  arbitrary raw label instead of an already-underscored key: this
  version ALSO collapses every run of non `[a-z0-9]` characters (not
  only `_`) to a single `_` — the app's own migrated keys
  (`main_color`, `cup_color`, `basket_main_color`) never contain any
  other punctuation, so both algorithms agree on them, but they diverge
  on option names with hyphens or accents (`"Größe"` mangles to
  `"gr_e"` here — see `set_slug_test.exs`), which the app's version
  never has to handle at all.
  """

  @doc """
  Normalizes `name` to a slug: downcase, every run of characters outside
  `[a-z0-9]` becomes one `_`, leading/trailing `_` trimmed.

      iex> PhoenixKitEcommerce.Catalogue.SetSlug.normalise("Cup Color")
      "cup_color"

      iex> PhoenixKitEcommerce.Catalogue.SetSlug.normalise("  Size! ")
      "size"
  """
  @spec normalise(String.t()) :: String.t()
  def normalise(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end
end
