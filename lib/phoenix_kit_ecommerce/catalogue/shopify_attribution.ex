defmodule PhoenixKitEcommerce.Catalogue.ShopifyAttribution do
  @moduledoc """
  Attribution and write scope for the writes of the Shopify sync into
  catalogue items.

  Two things go with every catalogue write the sync makes:

    * `log_metadata: %{"via" => "shopify_sync"}` and `logged_data_paths`, so
      the item's change log says who wrote a value and shows the `data`
      sub-paths that changed (until now a sync write was logged without its
      `data` diff and without a name);
    * `data_owned_paths`, the `data` sub-paths this write changes. The sync
      reads an item, builds a whole new `data` map and writes it back; without
      the paths a value written in between by the admin API (or by anyone) is
      overwritten by the stale copy. With them the catalogue keeps the fresh
      value of every path the sync did not change (last write wins **per
      field**).

  The paths are not listed by hand. They are the paths whose value differs
  between the `data` the item had and the `data` the writer built, found by
  `changed_paths/2`, so a field a writer starts to write later is covered
  without touching this module.

  Options the running catalogue does not know are ignored by it, so passing
  them is safe against an older catalogue. `data_owned_paths` is the one that
  changes **what** is stored (a path removed from the new `data` has to be
  written as an explicit `nil`), so it is only used when
  `PhoenixKitEcommerce.API.Gate.catalogue_api_ready?/0` says the catalogue
  honours it. When it is used it is always sent: a write that changes no
  `data` path sends `[]`, which owns nothing, so the item's current `data`
  is kept whole (the common price-only or title-only sync).
  """

  alias PhoenixKitEcommerce.API.Gate

  @via %{"via" => "shopify_sync"}

  # A path is followed through nested maps down to this depth and is a leaf
  # below it: `["ecommerce", "shopify", "image_ids"]` is written as a whole.
  # Under `price_modifiers` it is followed one level further, to the single
  # option price, because the admin API owns single option prices
  # (`["ecommerce", "price_modifiers", option, value]`): a sync that owned a
  # whole option would overwrite a price the API stored in it after the sync
  # read the item.
  @max_depth 3
  @modifiers_depth 4

  @doc "The metadata every sync write carries."
  @spec metadata() :: %{String.t() => String.t()}
  def metadata, do: @via

  @doc """
  `{data, opts}` for one catalogue write: `old` is the `data` the item has,
  `new` the `data` the writer built, `opts` the options the call already
  passes (`:actor_uuid`, ...) plus two of this module's:

    * `:intended` - the `data` the writer meant to write, when `new` carries
      more than that. `ItemCommerce.cast/2` fills every field the sync did not
      touch with its schema default; those defaults are in `new` (the stored
      value, as before) but they are not changes, and a path the sync did not
      mean to write must not be owned by it. Defaults to `new`.
    * `:owned?` - whether the catalogue honours `:data_owned_paths`; by
      default it asks the gate.
  """
  @spec prepare(map() | nil, map() | nil, keyword()) :: {map(), keyword()}
  def prepare(old, new, opts \\ []) do
    {intended, opts} = Keyword.pop(opts, :intended)
    {owned?, opts} = Keyword.pop_lazy(opts, :owned?, &Gate.catalogue_api_ready?/0)

    old = old || %{}
    new = new || %{}
    paths = changed_paths(old, intended || new)
    logged = Enum.filter(paths, &match?(["ecommerce" | _], &1))
    base = Keyword.merge(opts, log_metadata: @via, logged_data_paths: logged)

    if owned? do
      # `paths == []` is sent too: it owns nothing, so the fresh row's `data`
      # survives whole instead of being replaced by the reader's stale copy.
      {with_deletions(new, paths), Keyword.put(base, :data_owned_paths, paths)}
    else
      {new, base}
    end
  end

  @doc "Options for a write that carries no `data` change (a position, a category)."
  @spec metadata_opts(keyword()) :: keyword()
  def metadata_opts(base_opts \\ []), do: Keyword.put(base_opts, :log_metadata, @via)

  @doc """
  The paths whose value differs between `old` and `new`, as lists of keys.
  Maps are followed down to paths of three keys, and of four under
  `["ecommerce", "price_modifiers"]`, where a missing (`nil`) old side is
  followed too when the new side is a map. Any other value that is not a map
  on both sides is a leaf.
  """
  @spec changed_paths(map(), map()) :: [[String.t()]]
  def changed_paths(old, new), do: walk(old, new, [], 1)

  defp walk(old, new, prefix, depth) do
    (Map.keys(old) ++ Map.keys(new))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(fn key ->
      before = Map.get(old, key)
      current = Map.get(new, key)
      path = prefix ++ [key]

      cond do
        before == current ->
          []

        descend?(before, current, path, depth) ->
          walk(before || %{}, current, path, depth + 1)

        true ->
          [path]
      end
    end)
  end

  # Both sides are maps, or the path is under `price_modifiers` and only the
  # new side is: a product (or option) with no option prices yet gets its first
  # ones from the sync, and listing it as a whole would overwrite an option
  # price the API stored in it after the sync read the item.
  defp descend?(before, current, path, depth) when is_map(current) do
    depth < max_depth(path) and (is_map(before) or (is_nil(before) and modifiers_path?(path)))
  end

  defp descend?(_before, _current, _path, _depth), do: false

  defp modifiers_path?(["ecommerce", "price_modifiers" | _]), do: true
  defp modifiers_path?(_path), do: false

  defp max_depth(["ecommerce", "price_modifiers" | _]), do: @modifiers_depth
  defp max_depth(_path), do: @max_depth

  # A path the new `data` no longer has is written as an explicit `nil`: for
  # an owned path, absence means "keep the fresh value", `nil` means delete.
  defp with_deletions(new, paths) do
    Enum.reduce(paths, new, fn path, acc ->
      if present?(acc, path), do: acc, else: put_nil(acc, path)
    end)
  end

  defp present?(data, [key]), do: is_map(data) and Map.has_key?(data, key)

  defp present?(data, [key | rest]) when is_map(data) do
    case Map.fetch(data, key) do
      {:ok, child} -> present?(child, rest)
      :error -> false
    end
  end

  defp present?(_data, _path), do: false

  defp put_nil(data, [key]), do: Map.put(data, key, nil)

  defp put_nil(data, [key | rest]) do
    case Map.get(data, key) do
      %{} = child -> Map.put(data, key, put_nil(child, rest))
      _ -> data
    end
  end
end
